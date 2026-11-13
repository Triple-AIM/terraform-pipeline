package main

// Run as `compare dependencies`, the tool prints the paths each root depends
// on, as a JSON map from each root to its result. A change to any file at or
// under one of those paths can change the root's plan.
//
// A root depends on:
//
//   - its own directory
//   - the directory of each local module it calls, and of each module those
//     call
//   - each path that a string in that code names
//   - each link on the way to one of those paths, and where the link leads
//
// A string names a path in one of two ways. It can start from `path.module`,
// `path.root` or `path.cwd`. Or it can be a relative path, such as
// `../policies/read.json`. A relative path could be used from any module of
// the root, since a value can be passed from one module to another. So it is
// resolved from every one of them, and from the root.
//
// Most strings are not paths. Read as a path, a string such as `us-east-1`
// names a file in the module's own directory. That directory is already a
// dependency, so it adds nothing.
//
// A path ends at the first piece that cannot be part of a file name, or at an
// expression whose value is not known. So `${path.module}/files/${var.name}`
// names the directory `files`. That is wider than the file Terraform reads,
// so the root is planned more often, never less.
//
// Some code uses a path that the tool cannot follow. Then the root's result
// says why, and the root is planned on every change. That happens when:
//
//   - a string climbs out of a directory with `..` after a part that is not
//     known, or not plainly a name
//   - a string is only `..`, so where it leads depends on what it is joined
//     with
//   - the code calls `dirname`, which climbs out of a directory too
//   - a module's source is an expression
//   - a module's directory does not exist, or is outside the repository
//   - a file cannot be read, or leads outside the repository
//
// A path is followed only when one string holds it. The tool does not follow
// a path joined from several strings, a path written inside a template file,
// or a path that a program reads and the code never names.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

// The result for one root. Exactly one of the two is set.
type result struct {
	Paths []string `json:"paths,omitempty"`
	Every string   `json:"every,omitempty"` // why the root is planned on every change
}

// A piece of a string that may be a path.
type piece struct {
	base     string    // the directory it starts from, or "" if it is relative
	text     string    // the literal text after the start
	complete bool      // whether the text runs to the end of the string
	rng      hcl.Range // where the string is, for messages
}

// A segment of a path that is plainly part of a file or directory name.
var nameSegment = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type walker struct {
	repository string
	root       string
	modules    []string // every module directory, in the order found
	seen       map[string]bool
	pieces     []piece
	paths      map[string]bool
	// Strings already read as part of a larger one, or that are not paths.
	// Every expression type is a pointer, so any expression can be a key.
	skip map[hclsyntax.Expression]bool
}

func (w *walker) fail(rng hcl.Range, format string, args ...any) error {
	return problem{fmt.Sprintf("%s:%d %s", rng.Filename, rng.Start.Line, fmt.Sprintf(format, args...))}
}

func (w *walker) rel(path string) string {
	rel, err := filepath.Rel(w.repository, path)
	if err != nil {
		return path
	}
	return rel
}

func (w *walker) inRepository(path string) bool {
	rel, err := filepath.Rel(w.repository, filepath.Clean(path))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, "../")
}

// pathRef returns the directory that `path.module`, `path.root` or `path.cwd`
// names, if the expression is one of them. `abspath` of one names the same
// directory.
func (w *walker) pathRef(expr hclsyntax.Expression, module string) (string, bool) {
	if call, ok := expr.(*hclsyntax.FunctionCallExpr); ok && call.Name == "abspath" && len(call.Args) == 1 {
		return w.pathRef(call.Args[0], module)
	}
	ref, ok := expr.(*hclsyntax.ScopeTraversalExpr)
	if !ok || len(ref.Traversal) != 2 || ref.Traversal.RootName() != "path" {
		return "", false
	}
	attr, ok := ref.Traversal[1].(hcl.TraverseAttr)
	if !ok {
		return "", false
	}
	switch attr.Name {
	case "module":
		return module, true
	case "root", "cwd":
		// The pipeline runs Terraform in the root's directory.
		return w.root, true
	}
	return "", false
}

// literalString returns a template part's text, if it is literal text.
func literalString(expr hclsyntax.Expression) (string, bool) {
	lit, ok := expr.(*hclsyntax.LiteralValueExpr)
	if !ok || !lit.Val.Type().Equals(cty.String) || !lit.Val.IsKnown() || lit.Val.IsNull() {
		return "", false
	}
	return lit.Val.AsString(), true
}

