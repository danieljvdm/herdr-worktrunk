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

if [[ $remove_mode == current ]]; then
  # The confirmation only needs topology: the primary checkout plus the
  # pinned/current worktree's path and branch. `wt list` also calculates status,
  # divergence, integration, diffs, and dev-server state for every sibling
  # worktree; that made this prompt take tens of seconds in repos with many
  # worktrees. Raw git topology is sufficient here. `wt remove` still performs
  # its own dirty/unmerged safety checks for the selected target below.
  list_dir=${pinned_checkout:-$PWD}
  topology_dir=$list_dir
  if ! topology=$(git -c core.quotePath=false -C "$topology_dir" worktree list --porcelain 2>/dev/null); then
    # A stale pin may already be gone. Fall back to the remover pane's cwd so we
    # can distinguish "not registered" from "not a repository" without ever
    # guessing a different target.
    topology_dir=$PWD
    if ! topology=$(git -c core.quotePath=false -C "$topology_dir" worktree list --porcelain 2>/dev/null); then
      fail "failed to list git worktrees (from $list_dir)"
    fi
  fi

  repo_path="" wtpath="" name="" best_len=0
  record_path="" record_branch=""
  resolve_record() {
    local record_len
    [[ -n $record_path ]] || return
    [[ -n $repo_path ]] || repo_path=$record_path

    if [[ -n $pinned_checkout ]]; then
      [[ $record_path == "$pinned_checkout" ]] || return
    else
      [[ $PWD == "$record_path" || $PWD == "$record_path/"* ]] || return
      record_len=${#record_path}
      ((record_len >= best_len)) || return
      best_len=$record_len
    fi
    wtpath=$record_path
    name=$record_branch
  }

  while IFS= read -r line; do
    case $line in
      "")
        resolve_record
        record_path="" record_branch=""
        ;;
      "worktree "*) record_path=${line#worktree } ;;
      "branch refs/heads/"*) record_branch=${line#branch refs/heads/} ;;
    esac
  done <<<"$topology"
  resolve_record

  if [[ -z $wtpath ]]; then
    if [[ -n $pinned_checkout ]]; then
      fail "pinned worktree is not registered: $pinned_checkout"
    fi
    fail "could not resolve the current worktree"
  fi
  if [[ $wtpath == "$repo_path" ]]; then
    printf '\033[33m%s\033[0m\n' "The primary worktree cannot be removed."
    [[ -t 0 ]] && sleep 2
    exit 0
  fi
  target=${name:-$wtpath}
else
  # The picker genuinely needs all worktree rows, including Worktrunk's status
  # and safety metadata, so retain the full (and potentially slower) list here.
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
wsid=$("$herdr" worktree list --cwd "$repo_path" --json 2>/dev/null \
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
  status_out=$(git -C "$wtpath" status --porcelain 2>/dev/null)
  if [[ -z $status_out ]]; then
    changes_label="clean"
  else
    changes=0
    while IFS= read -r _; do ((changes++)); done <<<"$status_out"
    changes_label="$changes uncommitted path(s)"
  fi
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
    agents_line=${agents//$'\n'/; }
    if [[ $agents == *"[working]"* ]]; then
      printf '  \033[31magents   %s — still working!\033[0m\n' "$agents_line"
    else
      printf '  agents   %s\n' "$agents_line"
    fi
  fi
  printf '\n\033[1my\033[0m to remove · any other key cancels '
  read -r -n1 answer; printf '\n'
  [[ $answer == [yY] ]] || exit 0
fi

# Run from the primary checkout so removing this pane's own worktree does not
# require shell integration to cd the plain Bash plugin process elsewhere.
# Worktrunk gates dirty/unmerged deletion synchronously, then detaches the
# actual file deletion into the background — verified to survive this caller
# (and its pane) dying immediately afterward, so no --foreground: waiting for
# a 4.5GB node_modules to unlink is what made reap feel broken.
# Fail with a real exit code for scripted callers (agents reaping their own
# session via `remove.sh --current`); only block for a keypress on a TTY.
if ! wt -C "$repo_path" remove "$target"; then
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
