#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
workflow="$repo_root/.github/workflows/iac-ci.yml"
metadata_workflow="$repo_root/.github/workflows/iac-contract-edit.yml"
template="$repo_root/.github/pull_request_template.md"
hook="$repo_root/.githooks/pre-push"
fetch_contract="$repo_root/scripts/ci/fetch-pr-contract-inputs.sh"

require_literal() {
  file=$1
  literal=$2
  grep -Fq -- "$literal" "$file" || {
    printf 'missing required workflow contract in %s: %s\n' "$file" "$literal" >&2
    exit 1
  }
}

require_literal "$workflow" 'types: [opened, synchronize, reopened]'
require_literal "$workflow" 'migrations: ${{ steps.changes.outputs.migrations }}'
require_literal "$workflow" 'functions: ${{ steps.changes.outputs.functions }}'
require_literal "$workflow" 'cloudflare: ${{ steps.changes.outputs.cloudflare }}'
require_literal "$workflow" "needs: contract-gate"
require_literal "$workflow" 'scripts/ci/test-workflow-contract.sh'
require_literal "$workflow" 'scripts/ci/test-validate-pr-contract.sh'
require_literal "$metadata_workflow" 'types: [edited]'
require_literal "$metadata_workflow" 'name: Compatibility & docs-first declaration gate'
require_literal "$fetch_contract" '.previous_filename // empty'
require_literal "$fetch_contract" 'changed_files'
require_literal "$fetch_contract" '-ge 3000'
require_literal "$template" 'Compatibility: backward-compatible'
require_literal "$template" 'Docs: none'
require_literal "$hook" 'supabase status'
require_literal "$hook" 'git status --porcelain'
require_literal "$hook" 'git rev-parse HEAD'
require_literal "$hook" '--no-renames --name-only'

if grep -Fq 'edited' "$workflow"; then
  printf 'heavy IaC workflow must not react to pull_request.edited\n' >&2
  exit 1
fi

if grep -Fq "matrix.target.name == 'functions'" "$workflow"; then
  printf 'function checks must not remain as unreachable migration matrix steps\n' >&2
  exit 1
fi

test -x "$hook" || {
  printf 'pre-push hook must exist and be executable\n' >&2
  exit 1
}

printf 'IaC workflow contract passed\n'
