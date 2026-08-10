#!/usr/bin/env bash

# True when NAME is a token worktrunk resolves itself — a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
worktrunk_is_shortcut() {
  case $1 in
    '^'|'-'|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
worktrunk_ref_exists() {
  git show-ref --quiet --verify "refs/heads/$1" \
    || git show-ref --quiet --verify "refs/remotes/$1"
}

# Emit one worktrunk list item per line with the schema 1 location fields
# (`kind`, `path`, and `is_main`) available at the top level. Worktrunk's JSON
# schema 2 wraps items in an envelope and nests those fields under `worktree`.
worktrunk_list_items() {
  jq -c '
    def normalize:
      . + {
        kind: (.kind // (if (.worktree | type) == "object" then "worktree" else "branch" end)),
        path: (.path // .worktree.path // null),
        is_main: (.is_main // .worktree.main // false),
        is_current: (.is_current // .worktree.current // false)
      };

    if type == "array" then
      .[] | normalize
    elif type == "object" and ((.items | type) == "array") then
      .items[] | normalize
    else
      error("unsupported worktrunk list JSON schema")
    end
  '
}

# Read `wt list --format=json` on stdin and emit the normalized item for the
# worktree containing the command's current directory.
worktrunk_current_worktree() {
  worktrunk_list_items \
    | jq -c 'select(.kind == "worktree" and .is_current == true)' \
    | head -n1
}

# Read `wt list --format=json` on stdin and return the paths of all worktrees as
# a JSON array. The snapshot lets a caller recognize a newly registered
# worktree even when the requested token is a shortcut or remote ref whose
# eventual local branch name differs.
worktrunk_list_worktree_paths_json() {
  worktrunk_list_items \
    | jq -sc '[.[] | select(.kind == "worktree" and .path != null) | .path]'
}

# Read `wt list --format=json` on stdin and resolve the worktree that appeared
# for a switch/create operation. Prefer an exact branch match; otherwise accept
# exactly one path absent from the caller's pre-operation snapshot.
worktrunk_started_worktree_path() {
  local branch=$1 before_paths=${2:-[]}

  worktrunk_list_items \
    | jq -sr --arg branch "$branch" --argjson before "$before_paths" '
        (map(select(.kind == "worktree" and .branch == $branch)) | first | .path)
        //
        ([.[]
          | select(.kind == "worktree" and .path != null)
          | select(.path as $path | ($before | index($path)) == null)]
         | if length == 1 then .[0].path else empty end)
      '
}

# Print "path<TAB>name" for each distinct git repository with a pane open in
# the current herdr session. Linked-worktree panes resolve to their repo's
# primary checkout via the git common dir, so each repo appears once.
worktrunk_open_repos() {
  local herdr=${HERDR_BIN_PATH:-herdr} cwd root
  "$herdr" pane list 2>/dev/null \
    | jq -r '[.. | objects | select(has("pane_id")) | .cwd // empty] | unique | .[]' \
    | while IFS= read -r cwd; do
        root=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
        root=${root%/.git}
        [[ -n $root ]] || continue
        printf '%s\t%s\n' "$root" "${root##*/}"
      done | LC_ALL=C sort -u
}

# Parse the sow inline grammar off the front of a task text. Sets the globals
# grammar_agent, grammar_branch, grammar_repo, and task (the remaining text,
# whitespace preserved).
parse_grammar() {
  local first
  task=$1
  grammar_agent=''
  grammar_branch=''
  grammar_repo=''
  while :; do
    task=${task#"${task%%[![:space:]]*}"}
    first=${task%%[[:space:]]*}
    if [[ $first == @[a-z]* && $first != *:* ]]; then
      grammar_agent=${first#@}
    elif [[ $first == '>'?* ]]; then
      grammar_repo=${first#>}
    elif [[ $first =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*:$ ]]; then
      grammar_branch=${first%:}
    else
      break
    fi
    task=${task#"$first"}
  done
  task=${task#"${task%%[![:space:]]*}"}
}

# Resolve a `>token` from the grammar to a repository path: an existing
# directory wins, then an exact open-repo name, then a unique substring match.
resolve_repo_token() {
  local token=$1 repos path name hits=''
  [[ -d $token ]] && { printf '%s\n' "$token"; return 0; }
  repos=$(worktrunk_open_repos)
  while IFS=$'\t' read -r path name; do
    [[ $name == "$token" ]] && { printf '%s\n' "$path"; return 0; }
  done <<<"$repos"
  while IFS=$'\t' read -r path name; do
    case $name in *"$token"*) hits+="$path"$'\n' ;; esac
  done <<<"$repos"
  hits=${hits%$'\n'}
  [[ -n $hits && $(printf '%s\n' "$hits" | wc -l) -eq 1 ]] \
    && { printf '%s\n' "$hits"; return 0; }
  return 1
}

# Interactive repo resolution for the composer's global mode: a repo name
# appearing in the task text wins when it is unique; otherwise fzf over open
# repos with the UI-focused repo listed first. Returns 130 on picker cancel.
pick_repo_for_task() {
  local herdr=${HERDR_BIN_PATH:-herdr}
  local task_text=$1 repos path name task_lc name_lc hits='' focused focused_root choice
  repos=$(worktrunk_open_repos)
  [[ -z $repos ]] && return 1
  task_lc=$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r path name; do
    name_lc=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    case " $task_lc " in *"$name_lc"*) hits+="$path"$'\n' ;; esac
  done <<<"$repos"
  hits=${hits%$'\n'}
  if [[ -n $hits && $(printf '%s\n' "$hits" | wc -l) -eq 1 ]]; then
    printf '%s\n' "$hits"
    return 0
  fi
  command -v fzf >/dev/null || return 1
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
    } | fzf --with-nth=2 --delimiter='\t' --reverse --no-info --border=rounded \
          --prompt='repo ❯ ' --header='target repository · ↵ pick · esc cancel'
  ) || return 130
  printf '%s\n' "${choice%%$'\t'*}"
}

# Resolve the herdr root workspace of the repository containing PATH, opening
# one in the background when the repo has none. Prints the workspace id.
worktrunk_root_workspace() {
  local path=$1 herdr=${HERDR_BIN_PATH:-herdr} ws repo_root
  ws=$("$herdr" worktree list --cwd "$path" --json 2>/dev/null \
    | jq -r '.result.source.source_workspace_id // empty')
  if [[ -n $ws ]]; then
    printf '%s\n' "$ws"
    return 0
  fi
  repo_root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
  [[ -n $repo_root ]] || return 1
  ws=$("$herdr" workspace create --cwd "$repo_root" \
    --label "${repo_root##*/}" --no-focus 2>/dev/null \
    | jq -r '.result.workspace.workspace_id // empty')
  [[ -n $ws ]] || return 1
  printf '%s\n' "$ws"
}

