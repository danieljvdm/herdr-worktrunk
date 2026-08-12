#!/usr/bin/env bash
# Task-first dispatch for the worktrunk herdr plugin: describe the work, and
# this creates a worktree for it (via `wt`, so lifecycle hooks run), opens it
# as a native herdr worktree workspace, starts a coding agent in its root
# pane, and submits the task as the agent's opening prompt.
#
# The branch name comes from a fast model call over the task text unless
# overridden (config key branch_name_command, else claude haiku, else a slug
# of the text) — the task is the primitive, the branch is bookkeeping.
#
# Usage: dispatch.sh [options] [--] <task text...>
#        dispatch.sh [options] -            # read task text from stdin
#
# Options:
#   -a, --agent KIND   agent kind (any `herdr agent start` kind); default from
#                      plugin config `default_agent`, else claude
#       --claude       shorthand for --agent claude
#       --codex        shorthand for --agent codex
#   -b, --branch NAME  branch/worktree name (default: model-named from the task)
#       --repo PATH    dispatch into this repository instead of the current
#                      directory's; opens a root workspace for it if none is
#                      open yet (alias: -C)
#       --base REF     base ref for a newly created branch (worktrunk syntax)
#       --here         shorthand for --base @ (current branch)
#       --model ID     launch the agent on this model (codex: -m ID,
#                      claude: --model ID)
#       --effort LEVEL reasoning effort (codex: -c model_reasoning_effort=LEVEL,
#                      claude: --effort LEVEL)
#       --speed TIER   fast | normal. For codex this sets service_tier: fast,
#                      or the explicit `default` sentinel for normal — the only
#                      value that suppresses a model catalog's default tier
#                      (gpt-5.6-sol's catalog defaults to fast; omitting the
#                      key does NOT). claude has no fast-mode launch flag, so
#                      --speed fast with a claude agent is an error (/fast is
#                      an in-session toggle).
#       --focus        switch to the new workspace when it opens
#       --no-focus     open the workspace without stealing focus, and announce
#                      via a herdr notification instead; the default comes
#                      from the dispatch_focus plugin config key (true)
#       --pick-repo    interactive repo resolution (used by the composer's
#                      global mode): match the task text against open repos,
#                      falling back to an fzf picker
#       --hold         on failure, wait for a keypress before exiting (for
#                      transient plugin panes)
#       --slug TEXT    print the branch name derived from TEXT and exit
#       --preview TEXT print a "branch · agent" header line for TEXT and exit
#
# Inline grammar (parsed from the front of the task text, flags win):
#   @claude / @codex / @KIND   pick the agent
#   some-branch-name:          pick the branch (first word, ending in `:`)
#   >repo                     pick the target repository: a path, or the name
#                              of a repo with a pane open in this session
#
# Environment:
#   WORKTRUNK_BRANCH_HINT  branch to use when neither -b nor grammar name one
#                          (set by the picker's promote chord)

set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}
hold=false

die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  if [[ $hold == true ]]; then
    printf 'press any key to close' >&2
    read -rn1
  fi
  exit 1
}

