#!/bin/bash
# Runs the pipeline's steps that pick which roots to plan, and which to apply.
#
#   run.sh plans COMPARE
#   run.sh applies
#
# COMPARE is the comparison tool, which finds the roots. GitHub's API is
# replaced by a fake `gh`, which answers from files this script writes. For
# `applies`, Terraform must be on the PATH, and so must `inert`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
section=$1
compare=${2:-}
case "$section" in
  plans) [ -n "$compare" ] || { echo "plans needs the comparison tool." >&2; exit 2; } ;;
  applies) ;;
  *) echo "Unknown section: $section" >&2; exit 2 ;;
esac
# Kept beside this script. Terraform runs in the pipeline's sandbox, which can
# reach the workspace but not the system's temporary directory.
work=$(mktemp -d "$here/.work.XXXXXX")
trap 'rm -rf "$work"' EXIT
failed=0

# The roots job runs the tool from where the install action puts it.
export RUNNER_TEMP="$work/runner"
mkdir -p "$RUNNER_TEMP/terraform-tools/compare"
if [ -n "$compare" ]; then
  ln -s "$compare" "$RUNNER_TEMP/terraform-tools/compare/compare"
fi

# The fake `gh`. It answers `gh api PATH` from $STUB/NAME.json. A comparison
# is answered from compare-BASE.json. A missing file is an API error. A new
# deployment is kept in created.json, and gets the ID 7. The fields of a new
# status are kept in status.txt.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
[ "$1" = api ] || exit 1
[ "$2" != --paginate ] || shift
case "$2" in
  */deployments) cat > "$STUB/created.json"; echo 7; exit ;;
  */deployments/*/statuses) shift 2; printf '%s\n' "$@" > "$STUB/status.txt"; exit ;;
  */actions/runs/*/artifacts) name=run-artifacts ;;
  */deployments/*/statuses*) id=${2#*/deployments/}; name=statuses-${id%%/*} ;;
  */deployments\?*) name=deployments ;;
  */compare/*) base=${2##*/compare/}; name=compare-${base%%...*} ;;
  *) exit 1 ;;
esac
cat "$STUB/$name.json"
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

export STUB="$work/stub"
export GITHUB_REPOSITORY=example/infrastructure
export GITHUB_SHA=head
export GITHUB_RUN_ID=9
export DEFAULT_BRANCH=main
export APPLY_ENVIRONMENT=terraform-apply
export WORKFLOW=Terraform
export CONFIG_FILE=.github/terraform-pipeline/config.yml
export PULL_REQUEST=''
export SHARED_PATHS=''
export ROOT_DIRECTORY=test/claims/roots

all='["test/claims/roots/backend-file","test/claims/roots/cloud","test/claims/roots/json","test/claims/roots/json-list","test/claims/roots/other-file"]'
log="$work/log"
out="$work/output"

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  sed 's/^/     /' "$log"
  failed=1
}
# Clears the fake API's answers.
reset() { rm -rf "$STUB"; mkdir -p "$STUB"; }
# The deployments, newest first. Each argument is `ID SHA CREATOR STATE...`.
# Each state is one of the deployment's statuses.
deployments() {
  local line id sha creator
  for line in "$@"; do
    read -r id sha creator states <<<"$line"
    jq -nc --argjson id "$id" --arg sha "$sha" --arg creator "$creator" \
      '{id: $id, sha: $sha, creator: {login: $creator}}'
    # shellcheck disable=SC2086 # one state per word
    printf '%s\n' $states | jq -Rnc '[inputs | select(length > 0) | {state: .}]' > "$STUB/statuses-$id.json"
  done | jq -s . > "$STUB/deployments.json"
}
# The comparison from commit $1, with status $2. The other arguments are
# changed files, as `name` or `old>new` for a rename.
comparison() {
  local base=$1 status=$2
  shift 2
  printf '%s\n' "$@" | jq -Rnc --arg status "$status" '{status: $status, files: [inputs | select(length > 0)
    | split(">") | if length == 2 then {previous_filename: .[0], filename: .[1]} else {filename: .[0]} end]}' > "$STUB/compare-$base.json"
}
# Runs the roots job's step, and checks the roots it picks against $2.
pick() {
  : > "$out"
  if (cd "$top" && GITHUB_OUTPUT="$out" "$top/test/run-step.sh" 'Pick the roots this change touches' roots) > "$log" 2>&1 &&
    [ "$(sed -n 's/^roots=//p' "$out")" = "$2" ]; then
    pass "$1"
  else
    echo "     picked: $(sed -n 's/^roots=//p' "$out")" >> "$log"
    fail "$1"
  fi
}

