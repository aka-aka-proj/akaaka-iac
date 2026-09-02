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
  esac
done

printf 'migrations=%s\n' "$migrations"
printf 'functions=%s\n' "$functions"
printf 'cloudflare=%s\n' "$cloudflare"
