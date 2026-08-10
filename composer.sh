#!/usr/bin/env bash
# Task composer for the worktrunk herdr plugin. The target repo is settled
# first — the caller's workspace repo, or (global invocations) an fzf picker
# over open repos with the focused repo on top so bare Enter passes through —
# and then the task is composed in a multiline gum textarea filling the
# popup. One widget per job: the picker owns repo typeahead, the textarea
# owns the writing. Dispatch then runs in a background "sow" tab of the
# target repo's root workspace and the popup exits, so it never blocks on
# worktree hooks or branch naming. (The runner must be a herdr pane of its
# own: a pane's children die with it, so a nohup'd child would not survive
# this popup closing.)
#
# Inline grammar (parsed here via helpers, resolved before detaching):
#   @claude / @codex / @KIND   pick the agent
#   some-branch-name:          pick the branch
#   >repo                      pick the target repository
#
# Environment:
#   WORKTRUNK_COMPOSER_BRANCH  pre-set branch name (picker promote chord)
#   WORKTRUNK_COMPOSER_BASE    base ref forwarded to dispatch.sh --base
#   WORKTRUNK_COMPOSER_GLOBAL  no-workspace invocation: resolve the target
#                              repo from the task text, else pick one

set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}
branch_hint=${WORKTRUNK_COMPOSER_BRANCH:-}
base_hint=${WORKTRUNK_COMPOSER_BASE:-}
global_mode=${WORKTRUNK_COMPOSER_GLOBAL:-}
default_agent=$(worktrunk_default_agent)

fail() {
  printf '\033[31m%s\033[0m' "$*" >&2
  if [[ -t 0 ]]; then
    printf ' press any key to close' >&2
    read -rn1
  fi
  printf '\n' >&2
  exit 1
}

# Task first, from anywhere: the textarea opens immediately and the target
# repo settles after submit — the caller's workspace repo, or (globally) a
# >token / repo name mentioned in the task, with the picker as the last net.
if [[ -n $global_mode ]]; then
  header_line="global sow · agent: $default_agent"
  hint_line="repo: name it in the task or >repo (picker if unclear) · @agent / name: override · esc cancels"
else
  repo_name=$(git rev-parse --show-toplevel 2>/dev/null)
  repo_name=${repo_name##*/}
  header_line="→ ${repo_name:-$PWD} · agent: $default_agent"
  [[ -n $branch_hint ]] && header_line+=" · branch: $branch_hint"
  hint_line="@agent / name: on the first line override · esc cancels"
fi

# Image pastes need nothing from us: herdr intercepts them in any pane,
# saves the image, and injects the saved file's path as text. The hint just
# advertises it when the clipboard actually holds an image; the bare paths
# are wrapped for the agent after submit.
if command -v pngpaste >/dev/null && pngpaste - >/dev/null 2>&1; then
  hint_line="📋 paste attaches your clipboard image · $hint_line"
fi

if command -v gum >/dev/null; then
  task=$(
    gum write --width 74 --height 10 --char-limit 0 --show-help \
      --header "$header_line
$hint_line" \
      --placeholder 'describe the task…'
  ) || exit 0
elif command -v fzf >/dev/null; then
  task=$(
    : | fzf --disabled --print-query --no-info --reverse \
        --border=rounded --margin=0,1 \
        --prompt='sow ❯ ' \
        --header="$header_line
$hint_line"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0   # esc/abort → cancel (1 = accepted with no match list, expected)
  task=$(printf '%s\n' "$task" | sed -n 1p)
else
  printf '%s\n%s\n' "$header_line" "$hint_line"
  read -er -p 'sow ❯ ' task
fi

[[ -z ${task//[[:space:]]/} ]] && exit 0

# Image pastes arrive as bare paths under herdr's clipboard-images dir; wrap
# each so the sown agent knows to read them.
task=$(printf '%s' "$task" \
  | sed -E 's#(/[^[:space:]]*/herdr-clipboard-images-[^[:space:]]+\.(png|jpe?g|webp|gif))#[attached image — read \1]#g')

# Grammar is resolved here (dispatch's stdin mode takes the task verbatim);
# explicit flags below carry the parsed pieces to the runner.
parse_grammar "$task"

# Target repo ladder: >token > workspace repo > (global) repo name mentioned
# in the task > interactive picker — all while the popup owns the terminal.
repo_path=''
if [[ -n $grammar_repo ]]; then
  if ! repo_path=$(resolve_repo_token "$grammar_repo"); then
    repo_path=$(worktrunk_open_repos \
      | fzf --with-nth=2 --delimiter=$'\t' --query "$grammar_repo" \
            --reverse --no-info --border=rounded --prompt='repo ❯ ' \
            --header="'>$grammar_repo' is ambiguous · ↵ pick · esc cancel") \
      || exit 0
    repo_path=${repo_path%%$'\t'*}
  fi
elif [[ -z $global_mode ]]; then
  repo_path=$PWD
else
  repo_path=$(pick_repo_for_task "$task")
  pick_rc=$?
  [[ $pick_rc -eq 130 ]] && exit 0
  [[ $pick_rc -ne 0 || -z $repo_path ]] && fail "could not resolve a target repository"
fi

root_ws=$(worktrunk_root_workspace "$repo_path") \
  || fail "could not resolve a root workspace for $repo_path"

# Detach: run dispatch in a background tab of the root workspace. The task
# travels via a temp file into dispatch's stdin mode — pane run sends a
# single shell line, which multiline task text must never be spliced into.
task_tmp=$(mktemp "${TMPDIR:-/tmp}/sow-task.XXXXXX")
printf '%s' "$task" > "$task_tmp"

# The runner is a plain tab, not a plugin pane, so herdr does not inject
# HERDR_PLUGIN_CONFIG_DIR there — without it dispatch silently loses the
# plugin config (dispatch_focus, branch_name_command, default_agent) and
# reverts to focus-stealing defaults.
runner=''
[[ -n ${HERDR_PLUGIN_CONFIG_DIR:-} ]] \
  && runner="HERDR_PLUGIN_CONFIG_DIR=$(printf '%q' "$HERDR_PLUGIN_CONFIG_DIR") "
runner+="bash $(printf '%q' "$plugin_root/dispatch.sh")"
[[ -n $grammar_agent ]] && runner+=" --agent $(printf '%q' "$grammar_agent")"
if [[ -n $grammar_branch ]]; then
  runner+=" -b $(printf '%q' "$grammar_branch")"
elif [[ -n $branch_hint ]]; then
  runner+=" -b $(printf '%q' "$branch_hint")"
fi
[[ -n $base_hint ]] && runner+=" --base $(printf '%q' "$base_hint")"
runner+=" --repo $(printf '%q' "$repo_path") - < $(printf '%q' "$task_tmp")"
# Success closes the runner tab; failure keeps it open for inspection and
# raises a notification.
runner+="; rc=\$?; rm -f $(printf '%q' "$task_tmp"); [ \$rc -eq 0 ] && exit"
runner+="; $(printf '%q' "$herdr") notification show '🥀 sow failed' --body 'details in the sow tab' --sound request"

runner_pane=$("$herdr" tab create --workspace "$root_ws" --cwd "$repo_path" \
  --label sow --no-focus | jq -r '.result.root_pane.pane_id // empty')
[[ -z $runner_pane ]] && { rm -f "$task_tmp"; fail "could not open a runner tab in $root_ws"; }

"$herdr" pane run "$runner_pane" "$runner" >/dev/null \
  || { rm -f "$task_tmp"; fail "could not start the dispatch runner"; }

exit 0
