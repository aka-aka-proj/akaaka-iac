#!/bin/bash

set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${DOCS_REPO:?DOCS_REPO is required}"

files_json="$RUNNER_TEMP/pr_files.json"
pr_json="$RUNNER_TEMP/pr.json"
fail() { echo "::error::$1"; exit 1; }

test -s "$files_json" || fail "PR files are unavailable; refusing to validate an unknown diff"
test -s "$pr_json" || fail "PR metadata is unavailable; refusing to validate unknown input"

body=$(jq -r '.body // ""' "$pr_json")
touches=0
while IFS= read -r file; do
  case "$file" in
    supabase/migrations/* | supabase/functions/*) touches=1; break ;;
  esac
done < <(jq -r '.[] | .filename, (.previous_filename // empty)' "$files_json")

compat=$(printf '%s' "$body" | awk 'tolower($0) ~ /^compatibility:/ {gsub(/\r/,""); sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}')
docs_decl=$(printf '%s' "$body" | awk 'tolower($0) ~ /^docs:/ {gsub(/\r/,""); sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}')

if [ "$touches" -eq 0 ]; then
  if [ -n "$compat" ] && ! printf '%s' "$compat" | grep -Eq '^(backward-compatible|expand-only|contract-step)$'; then
    fail "Compatibility value '$compat' is not one of backward-compatible | expand-only | contract-step"
  fi
  echo "PR does not touch supabase contract paths; declaration gate satisfied."
  exit 0
fi

case "$compat" in
  backward-compatible|expand-only|contract-step) : ;;
  "") fail "PR touches supabase/migrations or supabase/functions but the body is missing the required declaration: 'Compatibility: backward-compatible | expand-only | contract-step'" ;;
  *) fail "Compatibility value '$compat' is not one of backward-compatible | expand-only | contract-step" ;;
esac

detected=""
migration_pattern='(DROP[[:space:]]+(TABLE|COLUMN|CONSTRAINT|POLICY|FUNCTION|SCHEMA)|ALTER[[:space:]]+TABLE[^;]*DROP[[:space:]]+(COLUMN|CONSTRAINT)|REVOKE[[:space:]]|SET[[:space:]]+NOT[[:space:]]+NULL)'
while IFS= read -r entry; do
  filename="${entry%%$'\t'*}"
  patch=$(jq -r --arg file "$filename" '[.[] | select(.filename == $file)][0].patch // ""' "$files_json")
  case "$filename" in
    supabase/migrations/*)
      plus_lines=$(printf '%s' "$patch" | grep '^+' || true)
      contract_lines=$(printf '%s\n' "$plus_lines" \
        | grep -Ev 'REVOKE[^;]*ON[[:space:]]+FUNCTION' \
        | grep -Ev 'DROP[[:space:]]+(TABLE|COLUMN|CONSTRAINT|POLICY|FUNCTION|SCHEMA)[[:space:]]+IF[[:space:]]+EXISTS' \
        || true)
      created_objects=$(printf '%s\n' "$plus_lines" \
        | sed -nE 's/^\+[[:space:]]*CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.]*).*/\2/p' \
        | awk -F. '{print $NF}' | sort -u | tr '\n' '|' | sed 's/|$//')
      if [ -n "$created_objects" ]; then
        contract_lines=$(printf '%s\n' "$contract_lines" \
          | grep -Eiv "REVOKE[^;]*ON[[:space:]]+(TABLE[[:space:]]+)?[A-Za-z0-9_.]*($created_objects)([[:space:];]|$)" \
          || true)
      fi
      hits=$(printf '%s\n' "$contract_lines" | grep -Ei "$migration_pattern" || true)
      if [ -n "$hits" ]; then detected="migrations:$filename"; fi
      ;;
    supabase/functions/*)
      deleted_exports=$(printf '%s' "$patch" | grep '^-.*export ' || true)
      if [ -n "$deleted_exports" ]; then detected="functions-export-removed:$filename"; fi
      ;;
  esac
  [ -z "$detected" ] || break
done < <(jq -r '.[] | [.filename] | @tsv' "$files_json")

if [ -n "$detected" ] && [ "$compat" != "contract-step" ]; then
  fail "Declaration mismatch: diff shows breaking change ($detected) but declared '$compat'. Declare 'Compatibility: contract-step' or fix the change."
fi

if [ -z "$docs_decl" ]; then
  fail "PR body is missing the required 'Docs:' declaration ('Docs: none' or akaaka-docs PR numbers). Contract: docs-first binding in 001-vercel-deployment-spec.md."
fi

if [ "$(printf '%s' "$docs_decl" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != "none" ]; then
  if [ -z "${CROSS_REPO_TOKEN:-}" ]; then
    fail "AKA_REPO_TOKEN secret is required to validate akaaka-docs dependency merge state; set it or declare 'Docs: none' when no docs change is needed"
  fi
  for docs_number in $(printf '%s' "$docs_decl" | tr ',' ' '); do
    case "$docs_number" in ''|*[!0-9]*) fail "Docs reference '$docs_number' is not an akaaka-docs PR number" ;; esac
    stamp=$(gh api "repos/$DOCS_REPO/pulls/$docs_number" --jq '[(.state // ""),((.merged // false)|tostring),(.base.ref // "")] | @tsv' 2>/dev/null) \
      || fail "Referenced akaaka-docs PR #$docs_number does not exist"
    state=$(printf '%s' "$stamp" | cut -f1)
    merged=$(printf '%s' "$stamp" | cut -f2)
    base=$(printf '%s' "$stamp" | cut -f3)
    if [ "$state" != "closed" ] || [ "$merged" != "true" ] || [ "$base" != "main" ]; then
      fail "Referenced akaaka-docs PR #$docs_number is not merged into $DOCS_REPO main (state=$state merged=$merged); authoritative documentation must land first"
    fi
  done
fi

echo "contract-gate passed (Compatibility=$compat; Docs=$docs_decl)"
