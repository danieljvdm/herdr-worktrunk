#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dispatch="$repo_root/dispatch.sh"

assert_slug() {
  local expected=$1; shift
  local actual
  actual=$(bash "$dispatch" --slug "$@" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected slug %q for %q, got %q\n' "$expected" "$*" "$actual" >&2
    exit 1
  fi
}

assert_preview() {
  local expected=$1; shift
  local actual
  actual=$(bash "$dispatch" --preview "$@" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected preview %q for %q, got %q\n' "$expected" "$*" "$actual" >&2
    exit 1
  fi
}

unset HERDR_PLUGIN_CONFIG_DIR WORKTRUNK_BRANCH_HINT

# Filler words drop out; the first four meaningful words survive.
assert_slug fix-flaky-token-refresh "fix the flaky token refresh in auth"
assert_slug fix-auth "Fix auth!"
assert_slug rewrite-search-index-use "rewrite the search index to use sqlite and add tests"

# Slugs cap at 40 chars and non-alphanumerics become separators.
assert_slug supercalifragilisticexpialidocious-refac "supercalifragilisticexpialidocious refactoring extravaganza bonanza"
assert_slug bump-node-22-lts "bump node -> 22 (LTS)"

# No derivable words is an error, not an empty slug.
if bash "$dispatch" --slug "the a an" >/dev/null 2>&1; then
  printf 'expected --slug to fail on filler-only text\n' >&2
  exit 1
fi

# Grammar: @agent and branch-name: peel off the front, in either order.
assert_preview 'branch: fix-login · agent: codex' "@codex fix-login: repair the login flow"
assert_preview 'branch: fix-login · agent: codex' "fix-login: @codex repair the login flow"
assert_preview 'branch: repair-login-flow · agent: claude' "@claude repair the login flow"
assert_preview 'branch: repair-login-flow · agent: claude' "repair the login flow"

# A branch hint fills in when the grammar names none.
WORKTRUNK_BRANCH_HINT=hinted-branch \
  assert_preview 'branch: hinted-branch · agent: claude' "repair the login flow"

# default_agent config steers the preview.
config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
printf 'default_agent = "codex"\n' > "$config_dir/config.toml"
HERDR_PLUGIN_CONFIG_DIR=$config_dir \
  assert_preview 'branch: repair-login-flow · agent: codex' "repair the login flow"

printf 'dispatch tests passed\n'
