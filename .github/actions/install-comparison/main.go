// Command compare reports whether each root's provider and backend settings
// let it be planned.
//
// Provider and backend settings decide where credentials are sent. The only
// exceptions are settings listed as safe. So the check takes each provider and
// backend block a root uses, and sets aside its safe settings. What is left
// must match a block on the default branch, or be empty.
//
// A `terraform_remote_state` data source runs a backend too, with the settings
// in its `config`. So it counts as a backend block.
//
// Files are read with the same HCL library that Terraform uses. A value counts
// as a literal only if HCL can work it out with no variables and no functions.
//
// Inputs come from the environment. For each root, it writes the reasons why
// the root cannot be planned yet. A root with no reasons can be planned.
//
// Run as `compare roots`, it instead prints the roots under $CODE, as a JSON
// list of paths relative to it.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
	ctyjson "github.com/zclconf/go-cty/cty/json"
)

const defaultHost = "registry.terraform.io"

// A block that decides where credentials go.
type block struct {
	subject string // a provider's source address, or "backend TYPE", or "cloud"
	label   string // how to name it in a message
	body    map[string]any
}

type unreadable struct{ reason string }

func (u unreadable) Error() string { return u.reason }

func address(source string) string {
	parts := strings.Split(strings.ToLower(source), "/")
	if len(parts) == 2 {
		parts = append([]string{defaultHost}, parts...)
	}
	return strings.Join(parts, "/")
}

// parseSafe reads `namespace/type: setting ...` or `backend TYPE: setting ...`
// lines.
func parseSafe(text string) map[string]map[string]bool {
	safe := map[string]map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		subject, names, _ := strings.Cut(strings.TrimSpace(line), ":")
		subject = strings.Join(strings.Fields(subject), " ")
		if subject == "" {
			continue
		}
		if !strings.HasPrefix(subject, "backend ") {
			subject = address(subject)
		}
		if safe[subject] == nil {
			safe[subject] = map[string]bool{}
		}
		for _, name := range strings.Fields(names) {
			safe[subject][name] = true
		}
	}
	return safe
}

// literal is a value that HCL could work out on its own. Anything else is kept
// as its source text, and marked as an expression.
type literal struct {
	Value json.RawMessage `json:"value,omitempty"`
	Expr  string          `json:"expression,omitempty"`
}

func value(expr hclsyntax.Expression, src []byte) literal {
	v, diags := expr.Value(nil)
	if !diags.HasErrors() && v.IsWhollyKnown() {
		if out, err := ctyjson.Marshal(v, v.Type()); err == nil {
			return literal{Value: out}
		}
	}
	return literal{Expr: string(expr.Range().SliceBytes(src))}
}

// contents turns a block's body into a form that can be compared. Nested
// blocks keep the order they were written in, because order can matter to a
// provider.
func contents(body *hclsyntax.Body, src []byte) map[string]any {
	out := map[string]any{}
	for name, attr := range body.Attributes {
		out[name] = value(attr.Expr, src)
	}
	for _, b := range body.Blocks {
		key := "block " + b.Type
		nested, _ := out[key].([]any)
		out[key] = append(nested, map[string]any{"labels": b.Labels, "body": contents(b.Body, src)})
	}
	return out
}

func hasExpression(v any) bool {
	switch v := v.(type) {
	case literal:
		return v.Expr != ""
	case map[string]any:
		for _, x := range v {
			if hasExpression(x) {
				return true
			}
		}
	case []any:
		for _, x := range v {
			if hasExpression(x) {
				return true
			}
		}
	}
	return false
}

// The block types Terraform reads at the top of a configuration file. A file
// with any other type is not passed, because that block could hold a
// provider, a backend or a data source that the check does not look for.
var knownTypes = map[string]bool{
	"terraform": true, "provider": true, "variable": true, "locals": true,
	"output": true, "resource": true, "data": true, "ephemeral": true,
	"module": true, "moved": true, "import": true, "removed": true,
	"check": true, "action": true,
}

// The top-level keys that a file in the JSON syntax may have and still pass.
// The others can hold a provider, a backend or a data source, and the JSON
// syntax is not compared.
var comparableJSON = map[string]bool{
	"//": true, "variable": true, "locals": true, "output": true,
	"resource": true, "ephemeral": true, "module": true, "moved": true,
	"import": true, "removed": true, "action": true,
}

func isRemoteState(b *hclsyntax.Block) bool {
	return b.Type == "data" && len(b.Labels) == 2 && b.Labels[0] == "terraform_remote_state"
}

