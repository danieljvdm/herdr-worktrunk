#!/usr/bin/env bash
# Picker for the worktrunk herdr plugin. Picks a branch via fzf (fast), then opens a
# new tab and runs `wt switch` in THAT pane — so the worktree creation and any hook
# output happen in the pane you keep, not in this transient picker pane. The new tab
# runs your interactive shell, so its `wt` function cd's into the worktree and sticks.

create_base=""
create_base_label="default branch"
case ${1:-} in
  ""|--create-base=default)
    ;;
  --create-base=current)
    create_base="@"
    current_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ -n $current_branch ]]; then
      create_base_label="current branch (${current_branch})"
    else
      current_commit=$(git rev-parse --short HEAD 2>/dev/null || true)
      if [[ -n $current_commit ]]; then
        create_base_label="current HEAD (${current_commit})"
      else
        create_base_label="current branch"
      fi
    fi
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported picker option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches unless disabled via show_remote_branches = false.
branch_refs=(refs/heads refs/remotes)
[[ $(worktrunk_show_remote_branches) == false ]] && branch_refs=(refs/heads)

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it, and --expect=ctrl-o promotes the choice into the
# task composer (worktree + agent + opening prompt via dispatch.sh). Falls back
# to a plain read if fzf isn't on PATH.
if command -v fzf >/dev/null; then
  choice=$(
    {
      # git porcelain, not `wt list`: the picker only needs branch names,
      # and wt's per-worktree status pass takes seconds on big repos.
      worktrunk_git_worktree_items \
        | worktrunk_list_items \
        | jq -r 'select(.branch != null) | .branch'
      # Drop origin/HEAD: its short form is bare "origin", so filter on the full
      # refname (refs/remotes/origin/HEAD) instead, then emit the short name.
      git for-each-ref --format='%(refname) %(refname:short)' "${branch_refs[@]}" 2>/dev/null \
        | awk '$1 !~ /\/HEAD$/ {print $2}'
    } | LC_ALL=C sort -u \
      | fzf --print-query --expect=ctrl-o --reverse --info=inline --border=rounded --margin=20%,30% \
            --prompt='worktree ❯ ' \
            --header="↵ on a match → switch · type a new name + ↵ → create from ${create_base_label} · ctrl-o → +agent prompt · esc → cancel"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  # --print-query + --expect: line 1 = typed query, line 2 = accepting key,
  # line 3 = the selection (absent when the query matched nothing).
  query=$(sed -n 1p <<<"$choice")
  pressed=$(sed -n 2p <<<"$choice")
  name=$(sed -n 3p <<<"$choice")
  [[ -z $name ]] && name=$query
  if [[ $pressed == ctrl-o ]]; then
    export WORKTRUNK_COMPOSER_BRANCH=$name
    [[ -n $create_base ]] && export WORKTRUNK_COMPOSER_BASE=$create_base
    exec bash "$plugin_root/composer.sh"
  fi
else
  printf 'Branch (existing → switch · new → create from %s): ' "$create_base_label"
  read -r name
fi
[[ -z $name ]] && exit 0

open_mode=$(worktrunk_open_mode)

# Existing local or remote-tracking branch → switch (wt creates the worktree if
# it doesn't exist yet, and checks out a remote ref like origin/foo directly).
# worktrunk shortcuts (^ default, - previous, pr:N/mr:N, PR/MR URL) are resolved
# by worktrunk itself, so pass them through as-is — never --create.
# Anything else is a new branch → create it.
if worktrunk_is_shortcut "$name" || worktrunk_ref_exists "$name"; then
  wtargs=(switch "$name")
  is_create=false
else
  wtargs=(switch --create "$name")
  [[ -n $create_base ]] && wtargs+=(--base "$create_base")
  is_create=true
fi

herdr=${HERDR_BIN_PATH:-herdr}

if [[ $open_mode == tab ]]; then
  # Preserve the original behavior: run wt in a new tab's interactive shell so
  # shell integration can cd into the worktree and keep the user there.
  printf -v quoted_name '%q' "$name"
  if [[ $is_create == true ]]; then
    if [[ -n $create_base ]]; then
      printf -v quoted_base '%q' "$create_base"
      wtcmd="wt switch --create $quoted_name --base $quoted_base"
    else
      wtcmd="wt switch --create $quoted_name"
    fi
  else
    wtcmd="wt switch $quoted_name"
  fi

  newpane=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" --focus \
    | jq -r '.result.root_pane.pane_id')
  [[ -z $newpane ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; exit 1; }

  # pane run sends the command to the tab's interactive shell; the terminal buffers it
  # until the shell finishes loading, so its `wt` function is in place when it runs.
  "$herdr" pane run "$newpane" "$wtcmd"
  exit
fi

# Resolve the repo's ROOT workspace before starting worktrunk. When the picker
# runs inside an existing linked-worktree workspace, $HERDR_WORKSPACE_ID names
# that child workspace, and new worktrees must instead be registered under its
# repo parent.
root_ws=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
  | jq -r '.result.source.source_workspace_id // empty')
[[ -z $root_ws ]] && root_ws=$HERDR_WORKSPACE_ID

# Snapshot existing paths so shortcuts and remote refs can still identify the
# single new worktree they create even when their eventual branch name differs.
before_paths=$(worktrunk_git_worktree_items \
  | worktrunk_list_worktree_paths_json 2>/dev/null)
[[ -z $before_paths ]] && before_paths='[]'

# Worktrunk creates and registers the checkout before running blocking pre-start
# hooks. Watch for that point from a background helper, open the native Herdr
# workspace, and move this still-running setup pane into a temporary focused tab
# there. The foreground wt process keeps terminal ownership, so hook approvals
# and output remain fully interactive across the move.
focus_setup_when_ready() {
  local branch=$1 paths_before=$2 parent_pid=$3
  local list_json wtpath opened ws_id attempt

  [[ -n ${HERDR_PANE_ID:-} ]] || return 0

  for ((attempt = 0; attempt < 200; attempt++)); do
    kill -0 "$parent_pid" 2>/dev/null || return 0

    list_json=$(worktrunk_git_worktree_items) || true
    wtpath=$(printf '%s\n' "$list_json" \
      | worktrunk_started_worktree_path "$branch" "$paths_before" 2>/dev/null) || true

    if [[ -n $wtpath ]]; then
      opened=$("$herdr" worktree open --workspace "$root_ws" \
        --path "$wtpath" --label "$branch" --no-focus --json 2>/dev/null) || {
          sleep 0.1
          continue
        }
      ws_id=$(printf '%s\n' "$opened" \
        | jq -r '.result.workspace.workspace_id // empty')
      if [[ -n $ws_id ]]; then
        "$herdr" pane move "$HERDR_PANE_ID" --new-tab --workspace "$ws_id" \
          --label setup --focus >/dev/null 2>&1
      fi
      return 0
    fi

    sleep 0.1
  done
}

setup_watcher_pid=''
focus_setup_when_ready "$name" "$before_paths" "$$" &
setup_watcher_pid=$!

stop_setup_watcher() {
  [[ -n $setup_watcher_pid ]] || return 0
  kill "$setup_watcher_pid" 2>/dev/null || true
  wait "$setup_watcher_pid" 2>/dev/null || true
  setup_watcher_pid=''
}
trap stop_setup_watcher EXIT

# Native workspace mode: let worktrunk create/switch the checkout and run hooks.
# The watcher above moves this pane to the destination while blocking setup runs;
# the final open remains the fallback for fast switches and unresolvable refs.
if ! result=$(wt "${wtargs[@]}" --no-cd --format=json); then
  stop_setup_watcher
  printf '\n\033[31m%s\033[0m press any key to close' "wt switch failed (see above)."
  read -n1
  exit 1
fi
stop_setup_watcher
trap - EXIT

wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
if [[ -z $wtpath ]]; then
  wtpath=$(worktrunk_git_worktree_items \
    | worktrunk_list_items \
    | jq -r --arg b "$name" 'select(.branch == $b and .kind == "worktree") | .path' \
    | head -n1)
fi
if [[ -z $wtpath ]]; then
  printf '\033[31m%s\033[0m\n' "worktrunk returned no worktree path for: $name"
  sleep 2
  exit 1
fi

exec "$herdr" worktree open --workspace "$root_ws" \
  --path "$wtpath" --label "$name" --focus --json
