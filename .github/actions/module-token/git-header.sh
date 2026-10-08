#!/bin/bash
# Lets git send $TOKEN to the repositories of $OWNER on github.com. Git reads
# the setting from the environment, so nothing is written to a file.
#
# The header goes to every repository of the owner. So one token covers all
# the repositories it can read. Each owner gets its own setting, so tokens
# for different owners do not meet.
#
# The setting is added after any that an earlier step set.
set -euo pipefail

basic=$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)
echo "::add-mask::$basic"
n=${GIT_CONFIG_COUNT:-0}
{
  echo "GIT_CONFIG_KEY_$n=http.https://github.com/$OWNER/.extraheader"
  echo "GIT_CONFIG_VALUE_$n=AUTHORIZATION: basic $basic"
  echo "GIT_CONFIG_COUNT=$((n + 1))"
} >> "$GITHUB_ENV"
