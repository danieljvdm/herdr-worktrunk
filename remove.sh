#!/usr/bin/env bash
# Remover for the worktrunk herdr plugin. Plain bash, shell-agnostic: it calls
# the `wt` binary directly, so it needs no shell-function/rc integration.
#
# Modes:
#   --current   remove the worktree the invoking action pinned in
#               WORKTRUNK_REMOVE_CHECKOUT (captured from herdr's worktree model
#               at keypress time), falling back to the worktree containing this
#               pane. The pin exists because focus can move between the
#               keypress and this script running — resolving from "whatever is
#               focused now" has deleted the wrong worktree before.
#   --picker    fzf over removable worktrees.
#
# Flags:
#   --yes       skip the confirmation summary (for deliberate scripted callers)
#   --resolve   print the resolved target and exit without removing (tests)
#
# Interactive runs (stdin is a TTY, no --yes) always get a confirmation
# summary showing the branch, path, uncommitted changes, and any live agents
# in the target workspace. Non-TTY runs keep the old immediate behavior so
# agents reaping their own session (`reap` → `remove.sh --current`) still work.

remove_mode=picker assume_yes=0 resolve_only=0
while (($#)); do
  case $1 in
    --picker) remove_mode=picker ;;
    --current) remove_mode=current ;;
    --yes) assume_yes=1 ;;
    --resolve) resolve_only=1 ;;
    *) printf 'usage: %s [--current|--picker] [--yes] [--resolve]\n' "$0" >&2; exit 2 ;;
  esac
  shift
done

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}
pinned_checkout=${WORKTRUNK_REMOVE_CHECKOUT:-}
pinned_ws=${WORKTRUNK_REMOVE_WORKSPACE:-}
pinned_ws_label=${WORKTRUNK_REMOVE_WORKSPACE_LABEL:-}

fail() { printf '\033[31m%s\033[0m\n' "$1"; [[ -t 0 ]] && sleep 2; exit 1; }

