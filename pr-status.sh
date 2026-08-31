#!/usr/bin/env bash
# Reports the current worktree's GitHub PR (if any) as Herdr workspace
# metadata, so `$pr` can appear in [ui.sidebar.spaces] rows next to the
# branch. Also opens the PR in a browser. Plain bash: called from a
# worktrunk post-switch hook (no herdr plugin context, just
# $HERDR_WORKSPACE_ID from the pane env) and from this plugin's
# refresh-pr/open-pr actions (which additionally get
# $HERDR_PLUGIN_CONTEXT_JSON for the workspace's cwd).
set -euo pipefail

# Turn `gh pr view --json number,state,isDraft` output into a short sidebar
# label. Split out so it's testable without gh/herdr/network.
format_pr_label() {
  local json=$1 number state draft label
  number=$(jq -r '.number' <<<"$json")
  state=$(jq -r '.state' <<<"$json")
  draft=$(jq -r '.isDraft' <<<"$json")
  label="#$number"
  case $state in
    MERGED) label="$label merged" ;;
    CLOSED) label="$label closed" ;;
    *) [[ $draft == true ]] && label="$label draft" ;;
  esac
  printf '%s\n' "$label"
}

# Resolve which checkout to query: the plugin context's workspace_cwd when
# invoked as an action, otherwise the caller's $PWD (the post-switch hook
# runs with cwd already inside the new worktree).
resolve_cwd() {
  local cwd=$PWD ctx_cwd
  if [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]]; then
    ctx_cwd=$(jq -r '.workspace_cwd // .focused_pane_cwd // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")
    [[ -n $ctx_cwd ]] && cwd=$ctx_cwd
  fi
  printf '%s\n' "$cwd"
}

cmd_report() {
  local herdr=${HERDR_BIN_PATH:-herdr}
  local ws_id=${HERDR_WORKSPACE_ID:-}
  [[ -z $ws_id ]] && return 0

  local cwd
  cwd=$(resolve_cwd)
  command -v gh >/dev/null 2>&1 || return 0
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local pr_json label
  if pr_json=$(cd "$cwd" && gh pr view --json number,state,isDraft 2>/dev/null); then
    label=$(format_pr_label "$pr_json")
    "$herdr" workspace report-metadata "$ws_id" --source worktrunk-pr --token "pr=$label" >/dev/null 2>&1 || true
  else
    "$herdr" workspace report-metadata "$ws_id" --source worktrunk-pr --clear-token pr >/dev/null 2>&1 || true
  fi
}

cmd_open() {
  local cwd
  cwd=$(resolve_cwd)
  cd "$cwd"
  exec gh pr view --web
}

case ${1:-report} in
  report) cmd_report ;;
  open) cmd_open ;;
  --format) format_pr_label "$(cat)" ;;
  *) printf 'usage: %s [report|open|--format]\n' "$0" >&2; exit 2 ;;
esac
