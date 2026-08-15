# Worktrunk

A [herdr](https://herdr.dev) plugin for switching, creating, and removing git
worktrees through [worktrunk](https://github.com/max-sixty/worktrunk). Pick (or
type) a branch in an fzf picker and open the worktree as a herdr tab or a native
worktree workspace — with worktrunk's hooks running along the way.

## Why this plugin

herdr already ships with its own worktree management (`herdr worktree
create/open/remove/list`), and it works fine. But worktrunk is a dedicated
worktree manager that does more — most importantly, **lifecycle hooks**: run
setup when a worktree is created (install deps, copy `.env` files, bootstrap
services) and teardown when it's removed, with template variables like
`{{ branch }}` and `{{ worktree_path }}`. herdr's built-in worktree commands
have no hook system.

Rather than reimplement hooks inside herdr, this plugin wires worktrunk's `wt`
into herdr: you get worktrunk's hook-driven workflow (plus its niceties — base
branch selection, PR shortcuts, live preview) while choosing whether the
resulting worktree opens as a tab or as a native linked-worktree workspace.

## What it does

Four workspace actions:

- **Worktree: switch / create from default branch** — opens an fzf picker over
  your existing worktrees and local branches without worktrees (remote-tracking
  branches too, if enabled — see [Remote branches in the picker](#remote-branches-in-the-picker)).
  Press `Enter` on a match to switch to it, or type a new name and press `Enter`
  to create it from worktrunk's default base branch.

- **Worktree: switch / create from current branch** — the same picker, but typed
  new branch names are created with `wt switch --create --base @`, i.e. from the
  currently checked-out branch/worktree.

Both create actions support [worktrunk syntax for PR/MR along with other shortcuts](https://worktrunk.dev/switch/#shortcuts).
Worktrunk's lifecycle hooks run in either presentation mode, and the checkout
opens as a tab or a native worktree workspace according to plugin configuration.

- **Sow: worktree + agent from a task prompt** — task-first dispatch. A
  compact centered popup asks you to describe the work; a fast model call
  names the branch from your text, the worktree is created through `wt`
  (hooks run), it opens as a native worktree workspace, and a coding agent
  starts in its root pane with your task as the opening prompt. Inline
  grammar: start with `@claude`, `@codex`, or `@opencode2` (other
  `herdr agent start` kinds also work) to pick the agent,
  `some-branch-name:` to pick the branch yourself, or
  `>repo` (a path, or the name of any repo with a pane open) to target
  another repository. Set `default_agent = "codex"` in the plugin config to
  change the default agent (claude). Inside the switch/create pickers,
  `ctrl-o` promotes the highlighted or typed branch into the same composer.

  Images: paste them. herdr intercepts image pastes in any pane, saves the
  image, and injects the saved file's path into the composer; on submit each
  path is wrapped as an attachment note so the sown agent knows to read it.
  Multiple pastes attach multiple images.

  The action carries both `workspace` and `global` contexts. From a focused
  workspace, that workspace's repo is the target. Invoked with no workspace
  context, the composer resolves the target from the task text — an explicit
  `>repo` token first, then a repo name mentioned anywhere in the text
  (matched against repos with panes open) — and falls back to an fzf picker
  over open repos, the focused repo listed first.

  Branch naming: set `branch_name_command` in the plugin config to any shell
  command that reads the task text on stdin and prints a branch name on
  stdout (keep the value a simple string — point it at a script for anything
  involved, including conventions like a `you/` branch prefix). Without it,
  `claude --model haiku -p` names the branch; if neither works (or takes over
  20s), the fallback is a slug of the task's first words. Model output is
  sanitized to a plausible branch name either way.

  Prose routing: set `task_classifier_command` to a shell command that reads
  the full task text on stdin and prints one JSON object
  `{"branch", "agent", "model", "effort", "speed"}` (null/`""` fields mean
  no opinion). One model call then both names the branch and routes prose
  directives — "use codex xhigh slow — fix the flaky auth test" starts codex
  at xhigh on the normal tier, no grammar or flags needed. Explicit flags
  and `@agent` grammar always win; the classifier only fills what they left
  open, implausible fields are dropped, and a failed or slow (>30s) call
  falls back to the `branch_name_command` chain. A dispatch that already
  names both its agent and its branch skips the call entirely.

  Focus: dispatch switches to the new workspace by default. Set
  `dispatch_focus = false` in the plugin config to keep working where you
  are — the workspace opens in the background and a notification announces
  the agent instead. `--focus` / `--no-focus` override per invocation.

  The engine behind the overlay is `dispatch.sh`, which is also a standalone
  CLI — alias it (e.g. `sow`) to dispatch from any shell or coding agent:

  ```bash
  sow "fix the flaky token refresh in auth"        # branch + agent, one shot
  sow --codex "bump node to 22"                    # pick the agent
  sow --opencode2 --model xai/grok-4.6 "..."       # OpenCode 2 + Grok 4.6
  sow --opencode2 --model xai/grok-4.6 --speed fast "..."
  sow --repo ~/dev/other-repo "fix the CI flake"   # dispatch into another repo
  sow --codex --effort xhigh --speed normal "..."  # pin the agent's settings
  sow -b fix-auth --no-focus - <<'EOF'             # scripted, prompt on stdin
  Fix the flaky token refresh...
  EOF
  ```

  `--repo` dispatches into a repository other than the current directory's;
  if that repo has no herdr workspace open yet, its root opens as a
  background workspace so the worktree has a parent to register under.

  `--model`, `--effort`, and `--speed fast|normal` pass per-dispatch agent
  settings through to the launch (codex: `-m`, `-c model_reasoning_effort=`,
  `-c service_tier=`; claude: `--model`, `--effort`; OpenCode 2:
  `opencode2 mini --model`). On OpenCode 2, speed is part of the model ID:
  `--model xai/grok-4.6 --speed fast` resolves to `xai/grok-4.6-fast`, while
  `normal` selects the base ID; `--speed` therefore requires `--model`, and
  `--effort` is unsupported. The resolved ID is checked against the live
  `opencode2 models` catalog before a worktree is created. On codex,
  `--speed normal` sets the explicit `service_tier=default` sentinel — the
  only value that suppresses a model catalog's default tier — and after
  launch the live TUI footer is read back, with any divergence from the
  request reported loudly; the footer, not the flags, is what the session
  actually runs.

- **Worktree: remove current** — removes the worktree of the workspace the
  action was invoked from. The target worktree and workspace are pinned into
  the remover's environment at keypress time (from herdr's worktree model), so
  focus moving before the pane opens can no longer redirect the removal. A
  confirmation summary shows the branch, path, uncommitted-change count, any
  live agents in the workspace (with a red warning if one is still working),
  and the workspace that will close; `y` proceeds, anything else cancels.
  The prompt resolves the pinned checkout from Git's lightweight worktree
  topology rather than computing full Worktrunk status for every sibling, so
  it stays fast even in repositories with many worktrees.
  Worktrunk still applies its dirty/unmerged safeguards. Non-interactive
  callers (agents reaping via `remove.sh --current`, or `--yes`) skip the
  confirmation. A pane whose shell survives an *interrupted* removal — its cwd
  stranded under `.git/wt/trash/` — is recognized and offered a cleanup
  (delete the trash copy, close the workspace) instead of a resolution error.

- **Worktree: remove any** — opens an fzf picker over removable worktrees
  (everything except the main checkout). Pick one, then the same confirmation
  summary as above; worktrunk gates unmerged branches and untracked files
  itself, then removes it. The native workspace or any legacy tab panes
  associated with the deleted worktree are closed automatically.

- **Worktree: refresh PR status** / **Worktree: open PR in browser** — the
  focused workspace's checkout is queried with `gh pr view`; refresh reports
  the result (`#123`, `#123 draft`, `#123 merged`, `#123 closed`, or nothing)
  as a `$pr` workspace metadata token, and open runs `gh pr view --web`. See
  [PR status](#pr-status) to wire refresh into `wt switch` and show `$pr` in
  the sidebar.

## Worktree presentation

By default the plugin organizes worktrees the same way as herdr's built-in
worktree support: each checkout becomes a nested worktree workspace in the
sidebar. To restore the original tab-based behavior, set `open_mode` to `"tab"`
in the plugin's managed configuration directory:

```bash
config_dir=$(herdr plugin config-dir worktrunk)
mkdir -p "$config_dir"
${EDITOR:-vi} "$config_dir/config.toml"
```

```toml
open_mode = "tab"
```

Supported values:

- `open_mode = "workspace"` — let Worktrunk create or switch the checkout and
  run its hooks, then register that checkout with `herdr worktree open`. Herdr
  displays it as a nested worktree workspace in the sidebar. This is the default.
  For newly created checkouts, the workspace opens as soon as Git registers it;
  blocking setup continues visibly in a focused `setup` tab, which closes when
  Worktrunk finishes.
- `open_mode = "tab"` — open a new tab in the current workspace and run `wt`
  there. This preserves the original plugin behavior.

The config file is read each time the picker runs, so changing the mode does
not require reinstalling or reloading the plugin.

## Remote branches in the picker

By default the picker lists only your worktrees and local branches. To also
offer remote-tracking branches (e.g. `origin/foo`; run `git fetch` yourself to
refresh these), set `show_remote_branches` to `true` in the same `config.toml`:

```toml
show_remote_branches = true
```

Local branches without worktrees always appear regardless of this setting.

## PR status

`pr-status.sh` reports the current worktree's GitHub PR as a Herdr workspace
metadata token (`$pr`) via `herdr workspace report-metadata`, using
`$HERDR_WORKSPACE_ID` from the pane environment — no plugin action required
to report, though `refresh-pr` and `open-pr` (above) expose it as one too.

To refresh automatically on every `wt switch`, add a personal
[post-switch hook](https://worktrunk.dev/hook/) in `~/.config/worktrunk/config.toml`
(`post-switch` already runs in the background, so this doesn't block the switch):

```toml
[post-switch]
pr-status = """
cd "{{ worktree_path }}" || exit 0
plugin_root=$(herdr plugin list --plugin worktrunk --json 2>/dev/null | jq -r '[.. | objects | .plugin_root? // empty] | first // empty')
[ -n "$plugin_root" ] && bash "$plugin_root/pr-status.sh" report
"""
```

(The explicit `cd` doesn't rely on the hook's own working directory; the
`herdr plugin list --json` lookup mirrors `bin/sow`/`bin/reap` — it survives
plugin reinstalls, which change the on-disk path's hash suffix.)

This covers switching branches from a terminal already inside a Herdr
worktree workspace — the common case. It doesn't reach a worktree at the
moment the picker/dispatch actions first create its workspace (the hook
fires before Herdr registers that workspace), but a brand-new branch has no
PR yet anyway; once one exists, `worktrunk.refresh-pr` picks it up.

Then show the token in `[ui.sidebar.spaces]` in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["branch", "git_status", "$pr"]]
```

No open PR clears the token, so `$pr` renders as nothing rather than a stale
value. It only updates on switch — if a PR merges while you're still sitting
in the worktree, run `worktrunk.refresh-pr` (e.g. bind a key, see
[Keybindings](#keybindings)) to re-check it.

## Requirements

- [**herdr**](https://herdr.dev) ≥ 0.7.0
- [**worktrunk**](https://github.com/max-sixty/worktrunk) ≥ 0.60.0 — the `wt` CLI on your `PATH`
- [**gh**](https://cli.github.com/) — GitHub CLI, for PR status (optional; other actions work without it)
- **fzf** — the interactive picker
- **jq** — JSON parsing
- **bash** — the scripts run with `/bin/bash`

Platforms: macOS and Linux.

## Installation

From the herdr CLI:

```bash
herdr plugin install danieljvdm/herdr-worktrunk
```

Or, for local development, clone and link:

```bash
git clone https://github.com/danieljvdm/herdr-worktrunk
herdr plugin link /path/to/herdr-worktrunk
```

### CLI: `sow` and `reap`

`bin/sow` and `bin/reap` are thin wrappers over the installed plugin (they
resolve its root through `herdr plugin list`, so they survive plugin
updates). Copy them anywhere on your `PATH`:

```bash
install -m 0755 bin/sow bin/reap ~/.local/bin/
```

`sow "task"` dispatches a worktree + agent from any shell inside a herdr
session; `reap` removes the worktree you stand in and closes its workspace —
the CLI forms of the composer and remove-current actions.

### Agent skill

`skills/sow/SKILL.md` teaches coding agents to dispatch tasks with `sow`
(deriving a branch name from context and writing a self-contained handoff
prompt) and to tear sessions down safely with `reap`. Copy the `sow`
directory into your agent's skills directory (e.g. `~/.agents/skills/`) and
adapt to taste.

## Usage

### Create/Switch a worktree from the default branch
```
herdr plugin action invoke open --plugin worktrunk
```

### Create/Switch a worktree from the current branch
```
herdr plugin action invoke open-current --plugin worktrunk
```

### Remove Current Worktree
```
herdr plugin action invoke remove-current --plugin worktrunk
```

### Remove Any Worktree
```
herdr plugin action invoke remove --plugin worktrunk
```

### Refresh PR Status
```
herdr plugin action invoke refresh-pr --plugin worktrunk
```

### Open PR in Browser
```
herdr plugin action invoke open-pr --plugin worktrunk
```

## Keybindings

To drive the plugin from the keyboard, add `[[keys.command]]` entries to
`~/.config/herdr/config.toml` with `type = "plugin_action"`. The `command` is the
plugin's action id qualified with the plugin id (`worktrunk.<action>`; run
`herdr plugin action list` to see the ids):

```toml
# Override herdr's built-in "new worktree" key (prefix+shift+g) with worktrunk's
# default-branch switch/create picker:
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "worktrunk.open"
description = "Worktree: switch / create from default branch"

# Optional: bind current-branch creation separately.
[[keys.command]]
key = "prefix+shift+c"
type = "plugin_action"
command = "worktrunk.open-current"
description = "Worktree: switch / create from current branch"

# Task-first dispatch: describe the work, get a worktree + agent + prompt.
[[keys.command]]
key = "prefix+shift+a"
type = "plugin_action"
command = "worktrunk.dispatch"
description = "Sow: worktree + agent from a task prompt"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.remove-current"
description = "Worktree: remove current"

# PR status: re-check on demand, and jump straight to the PR in a browser.
# (prefix+shift+r and prefix+shift+p are herdr's built-in reload_config and
# rename_pane — pick other keys if you use those.)
[[keys.command]]
key = "prefix+shift+u"
type = "plugin_action"
command = "worktrunk.refresh-pr"
description = "Worktree: refresh PR status"

[[keys.command]]
key = "prefix+shift+o"
type = "plugin_action"
command = "worktrunk.open-pr"
description = "Worktree: open PR in browser"
```

The remove-any picker remains available through the action list as
`worktrunk.remove`; bind it separately only if you use it frequently.

**Recommended:** override herdr's built-in worktree management with these. herdr
binds `prefix+shift+g` to "new worktree" by default, and a custom keybinding takes
precedence over the built-in on the same key — so mapping `worktrunk.open`
to `prefix+shift+g` replaces it with worktrunk's switch/create picker, hooks
included. Pick matching keys for `worktrunk.open-current` and
`worktrunk.remove-current` to round out the workflow.

Reload the config after editing it:

```bash
herdr server reload-config
```

## Development

The plugin is a manifest plus small bash scripts:

- `herdr-plugin.toml` — actions and panes
- `config.sh` — worktree presentation configuration
- `helpers.sh` — shared shell helpers (e.g. worktrunk shortcut detection)
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + orphaned-pane cleanup
- `pr-status.sh` — PR status: report as workspace metadata, or open in a browser
- `tests/config_test.sh` — configuration parser checks
- `tests/helpers_test.sh` — helper function checks
- `tests/pr_status_test.sh` — PR label formatting checks

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink worktrunk && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Devashish Chandra