# ---------------------------------------------------------------------------
# Interrupted-removal recovery. `wt remove` moves a worktree to
# .git/wt/trash/<name>-<epoch> before deleting it; if the removal is stopped
# in between (an agent interrupting it, a crash), the surviving shell keeps
# its cwd inside the trash copy. Resolving "the current worktree" from there
# can never work — recognize it, explain, and offer to finish the cleanup.
# ---------------------------------------------------------------------------
trash_source=""
for candidate in "$pinned_checkout" "$PWD"; do
  case $candidate in
    */.git/wt/trash/*) trash_source=$candidate; break ;;
  esac
done

if [[ -n $trash_source && $remove_mode == current ]]; then
  trash_repo=${trash_source%%/.git/wt/trash/*}
  trash_rest=${trash_source#*/.git/wt/trash/}
  trash_dir=$trash_repo/.git/wt/trash/${trash_rest%%/*}

  if ((resolve_only)); then
    printf 'mode=trash repo=%s trash_dir=%s workspace=%s\n' \
      "$trash_repo" "$trash_dir" "${pinned_ws:-${HERDR_WORKSPACE_ID:-}}"
    exit 0
  fi

  printf '\033[33m%s\033[0m\n' "This pane survives an interrupted 'wt remove':"
  printf '  its shell lives in the trashed copy of an already-removed worktree.\n'
  printf '    \033[2m%s\033[0m\n\n' "$trash_dir"
  if [[ ! -t 0 && $assume_yes == 0 ]]; then
    printf 'rerun with --yes to delete the trash copy and close this workspace\n'
    exit 1
  fi
  if ((! assume_yes)); then
    printf 'Delete the trash copy and close this workspace? [y/N] '
    read -r -n1 answer; printf '\n'
    [[ $answer == [yY] ]] || exit 0
  fi
  rm -rf "$trash_dir"
  wsid=${pinned_ws:-${HERDR_WORKSPACE_ID:-}}
  [[ -n $wsid ]] && "$herdr" workspace close "$wsid"
  exit 0
fi

if [[ $remove_mode == picker ]] && ! command -v fzf >/dev/null; then
  fail "fzf not found on PATH"
fi

# List worktrees from the pinned checkout's repo when we have one; the pane's
# own cwd may already be gone or point somewhere unrelated.
list_dir=${pinned_checkout:-$PWD}
if ! wtjson=$(wt -C "$list_dir" list --format=json 2>/dev/null); then
  fail "failed to list worktrees (from $list_dir)"
fi
if ! wtitems=$(printf '%s\n' "$wtjson" | worktrunk_list_items); then
  fail "unsupported worktrunk list output"
fi
repo_path=$(printf '%s\n' "$wtitems" \
  | jq -r 'select(.kind == "worktree" and .is_main == true) | .path' \
  | head -n1)
[[ -z $repo_path ]] && repo_path=$PWD

if [[ $remove_mode == current ]]; then
  if [[ -n $pinned_checkout ]]; then
    current=$(printf '%s\n' "$wtitems" \
      | jq -c --arg p "$pinned_checkout" \
          'select(.kind == "worktree" and .path == $p)' \
      | head -n1)
    [[ -z $current ]] && fail "pinned worktree is not registered: $pinned_checkout"
  else
    current=$(printf '%s\n' "$wtjson" | worktrunk_current_worktree)
    [[ -z $current ]] && fail "could not resolve the current worktree"
  fi
  if [[ $(printf '%s\n' "$current" | jq -r '.is_main') == true ]]; then
    printf '\033[33m%s\033[0m\n' "The primary worktree cannot be removed."
    [[ -t 0 ]] && sleep 2
    exit 0
  fi

  name=$(printf '%s\n' "$current" | jq -r '.branch // empty')
  wtpath=$(printf '%s\n' "$current" | jq -r '.path // empty')
  target=${name:-$wtpath}
else
  # Removable = any real worktree except the main one (the primary checkout
  # cannot be removed). The current worktree is included.
  cands=$(printf '%s\n' "$wtitems" \
    | jq -r 'select(.kind == "worktree" and .branch != null and .is_main != true) | .branch')
  if [[ -z $cands ]]; then
    printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."
    [[ -t 0 ]] && sleep 2
    exit 0
  fi

  name=$(printf '%s\n' "$cands" \
    | fzf --reverse --info=inline --border=rounded --margin=20%,30% \
          --prompt='remove worktree ❯ ' \
          --header='↵ to remove (worktrunk safeguards dirty/unmerged work) · esc to cancel')
  [[ -z $name ]] && exit 0      # esc / no selection → cancel

  wtpath=$(printf '%s\n' "$wtitems" \
    | jq -r --arg b "$name" 'select(.kind == "worktree" and .branch == $b) | .path')
  target=$name
fi

# Native herdr workspace (if open) of the worktree we're about to remove.
# The live path→workspace lookup is authoritative; the pinned workspace id
# from the invoking action is the fallback when the lookup is unavailable.
wsid=$("$herdr" worktree list --cwd "$list_dir" --json 2>/dev/null \
  | jq -r --arg p "$wtpath" \
      '.result.worktrees[] | select(.path == $p) | .open_workspace_id // empty' \
  | head -n1)
[[ -z $wsid ]] && wsid=$pinned_ws

if ((resolve_only)); then
  printf 'mode=%s branch=%s path=%s workspace=%s\n' \
    "$remove_mode" "$name" "$wtpath" "$wsid"
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation summary. Deleting a worktree also closes its workspace and
# kills every pane in it, so show exactly what is about to die — the pinned
# target can differ from where the user thinks focus is.
# ---------------------------------------------------------------------------
if [[ -t 0 && $assume_yes == 0 ]]; then
  changes=$(git -C "$wtpath" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [[ $changes == 0 ]] && changes_label="clean" || changes_label="$changes uncommitted path(s)"
  agents=$("$herdr" agent list 2>/dev/null \
    | jq -r --arg p "$wtpath" \
        '.result.agents[]? | select(.cwd == $p or (.cwd | startswith($p + "/")))
         | "\(.agent) [\(.agent_status)]\(if .name then " " + .name else "" end)"')

  printf '\033[1mRemove worktree\033[0m\n'
  printf '  branch   %s\n' "$name"
  printf '  path     %s\n' "$wtpath"
  printf '  changes  %s\n' "$changes_label"
  if [[ -n $wsid ]]; then
    printf '  closes   workspace %s%s\n' "$wsid" "${pinned_ws_label:+ ($pinned_ws_label)}"
  fi
  if [[ -n $agents ]]; then
    if printf '%s' "$agents" | grep -q '\[working\]'; then
      printf '  \033[31magents   %s — still working!\033[0m\n' "$(printf '%s' "$agents" | tr '\n' ';')"
    else
      printf '  agents   %s\n' "$(printf '%s' "$agents" | tr '\n' ';')"
    fi
  fi
  printf '\n\033[1my\033[0m to remove · any other key cancels '
  read -r -n1 answer; printf '\n'
  [[ $answer == [yY] ]] || exit 0
fi

# Run from the primary checkout so removing this pane's own worktree does not
# require shell integration to cd the plain Bash plugin process elsewhere.
# Worktrunk still runs hooks in the target worktree and gates dirty/unmerged
# deletion. --foreground keeps the pane until removal is complete.
# Fail with a real exit code for scripted callers (agents reaping their own
# session via `remove.sh --current`); only block for a keypress on a TTY.
if ! wt -C "$repo_path" remove --foreground "$target"; then
  printf '\n\033[31m%s\033[0m' "wt remove failed (see above)."
  if [[ -t 0 ]]; then
    printf ' press any key to close'
    read -n1
  fi
  printf '\n'
  exit 1
fi
cd "$repo_path" 2>/dev/null || true

# Close a native worktree workspace as a unit. Fall back to pane cleanup for the
# original tab-based mode and worktrees opened by older plugin versions.
if [[ -n $wsid ]]; then
  "$herdr" workspace close "$wsid"
elif [[ -n $wtpath && $wtpath != "/" ]]; then
  "$herdr" pane list 2>/dev/null \
    | jq -r --arg p "$wtpath" --arg self "${HERDR_PANE_ID:-}" \
        '.result.panes[] | select(.pane_id != $self)
         | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .pane_id' \
    | while read -r pid; do "$herdr" pane close "$pid"; done
fi