// isOverride reports whether Terraform reads a file as an override file.
// Terraform merges an override file's blocks into the blocks they override.
func isOverride(path string) bool {
	name := strings.TrimSuffix(filepath.Base(path), ".json")
	return name == "override.tf" || strings.HasSuffix(name, "_override.tf")
}

// remoteState turns a `terraform_remote_state` data source into the backend
// block it runs.
func remoteState(b *hclsyntax.Block, src []byte) block {
	label := fmt.Sprintf("data.terraform_remote_state.%s", b.Labels[1])
	attrs := b.Body.Attributes
	backend, ok := attrs["backend"]
	if !ok {
		return block{"remote state", label, map[string]any{"backend": literal{Expr: "(missing)"}}}
	}
	name, diags := backend.Expr.Value(nil)
	if diags.HasErrors() || !name.IsWhollyKnown() || name.IsNull() || !name.Type().Equals(cty.String) {
		return block{"remote state", label, map[string]any{"backend": value(backend.Expr, src)}}
	}
	subject := "backend " + name.AsString()
	label += fmt.Sprintf(" (backend %q)", name.AsString())

	config, ok := attrs["config"]
	if !ok {
		return block{subject, label, map[string]any{}}
	}
	v, diags := config.Expr.Value(nil)
	if diags.HasErrors() || !v.IsWhollyKnown() || v.IsNull() || !(v.Type().IsObjectType() || v.Type().IsMapType()) {
		return block{subject, label, map[string]any{"config": value(config.Expr, src)}}
	}
	// Each key of `config` is a setting, as an attribute of a backend block
	// would be.
	body := map[string]any{}
	for it := v.ElementIterator(); it.Next(); {
		k, x := it.Element()
		out, err := ctyjson.Marshal(x, x.Type())
		if err != nil {
			body[k.AsString()] = literal{Expr: "(unreadable)"}
			continue
		}
		body[k.AsString()] = literal{Value: out}
	}
	return block{subject, label, body}
}

// blocks reads every provider and backend block in one module.
func blocks(directory string) ([]block, error) {
	jsonFiles, _ := filepath.Glob(filepath.Join(directory, "*.tf.json"))
	for _, path := range jsonFiles {
		var doc map[string]json.RawMessage
		src, err := os.ReadFile(path)
		if err != nil || json.Unmarshal(src, &doc) != nil {
			return nil, unreadable{filepath.Base(path) + " could not be read"}
		}
		// Any data source counts, not only `terraform_remote_state`. A name
		// in JSON can be written with escapes, so the raw text cannot be
		// searched for it.
		for key := range doc {
			if !comparableJSON[key] {
				return nil, unreadable{filepath.Base(path) + " is in the JSON syntax, which cannot be compared"}
			}
		}
	}

	files, _ := filepath.Glob(filepath.Join(directory, "*.tf"))
	sort.Strings(files)
	sources := map[string]string{}
	type provider struct {
		name string
		body map[string]any
	}
	var providers []provider
	var found []block

	for _, path := range files {
		src, err := os.ReadFile(path)
		if err != nil {
			return nil, unreadable{filepath.Base(path) + " could not be read"}
		}
		file, diags := hclsyntax.ParseConfig(src, path, hcl.InitialPos)
		if diags.HasErrors() {
			return nil, unreadable{filepath.Base(path) + " could not be read: " + diags.Error()}
		}
		for _, b := range file.Body.(*hclsyntax.Body).Blocks {
			if !knownTypes[b.Type] {
				return nil, unreadable{fmt.Sprintf("%s has a %q block, which the check does not know", filepath.Base(path), b.Type)}
			}
			// A check block can hold a data source of its own.
			var states []*hclsyntax.Block
			if isRemoteState(b) {
				states = append(states, b)
			}
			if b.Type == "check" {
				for _, nested := range b.Body.Blocks {
					if isRemoteState(nested) {
						states = append(states, nested)
					}
				}
			}
			if isOverride(path) && (b.Type == "terraform" || b.Type == "provider" || len(states) > 0) {
				return nil, unreadable{filepath.Base(path) + " is an override file. Terraform merges its blocks into others, so they cannot be compared one by one"}
			}
			for _, state := range states {
				found = append(found, remoteState(state, src))
			}
			switch b.Type {
			case "terraform":
				for _, inner := range b.Body.Blocks {
					switch inner.Type {
					case "required_providers":
						for name, attr := range inner.Body.Attributes {
							v, diags := attr.Expr.Value(nil)
							if diags.HasErrors() || !v.Type().IsObjectType() || !v.Type().HasAttribute("source") {
								continue
							}
							if s := v.GetAttr("source"); s.IsKnown() && !s.IsNull() {
								sources[name] = address(s.AsString())
							}
						}
					case "backend":
						if len(inner.Labels) == 1 {
							found = append(found, block{"backend " + inner.Labels[0], fmt.Sprintf("backend %q", inner.Labels[0]), contents(inner.Body, src)})
						}
					case "cloud":
						found = append(found, block{"cloud", "cloud", contents(inner.Body, src)})
					}
				}
			case "provider":
				if len(b.Labels) == 1 {
					providers = append(providers, provider{b.Labels[0], contents(b.Body, src)})
				}
			}
		}
	}

	// A provider's local name means whatever this module's requirements say.
	// Only if they say nothing does it mean the hashicorp namespace.
	for _, p := range providers {
		subject, ok := sources[p.name]
		if !ok {
			subject = address("hashicorp/" + p.name)
		}
		label := fmt.Sprintf("provider %q", p.name)
		if alias, ok := p.body["alias"].(literal); ok {
			label += fmt.Sprintf(" (alias %s)", alias.Value)
		}
		found = append(found, block{subject, label, p.body})
	}
	return found, nil
}

