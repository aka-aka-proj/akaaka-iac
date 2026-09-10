#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
classifier="$repo_root/scripts/ci/classify-changes.sh"

assert_case() {
  name=$1
  expected=$2
  paths=$3

  actual=$(printf '%s\n' "$paths" | "$classifier")
  if [ "$actual" != "$expected" ]; then
    printf 'case %s failed\nexpected:\n%s\nactual:\n%s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

none='migrations=false
functions=false
cloudflare=false'
all='migrations=true
functions=true
cloudflare=true'

assert_case metadata-only "$none" 'README.md'
assert_case workflow-only "$none" '.github/workflows/weekly-production-release.yml'
assert_case opencode-command "$none" '.opencode/commands/work-issue.md'
assert_case migration 'migrations=true
functions=false
cloudflare=false' 'supabase/migrations/20260901000000_example.sql'
assert_case pgtap 'migrations=true
functions=false
cloudflare=false' 'supabase/tests/example_test.sql'
assert_case config 'migrations=true
functions=false
cloudflare=false' 'supabase/config.toml'
assert_case functions 'migrations=false
functions=true
cloudflare=false' 'supabase/functions/example/index.ts'
assert_case ledger 'migrations=false
functions=true
cloudflare=false' 'supabase/ledger/001_deletion_ledger_bootstrap.sql'
assert_case cloudflare 'migrations=false
functions=false
cloudflare=true' 'cloudflare/deletion-ledger-worker/src/index.ts'
assert_case mixed 'migrations=true
functions=true
cloudflare=false' 'supabase/migrations/20260901000000_example.sql
supabase/functions/example/index.ts'
assert_case ci-router "$all" 'scripts/ci/classify-changes.sh'
assert_case ci-test "$all" 'scripts/ci/test-classify-changes.sh'
assert_case ci-workflow "$all" '.github/workflows/iac-ci.yml'
assert_case hook "$all" '.githooks/pre-push'
assert_case unknown-supabase "$all" 'supabase/new-runtime/file.txt'
assert_case unknown-runtime-root "$all" 'new-provider/runtime/config.json'

printf 'changed-path classifier contract passed\n'
