#!/usr/bin/env bash
# Task composer for the worktrunk herdr plugin: a one-line prompt where you
# describe the work. Enter dispatches through dispatch.sh in this same pane,
# so branch naming and worktrunk hook output stay visible. The header is
# static on purpose — a per-keystroke transform means a process spawn per
# character, which makes typing visibly laggy.
#
# Inline grammar (parsed by dispatch.sh, shown live in the header):
#   @claude / @codex / @KIND   pick the agent
#   some-branch-name:          pick the branch (first word, ending in `:`)
#
# Environment:
#   WORKTRUNK_COMPOSER_BRANCH  pre-set branch name (picker promote chord)
#   WORKTRUNK_COMPOSER_BASE    base ref forwarded to dispatch.sh --base

set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"

branch_hint=${WORKTRUNK_COMPOSER_BRANCH:-}
base_hint=${WORKTRUNK_COMPOSER_BASE:-}
global_mode=${WORKTRUNK_COMPOSER_GLOBAL:-}
default_agent=$(worktrunk_default_agent)

hint_line="@claude / @codex picks the agent · name: picks the branch · esc cancels"
if [[ -n $global_mode ]]; then
  hint_line=">repo or a repo named in the task picks the target · $hint_line"
  header_line="global sow · agent: $default_agent"
elif [[ -n $branch_hint ]]; then
  header_line="branch: $branch_hint · agent: $default_agent"
else
  header_line="branch: named from your task · agent: $default_agent"
fi

if command -v fzf >/dev/null; then
  task=$(
    : | fzf --disabled --print-query --no-info --reverse \
        --border=rounded --margin=0,1 \
        --prompt='sow ❯ ' \
        --header="$header_line
$hint_line"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0   # esc/abort → cancel (1 = accepted with no match list, expected)
else
  printf '%s\n%s\n' "$header_line" "$hint_line"
  read -er -p 'sow ❯ ' task
fi

[[ -z ${task// /} ]] && exit 0

args=(--hold)
[[ -n $branch_hint ]] && export WORKTRUNK_BRANCH_HINT=$branch_hint
[[ -n $base_hint ]] && args+=(--base "$base_hint")
[[ -n $global_mode ]] && args+=(--pick-repo)
exec bash "$plugin_root/dispatch.sh" "${args[@]}" -- "$task"
