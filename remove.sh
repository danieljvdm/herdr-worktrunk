#!/usr/bin/env bash
# Remover for the worktrunk herdr plugin. With --current, remove the worktree
# containing this pane; otherwise use fzf to choose one. Plain bash,
# shell-agnostic: it calls the `wt` binary directly, so it needs no
# shell-function/rc integration.

remove_mode=picker
case ${1:-} in
  ""|--picker) ;;
  --current) remove_mode=current ;;
  *) printf 'usage: %s [--current|--picker]\n' "$0" >&2; exit 2 ;;
esac

if [[ $remove_mode == picker ]] && ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}
if ! wtjson=$(wt list --format=json 2>/dev/null); then
  printf '\033[31m%s\033[0m\n' "failed to list worktrees"; sleep 2; exit 1
fi
if ! wtitems=$(printf '%s\n' "$wtjson" | worktrunk_list_items); then
  printf '\033[31m%s\033[0m\n' "unsupported worktrunk list output"; sleep 2; exit 1
fi
repo_path=$(printf '%s\n' "$wtitems" \
  | jq -r 'select(.kind == "worktree" and .is_main == true) | .path' \
  | head -n1)
[[ -z $repo_path ]] && repo_path=$PWD

if [[ $remove_mode == current ]]; then
  current=$(printf '%s\n' "$wtjson" | worktrunk_current_worktree)
  if [[ -z $current ]]; then
    printf '\033[31m%s\033[0m\n' "could not resolve the current worktree"; sleep 2; exit 1
  fi
  if [[ $(printf '%s\n' "$current" | jq -r '.is_main') == true ]]; then
    printf '\033[33m%s\033[0m\n' "The primary worktree cannot be removed."; sleep 2; exit 0
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
    printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."; sleep 2; exit 0
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
wsid=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
  | jq -r --arg p "$wtpath" \
      '.result.worktrees[] | select(.path == $p) | .open_workspace_id // empty' \
  | head -n1)

# Run from the primary checkout so removing this pane's own worktree does not
# require shell integration to cd the plain Bash plugin process elsewhere.
# Worktrunk still runs hooks in the target worktree and gates dirty/unmerged
# deletion. --foreground keeps the pane until removal is complete.
if ! wt -C "$repo_path" remove --foreground "$target"; then
  printf '\n\033[31m%s\033[0m press any key to close' "wt remove failed (see above)."; read -n1
  exit 0
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
