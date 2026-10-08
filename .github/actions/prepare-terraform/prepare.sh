#!/bin/bash
# After this, `terraform` runs Terraform in a Landlock sandbox. Terraform, and
# every provider it starts, can only open:
#
# - the system files that any process needs
# - the workspace
# - its own working files
#
# So it cannot open /proc, where its own environment is. It cannot open the
# home directory. And it cannot open the runner's temporary files, which hold
# every variable that steps export.
#
# The CLI configuration and Terraform's working directory are kept outside the
# workspace. So the code being planned cannot supply either one. It cannot
# bring installation settings of its own. And it cannot commit provider
# binaries under `.terraform/` for `terraform init` to find.
set -euo pipefail

# Terraform cannot reach the tools. It can reach its working files.
tools="$RUNNER_TEMP/terraform-tools"
work="$RUNNER_TEMP/terraform"
mkdir -p "$tools/bin" "$work/data" "$work/plugin-cache" "$work/tmp" "$work/home"

include=""
while read -r address; do
  [ -n "$address" ] || continue
  if ! grep -Eq '^([a-z0-9.-]+/)?[a-z0-9-]+/[a-z0-9_-]+$' <<<"$address"; then
    echo "::error::Not a provider address: $address"
    exit 1
  fi
  [ "$(tr -cd / <<<"$address" | wc -c)" -eq 2 ] || address="registry.terraform.io/$address"
  include="$include\"$address\", "
done <<<"$(tr '[:upper:]' '[:lower:]' <<<"$PROVIDERS")"
cat > "$tools/terraformrc" <<EOT
disable_checkpoint = true
plugin_cache_dir   = "$work/plugin-cache"
provider_installation {
  direct {
    include = [${include%, }]
  }
}
EOT
cat "$tools/terraformrc"

# Copied, so that the sandbox does not depend on where the runner keeps this
# action.
cp "$GITHUB_ACTION_PATH/sandbox.py" "$tools/sandbox.py"
install -m 0755 "$GITHUB_ACTION_PATH/inert" "$tools/bin/inert"
install -m 0755 "$GITHUB_ACTION_PATH/terraform-init" "$tools/bin/terraform-init"
install -m 0755 "$GITHUB_ACTION_PATH/module-hash" "$tools/bin/module-hash"

# Terraform gets a home directory of its own. Providers write caches there,
# and the real one is out of reach.
#
# It also gets none of the runner's own variables, whose names start with
# ACTIONS_. One of them is the token that requests OIDC tokens. A backend or
# provider configured by the code being planned could send it anywhere.
# Credentials that Terraform needs come from steps before it.
real=$(readlink -f "$(command -v terraform)")
{
  echo '#!/bin/bash'
  # shellcheck disable=SC2016 # expanded by the wrapper, not here
  echo 'for name in $(compgen -e); do [[ $name != ACTIONS_* ]] || unset "$name"; done'
  printf 'exec env HOME=%q TMPDIR=%q /usr/bin/python3 %q' "$work/home" "$work/tmp" "$tools/sandbox.py"
  printf ' --rx %q' "$(dirname "$real")"
  printf ' --ro %q' "$tools/terraformrc"
  printf ' --rw %q' "$GITHUB_WORKSPACE" "$work"
  printf ' -- %q "$@"\n' "$real"
} > "$tools/bin/terraform"
chmod +x "$tools/bin/terraform"

# If the sandbox cannot run, this fails here, not at the first plan.
"$tools/bin/terraform" version

echo "$tools/bin" >> "$GITHUB_PATH"
echo "TF_CLI_CONFIG_FILE=$tools/terraformrc" >> "$GITHUB_ENV"
echo "TF_DATA_DIR=$work/data" >> "$GITHUB_ENV"
