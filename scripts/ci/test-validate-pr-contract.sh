#!/bin/sh

set -eu

if ! command -v jq >/dev/null 2>&1; then
  printf 'IaC contract validator regression skipped: jq is unavailable locally (GitHub Actions provides jq)\n'
  exit 0
fi

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
validator="$repo_root/scripts/ci/validate-pr-contract.sh"
temp_root=$(mktemp -d)
trap 'rm -rf "$temp_root"' EXIT

run_case() {
  name=$1
  body=$2
  files=$3
  expected=$4
  case_dir="$temp_root/$name"
  mkdir -p "$case_dir"
  printf '%s' "{\"body\":$(printf '%s' "$body" | jq -Rs .)}" > "$case_dir/pr.json"
  printf '%s' "$files" > "$case_dir/pr_files.json"
  if RUNNER_TEMP="$case_dir" DOCS_REPO=aka-aka-proj/akaaka-docs "$validator" >"$case_dir/output" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [ "$actual" -ne "$expected" ]; then
    printf '%s failed: expected exit %s, got %s\n%s\n' "$name" "$expected" "$actual" "$(cat "$case_dir/output")" >&2
    exit 1
  fi
}

run_case drop-if-exists \
  'Compatibility: backward-compatible
Docs: none' \
  '[{"filename":"supabase/migrations/20260907000100_drop.sql","status":"modified","patch":"@@\n+DROP TABLE IF EXISTS public.events;"}]' 1

run_case missing-patch \
  'Compatibility: backward-compatible
Docs: none' \
  '[{"filename":"supabase/migrations/20260907000200_large.sql","status":"modified"}]' 1

run_case function-entrypoint-removal \
  'Compatibility: backward-compatible
Docs: none' \
  '[{"filename":"supabase/functions/old-handler/index.ts","status":"removed","patch":"@@"}]' 1

run_case workflow-needs-docs \
  'Compatibility: backward-compatible' \
  '[{"filename":".github/workflows/iac-ci.yml","status":"modified","patch":"@@\n+jobs:"}]' 1

run_case workflow-with-docs \
  'Compatibility: backward-compatible
Docs: none' \
  '[{"filename":".github/workflows/iac-ci.yml","status":"modified","patch":"@@\n+jobs:"}]' 0

printf 'IaC contract validator regression passed\n'
