#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pr_status="$repo_root/pr-status.sh"

assert_label() {
  local expected=$1 json=$2 actual
  actual=$(printf '%s' "$json" | bash "$pr_status" --format)
  if [[ $actual != "$expected" ]]; then
    printf 'expected label %q for %q, got %q\n' "$expected" "$json" "$actual" >&2
    exit 1
  fi
}

assert_label '#123' '{"number":123,"state":"OPEN","isDraft":false}'
assert_label '#123 draft' '{"number":123,"state":"OPEN","isDraft":true}'
assert_label '#123 merged' '{"number":123,"state":"MERGED","isDraft":false}'
assert_label '#123 closed' '{"number":123,"state":"CLOSED","isDraft":false}'
# A merged/closed PR is never also flagged draft, regardless of isDraft.
assert_label '#123 merged' '{"number":123,"state":"MERGED","isDraft":true}'

# report/open no-op quietly outside a Herdr workspace (no HERDR_WORKSPACE_ID).
unset HERDR_WORKSPACE_ID HERDR_PLUGIN_CONTEXT_JSON 2>/dev/null || true
bash "$pr_status" report

echo "pr_status_test: ok"
