# Herdr Worktrunk

Switch, create, and remove Git worktrees in Herdr using Worktrunk. The plugin
provides a branch picker, cleanup confirmation, and GitHub PR actions.

## Install

Requires Herdr, Git, Worktrunk `wt`, Bash, and `jq`. Install `fzf` for the branch
and cleanup pickers, and `gh` for PR actions. There is no build step.

```sh
herdr plugin install danieljvdm/herdr-worktrunk
```

## Actions

| Action | What it does |
| --- | --- |
| `worktrunk.open` | Switch to a branch or create one from the default branch |
| `worktrunk.open-current` | Switch to a branch or create one from the current branch |
| `worktrunk.remove-current` | Confirm removal of the invoking worktree |
| `worktrunk.remove` | Pick a worktree to remove |
| `worktrunk.refresh-pr` | Update the workspace's PR status |
| `worktrunk.open-pr` | Open the current branch's PR in a browser |

Run an action directly:

```sh
herdr plugin action invoke worktrunk.open
```

In the branch picker, select a match to switch or type a new name to create it.
Worktrunk shortcuts such as `^`, `-`, and `pr:123` work too. Hook approvals and
setup output stay interactive.

To bind cleanup, add this to your Herdr configuration and reload it:

```toml
[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.remove-current"
description = "Worktree: remove current"
```

Cleanup pins the target when invoked, shows its branch, path, pending changes,
and live agents, then calls `wt remove`. Worktrunk's removal safeguards still
apply. A successful removal closes the associated workspace or checkout panes.

`bin/reap` invokes the same cleanup from a shell. It closes every pane in the
target workspace, including its caller. Use it only when that worktree is ready
to remove.

## Configuration

Find the plugin configuration directory with `herdr plugin config-dir worktrunk`.
Its `config.toml` supports two settings:

```toml
open_mode = "workspace"       # or "tab"
show_remote_branches = false
```

Both modes use Worktrunk to switch or create a checkout. `workspace` opens it as
a native Herdr worktree workspace; `tab` runs `wt switch` in a new shell tab.
Tab mode requires Worktrunk shell integration.

For sidebar PR labels, include `$pr` in your Herdr sidebar rows and invoke
`worktrunk.refresh-pr`. An existing post-switch hook can continue calling
`pr-status.sh report`.

## Development

```sh
herdr plugin link "$PWD"
for test in tests/*_test.sh; do bash "$test" || exit; done
```

[MIT license](LICENSE.md).