// climbs reports whether a piece of text has a `..` segment.
func climbs(text string) bool {
	for _, segment := range strings.Split(text, "/") {
		if segment == ".." {
			return true
		}
	}
	return false
}

// onlyClimbs reports whether a piece of text is nothing but `..` segments,
// such as `..` or `../..`.
func onlyClimbs(text string) bool {
	for _, segment := range strings.Split(text, "/") {
		if segment != ".." && segment != "" && segment != "." {
			return false
		}
	}
	return climbs(text)
}

// template reads the pieces of a string that may be paths. A piece starts at
// the start of the string, and at each path reference.
func (w *walker) template(parts []hclsyntax.Expression, rng hcl.Range, module string) error {
	current := &piece{rng: rng}
	unknown := false // whether a part whose value is not known came last
	end := func(complete bool) {
		if current != nil {
			current.complete = complete
			w.pieces = append(w.pieces, *current)
			current = nil
		}
	}
	for _, part := range parts {
		w.skip[part] = true
		if text, ok := literalString(part); ok {
			switch {
			case current != nil:
				current.text += text
			case unknown && climbs(text):
				return w.fail(part.Range(), "climbs out of a directory with `..`, after a part whose value is not known")
			}
			continue
		}
		if dir, ok := w.pathRef(part, module); ok {
			end(false)
			current = &piece{base: dir, rng: rng}
			unknown = false
			continue
		}
		end(false)
		unknown = true
	}
	end(true)
	return nil
}

// skipAll marks an expression, and every one inside it, as handled.
func (w *walker) skipAll(expr hclsyntax.Expression) {
	hclsyntax.VisitAll(expr, func(n hclsyntax.Node) hcl.Diagnostics {
		if e, ok := n.(hclsyntax.Expression); ok {
			w.skip[e] = true
		}
		return nil
	})
}

// expressions reads every string in a body or an expression.
func (w *walker) expressions(node hclsyntax.Node, module string) error {
	var err error
	hclsyntax.VisitAll(node, func(n hclsyntax.Node) hcl.Diagnostics {
		if err != nil {
			return nil
		}
		if e, ok := n.(hclsyntax.Expression); ok && w.skip[e] {
			return nil
		}
		switch n := n.(type) {
		case *hclsyntax.FunctionCallExpr:
			if n.Name == "dirname" {
				err = w.fail(n.Range(), "calls `dirname`, which climbs out of a directory")
			}
		case *hclsyntax.TemplateExpr:
			err = w.template(n.Parts, n.Range(), module)
		case *hclsyntax.TemplateWrapExpr:
			err = w.template([]hclsyntax.Expression{n.Wrapped}, n.Range(), module)
		case *hclsyntax.LiteralValueExpr:
			if text, ok := literalString(n); ok {
				w.pieces = append(w.pieces, piece{text: text, complete: true, rng: n.Range()})
			}
		}
		return nil
	})
	return err
}

// local returns the directory a module's source names, if it is a local
// path.
func local(source, module string) (string, bool) {
	if !strings.HasPrefix(source, "./") && !strings.HasPrefix(source, "../") {
		return "", false
	}
	return filepath.Join(module, source), true
}

// read reads one configuration file. It must lead to a file in the
// repository. Any file outside it is not the branch's to change, and its
// contents must not reach a message.
func (w *walker) read(path string) ([]byte, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, problem{w.rel(path) + " could not be read"}
	}
	if !w.inRepository(real) {
		return nil, problem{w.rel(path) + " leads outside the repository"}
	}
	src, err := readSource(real)
	if err != nil {
		return nil, problem{w.rel(path) + " could not be read"}
	}
	return src, nil
}

// readHCL reads one file in the native syntax.
func (w *walker) readHCL(path, module string, calls *[]string) error {
	src, err := w.read(path)
	if err != nil {
		return err
	}
	file, diags := hclsyntax.ParseConfig(src, w.rel(path), hcl.InitialPos)
	if diags.HasErrors() {
		return problem{diags.Error()}
	}
	body := file.Body.(*hclsyntax.Body)
	for _, b := range body.Blocks {
		if b.Type != "module" {
			continue
		}
		attr, ok := b.Body.Attributes["source"]
		if !ok {
			continue
		}
		v, diags := attr.Expr.Value(nil)
		if diags.HasErrors() || !v.IsWhollyKnown() || v.IsNull() || !v.Type().Equals(cty.String) {
			return w.fail(attr.Range(), "sets a module's source with an expression")
		}
		if dir, ok := local(v.AsString(), module); ok {
			*calls = append(*calls, dir)
		}
		// The source is followed as a module. Read again as a plain path, it
		// would name directories the root does not use.
		w.skipAll(attr.Expr)
	}
	return w.expressions(body, module)
}

