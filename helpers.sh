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
