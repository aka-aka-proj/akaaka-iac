#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/release-check-status.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "$url" in
  *check-runs*) [ "${MOCK_CHECKS_EXIT:-0}" -eq 0 ] || exit "$MOCK_CHECKS_EXIT"; printf '%s\n' "${MOCK_CHECKS:?}" ;;
  */status) [ "${MOCK_STATUS_EXIT:-0}" -eq 0 ] || exit "$MOCK_STATUS_EXIT"; printf '%s\n' "${MOCK_STATUS:?}" ;;
  *) exit 99 ;;
esac
GH
chmod +x "$tmp/gh"

PATH="$tmp:$PATH"
export PATH

assert_json() {
  local name="$1" checks="$2" statuses="$3" expected="$4" actual
  actual="$(env MOCK_CHECKS="$checks" MOCK_STATUS="$statuses" "$TARGET" owner/repo deadbeef)"
  if ! jq -e --argjson e "$expected" '. == $e' <<<"$actual" >/dev/null; then
    echo "FAIL: $name" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

assert_json \
  success \
  '{"check_runs":[{"status":"completed","conclusion":"success"}]}' \
  '{"statuses":[{"state":"success"}]}' \
  '{"failed":0,"pending":0,"check_runs":1,"statuses":1}'

assert_json \
  failure \
  '{"check_runs":[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]}' \
  '{"statuses":[{"state":"error"}]}' \
  '{"failed":2,"pending":0,"check_runs":2,"statuses":1}'

assert_json \
  pending \
  '{"check_runs":[{"status":"in_progress","conclusion":null}]}' \
  '{"statuses":[{"state":"pending"}]}' \
  '{"failed":0,"pending":2,"check_runs":1,"statuses":1}'

assert_read_failure() {
  local name="$1" endpoint="$2" output
  if output="$(MOCK_CHECKS='{"check_runs":[]}' MOCK_STATUS='{"statuses":[]}' env "$endpoint=1" "$TARGET" owner/repo deadbeef 2>&1)"; then
    echo "FAIL: $name unexpectedly succeeded" >&2
    exit 1
  fi
  if ! grep -Fq 'release readiness is unknown' <<<"$output"; then
    echo "FAIL: $name did not report fail-closed readiness" >&2
    exit 1
  fi
}

assert_read_failure check_runs_denied MOCK_CHECKS_EXIT
assert_read_failure statuses_denied MOCK_STATUS_EXIT

echo "release-check-status tests passed"