// objects returns a JSON value's objects. A block in the JSON syntax is an
// object, or a list of objects.
func objects(v any) []map[string]any {
	switch v := v.(type) {
	case map[string]any:
		return []map[string]any{v}
	case []any:
		var out []map[string]any
		for _, x := range v {
			if m, ok := x.(map[string]any); ok {
				out = append(out, m)
			}
		}
		return out
	}
	return nil
}

// readJSON reads one file in the JSON syntax. Each string in it is a
// template.
func (w *walker) readJSON(path, module string, calls *[]string) error {
	src, err := w.read(path)
	if err != nil {
		return err
	}
	var doc any
	if json.Unmarshal(src, &doc) != nil {
		return problem{w.rel(path) + " could not be read"}
	}
	// A module block is `"module": {NAME: {...}}`.
	if top, ok := doc.(map[string]any); ok {
		for _, byName := range objects(top["module"]) {
			for _, call := range byName {
				for _, body := range objects(call) {
					source, ok := body["source"]
					if !ok {
						continue
					}
					text, ok := source.(string)
					if !ok || strings.Contains(text, "${") || strings.Contains(text, "%{") {
						return problem{w.rel(path) + " sets a module's source with an expression"}
					}
					if dir, ok := local(text, module); ok {
						*calls = append(*calls, dir)
					}
					// As in the native syntax, the source is not read again
					// as a plain path.
					delete(body, "source")
				}
			}
		}
	}
	var walk func(v any) error
	walk = func(v any) error {
		switch v := v.(type) {
		case string:
			expr, diags := hclsyntax.ParseTemplate([]byte(v), w.rel(path), hcl.InitialPos)
			if diags.HasErrors() {
				return problem{w.rel(path) + " has a string that could not be read: " + diags.Error()}
			}
			return w.expressions(expr, module)
		case map[string]any:
			for key, x := range v {
				if key == "//" {
					continue
				}
				if err := walk(x); err != nil {
					return err
				}
			}
		case []any:
			for _, x := range v {
				if err := walk(x); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return walk(doc)
}

// The files Terraform reads in a module's directory. In the root's
// directory, it also reads variable files.
func configFiles(dir string, isRoot bool) []string {
	patterns := []string{"*.tf", "*.tf.json"}
	if isRoot {
		patterns = append(patterns, "terraform.tfvars", "terraform.tfvars.json", "*.auto.tfvars", "*.auto.tfvars.json")
	}
	var files []string
	for _, pattern := range patterns {
		found, _ := filepath.Glob(filepath.Join(dir, pattern))
		files = append(files, found...)
	}
	sort.Strings(files)
	return files
}

// addPath records a path the root depends on, if it is in the repository. A
// path outside it cannot change with the repository's files.
//
// A link on the way to the path decides where the path leads. So it records
// each such link, and the path the links lead to.
func (w *walker) addPath(path string) {
	path = filepath.Clean(path)
	if !w.inRepository(path) {
		return
	}
	w.paths[w.rel(path)] = true

	// The longest part of the path that exists. The rest may not exist yet.
	existing, rest := path, ""
	for {
		if _, err := os.Lstat(existing); err == nil {
			break
		}
		if existing == w.repository {
			return
		}
		rest = filepath.Join(filepath.Base(existing), rest)
		existing = filepath.Dir(existing)
	}
	for p := existing; p != w.repository && w.inRepository(p); p = filepath.Dir(p) {
		if info, err := os.Lstat(p); err == nil && info.Mode()&os.ModeSymlink != 0 {
			w.paths[w.rel(p)] = true
		}
	}
	if real, err := filepath.EvalSymlinks(existing); err == nil {
		if target := filepath.Join(real, rest); w.inRepository(target) {
			w.paths[w.rel(target)] = true
		}
	}
}

// module reads one module's directory, and then each local module it calls.
func (w *walker) module(dir string) error {
	if w.seen[dir] {
		return nil
	}
	w.seen[dir] = true
	if !w.inRepository(dir) {
		return problem{"a module's directory, " + w.rel(dir) + ", is outside the repository"}
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return problem{"the module directory " + w.rel(dir) + " does not exist"}
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil || !w.inRepository(real) {
		return problem{"the module directory " + w.rel(dir) + " leads outside the repository"}
	}
	w.addPath(dir)
	w.modules = append(w.modules, dir)

	var calls []string
	for _, path := range configFiles(dir, dir == w.root) {
		var err error
		if strings.HasSuffix(path, ".json") {
			err = w.readJSON(path, dir, &calls)
		} else {
			err = w.readHCL(path, dir, &calls)
		}
		if err != nil {
			return err
		}
	}
	for _, call := range calls {
		if err := w.module(call); err != nil {
			return err
		}
	}
	return nil
}

// reach follows a piece's text from a directory. It returns where the path
// leads. It stops at the first segment that is not plainly part of a name.
func reach(base, text string, complete bool) (string, bool) {
	segments := strings.Split(text, "/")
	if !complete {
		// The last segment is cut short by a part whose value is not known.
		segments = segments[:len(segments)-1]
	}
	dir := base
	for i, segment := range segments {
		switch {
		case segment == "" || segment == ".":
		case segment == "..":
			dir = filepath.Dir(dir)
		case nameSegment.MatchString(segment):
			dir = filepath.Join(dir, segment)
		default:
			// The path ends here. If it climbs after this, where it leads
			// cannot be worked out.
			if climbs(strings.Join(segments[i+1:], "/")) {
				return "", false
			}
			return dir, true
		}
	}
	return dir, true
}

// links records where each link under the root's paths leads. A change to
// that target changes what is read through the link. A link may lead to
// another link, so this repeats until nothing new is found.
func (w *walker) links() error {
	walked := map[string]bool{}
	for {
		var next []string
		for p := range w.paths {
			if !walked[p] && p != "." {
				next = append(next, p)
			}
		}
		if len(next) == 0 {
			return nil
		}
		sort.Strings(next)
		for _, p := range next {
			walked[p] = true
			err := filepath.WalkDir(filepath.Join(w.repository, p), func(path string, d os.DirEntry, err error) error {
				if os.IsNotExist(err) && path == filepath.Join(w.repository, p) {
					// A path the code names, but that does not exist yet.
					return nil
				}
				if err != nil {
					return err
				}
				if d.IsDir() && (d.Name() == ".git" || d.Name() == ".terraform") {
					return filepath.SkipDir
				}
				if d.Type()&os.ModeSymlink == 0 {
					return nil
				}
				// A link that leads nowhere yet still names its target.
				target, err := os.Readlink(path)
				if err != nil {
					return err
				}
				if !filepath.IsAbs(target) {
					target = filepath.Join(filepath.Dir(path), target)
				}
				w.addPath(target)
				return nil
			})
			if err != nil {
				return problem{"the files under " + p + " could not all be read"}
			}
		}
	}
}

// minimal sorts paths and drops each one that is under another.
func minimal(paths map[string]bool) []string {
	if paths["."] {
		return []string{"."}
	}
	var out []string
	for p := range paths {
		under := false
		for dir := filepath.Dir(p); dir != "."; dir = filepath.Dir(dir) {
			if paths[dir] {
				under = true
				break
			}
		}
		if !under {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// dependsOn works out the paths one root depends on.
func dependsOn(repository, root string) result {
	w := &walker{
		repository: repository,
		root:       filepath.Join(repository, root),
		seen:       map[string]bool{},
		paths:      map[string]bool{},
		skip:       map[hclsyntax.Expression]bool{},
	}
	if err := w.module(w.root); err != nil {
		return result{Every: err.Error()}
	}
	for _, p := range w.pieces {
		bases := []string{p.base}
		if p.base == "" {
			if strings.HasPrefix(p.text, "/") || strings.HasPrefix(p.text, "~") {
				continue
			}
			if p.complete && onlyClimbs(p.text) {
				return result{Every: w.fail(p.rng, "has a string that is only `..`, so where it leads depends on what it is joined with").Error()}
			}
			bases = append([]string{w.root}, w.modules...)
		}
		for _, base := range bases {
			dir, ok := reach(base, p.text, p.complete)
			if !ok {
				return result{Every: w.fail(p.rng, "climbs out of a directory with `..`, after a part that is not plainly a name").Error()}
			}
			w.addPath(dir)
		}
	}
	if err := w.links(); err != nil {
		return result{Every: err.Error()}
	}
	return result{Paths: minimal(w.paths)}
}

// dependencies works out the paths each root depends on.
func dependencies(repository string, roots []string) (map[string]result, error) {
	repository, err := filepath.Abs(repository)
	if err != nil {
		return nil, err
	}
	if repository, err = filepath.EvalSymlinks(repository); err != nil {
		return nil, err
	}
	out := map[string]result{}
	for _, root := range roots {
		out[root] = dependsOn(repository, root)
	}
	return out, nil
}
