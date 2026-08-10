#!/usr/bin/env bash
# Task composer for the worktrunk herdr plugin. Collects the task in a compact
# popup: a single-line fzf with inline >repo typeahead first, and ctrl+e
# expands into a multiline gum textarea seeded with the typed text (enter
# submits in both stages). Dispatch then runs in a background "sow" tab of
# the target repo's root workspace and the popup exits, so it never blocks
# on worktree hooks or branch naming. (The runner must be a herdr pane of
# its own: a pane's children die with it, so a nohup'd child would not
# survive this popup closing.)
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

hint_line="@agent · name: picks branch · >repo targets · esc cancels"
if [[ -n $global_mode ]]; then
  header_line="global sow · agent: $default_agent"
elif [[ -n $branch_hint ]]; then
  header_line="branch: $branch_hint · agent: $default_agent"
else
  header_line="branch: named from your task · agent: $default_agent"
fi

repos_tmp=$(mktemp "${TMPDIR:-/tmp}/sow-repos.XXXXXX")
trap 'rm -f "$repos_tmp"' EXIT
worktrunk_open_repos | cut -f2 > "$repos_tmp"
if [[ -n $global_mode ]]; then
  repo_names=$(tr '\n' ' ' < "$repos_tmp")
  [[ -n $repo_names ]] && hint_line+=$'\n'"open: ${repo_names:0:70}"
fi

have_gum=false
command -v gum >/dev/null && have_gum=true

if command -v fzf >/dev/null; then
  [[ $have_gum == true ]] && hint_line+=" · ctrl+e multiline"
  candidates_bind="change:reload(sh $(printf '%q' "$plugin_root/repo-candidates.sh") {q} $(printf '%q' "$repos_tmp"))"
  # Enter completes like tab while a bare >token has a highlighted candidate
  # (a bare token is never a dispatchable task); otherwise it accepts.
  enter_bind='enter:transform:q={q}; sel={}; case "$q" in ">"*" "*) echo accept ;; ">"*) if [ -n "$sel" ]; then echo replace-query; else echo accept; fi ;; *) echo accept ;; esac'
  out=$(
    : | fzf --disabled --print-query --expect=ctrl-e --no-info --reverse \
        --border=rounded --margin=0,1 \
        --prompt='sow ❯ ' \
        --bind "$candidates_bind" \
        --bind 'tab:replace-query' \
        --bind "$enter_bind" \
        --header="$header_line
$hint_line"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0   # esc/abort → cancel (1 = accepted with no match list, expected)
  # --print-query + --expect: line 1 = typed text, line 2 = accepting key.
  task=$(printf '%s\n' "$out" | sed -n 1p)
  pressed=$(printf '%s\n' "$out" | sed -n 2p)
  if [[ $pressed == ctrl-e && $have_gum == true ]]; then
    task=$(
      gum write --width 74 --height 9 --char-limit 0 --show-help \
        --value "$task" \
        --header "$header_line
$hint_line" \
        --placeholder 'describe the task…'
    ) || exit 0
  fi
elif [[ $have_gum == true ]]; then
  task=$(
    gum write --width 74 --height 9 --char-limit 0 --show-help \
      --header "$header_line
$hint_line" \
      --placeholder 'describe the task…'
  ) || exit 0
else
  printf '%s\n%s\n' "$header_line" "$hint_line"
  read -er -p 'sow ❯ ' task
fi

[[ -z ${task//[[:space:]]/} ]] && exit 0

# Grammar is resolved here (dispatch's stdin mode takes the task verbatim);
# explicit flags below carry the parsed pieces to the runner.
parse_grammar "$task"

# Target repo: >token > current workspace repo > (global) task-text mention
# or interactive picker while the popup still owns the terminal.
repo_path=''
if [[ -n $grammar_repo ]]; then
  if ! repo_path=$(resolve_repo_token "$grammar_repo"); then
    # Ambiguous or unknown token → picker seeded with it rather than an error.
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
