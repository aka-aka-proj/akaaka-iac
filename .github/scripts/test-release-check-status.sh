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
  *check-runs*) printf '%s\n' "${MOCK_CHECKS:?}" ;;
  */status) printf '%s\n' "${MOCK_STATUS:?}" ;;
  *) exit 99 ;;
esac
GH
chmod +x "$tmp/gh"

PATH="$tmp:$PATH"
export PATH

assert_json() {
  local name="$1" checks="$2" statuses="$3" expected="$4" actual
  MOCK_CHECKS="$checks" MOCK_STATUS="$statuses" actual="$($TARGET owner/repo deadbeef)"
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

echo "release-check-status tests passed"
