#!/bin/bash
# Reads the config file at $CONFIG and checks it. Then writes each setting
# to $GITHUB_OUTPUT. Every mistake is reported, not only the first.
#
# Messages name the file as $NAME, if it is set. That is its path in the
# repository, where $CONFIG may be its path in a checkout.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
name=${NAME:-$CONFIG}

if [ ! -f "$CONFIG" ]; then
  echo "::error::There is no config file at $name."
  exit 1
fi
if ! json=$(yq -o=json '.' "$CONFIG" 2>&1); then
  echo "::error file=$name::$name is not valid YAML: $json"
  exit 1
fi

mistakes=$(jq -r -f "$here/check.jq" <<<"$json")
if [ -n "$mistakes" ]; then
  while read -r mistake; do
    echo "::error file=$name::$mistake"
  done <<<"$mistakes"
  exit 1
fi

# Writes one output. A delimiter allows values of more than one line.
output() {
  local delimiter
  delimiter="EOF_$(openssl rand -hex 8)"
  printf '%s<<%s\n%s\n%s\n' "$1" "$delimiter" "$2" "$delimiter" >> "$GITHUB_OUTPUT"
}
get() { jq -r "$1" <<<"$json"; }

output terraform-version "${VERSION:-$(get '."terraform-version"')}"
output providers "$(get '.providers | keys_unsorted | join("\n")')"
output safe-settings "$(get '[(.providers | to_entries[] | "\(.key): \(.value."safe-settings" // [] | join(" "))"),
  (.backends // {} | to_entries[] | "backend \(.key): \(.value."safe-settings" // [] | join(" "))")] | join("\n")')"
output root-directory "$(get '."root-directory" // "."')"
output shared-paths "$(get '."shared-paths" // [] | join("\n")')"
output plan-environment "$(get '.environments.plan // "terraform-plan"')"
output apply-environment "$(get '.environments.apply // "terraform-apply"')"
output modules-environment "$(get '.environments.modules // ""')"
output approval-environment "$(get '.environments.approval // ""')"
output environment-variables "$(get '."environment-variables" // {} | tojson')"
output private-modules "$(get '."private-modules" // null | if . then tojson else "" end')"
output checkov "$(get '.checkov // false')"
output checkov-config "$(get '."checkov-config" // ""')"
