#!/bin/bash
# Runs the pipeline's export script on sample variables.
#
#   run.sh
#
# Each case checks what the script writes for the job's environment, what it
# prints, and whether it fails.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
export_script="$here/../../.github/actions/export-environment-variables/export.sh"
env_file=$(mktemp)
log=$(mktemp)
trap 'rm -f "$env_file" "$log"' EXIT
failed=0

export ENVIRONMENT=terraform-plan
export VARS='{"USER_NAME": "user-value", "MULTI_LINE": "line one\nline two"}'

# Runs the script with $1 as the config's `environment-variables`. Sets
# $status to its exit status.
run() {
  : > "$env_file"
  status=0
  VARIABLES=$1 GITHUB_ENV="$env_file" "$export_script" > "$log" 2>&1 || status=$?
}
# Prints the value written for $1, as the runner would load it.
loaded() {
  while IFS= read -r line; do
    name=${line%%<<*}
    delimiter=${line#*<<}
    value=
    while IFS= read -r part && [ "$part" != "$delimiter" ]; do
      value+=${value:+$'\n'}$part
    done
    if [ "$name" = "$1" ]; then
      printf '%s' "$value"
    fi
  done < "$env_file"
}
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  sed 's/^/     /' "$log"
  failed=1
}

run '{"PROVIDER_USER": {"variable": "USER_NAME"}, "PROVIDER_LINES": {"variable": "multi_line"}}'
claim='variables are exported'
if [ "$status" = 0 ] &&
  [ "$(loaded PROVIDER_USER)" = user-value ] &&
  [ "$(loaded PROVIDER_LINES)" = $'line one\nline two' ]; then
  pass "$claim"
else
  fail "$claim"
fi
claim='the script masks nothing'
if grep -q '::add-mask::' "$log"; then fail "$claim"; else pass "$claim"; fi

run '{"PROVIDER_KEY": {"variable": "NO_SUCH_KEY"}, "PROVIDER_OTHER": {"variable": "NO_SUCH_VARIABLE"}}'
claim='a variable that is not set stops the job'
if [ "$status" != 0 ]; then pass "$claim"; else fail "$claim"; fi
claim='every variable that is not set is named'
if grep -qF 'The variable NO_SUCH_KEY is not set in the terraform-plan environment. So PROVIDER_KEY cannot be set.' "$log" &&
  grep -qF 'The variable NO_SUCH_VARIABLE is not set' "$log"; then
  pass "$claim"
else
  fail "$claim"
fi

exit $failed