# Run a command with a hard wall-clock budget; macOS ships no `timeout`.
run_with_timeout() {
  local secs=$1 pid watcher rc
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
  watcher=$!
  wait "$pid"
  rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

# Name the branch from the task with a model: the configured
# branch_name_command (task on stdin, name on stdout), else claude's haiku
# tier. Output is sanitized to a plausible branch name; empty/failed output
# falls back to worktrunk_slug at the call site.
name_branch_with_model() {
  local task=$1 cmd out
  cmd=$(worktrunk_config_value branch_name_command)
  if [[ -n $cmd ]]; then
    out=$(printf '%s\n' "$task" | run_with_timeout 20 bash -c "$cmd" 2>/dev/null)
  elif command -v claude >/dev/null 2>&1; then
    out=$(printf 'Task: %s\n' "$task" | run_with_timeout 20 claude --model haiku -p \
      'Reply with only a kebab-case git branch name (two to four words, lowercase letters/digits/dashes, max 40 chars) that describes this task. No quotes, no explanation, nothing else.' \
      2>/dev/null)
  else
    return 1
  fi
  out=$(printf '%s' "$out" | tail -n1 | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._/-' '-')
  out=$(printf '%s' "$out" | sed 's/^[^a-z0-9]*//; s/[^a-z0-9]*$//; s/-\{2,\}/-/g')
  out=${out:0:40}
  [[ -n $out ]] || return 1
  printf '%s\n' "$out"
}

# Derive a branch name from task text: lowercase, alphanumeric words, minus
# filler words, first four words joined with dashes, capped at 40 chars.
worktrunk_slug() {
  local text word out='' count=0
  text=$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
  for word in $text; do
    case $word in
      the|a|an|to|in|on|of|for|with|and|or|that|this|is|are|it|be|so|please|we|i|my|our|us|into|from|when|then) continue ;;
    esac
    out+=${out:+-}$word
    count=$((count + 1))
    [[ $count -ge 4 ]] && break
  done
  [[ -z $out ]] && return 1
  printf '%s\n' "${out:0:40}"
}

# Map the portable --model/--effort/--speed flags onto agent-specific launch
# arguments, one per line (empty flags emit nothing). Codex speed maps to the
# top-level service_tier config key: "fast" is the fast/priority tier, and
# normal is the explicit `default` sentinel — the only value that suppresses
# a model catalog's default_service_tier (gpt-5.6-sol's catalog defaults to
# "priority", so leaving the key unset still launches fast).
agent_settings_args() {
  local kind=$1 model=$2 effort=$3 speed=$4
  case $kind in
    codex)
      [[ -n $model ]] && printf '%s\n' -m "$model"
      [[ -n $effort ]] && printf '%s\n' -c "model_reasoning_effort=$effort"
      case $speed in
        fast) printf '%s\n' -c 'service_tier=fast' ;;
        normal) printf '%s\n' -c 'service_tier=default' ;;
      esac
      ;;
    claude)
      [[ -n $model ]] && printf '%s\n' --model "$model"
      [[ -n $effort ]] && printf '%s\n' --effort "$effort"
      ;;
  esac
  return 0
}

# Compare requested settings against the live TUI's footer text: one line per
# mismatch, empty output when everything checks out. The footer is
# authoritative over what was requested — config layers (notably codex model
# catalogs) can override launch flags, so only the running session proves
# what actually applies. Codex renders "<model> <effort> [fast]"; sol
# displays its xhigh effort as "ultra".
settings_footer_mismatches() {
  local footer=$1 model=$2 effort=$3 speed=$4 pattern
  if [[ -n $model ]] && ! grep -qF -- "$model" <<<"$footer"; then
    printf 'model %s\n' "$model"
  fi
  if [[ -n $effort ]]; then
    pattern=$effort
    [[ $effort == xhigh ]] && pattern='(xhigh|ultra)'
    grep -qiE "(^|[^[:alpha:]])${pattern}([^[:alpha:]]|$)" <<<"$footer" \
      || printf 'effort %s\n' "$effort"
  fi
  case $speed in
    fast)
      grep -qiE '(^|[^[:alpha:]])fast([^[:alpha:]]|$)' <<<"$footer" \
        || printf 'speed fast\n' ;;
    normal)
      grep -qiE '(^|[^[:alpha:]])fast([^[:alpha:]]|$)' <<<"$footer" \
        && printf 'speed normal (session is fast)\n' ;;
  esac
  return 0
}

