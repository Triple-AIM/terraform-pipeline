#!/bin/bash
# Runs one step of one of the pipeline's jobs, as the pipeline would. The job
# is the Config job unless another is named.
#
#   test/run-step.sh 'STEP NAME' [JOB]
#
# Tests run the pipeline's own steps, not copies of them. That way, they check
# what the pipeline actually does. The step's `env:` is not applied. The
# caller sets what the step expects.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=$(mktemp)
trap 'rm -f "$script"' EXIT
STEP=$1 JOB=${2:-config} yq 'explode(.) | .jobs[strenv(JOB)].steps[] | select(.name == strenv(STEP)) | .run' \
  "$here/../.github/workflows/terraform.yml" > "$script"
if [ ! -s "$script" ] || [ "$(cat "$script")" = null ]; then
  echo "No step named '$1' in the ${2:-config} job." >&2
  exit 2
fi
bash -e -o pipefail "$script"
