#!/bin/bash
# Writes each environment variable that $VARIABLES names to $GITHUB_ENV.
#
# $VARIABLES maps a name to its source, `{"variable": NAME}`, looked up in
# $VARS. Every source that is not set is reported, and then the script fails.
#
# A variable's value is not masked, because it is not secret.
set -euo pipefail

missing=0
while IFS=$'\t' read -r name source; do
  [ -n "$name" ] || continue
  # Names of variables are not case-sensitive, so neither is the lookup.
  value=$(jq -r --arg s "$source" 'to_entries[] | select((.key | ascii_upcase) == ($s | ascii_upcase)) | .value' <<<"$VARS")
  if [ -z "$value" ]; then
    echo "::error::The variable $source is not set in the $ENVIRONMENT environment. So $name cannot be set."
    missing=1
    continue
  fi
  # A value may span lines, so each is written with a delimiter.
  delimiter="EOF_$(openssl rand -hex 8)"
  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter" >> "$GITHUB_ENV"
  echo "Set $name from the variable $source."
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value.variable)"' <<<"$VARIABLES")
exit $missing