agent_kind=''
agent_model=''
agent_effort=''
agent_speed=''
branch=''
base=''
repo=''
repo_token=''
pick_repo=false
focus=$(worktrunk_dispatch_focus)
task=''
stdin_task=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--agent) agent_kind=${2:?--agent needs a kind}; shift 2 ;;
    --claude|--codex) agent_kind=${1#--}; shift ;;
    -b|--branch) branch=${2:?--branch needs a name}; shift 2 ;;
    --repo|-C) repo=${2:?--repo needs a path}; shift 2 ;;
    --pick-repo) pick_repo=true; shift ;;
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    --here) base='@'; shift ;;
    --model) agent_model=${2:?--model needs a model id}; shift 2 ;;
    --effort) agent_effort=${2:?--effort needs a level}; shift 2 ;;
    --speed) agent_speed=${2:?--speed needs fast or normal}; shift 2
      case $agent_speed in fast|normal) ;; *) die "--speed must be fast or normal, not: $agent_speed" ;; esac ;;
    --focus) focus=true; shift ;;
    --no-focus) focus=false; shift ;;
    --hold) hold=true; shift ;;
    --slug) shift; worktrunk_slug "$*" || die "no branch name derivable from: $*"; exit 0 ;;
    --preview) shift
      parse_grammar "$*"
      preview_branch=${grammar_branch:-${WORKTRUNK_BRANCH_HINT:-(model-named)}}
      preview_agent=${grammar_agent:-$(worktrunk_default_agent)}
      preview="branch: ${preview_branch:-—} · agent: $preview_agent"
      [[ -n $grammar_repo ]] && preview+=" · repo: $grammar_repo"
      printf '%s\n' "$preview"
      exit 0 ;;
    -h|--help) sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -) stdin_task=true; shift ;;
    --) shift; task="$*"; break ;;
    -*) die "unknown option: $1" ;;
    *) task="$*"; break ;;
  esac
done

if [[ $stdin_task == true ]]; then
  task=$(cat)
else
  parse_grammar "$task"
  [[ -n $grammar_agent && -z $agent_kind ]] && agent_kind=$grammar_agent
  [[ -n $grammar_branch && -z $branch ]] && branch=$grammar_branch
  [[ -n $grammar_repo && -z $repo ]] && repo_token=$grammar_repo
