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
assert_preview 'branch: (model-named) · agent: claude' "@claude repair the login flow"
assert_preview 'branch: (model-named) · agent: claude' "repair the login flow"

# A branch hint fills in when the grammar names none.
WORKTRUNK_BRANCH_HINT=hinted-branch \
  assert_preview 'branch: hinted-branch · agent: claude' "repair the login flow"

# default_agent config steers the preview.
config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
printf 'default_agent = "codex"\n' > "$config_dir/config.toml"
HERDR_PLUGIN_CONFIG_DIR=$config_dir \
  assert_preview 'branch: (model-named) · agent: codex' "repair the login flow"

# branch_name_command output is sanitized into a plausible branch name, and a
# failing/empty namer falls back to the slug (observable via the wt call —
# not covered here; sanitize via the config path instead).
assert_named() {
  local expected=$1 namer=$2
  local out
  printf 'branch_name_command = "%s"\n' "$namer" > "$config_dir/config.toml"
  out=$(HERDR_PLUGIN_CONFIG_DIR=$config_dir HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; name_branch_with_model "task"' _ "$dispatch_lib" 2>/dev/null)
  if [[ $out != "$expected" ]]; then
    printf 'expected named branch %q from namer %q, got %q\n' "$expected" "$namer" "$out" >&2
    exit 1
  fi
}

# Source dispatch.sh's functions without running its main flow: extract up to
# the option loop into a temp lib.
dispatch_lib=$config_dir/dispatch_lib.sh
sed -n '1,/^agent_kind=/p' "$dispatch" | sed '$d' > "$dispatch_lib"

assert_named fix-auth "printf 'Fix Auth!\\n'"
assert_named fix-auth "printf 'chatter\\nfix-auth\\n'"      # last line wins
assert_named fix-auth "printf '  --fix-auth--  \\n'"        # trimmed + squeezed

printf 'dispatch tests passed\n'
