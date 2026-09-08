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
  "repos/$repo/commits/$sha/check-runs?per_page=100" >"$checks_tmp"; then
  fail "cannot read check-runs for $repo@$sha; release readiness is unknown"
fi

if ! gh api \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "repos/$repo/commits/$sha/status" >"$status_tmp"; then
  fail "cannot read commit statuses for $repo@$sha; release readiness is unknown"
fi

jq -n \
  --slurpfile checks "$checks_tmp" \
  --slurpfile statuses "$status_tmp" '
  def check_failed:
    ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"] | index(.) != null;
  def status_failed:
    ["failure", "error"] | index(.) != null;
  {
    failed: (
      ([ $checks[0].check_runs[]? | (.conclusion // "") | select(check_failed) ] | length)
      +
      ([ $statuses[0].statuses[]? | (.state // "") | select(status_failed) ] | length)
    ),
    pending: (
      ([ $checks[0].check_runs[]? | select((.status // "") != "completed") ] | length)
      +
      ([ $statuses[0].statuses[]? | (.state // "") | select(. == "pending") ] | length)
    ),
    check_runs: ($checks[0].check_runs | length),
    statuses: ($statuses[0].statuses | length)
  }
'