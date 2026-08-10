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

# fzf over open repos, focused repo on top so bare Enter passes through.
# Prints the chosen path; returns nonzero on esc/no repos.
composer_pick_repo() {
  local repos focused focused_root choice
  repos=$(worktrunk_open_repos)
  [[ -z $repos ]] && return 1
  focused=$("$herdr" pane current 2>/dev/null \
    | jq -r '[.. | objects | .cwd? // empty] | first // empty')
  focused_root=''
  if [[ -n $focused ]]; then
    focused_root=$(git -C "$focused" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    focused_root=${focused_root%/.git}
  fi
  choice=$(
    {
      [[ -n $focused_root ]] && printf '%s\n' "$repos" | awk -F'\t' -v f="$focused_root" '$1 == f'
      printf '%s\n' "$repos" | awk -F'\t' -v f="$focused_root" '$1 != f'
    } | fzf --with-nth=2 --delimiter=$'\t' --reverse --no-info \
          --border=rounded --margin=0,1 --prompt='repo ❯ ' \
          --header='where does this task go? · ↵ pick · esc cancel'
  ) || return 1
  printf '%s\n' "${choice%%$'\t'*}"
}

# Target repo first: the caller's workspace repo, or a picker when invoked
# globally. The textarea header then names the settled target.
if [[ -n $global_mode ]]; then
  repo_path=$(composer_pick_repo) || exit 0
else
  repo_path=$PWD
fi
repo_name=$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)
repo_name=${repo_name##*/}

header_line="→ ${repo_name:-$repo_path} · agent: $default_agent"
[[ -n $branch_hint ]] && header_line+=" · branch: $branch_hint"
hint_line="@agent / name: on the first line override · esc cancels"

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

# Grammar is resolved here (dispatch's stdin mode takes the task verbatim);
# explicit flags below carry the parsed pieces to the runner. A >token still
# overrides the settled target for power use, with a seeded picker when it
# does not uniquely resolve.
parse_grammar "$task"
if [[ -n $grammar_repo ]]; then
  if ! repo_path=$(resolve_repo_token "$grammar_repo"); then
    repo_path=$(worktrunk_open_repos \
      | fzf --with-nth=2 --delimiter=$'\t' --query "$grammar_repo" \
            --reverse --no-info --border=rounded --prompt='repo ❯ ' \
            --header="'>$grammar_repo' is ambiguous · ↵ pick · esc cancel") \
      || exit 0
    repo_path=${repo_path%%$'\t'*}
  fi
fi

root_ws=$(worktrunk_root_workspace "$repo_path") \
  || fail "could not resolve a root workspace for $repo_path"

# Detach: run dispatch in a background tab of the root workspace. The task
# travels via a temp file into dispatch's stdin mode — pane run sends a
# single shell line, which multiline task text must never be spliced into.
task_tmp=$(mktemp "${TMPDIR:-/tmp}/sow-task.XXXXXX")
printf '%s' "$task" > "$task_tmp"

runner="bash $(printf '%q' "$plugin_root/dispatch.sh")"
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
