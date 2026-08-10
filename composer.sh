#!/usr/bin/env bash
# Task composer for the worktrunk herdr plugin: a one-line prompt where you
# describe the work. The header live-previews the branch name derived from
# your text and the agent that will pick it up; Enter dispatches through
# dispatch.sh in this same pane, so worktrunk hook output stays visible.
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
default_agent=$(worktrunk_default_agent)

hint_line="@claude / @codex picks the agent · name: picks the branch · esc cancels"
if [[ -n $branch_hint ]]; then
  header_line="branch: $branch_hint · agent: $default_agent"
else
  header_line="branch: (derived from task) · agent: $default_agent"
fi

if command -v fzf >/dev/null; then
  preview_cmd="WORKTRUNK_BRANCH_HINT=$(printf '%q' "$branch_hint") \
bash $(printf '%q' "$plugin_root/dispatch.sh") --preview {q}"
  task=$(
    : | fzf --disabled --print-query --no-info --reverse \
        --border=rounded --margin=20%,15% \
        --prompt='sow ❯ ' \
        --header="$header_line
$hint_line" \
        --bind "change:transform-header:$preview_cmd; echo $(printf '%q' "$hint_line")"
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
exec bash "$plugin_root/dispatch.sh" "${args[@]}" -- "$task"