// remainder returns the settings that decide where credentials go.
func remainder(b block, safe map[string]map[string]bool) map[string]any {
	rest := map[string]any{}
	for name, v := range b.body {
		setting := strings.TrimPrefix(name, "block ")
		if setting == "alias" || safe[b.subject][setting] {
			continue
		}
		rest[name] = v
	}
	return rest
}

func canonical(subject string, rest map[string]any) string {
	out, _ := json.Marshal(rest) // map keys are sorted
	return subject + "\x00" + string(out)
}

func settingNames(rest map[string]any, onlyExpressions bool) string {
	var names []string
	for name, v := range rest {
		if !onlyExpressions || hasExpression(v) {
			names = append(names, strings.TrimPrefix(name, "block "))
		}
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// modules installs the root's modules. It returns each module's directory by
// its key. The root's own key is "".
func modules(root, data string) (map[string]string, error) {
	cmd := exec.Command("terraform", "-chdir="+root, "get", "-no-color")
	cmd.Env = append(os.Environ(), "TF_DATA_DIR="+data)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, unreadable{"Its modules could not be installed:\n" + strings.TrimSpace(stderr.String())}
	}
	dirs := map[string]string{"": root}
	manifest, err := os.ReadFile(filepath.Join(data, "modules", "modules.json"))
	if errors.Is(err, os.ErrNotExist) {
		return dirs, nil
	}
	var m struct{ Modules []struct{ Key, Dir string } }
	if err != nil || json.Unmarshal(manifest, &m) != nil {
		return nil, unreadable{"Its module manifest could not be read"}
	}
	for _, mod := range m.Modules {
		if filepath.IsAbs(mod.Dir) {
			dirs[mod.Key] = mod.Dir
		} else {
			dirs[mod.Key] = filepath.Join(root, mod.Dir)
		}
	}
	return dirs, nil
}

// isRoot reports whether a directory is a root. A root is a directory whose
// configuration has a backend or cloud block, in any file. Terraform only
// uses those blocks in the directory it runs in, so a module never has one
// that counts.
//
// A file that cannot be read is an error, not a "no". Otherwise a root with
// a broken file would quietly not be planned.
func isRoot(directory string) (bool, error) {
	jsonFiles, _ := filepath.Glob(filepath.Join(directory, "*.tf.json"))
	for _, path := range jsonFiles {
		var doc struct{ Terraform json.RawMessage }
		src, err := os.ReadFile(path)
		if err != nil || json.Unmarshal(src, &doc) != nil {
			return false, unreadable{path + " could not be read"}
		}
		// The terraform block is an object, or a list of objects.
		var settings []map[string]json.RawMessage
		var one map[string]json.RawMessage
		if json.Unmarshal(doc.Terraform, &one) == nil {
			settings = append(settings, one)
		} else {
			json.Unmarshal(doc.Terraform, &settings)
		}
		for _, s := range settings {
			if s["backend"] != nil || s["cloud"] != nil {
				return true, nil
			}
		}
	}

	files, _ := filepath.Glob(filepath.Join(directory, "*.tf"))
	for _, path := range files {
		src, err := os.ReadFile(path)
		if err != nil {
			return false, unreadable{path + " could not be read"}
		}
		file, diags := hclsyntax.ParseConfig(src, path, hcl.InitialPos)
		if diags.HasErrors() {
			return false, unreadable{path + " could not be read: " + diags.Error()}
		}
		for _, b := range file.Body.(*hclsyntax.Body).Blocks {
			if b.Type != "terraform" {
				continue
			}
			for _, inner := range b.Body.Blocks {
				if inner.Type == "backend" || inner.Type == "cloud" {
					return true, nil
				}
			}
		}
	}
	return false, nil
}

// roots finds the roots under a directory of a repository. It returns their
// paths relative to the repository.
func roots(repository, directory string) ([]string, error) {
	var found []string
	err := filepath.WalkDir(filepath.Join(repository, directory), func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			return nil
		}
		if d.Name() == ".terraform" || d.Name() == ".git" {
			return filepath.SkipDir
		}
		root, err := isRoot(path)
		if err != nil {
			return err
		}
		if root {
			rel, _ := filepath.Rel(repository, path)
			found = append(found, rel)
		}
		return nil
	})
	sort.Strings(found)
	return found, err
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func main() {
	trusted, code, data := os.Getenv("TRUSTED"), os.Getenv("CODE"), os.Getenv("DATA")
	if len(os.Args) > 1 && os.Args[1] == "roots" {
		found, err := roots(code, os.Getenv("ROOT_DIRECTORY"))
		if err != nil {
			fmt.Fprintln(os.Stderr, "Roots could not be found:", err)
			os.Exit(1)
		}
		out, _ := json.Marshal(found)
		fmt.Println(string(out))
		return
	}

	safe := parseSafe(os.Getenv("SAFE_SETTINGS"))
	var checked []string
	if err := json.Unmarshal([]byte(os.Getenv("ROOTS")), &checked); err != nil {
		fmt.Fprintln(os.Stderr, "ROOTS is not a JSON list:", err)
		os.Exit(1)
	}

	// Every configuration on the default branch. The code being checked may
	// repeat any of them. They come from all roots, so a new root can follow
	// an existing one.
	known := map[string]bool{}
	trustedRoots, err := roots(trusted, os.Getenv("ROOT_DIRECTORY"))
	if err != nil {
		fmt.Printf("Warning: on the default branch, %v\n", err)
	}
	for i, root := range trustedRoots {
		dirs, err := modules(filepath.Join(trusted, root), filepath.Join(data, "trusted", fmt.Sprint(i)))
		if err != nil {
			fmt.Printf("Warning: on the default branch, %s: %v\n", root, err)
			continue
		}
		for _, key := range sortedKeys(dirs) {
			found, err := blocks(dirs[key])
			if err != nil {
				fmt.Printf("Warning: on the default branch, %s: %v\n", root, err)
				continue
			}
			for _, b := range found {
				if rest := remainder(b, safe); !hasExpression(rest) {
					known[canonical(b.subject, rest)] = true
				}
			}
		}
	}

	report := map[string][]string{}
	for i, root := range checked {
		problems := []string{}
		dirs, err := modules(filepath.Join(code, root), filepath.Join(data, "code", fmt.Sprint(i)))
		if err != nil {
			problems = append(problems, err.Error())
		}
		for _, key := range sortedKeys(dirs) {
			where, module := "", "The root module"
			if key != "" {
				where, module = " in module."+key, "module."+key
			}
			found, err := blocks(dirs[key])
			if err != nil {
				problems = append(problems, fmt.Sprintf("%s: %v.", module, err))
				continue
			}
			for _, b := range found {
				rest := remainder(b, safe)
				switch {
				case len(rest) == 0:
				case hasExpression(rest):
					problems = append(problems, fmt.Sprintf("`%s`%s sets %s with an expression, whose value cannot be compared.", b.label, where, settingNames(rest, true)))
				case !known[canonical(b.subject, rest)]:
					problems = append(problems, fmt.Sprintf("`%s`%s sets %s, and no configuration on the default branch sets them the same way.", b.label, where, settingNames(rest, false)))
				}
			}
		}
		report[root] = problems
	}

	for _, root := range checked {
		if len(report[root]) == 0 {
			fmt.Printf("%s: can be planned\n", root)
			continue
		}
		fmt.Printf("%s: cannot be planned yet\n", root)
		for _, p := range report[root] {
			fmt.Printf("  %s\n", p)
		}
	}
	out, _ := json.Marshal(report)
	if err := os.WriteFile(os.Getenv("OUT"), out, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
