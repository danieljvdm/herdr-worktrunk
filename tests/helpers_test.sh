#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"

for tok in '^' '-' 'pr:123' 'mr:45' 'https://github.com/o/r/pull/7'; do
  if ! worktrunk_is_shortcut "$tok"; then
    printf 'expected %q to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# @ (current) is intentionally not a shortcut — see helpers.sh.
for tok in 'my-feature' 'main' 'feature/foo' '@'; do
  if worktrunk_is_shortcut "$tok"; then
    printf 'expected %q not to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# worktrunk_ref_exists resolves both local heads and remote-tracking branches.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
(
  cd "$sandbox"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD
)
cd "$sandbox"

for ref in 'feature' 'origin/remote-feat'; do
  if ! worktrunk_ref_exists "$ref"; then
    printf 'expected %q to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

for ref in 'does-not-exist' 'origin/nope'; do
  if worktrunk_ref_exists "$ref"; then
    printf 'expected %q not to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

cd - >/dev/null

schema_one='[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true,"is_current":false},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false,"is_current":true},
  {"branch":"ready","kind":"branch"}
]'
schema_two='{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true,"current":false}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false,"current":true}},
    {"branch":"ready"}
  ]
}'
expected_items='main|worktree|/repo|true|false
feature|worktree|/repo.feature|false|true
ready|branch|null|false|false'

for list_json in "$schema_one" "$schema_two"; do
  actual_items=$(printf '%s\n' "$list_json" \
    | worktrunk_list_items \
    | jq -r '[.branch, .kind, (.path | tostring), (.is_main | tostring), (.is_current | tostring)] | join("|")')
  if [[ $actual_items != "$expected_items" ]]; then
    printf 'unexpected normalized worktrunk list items:\n%s\n' "$actual_items" >&2
    exit 1
  fi

  current_item=$(printf '%s\n' "$list_json" | worktrunk_current_worktree)
  if [[ $(printf '%s\n' "$current_item" | jq -r '.branch') != feature ]]; then
    printf 'expected feature to be the current worktree, got %s\n' "$current_item" >&2
    exit 1
  fi

  actual_paths=$(printf '%s\n' "$list_json" | worktrunk_list_worktree_paths_json)
  if [[ $actual_paths != '["/repo","/repo.feature"]' ]]; then
    printf 'unexpected worktree path snapshot: %s\n' "$actual_paths" >&2
    exit 1
  fi

  started_path=$(printf '%s\n' "$list_json" \
    | worktrunk_started_worktree_path feature '["/repo"]')
  if [[ $started_path != '/repo.feature' ]]; then
    printf 'expected exact started path, got %q\n' "$started_path" >&2
    exit 1
  fi

  shortcut_path=$(printf '%s\n' "$list_json" \
    | worktrunk_started_worktree_path 'pr:42' '["/repo"]')
  if [[ $shortcut_path != '/repo.feature' ]]; then
    printf 'expected unique new started path, got %q\n' "$shortcut_path" >&2
    exit 1
  fi
done

ambiguous='[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"one","kind":"worktree","path":"/repo.one","is_main":false},
  {"branch":"two","kind":"worktree","path":"/repo.two","is_main":false}
]'
ambiguous_path=$(printf '%s\n' "$ambiguous" \
  | worktrunk_started_worktree_path 'pr:42' '["/repo"]')
if [[ -n $ambiguous_path ]]; then
  printf 'expected ambiguous new paths to remain unresolved, got %q\n' "$ambiguous_path" >&2
  exit 1
fi

if printf '%s\n' '{"schema":3}' | worktrunk_list_items >/dev/null 2>&1; then
  printf 'expected unsupported worktrunk list schema to fail\n' >&2
  exit 1
fi

printf 'helpers tests passed\n'