fi
[[ -z ${task// /} ]] && die "no task text given (see --help)"

[[ -z $agent_kind ]] && agent_kind=$(worktrunk_default_agent)
if [[ -n $agent_model || -n $agent_effort || -n $agent_speed ]]; then
  case $agent_kind in
    codex|claude) ;;
    *) die "--model/--effort/--speed are only wired up for codex and claude, not: $agent_kind" ;;
  esac
  [[ $agent_kind == claude && $agent_speed == fast ]] \
    && die "claude has no fast-mode launch flag (/fast is an in-session toggle); drop --speed fast"
fi
agent_args=()
while IFS= read -r arg; do
  agent_args+=("$arg")
done < <(agent_settings_args "$agent_kind" "$agent_model" "$agent_effort" "$agent_speed")
# Reachability, not env: a global-context popup (and any plain terminal on
# the same machine) has no HERDR_WORKSPACE_ID injected but can still talk to
# the session over the socket.
"$herdr" workspace list >/dev/null 2>&1 \
  || die "no herdr session reachable (is herdr running?)"
if [[ -n $repo_token ]]; then
  repo=$(resolve_repo_token "$repo_token") || die "no open repository matches '>$repo_token' — open repos: $(worktrunk_open_repos | cut -f2 | tr '\n' ' ')"
fi
if [[ -z $repo && $pick_repo == true ]]; then
  repo=$(pick_repo_for_task "$task")
  pick_rc=$?
  [[ $pick_rc -eq 130 ]] && exit 0
  [[ $pick_rc -ne 0 || -z $repo ]] && die "could not resolve a target repository; pass --repo PATH"
fi
if [[ -n $repo ]]; then
  cd "$repo" 2>/dev/null || die "no such directory: $repo"
fi
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository: $PWD"

# Branch: explicit > hint > named by a model from the task (slug of the task
# text as last resort). A derived name that already exists gets a numeric
# suffix — a new task deserves a new worktree.
derived=false
if [[ -z $branch ]]; then
  branch=${WORKTRUNK_BRANCH_HINT:-}
fi
if [[ -z $branch ]]; then
  printf '\033[2m» naming the branch…\033[0m\n'
  branch=$(name_branch_with_model "$task" || true)
  if [[ -z $branch ]]; then
    branch=$(worktrunk_slug "$task") || die "could not derive a branch name; pass -b NAME"
    printf '\033[2m» model naming unavailable; falling back to: %s\033[0m\n' "$branch"
  fi
  derived=true
  if worktrunk_ref_exists "$branch"; then
    for i in 2 3 4 5 6 7 8 9; do
      if ! worktrunk_ref_exists "$branch-$i"; then
        branch="$branch-$i"
        break
      fi
    done
  fi
fi

# Existing refs and worktrunk shortcuts pass through to `wt switch` as-is;
# anything else is created. (Matches picker.sh.)
if worktrunk_is_shortcut "$branch" || worktrunk_ref_exists "$branch"; then
  wtargs=(switch "$branch")
else
  wtargs=(switch --create "$branch")
  [[ -n $base ]] && wtargs+=(--base "$base")
fi

# Register new worktrees under the repo's root workspace, not a sibling
# worktree workspace — opening the root as a background workspace when the
# repo has none yet (cross-repo dispatch, plain terminals, global popups).
root_ws=$(worktrunk_root_workspace "$PWD")
[[ -z $root_ws ]] && root_ws=${HERDR_WORKSPACE_ID:-}
[[ -z $root_ws ]] && die "could not resolve a root workspace for $PWD"

printf '\033[2m» wt %s\033[0m\n' "${wtargs[*]}"
result=$(wt "${wtargs[@]}" --no-cd --format=json) \
  || die "wt switch failed (see above)"

wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
if [[ -z $wtpath ]]; then
  wtpath=$(wt list --format=json 2>/dev/null \
    | worktrunk_list_items \
    | jq -r --arg b "$branch" 'select(.branch == $b and .kind == "worktree") | .path' \
    | head -n1)
fi
[[ -z $wtpath ]] && die "worktrunk returned no worktree path for: $branch"

focus_flag=--focus
[[ $focus == false ]] && focus_flag=--no-focus
opened=$("$herdr" worktree open --workspace "$root_ws" \
  --path "$wtpath" --label "$branch" "$focus_flag" --json) \
  || die "herdr worktree open failed for $wtpath"

ws_id=$(printf '%s\n' "$opened" | jq -r '.result.workspace.workspace_id // empty')
[[ -z $ws_id ]] && die "herdr worktree open returned no workspace id"
pane_id=$(printf '%s\n' "$opened" \
  | jq -r '[.. | objects | select(has("pane_id")) | .pane_id] | first // empty')
if [[ -z $pane_id ]]; then
  pane_id=$("$herdr" pane list --workspace "$ws_id" \
    | jq -r '[.. | objects | select(has("pane_id")) | .pane_id] | first // empty')
fi
[[ -z $pane_id ]] && die "no pane found in workspace $ws_id"

# Agent names must be unique and match [a-z][a-z0-9_-]{0,31}.
agent_name=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
agent_name=$(printf '%s' "$agent_name" | sed 's/^[^a-z]*//; s/-\{2,\}/-/g; s/-$//')
[[ -z $agent_name ]] && agent_name=task
agent_name=${agent_name:0:32}
taken=$("$herdr" agent list 2>/dev/null | jq -r '[.. | objects | .name? // empty] | .[]' 2>/dev/null)
if grep -qxF "$agent_name" <<<"$taken"; then
  for i in 2 3 4 5 6 7 8 9; do
    candidate="${agent_name:0:30}-$i"
    if ! grep -qxF "$candidate" <<<"$taken"; then
      agent_name=$candidate
      break
    fi
  done
fi

# The fresh workspace's shell needs a moment to reach its prompt before it
# counts as an available pane; retry rather than racing it.
printf '\033[2m» starting %s in %s\033[0m\n' "$agent_kind" "$ws_id"
start_cmd=("$herdr" agent start "$agent_name" --kind "$agent_kind" --pane "$pane_id")
[[ ${#agent_args[@]} -gt 0 ]] && start_cmd+=(-- "${agent_args[@]}")
started=false
start_err=''
for _ in $(seq 1 30); do
  if start_err=$("${start_cmd[@]}" 2>&1 >/dev/null); then
    started=true
    break
  fi
  sleep 0.5
done
[[ $started == false ]] && die "agent start failed: $start_err"

# A just-started agent can mishandle the first submission in two ways: a
# startup dialog (e.g. claude's workspace-trust prompt for the brand-new
# worktree directory) swallows text and Enter entirely, or the TUI accepts
# the pasted text into its input box but drops the Enter, leaving the task
# composed-but-unsent. An idle agent doesn't start working on its own, so
# reaching `working` is the only positive proof of submission. When it
# doesn't come, nudge a bare Enter first — it flushes a stuck input box and
# is a no-op on an empty one — before trusting the transcript (which renders
# a stuck input box identically) or re-typing the task. Stop typing into a
# dialog herdr reports as blocked; that one needs a human.
snippet=$(printf '%s' "$task" | head -n1 | cut -c1-40)
submitted=false
agent_status=''
for attempt in 1 2 3; do
  if [[ $attempt -gt 1 ]]; then
    sleep 1
  fi
  "$herdr" agent prompt "$agent_name" "$task" >/dev/null 2>&1 || true
  if "$herdr" agent wait "$agent_name" --until working --timeout 5000 >/dev/null 2>&1; then
    submitted=true
    break
  fi
  "$herdr" agent send-keys "$agent_name" enter >/dev/null 2>&1 || true
  if "$herdr" agent wait "$agent_name" --until working --timeout 3000 >/dev/null 2>&1; then
    submitted=true
    break
  fi
  # Fast turns settle back to idle before the waits fire; after the Enter
  # nudge the transcript match can no longer be a stuck input box.
  if "$herdr" agent read "$agent_name" --source recent-unwrapped --lines 200 2>/dev/null \
    | grep -qF "$snippet"; then
    submitted=true
    break
  fi
  agent_status=$("$herdr" agent get "$agent_name" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty')
  [[ $agent_status == blocked ]] && break
done
if [[ $submitted == false ]]; then
  "$herdr" notification show "🌱 $branch needs attention" \
    --body "$agent_kind started but the task was not submitted" --sound request \
    >/dev/null 2>&1 || true
  die "agent '$agent_name' is running but the task did not reach it (status: ${agent_status:-unknown}).
Dismiss whatever is on its screen, then: $herdr agent prompt $agent_name '<task>'"
fi

# Requested settings are a claim; the live session is the fact. Codex's TUI
# footer renders the model, effort, and speed tier actually in force (config
# layers like model catalogs can override launch flags), so read it back and
# refuse to stay quiet on a mismatch. Claude renders no such footer — its
# flags are trusted because an invalid value fails the launch itself.
if [[ -n $agent_model || -n $agent_effort || -n $agent_speed ]]; then
  if [[ $agent_kind == codex ]]; then
    # Codex's footer reads "<model> <effort> [fast] · <cwd>"; match on the
    # " · " and check only the settings segment before it, so a cwd or prompt
    # echo containing e.g. "fast" can't satisfy (or trip) the speed check.
    visible=$("$herdr" agent read "$agent_name" --source visible 2>/dev/null)
    footer_line=$(printf '%s\n' "$visible" | grep -F ' · ' | tail -n1 \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z $footer_line ]]; then
      footer_line=$(printf '%s\n' "$visible" | grep -vE '^[[:space:]]*$' \
        | tail -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    mismatches=$(settings_footer_mismatches "${footer_line%%·*}" \
      "$agent_model" "$agent_effort" "$agent_speed")
    [[ -z $footer_line ]] && mismatches='(session footer unreadable)'
    if [[ -n $mismatches ]]; then
      printf '\033[1;31m⚠ agent settings mismatch\033[0m — the live session does not show:\n' >&2
      printf '%s\n' "$mismatches" | sed 's/^/  requested /' >&2
      printf '  session footer: %s\n' "${footer_line:-(unreadable)}" >&2
      "$herdr" notification show "⚠️ $branch: agent settings mismatch" \
        --body "requested $(printf '%s' "$mismatches" | tr '\n' ',') — footer: ${footer_line:-unreadable}" \
        --sound request >/dev/null 2>&1 || true
    else
      printf '\033[2m» settings verified: %s\033[0m\n' "$footer_line"
    fi
  elif [[ ${#agent_args[@]} -gt 0 ]]; then
    printf '\033[2m» %s launched with:%s\033[0m\n' "$agent_kind" \
      "$(printf ' %s' "${agent_args[@]}")"
  fi
fi

if [[ $focus == false ]]; then
  "$herdr" notification show "🌱 sown: $branch" \
    --body "$agent_kind is on it" --sound none >/dev/null 2>&1 || true
fi

printf '\033[32m🌱 sown\033[0m  branch=%s  workspace=%s  agent=%s (%s)\n' \
  "$branch" "$ws_id" "$agent_name" "$agent_kind"
