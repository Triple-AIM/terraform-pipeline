# Prints one line for each mistake in the config, given as JSON. Prints
# nothing if there are none.

def settings: [
  "terraform-version", "providers", "backends", "root-directory",
  "shared-paths", "environments", "environment-variables", "private-modules",
  "checkov", "checkov-config"
];
def texts: type == "array" and all(.[]; type == "string");
def identifier: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$");

# Checks one entry of `providers` or `backends`. Its value is empty, or a map
# with `safe-settings`.
def subject($kind):
  .key as $name |
  if .value == null then empty
  elif (.value | type) != "object" then
    "`\($kind).\($name)` must be empty, or a map with `safe-settings`."
  else
    (.value | keys[] | select(. != "safe-settings") | "`\($kind).\($name).\(.)` is not a setting."),
    (.value | select(has("safe-settings") and (."safe-settings" | texts | not))
      | "`\($kind).\($name).safe-settings` must be a list of settings.")
  end;

if type != "object" then
  "The config must be a map of settings."
else
  (keys[] | select(IN(settings[]) | not) | "`\(.)` is not a setting."),

  if has("terraform-version") | not then
    "`terraform-version` is required."
  elif (."terraform-version" | type) != "string" then
    "`terraform-version` must be in quotes. Otherwise YAML may read it as a number, and 1.10 would become 1.1."
  else empty end,

  if has("providers") | not then
    "`providers` is required."
  elif (.providers | type) != "object" or (.providers | length) == 0 then
    "`providers` must be a map from each provider's address to its settings."
  else
    .providers | to_entries[] | subject("providers")
  end,

  (.backends // {} |
    if type != "object" then
      "`backends` must be a map from each backend's type to its settings."
    else
      to_entries[] | subject("backends")
    end),

  (."root-directory" // "." | select(type != "string")
    | "`root-directory` must be a path."),

  (."shared-paths" // [] | select(texts | not)
    | "`shared-paths` must be a list of paths."),

  (.environments // {} |
    if type != "object" then
      "`environments` must be a map from a phase to an environment's name."
    else
      (keys[] | select(IN("plan", "apply", "modules", "approval") | not)
        | "`environments.\(.)` is not used. The phases are plan, apply, modules and approval."),
      (to_entries[] | select((.value | type) != "string" or (.value | test("^[A-Za-z0-9._-]+$") | not))
        | "`environments.\(.key)` must be an environment's name.")
    end),

  (."environment-variables" // {} |
    if type != "object" then
      "`environment-variables` must be a map from a variable's name to a secret's name, or to `{ variable: NAME }`."
    else
      to_entries[] |
      if (.key | identifier | not) then
        "`\(.key)` is not a variable name."
      elif (.key | startswith("TF_VAR_")) then
        "`\(.key)` would pass its value to Terraform code, which can read any variable. Pass it to the provider instead."
      elif (.key | (test("^(TF_|GIT_|RUNNER_|ACTIONS_)") and (startswith("TF_TOKEN_") | not))
          or IN("PATH", "HOME", "TMPDIR", "LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV")) then
        "`\(.key)` is used by the pipeline, Terraform, git or the runner. It cannot be set here."
      # Providers read some `GITHUB_` names, such as GITHUB_APP_PEM_FILE. So
      # only the names the runner sets are refused. Each job is given the same
      # ones, so this job's environment shows them.
      elif (.key as $name | $name | startswith("GITHUB_") and ($ENV | has($name))) then
        "`\(.key)` is set by the runner. It cannot be set here."
      elif (.value | identifier or (type == "object" and keys == ["variable"] and (.variable | identifier)) | not) then
        "`environment-variables.\(.key)` must be a secret's name, or `{ variable: NAME }`."
      else empty end
    end),

  if has("private-modules") then
    (."private-modules" |
      if type != "object" then
        "`private-modules` must be a map."
      else
        (keys[] | select(IN("owner", "client-id", "private-key-secret") | not)
          | "`private-modules.\(.)` is not a setting."),
        (select(has("owner") and (.owner | type != "string" or (test("^[A-Za-z0-9-]+$") | not)))
          | "`private-modules.owner` must be an organization's name."),
        (select((."client-id" | type) != "string")
          | "`private-modules.client-id` is required. It is the GitHub App's client ID."),
        (select(."private-key-secret" | identifier | not)
          | "`private-modules.private-key-secret` is required. It is the name of the secret that holds the App's private key.")
      end),
    (select((try .environments.modules catch null) == null)
      | "`private-modules` needs `environments.modules`. Without it, the settings check cannot install them.")
  else empty end,

  (.checkov // false | select(type != "boolean") | "`checkov` must be true or false."),
  (."checkov-config" // "" | select(type != "string") | "`checkov-config` must be a path.")
end