if [ "$section" = plans ]; then
  export EVENT=push
  bot='github-actions[bot]'

  reset
  deployments "2 applied $bot success" "1 older $bot success"
  comparison applied ahead test/claims/roots/json/main.tf.json 'test/claims/roots/cloud/main.tf>elsewhere/main.tf' README.md
  pick 'a push plans the roots changed since the last commit applied in full' \
    '["test/claims/roots/cloud","test/claims/roots/json"]'

  comparison applied identical
  pick 'a push with nothing changed since the last commit applied in full plans no root' '[]'

  comparison applied ahead .github/workflows/terraform.yml
  pick 'a push that changes a workflow plans every root' "$all"

  SHARED_PATHS=test/modules/ comparison applied ahead test/modules/pet/main.tf
  SHARED_PATHS=test/modules/ pick 'a push that changes a shared path plans every root' "$all"

  comparison applied diverged test/claims/roots/json/main.tf.json
  pick "a push whose last commit applied in full is not in its history plans every root" "$all"

  rm "$STUB/compare-applied.json"
  pick 'a push whose last commit applied in full cannot be compared plans every root' "$all"

  # shellcheck disable=SC2046 # one file name per word
  comparison applied ahead $(seq -f 'docs/%g.md' 300)
  pick 'a push with too many changes to list plans every root' "$all"

  reset
  deployments
  pick 'a push with no commit applied in full plans every root' "$all"

  # Each newer deployment does not count. The one that counts compares as
  # changing one root, and the newer one as changing none. So either would
  # show.
  for case in "octocat success" "$bot pending" "$bot failure" "$bot"; do
    reset
    read -r who states <<<"$case"
    deployments "3 newer $case" "2 applied $bot inactive success"
    comparison newer identical
    comparison applied ahead test/claims/roots/json/main.tf.json
    pick "a deployment by $who, with statuses '${states:-none}', does not count" '["test/claims/roots/json"]'
  done

  reset
  deployments "2 applied $bot success"
  EVENT=workflow_dispatch pick 'a run by hand plans every root' "$all"

  # The Applied job's record is the one the Roots job looks for.
  reset
  deployments
  pick 'a push with no record plans every root' "$all"
  task=$(sed -n 's/^applied-task=//p' "$out")
  claim='a commit applied in full is recorded'
  if GITHUB_SHA=recorded TASK=$task GITHUB_SERVER_URL=https://github.com \
    "$top/test/run-step.sh" 'Record the commit' applied > "$log" 2>&1 &&
    jq -e --arg env "$APPLY_ENVIRONMENT" --arg task "$task" \
      '.ref == "recorded" and .environment == $env and .task == $task and .required_contexts == []' "$STUB/created.json" > /dev/null &&
    grep -qx 'state=success' "$STUB/status.txt"; then
    pass "$claim"
  else
    fail "$claim"
  fi
  deployments "7 recorded $bot success"
  comparison recorded ahead test/claims/roots/json/main.tf.json
  pick 'the next push plans the roots changed since the recorded commit' '["test/claims/roots/json"]'
fi

if [ "$section" = applies ]; then
  # The changes job. A root is applied only if its latest plan has changes.
  planned='[{"path":"a","slug":"a"},{"path":"b/c","slug":"b-c"}]'
  # Runs the step with the run's artifacts named in $2... and checks what it
  # applies against $1's expectation. An expectation of `fails` means the step
  # must fail.
  check_changes() {
    local claim=$1 expected=$2 status=0
    shift 2
    printf '%s\n' "$@" | jq -Rn '{artifacts: [inputs | select(length > 0) | {name: .}]}' > "$STUB/run-artifacts.json"
    : > "$out"
    GITHUB_OUTPUT="$out" PLANNED=$planned "$top/test/run-step.sh" 'Pick the roots whose plan has changes' changes > "$log" 2>&1 || status=$?
    if [ "$expected" = fails ]; then
      if [ "$status" != 0 ] && grep -q 'No plan was saved for: b/c' "$log"; then pass "$claim"; else fail "$claim"; fi
    elif [ "$status" = 0 ] && [ "$(sed -n 's/^apply=//p' "$out")" = "$expected" ]; then
      pass "$claim"
    else
      echo "     picked: $(sed -n 's/^apply=//p' "$out")" >> "$log"
      fail "$claim"
    fi
  }
  reset
  check_changes 'only a root whose plan has changes is applied' \
    '[{"path":"b/c","slug":"b-c","artifact":"tfplan-b-c-attempt-1"}]' \
    noplan-a-attempt-1 tfplan-b-c-attempt-1 tfplan-other-attempt-1 tfplan-a-b-attempt-1
  check_changes 'no root is applied when no plan has changes' '[]' noplan-a-attempt-1 noplan-b-c-attempt-1
  check_changes "a re-run that finds no changes does not apply an earlier attempt's plan" '[]' \
    tfplan-a-attempt-1 tfplan-b-c-attempt-1 noplan-a-attempt-2 noplan-b-c-attempt-2
  check_changes "a re-run of failed jobs applies the plans it kept from an earlier attempt" \
    '[{"path":"a","slug":"a","artifact":"tfplan-a-attempt-1"},{"path":"b/c","slug":"b-c","artifact":"tfplan-b-c-attempt-2"}]' \
    tfplan-a-attempt-1 noplan-b-c-attempt-1 tfplan-b-c-attempt-2
  check_changes 'a planned root with no saved plan stops the job' fails tfplan-a-attempt-1

  # The plan step. It saves whether the plan has changes.
  plan() {
    local dir="$work/root-$2"
    mkdir -p "$dir"
    printf '%s\n' "$3" > "$dir/main.tf"
    : > "$out"
    status=0
    export TF_DATA_DIR="$dir/.terraform"
    (cd "$dir" && terraform init -no-color > /dev/null && GITHUB_OUTPUT="$out" "$top/test/run-step.sh" 'Terraform Plan' plan) > "$log" 2>&1 || status=$?
  }
  plan 'a plan with changes' changes 'resource "terraform_data" "this" {}'
  claim='a plan with changes says so'
  if [ "$status" = 0 ] && grep -qx 'changes=true' "$out"; then pass "$claim"; else fail "$claim"; fi
  plan 'a plan without changes' none 'locals {}'
  claim='a plan without changes says so'
  if [ "$status" = 0 ] && grep -qx 'changes=false' "$out"; then pass "$claim"; else fail "$claim"; fi
  plan 'a plan that fails' broken 'resource "terraform_data" "this" { input = file("missing") }'
  claim='a plan that fails, fails the step'
  if [ "$status" != 0 ] && ! grep -q '^changes=' "$out"; then pass "$claim"; else fail "$claim"; fi
fi

exit $failed
