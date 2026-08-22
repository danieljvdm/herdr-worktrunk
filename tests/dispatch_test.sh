#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dispatch="$repo_root/dispatch.sh"

assert_slug() {
  local expected=$1; shift
  local actual
  actual=$(bash "$dispatch" --slug "$@" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected slug %q for %q, got %q\n' "$expected" "$*" "$actual" >&2
    exit 1
  fi
}

assert_preview() {
  local expected=$1; shift
  local actual
  actual=$(bash "$dispatch" --preview "$@" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected preview %q for %q, got %q\n' "$expected" "$*" "$actual" >&2
    exit 1
  fi
}

unset HERDR_PLUGIN_CONFIG_DIR WORKTRUNK_BRANCH_HINT

# Filler words drop out; the first four meaningful words survive.
assert_slug fix-flaky-token-refresh "fix the flaky token refresh in auth"
assert_slug fix-auth "Fix auth!"
assert_slug rewrite-search-index-use "rewrite the search index to use sqlite and add tests"

# Slugs cap at 40 chars and non-alphanumerics become separators.
assert_slug supercalifragilisticexpialidocious-refac "supercalifragilisticexpialidocious refactoring extravaganza bonanza"
assert_slug bump-node-22-lts "bump node -> 22 (LTS)"

# No derivable words is an error, not an empty slug.
if bash "$dispatch" --slug "the a an" >/dev/null 2>&1; then
  printf 'expected --slug to fail on filler-only text\n' >&2
  exit 1
fi

# Grammar: @agent and branch-name: peel off the front, in either order.
assert_preview 'branch: fix-login · agent: codex' "@codex fix-login: repair the login flow"
assert_preview 'branch: fix-login · agent: codex' "fix-login: @codex repair the login flow"
assert_preview 'branch: fix-login · agent: opencode2' "@opencode2 fix-login: repair the login flow"
assert_preview 'branch: (model-named) · agent: claude' "@claude repair the login flow"
assert_preview 'branch: (model-named) · agent: claude' "repair the login flow"

# >repo grammar peels off alongside the others, in any order.
assert_preview 'branch: fix-login · agent: codex · repo: egte' "@codex >egte fix-login: repair the login flow"
assert_preview 'branch: (model-named) · agent: claude · repo: ../elsewhere' ">../elsewhere repair the login flow"

# A branch hint fills in when the grammar names none.
WORKTRUNK_BRANCH_HINT=hinted-branch \
  assert_preview 'branch: hinted-branch · agent: claude' "repair the login flow"

# default_agent config steers the preview.
config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
printf 'default_agent = "codex"\n' > "$config_dir/config.toml"
HERDR_PLUGIN_CONFIG_DIR=$config_dir \
  assert_preview 'branch: (model-named) · agent: codex' "repair the login flow"

# branch_name_command output is sanitized into a plausible branch name, and a
# failing/empty namer falls back to the slug (observable via the wt call —
# not covered here; sanitize via the config path instead).
assert_named() {
  local expected=$1 namer=$2
  local out
  printf 'branch_name_command = "%s"\n' "$namer" > "$config_dir/config.toml"
  out=$(HERDR_PLUGIN_CONFIG_DIR=$config_dir HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; name_branch_with_model "task"' _ "$dispatch_lib" 2>/dev/null)
  if [[ $out != "$expected" ]]; then
    printf 'expected named branch %q from namer %q, got %q\n' "$expected" "$namer" "$out" >&2
    exit 1
  fi
}

# Source dispatch.sh's functions without running its main flow: extract up to
# the option loop into a temp lib.
dispatch_lib=$config_dir/dispatch_lib.sh
sed -n '1,/^agent_kind=/p' "$dispatch" | sed '$d' > "$dispatch_lib"

assert_named fix-auth "printf 'Fix Auth!\\n'"
assert_named fix-auth "printf 'chatter\\nfix-auth\\n'"      # last line wins
assert_named fix-auth "printf '  --fix-auth--  \\n'"        # trimmed + squeezed

# task_classifier_command output is validated field-by-field: plausible
# values land in the classifier_* globals, junk degrades to no-opinion.
assert_classified() {
  local expected=$1 json=$2
  local out
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n %q\n' "$json" > "$config_dir/fake-classifier"
  chmod +x "$config_dir/fake-classifier"
  printf 'task_classifier_command = "%s"\n' "$config_dir/fake-classifier" \
    > "$config_dir/config.toml"
  out=$(HERDR_PLUGIN_CONFIG_DIR=$config_dir HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"
      classifier_branch='' classifier_agent='' classifier_model=''
      classifier_effort='' classifier_speed=''
      run_task_classifier "task" || true
      printf "%s|%s|%s|%s|%s" "$classifier_branch" "$classifier_agent" \
        "$classifier_model" "$classifier_effort" "$classifier_speed"' \
    _ "$dispatch_lib" 2>/dev/null)
  if [[ $out != "$expected" ]]; then
    printf 'expected classified %q for %q, got %q\n' "$expected" "$json" "$out" >&2
    exit 1
  fi
}

assert_classified 'fix-auth|codex|gpt-5.6-sol|xhigh|normal' \
  '{"branch":"fix-auth","agent":"codex","model":"gpt-5.6-sol","effort":"xhigh","speed":"normal"}'
assert_classified 'fix-auth|||xhigh|' \
  '{"branch":"Fix Auth!","agent":null,"model":null,"effort":"xhigh","speed":"slow"}'
assert_classified 'dan/simplify-dev|codex|solstice-alpha|ultra|normal' \
  '{"branch":"dan/simplify-dev","agent":"codex","model":"solstice-alpha","effort":"ultra","speed":"normal"}'
assert_classified 'dan/fix-auth||||' \
  '{"branch":"dan/fix-auth","agent":"Not An Agent","model":"-bad","effort":"maximum","speed":"warp"}'
assert_classified '||||' 'not json at all'

# Bare, provider-unique model families select their agent before the configured
# default can misroute them. This is the regression for "use sol max slow"
# accidentally launching `claude --model sol --effort max`.
model_cache_dir=$config_dir/codex-home
mkdir -p "$model_cache_dir"
printf '%s\n' '{"models":[
  {"slug":"gpt-5.6-sol","visibility":"list","priority":2},
  {"slug":"gpt-5.7-sol","visibility":"list","priority":1},
  {"slug":"gpt-5.6-luna","visibility":"list","priority":1}
]}' > "$model_cache_dir/models_cache.json"

assert_model_route() {
  local expected=$1 kind=$2 model=$3 actual
  actual=$(CODEX_HOME=$model_cache_dir HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; shift; resolve_model_route "$@"' _ "$dispatch_lib" \
    "$kind" "$model" | tr $'\037' '|')
  if [[ $actual != "$expected" ]]; then
    printf 'expected model route %q for %q/%q, got %q\n' \
      "$expected" "$kind" "$model" "$actual" >&2
    exit 1
  fi
}

assert_model_route 'codex|gpt-5.7-sol' '' sol
assert_model_route 'codex|solstice-alpha' '' solstice
assert_model_route 'codex|solstice-alpha' '' solstice-alpha
assert_model_route 'codex|gpt-5.6-luna' '' luna
assert_model_route 'codex|gpt-5.6-terra' '' gpt-5.6-terra
assert_model_route 'claude|opus' '' opus
assert_model_route 'grok|grok-4.6' '' grok
assert_model_route 'grok|grok-4.6' '' xai
assert_model_route 'grok|grok-4.6' '' grok-4.6
assert_model_route 'grok|grok-4.6' '' xai/grok-4.6

if CODEX_HOME=$model_cache_dir HERDR_PLUGIN_ROOT=$repo_root \
  bash -c 'source "$1"; resolve_model_route claude sol' _ "$dispatch_lib" \
  >/dev/null 2>&1; then
  printf 'expected claude/sol to fail before launch\n' >&2
  exit 1
fi

# --model/--effort/--speed map onto agent-specific launch arguments.
assert_settings_args() {
  local expected=$1 kind=$2 model=$3 effort=$4 speed=$5
  local actual
  actual=$(HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; shift; agent_settings_args "$@"' _ "$dispatch_lib" \
    "$kind" "$model" "$effort" "$speed" | tr '\n' ' ')
  actual=${actual% }
  if [[ $actual != "$expected" ]]; then
    printf 'expected settings args %q for %s, got %q\n' "$expected" "$kind" "$actual" >&2
    exit 1
  fi
}

assert_settings_args \
  '-m gpt-5.6-sol -c model_reasoning_effort=high -c service_tier=fast' \
  codex gpt-5.6-sol high fast
# normal is the explicit `default` sentinel, not an absent key — the only
# way to suppress a model catalog's default_service_tier.
assert_settings_args '-c service_tier=default' codex '' '' normal
assert_settings_args \
  '-m solstice-alpha -c model_reasoning_effort=ultra -c service_tier=default' \
  codex solstice-alpha ultra normal
assert_settings_args '--model opus --effort xhigh' claude opus xhigh ''
assert_settings_args '--model xai/grok-4.6' opencode2 xai/grok-4.6 '' ''
assert_settings_args '-m grok-4.6 --reasoning-effort high' grok grok-4.6 high normal
assert_settings_args '' codex '' '' ''
assert_settings_args '' claude '' '' normal   # no claude launch flag for speed

# OpenCode 2 encodes speed in distinct model IDs.
assert_opencode2_model() {
  local expected=$1 model=$2 speed=$3 actual
  actual=$(HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; shift; opencode2_model_for_speed "$@"' _ "$dispatch_lib" \
    "$model" "$speed")
  if [[ $actual != "$expected" ]]; then
    printf 'expected opencode2 model %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_opencode2_model xai/grok-4.6-fast xai/grok-4.6 fast
assert_opencode2_model xai/grok-4.6-fast xai/grok-4.6-fast fast
assert_opencode2_model xai/grok-4.6 xai/grok-4.6-fast normal
assert_opencode2_model xai/grok-4.6 xai/grok-4.6 normal

# Footer verification: the live session is authoritative over the request.
assert_mismatches() {
  local expected=$1 footer=$2 model=$3 effort=$4 speed=$5
  local actual
  actual=$(HERDR_PLUGIN_ROOT=$repo_root \
    bash -c 'source "$1"; shift; settings_footer_mismatches "$@"' _ "$dispatch_lib" \
    "$footer" "$model" "$effort" "$speed")
  if [[ $actual != "$expected" ]]; then
    printf 'expected mismatches %q for footer %q, got %q\n' "$expected" "$footer" "$actual" >&2
    exit 1
  fi
}

footer='gpt-5.6-sol high fast · 82% context left'
assert_mismatches '' "$footer" gpt-5.6-sol high fast
assert_mismatches 'speed normal (session is fast)' "$footer" gpt-5.6-sol high normal
assert_mismatches 'effort xhigh' "$footer" '' xhigh ''
assert_mismatches '' 'gpt-5.6-sol ultra' '' xhigh ''     # sol shows xhigh as ultra
assert_mismatches '' 'solstice-alpha ultra' solstice-alpha ultra normal
assert_mismatches 'model gpt-5.6-sol' 'gpt-5.5-codex high fast' gpt-5.6-sol '' ''
assert_mismatches '' 'gpt-5.6-sol high' gpt-5.6-sol high normal
# "fast" must match as a word, not inside e.g. a branch named fastlane.
assert_mismatches 'speed fast' 'gpt-5.6-sol high · fastlane-fix' '' '' fast

# --speed rejects anything but fast/normal.
if bash "$dispatch" --speed sluggish --slug "fix auth" >/dev/null 2>&1; then
  printf 'expected --speed to reject unknown tiers\n' >&2
  exit 1
fi

printf 'default_agent = "codex"\ndisabled_agents = "claude"\n' \
  > "$config_dir/config.toml"
if HERDR_PLUGIN_CONFIG_DIR=$config_dir \
  bash "$dispatch" --claude -b blocked-agent "repair the login flow" \
  >/dev/null 2>&1; then
  printf 'expected disabled Claude dispatch to fail before creating a worktree\n' >&2
  exit 1
fi

printf 'dispatch tests passed\n'
