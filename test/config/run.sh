#!/bin/bash
# Runs the pipeline's config reader on each file below.
#
#   run.sh
#
# Each file under invalid/ must be refused. Its first line says
# `# expect: TEXT`, and the refusal must include TEXT. The other files must
# be accepted.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
read="$here/../../.github/actions/read-config/read.sh"
out=$(mktemp)
log=$(mktemp)
trap 'rm -f "$out" "$log"' EXIT
failed=0

for file in "$here"/*.yml; do
  : > "$out"
  if CONFIG="$file" GITHUB_OUTPUT="$out" "$read" > "$log" 2>&1; then
    echo "ok   $(basename "$file") is accepted"
  else
    echo "FAIL $(basename "$file") is refused"
    sed 's/^/     /' "$log"
    failed=1
  fi
done

for file in "$here"/invalid/*.yml; do
  want=$(sed -n '1s/^# expect: //p' "$file")
  : > "$out"
  if CONFIG="$file" GITHUB_OUTPUT="$out" "$read" > "$log" 2>&1; then
    echo "FAIL $(basename "$file") is accepted"
    failed=1
  elif grep -qF -- "$want" "$log"; then
    echo "ok   $(basename "$file") is refused"
  else
    echo "FAIL $(basename "$file") is refused, but not because: $want"
    sed 's/^/     /' "$log"
    failed=1
  fi
done

exit $failed
