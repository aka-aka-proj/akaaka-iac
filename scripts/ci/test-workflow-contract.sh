#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
workflow="$repo_root/.github/workflows/iac-ci.yml"
template="$repo_root/.github/pull_request_template.md"
hook="$repo_root/.githooks/pre-push"

require_literal() {
  file=$1
  literal=$2
  grep -Fq -- "$literal" "$file" || {
    printf 'missing required workflow contract in %s: %s\n' "$file" "$literal" >&2
    exit 1
  }
}

require_literal "$workflow" 'types: [opened, synchronize, reopened, edited]'
require_literal "$workflow" "github.event.action == 'edited' && 'metadata' || 'heavy'"
require_literal "$workflow" 'migrations: ${{ steps.changes.outputs.migrations }}'
require_literal "$workflow" 'functions: ${{ steps.changes.outputs.functions }}'
require_literal "$workflow" 'cloudflare: ${{ steps.changes.outputs.cloudflare }}'
require_literal "$workflow" "needs: contract-gate"
require_literal "$workflow" "github.event.action != 'edited'"
require_literal "$template" 'Compatibility: backward-compatible'
require_literal "$template" 'Docs: none'
require_literal "$hook" 'supabase status'

if grep -Fq "matrix.target.name == 'functions'" "$workflow"; then
  printf 'function checks must not remain as unreachable migration matrix steps\n' >&2
  exit 1
fi

test -x "$hook" || {
  printf 'pre-push hook must exist and be executable\n' >&2
  exit 1
}

printf 'IaC workflow contract passed\n'
