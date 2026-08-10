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
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

branch_hint=${WORKTRUNK_COMPOSER_BRANCH:-}
base_hint=${WORKTRUNK_COMPOSER_BASE:-}
global_mode=${WORKTRUNK_COMPOSER_GLOBAL:-}
default_agent=$(worktrunk_default_agent)

hint_line="@agent · name: picks branch · >repo targets, tab completes · esc cancels"
if [[ -n $global_mode ]]; then
  header_line="global sow · agent: $default_agent"
else
  if [[ -n $branch_hint ]]; then
    header_line="branch: $branch_hint · agent: $default_agent"
  else
    header_line="branch: named from your task · agent: $default_agent"
  fi
fi

# Inline >repo completion: cache open repo names once; while the query is a
# bare >token, change:reload greps them into the (otherwise empty) candidate
# list and tab completes the highlighted one into the query. A single grep
# per keystroke stays imperceptible — never put sourcing or herdr calls here.
repos_tmp=$(mktemp "${TMPDIR:-/tmp}/sow-repos.XXXXXX")
trap 'rm -f "$repos_tmp"' EXIT
worktrunk_open_repos | cut -f2 > "$repos_tmp"
if [[ -n $global_mode ]]; then
  repo_names=$(tr '\n' ' ' < "$repos_tmp")
  [[ -n $repo_names ]] && hint_line+=$'\n'"open: ${repo_names:0:70}"
fi

if command -v fzf >/dev/null; then
  candidates_bind="change:reload(sh $(printf '%q' "$plugin_root/repo-candidates.sh") {q} $(printf '%q' "$repos_tmp"))"
  task=$(
    : | fzf --disabled --print-query --no-info --reverse \
        --border=rounded --margin=0,1 \
        --prompt='sow ❯ ' \
        --bind "$candidates_bind" \
        --bind 'tab:replace-query' \
        --header="$header_line
$hint_line"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0   # esc/abort → cancel (1 = accepted with no match list, expected)
  task=$(printf '%s\n' "$task" | sed -n 1p)   # --print-query: line 1 is the typed text
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
