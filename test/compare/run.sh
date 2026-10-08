#!/bin/bash
# Runs the settings check against each case below, and checks its verdict.
#
#   run.sh COMMAND [ARG]...
#
# A case is the tree under main/, with the case's own files laid over it. Its
# `expect` file says, for each root, `plan` or `defer`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# Kept beside the cases. The settings check runs Terraform in the pipeline's
# sandbox, which can reach the workspace but not the system's temporary
# directory.
work=$(mktemp -d "$here/.work.XXXXXX")
failed=0

for case in "$here"/cases/*/; do
  name=$(basename "$case")
  rm -rf "$work/code" "$work/data"
  cp -R "$here/main" "$work/code"
  (cd "$case" && find . -type f ! -name expect -exec sh -c 'mkdir -p "$0/$(dirname "$1")" && cp "$1" "$0/$1"' "$work/code" {} \;)
  roots=$(awk '{print $1}' "$case/expect" | jq -Rsc 'split("\n") | map(select(length > 0))')

  TRUSTED="$here/main" CODE="$work/code" DATA="$work/data" OUT="$work/out.json" \
    ROOT_DIRECTORY=terraform ROOTS="$roots" \
    SAFE_SETTINGS=$'hashicorp/aws: region default_tags\nbackend s3: key' \
    "$@" > "$work/log" 2>&1 || { echo "FAIL $name: the comparison failed"; cat "$work/log"; failed=1; continue; }

  if [ ! -s "$case/expect" ]; then
    echo "FAIL $name: its expect file is empty"
    failed=1
    continue
  fi
  while read -r root want; do
    # A root missing from the report is not a verdict.
    got=$(jq -r --arg r "$root" 'if has($r) | not then "missing" elif (.[$r] | length) == 0 then "plan" else "defer" end' "$work/out.json")
    if [ "$got" = "$want" ]; then
      echo "ok   $name: $root $got"
    else
      echo "FAIL $name: $root $got, expected $want"
      sed 's/^/     /' "$work/log"
      failed=1
    fi
  done < "$case/expect"
done

rm -rf "$work"
exit $failed
