#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/config" "$work/repo"
git -C "$work/repo" init -q -b main
git -C "$work/repo" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m initial
git -C "$work/repo" branch feature
cat > "$work/bin/fzf" <<'TOOL'
#!/usr/bin/env bash
cat > "$TEST_ROOT/candidates"
printf '%s\n' "$*" > "$TEST_ROOT/fzf-args"
printf '%s\n' "$TEST_QUERY"
[[ -z ${TEST_SELECTION:-} ]] || printf '%s\n' "$TEST_SELECTION"
exit "${TEST_FZF_EXIT:-0}"
TOOL
cat > "$work/bin/wt" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_ROOT/wt-args"
printf '{"path":"%s"}\n' "$TEST_ROOT/repo"
TOOL
cat > "$work/bin/herdr" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/herdr-calls"
case "$1 $2" in
  'worktree list') printf '{"result":{"source":{"source_workspace_id":"wROOT"}}}\n' ;;
  'worktree open') printf '{"result":{"workspace":{"workspace_id":"wTASK"}}}\n' ;;
  'tab create') printf '{"result":{"root_pane":{"pane_id":"wROOT:pNEW"}}}\n' ;;
  'pane run') printf '%s\n' "$3" "$4" > "$TEST_ROOT/pane-command" ;;
  *) exit 1 ;;
esac
TOOL
chmod +x "$work/bin/"*
export TEST_ROOT=$work PATH="$work/bin:$PATH" HERDR_PLUGIN_ROOT=$root
export HERDR_BIN_PATH="$work/bin/herdr" HERDR_WORKSPACE_ID=wROOT HERDR_PLUGIN_CONFIG_DIR="$work/config"
unset HERDR_PANE_ID
cd "$work/repo"
export TEST_QUERY=feat TEST_SELECTION=feature
bash "$root/picker.sh" >/dev/null
[[ $(cat "$work/wt-args") == $'switch\nfeature\n--no-cd\n--format=json' ]]
[[ $(cat "$work/fzf-args") != *ctrl-o* ]]
# An unmatched query is the new name, not an absent selection line.
export TEST_QUERY=fresh TEST_SELECTION='' TEST_FZF_EXIT=1
bash "$root/picker.sh" --create-base=current >/dev/null
[[ $(cat "$work/wt-args") == $'switch\n--create\nfresh\n--base\n@\n--no-cd\n--format=json' ]]
# Worktrunk shortcuts never become --create requests.
export TEST_QUERY=pr:123
bash "$root/picker.sh" >/dev/null
[[ $(cat "$work/wt-args") == $'switch\npr:123\n--no-cd\n--format=json' ]]
# Cancel performs no switch or Herdr mutation.
rm "$work/wt-args" "$work/herdr-calls"
export TEST_FZF_EXIT=130
bash "$root/picker.sh" >/dev/null
[[ ! -e "$work/wt-args" && ! -e "$work/herdr-calls" ]]
# Tab presentation still sends wt to the returned pane.
printf 'open_mode = "tab"\n' > "$work/config/config.toml"
export TEST_QUERY=feature TEST_SELECTION=feature TEST_FZF_EXIT=0
bash "$root/picker.sh" >/dev/null
[[ $(cat "$work/pane-command") == $'wROOT:pNEW\nwt switch feature' ]]
printf 'picker tests passed\n'
