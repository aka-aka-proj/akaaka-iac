#!/bin/sh

set -eu

migrations=false
functions=false
cloudflare=false

while IFS= read -r file; do
  [ -n "$file" ] || continue

  case "$file" in
    .github/workflows/iac-ci.yml|scripts/ci/*|.githooks/*)
      migrations=true
      functions=true
      cloudflare=true
      ;;
    README.md|AGENTS.md|docs/*|.github/pull_request_template.md|.github/workflows/*)
      # Known governance-only paths do not need runtime runners.
      ;;
    supabase/migrations/*|supabase/tests/*|supabase/config.toml)
      migrations=true
      ;;
    supabase/functions/*|supabase/ledger/*)
      functions=true
      ;;
    cloudflare/*)
      cloudflare=true
      ;;
    supabase/*)
      # Unknown Supabase runtime paths fail safe until a fixture defines them.
      migrations=true
      functions=true
      cloudflare=true
      ;;
    *)
      # Unknown roots may introduce a new runtime provider. Expand validation
      # until an explicit metadata or runtime fixture classifies the path.
      migrations=true
      functions=true
      cloudflare=true
      ;;
  esac
done

printf 'migrations=%s\n' "$migrations"
printf 'functions=%s\n' "$functions"
printf 'cloudflare=%s\n' "$cloudflare"
