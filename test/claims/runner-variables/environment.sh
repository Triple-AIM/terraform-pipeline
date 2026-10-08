#!/bin/sh
# Prints, as JSON, how many of the runner's own variables this program got,
# and the marker the self-test set.
runner=$(env | grep -c '^ACTIONS_' || true)
printf '{"runner": "%s", "marker": "%s"}\n' "$runner" "${CLAIMS_MARKER:-}"
