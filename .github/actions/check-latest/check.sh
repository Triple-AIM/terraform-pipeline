#!/bin/bash
# Stops the job unless $GITHUB_SHA is the latest commit on the default branch.
#
# Under `pull_request`, the commit is the pull request's own merge, so there
# is nothing to compare. The pipeline only runs under it when testing itself.
set -euo pipefail

if [ "$EVENT" = pull_request ]; then
  echo "Not checked under pull_request."
  exit 0
fi
latest=$(gh api "repos/$GITHUB_REPOSITORY/commits/heads/$DEFAULT_BRANCH" --jq .sha)
if [ "$latest" != "$GITHUB_SHA" ]; then
  echo "::error::This run belongs to commit $GITHUB_SHA, but the default branch is now at $latest. A run cannot go on with an older pipeline and config. For a pull request, push to it, or close and reopen it."
  exit 1
fi
echo "The run's commit is the latest on the default branch."
