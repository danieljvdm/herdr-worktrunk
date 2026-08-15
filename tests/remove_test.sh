#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
remove="$repo_root/remove.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fake repo layout the fixtures point into.
repo="$work/repo"
mkdir -p "$repo/.worktrees/one" "$repo/.worktrees/two" "$repo/.git/wt/trash/one-123"

# Current removal must not invoke Worktrunk's full-list path: that computes
# status and integration metadata for every sibling worktree. Make any `wt`
# call fail so these resolution tests protect the fast topology-only path.
mkdir -p "$work/bin"
cat > "$work/bin/wt" <<'EOF'
#!/usr/bin/env bash
printf 'remove_test: unexpected wt invocation: %s\n' "$*" >&2
exit 99
EOF
# Fake `git`: emits the cheap topology data used by remove-current.
cat > "$work/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"worktree list --porcelain"*) cat <<'TOPOLOGY'
worktree $repo
HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
branch refs/heads/main

worktree $repo/.worktrees/one
HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
branch refs/heads/dan/one

worktree $repo/.worktrees/two
HEAD cccccccccccccccccccccccccccccccccccccccc
branch refs/heads/dan/two

TOPOLOGY
    ;;
  *) exit 1 ;;
esac
EOF
# Fake `herdr`: maps .worktrees/two to workspace wTWO, everything else unmapped.
cat > "$work/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "worktree list"*) printf '{"result":{"worktrees":[{"path":"%s","open_workspace_id":"wTWO"}]}}\n' "$repo/.worktrees/two" ;;
  "agent list"*) printf '{"result":{"agents":[]}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
EOF
chmod +x "$work/bin/wt" "$work/bin/git" "$work/bin/herdr"
export PATH="$work/bin:$PATH"
unset WORKTRUNK_REMOVE_CHECKOUT WORKTRUNK_REMOVE_WORKSPACE WORKTRUNK_REMOVE_WORKSPACE_LABEL HERDR_WORKSPACE_ID

run_resolve() {  # [env KEY=VALUE ...] -- extra args...
  local envs=()
  while [[ ${1:-} == *=* ]]; do envs+=("$1"); shift; done
  (cd "${RESOLVE_CWD:-$repo}" && env "${envs[@]}" bash "$remove" --current --resolve </dev/null)
}

assert_contains() {
  local haystack=$1 needle=$2 label=$3
  if [[ $haystack != *"$needle"* ]]; then
    printf 'remove_test: %s\n  expected: %s\n  got:      %s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

# 1. The env-pinned checkout wins over is_current: the pane may sit in one
#    worktree while the action was invoked from another workspace.
out=$(run_resolve WORKTRUNK_REMOVE_CHECKOUT="$repo/.worktrees/two" WORKTRUNK_REMOVE_WORKSPACE="wPIN")
assert_contains "$out" "branch=dan/two" "env pin selects the pinned worktree"
assert_contains "$out" "workspace=wTWO" "live path→workspace lookup is authoritative"

# 2. Without a pin, fall back to the worktree containing this pane.
out=$(RESOLVE_CWD="$repo/.worktrees/one" run_resolve)
assert_contains "$out" "branch=dan/one" "cwd fallback resolves the current worktree"

# 3. A pinned path that is no longer a registered worktree fails loudly
#    instead of guessing another target.
if out=$(run_resolve WORKTRUNK_REMOVE_CHECKOUT="$repo/.worktrees/gone" 2>&1); then
  printf 'remove_test: expected failure for unregistered pinned path\n' >&2
  exit 1
fi

# 4. The primary worktree is refused.
out=$(run_resolve WORKTRUNK_REMOVE_CHECKOUT="$repo")
assert_contains "$out" "primary worktree" "main checkout is refused"

# 5. A pane whose cwd survives an interrupted removal (inside .git/wt/trash)
#    is recognized as recovery, not resolved as a worktree.
out=$(RESOLVE_CWD="$repo/.git/wt/trash/one-123" run_resolve)
assert_contains "$out" "mode=trash" "trash cwd enters recovery mode"
assert_contains "$out" "trash_dir=$repo/.git/wt/trash/one-123" "recovery targets the trash copy"

# 6. A pinned checkout inside the trash also enters recovery.
out=$(run_resolve WORKTRUNK_REMOVE_CHECKOUT="$repo/.git/wt/trash/one-123" WORKTRUNK_REMOVE_WORKSPACE="wONE")
assert_contains "$out" "mode=trash" "trash pin enters recovery mode"
assert_contains "$out" "workspace=wONE" "recovery closes the pinned workspace"

printf 'remove_test: ok\n'
