#!/usr/bin/env bash
set -euo pipefail

repo="${1:?repository required}"
sha="${2:?commit sha required}"

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

checks_tmp="$(mktemp)"
status_tmp="$(mktemp)"
trap 'rm -f "$checks_tmp" "$status_tmp"' EXIT

if ! gh api \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  --paginate \
  --slurp \
  "repos/$repo/commits/$sha/check-runs?per_page=100" >"$checks_tmp"; then
  fail "cannot read check-runs for $repo@$sha; release readiness is unknown"
fi

if ! gh api \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  --paginate \
  --slurp \
  "repos/$repo/commits/$sha/status?per_page=100" >"$status_tmp"; then
  fail "cannot read commit statuses for $repo@$sha; release readiness is unknown"
fi

jq -n \
  --slurpfile check_pages "$checks_tmp" \
  --slurpfile status_pages "$status_tmp" '
  def check_failed($value):
    ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"] | index($value) != null;
  def status_failed($value):
    ["failure", "error"] | index($value) != null;
  ($check_pages[0] | map(.check_runs // []) | add // []) as $checks
  | ($status_pages[0] | map(.statuses // []) | add // []) as $statuses
  | {
    failed: (
      ([ $checks[]? | (.conclusion // "") as $conclusion | select(check_failed($conclusion)) ] | length)
      +
      ([ $statuses[]? | (.state // "") as $state | select(status_failed($state)) ] | length)
    ),
    pending: (
      ([ $checks[]? | select((.status // "") != "completed") ] | length)
      +
      ([ $statuses[]? | (.state // "") | select(. == "pending") ] | length)
    ),
    check_runs: ($checks | length),
    statuses: ($statuses | length)
  }
'
