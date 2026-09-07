#!/bin/sh

set -eu

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

pr_json="$RUNNER_TEMP/pr.json"
pages_json="$RUNNER_TEMP/pr_files_pages.json"
files_json="$RUNNER_TEMP/pr_files.json"

gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" > "$pr_json" \
  || { echo "::error::cannot read PR metadata; refusing to evaluate an unknown diff"; exit 1; }

changed_files=$(jq -r '.changed_files' "$pr_json")
if [ "$changed_files" -ge 3000 ]; then
  echo "::error::PR has $changed_files changed files, at or above the GitHub PR files API limit; split the PR before routing checks"
  exit 1
fi

gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files" --paginate > "$pages_json" \
  || { echo "::error::cannot fetch PR files; refusing to route checks on an unknown diff"; exit 1; }
jq -s 'flatten' "$pages_json" > "$files_json"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  jq -r '.[] | .filename, (.previous_filename // empty)' "$files_json" \
    | sort -u \
    | scripts/ci/classify-changes.sh >> "$GITHUB_OUTPUT"
fi
