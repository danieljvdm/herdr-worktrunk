---
name: sow
description: Dispatch a task to a fresh git worktree with its own coding agent, in one shot, using the `sow` CLI inside a Herdr session — and tear such sessions down again with `reap`. Use when the user asks to spin up / hand off / sow a task into a new worktree or agent ("spin up a worktree for X", "hand this to codex in a new worktree"), to fan several tasks out at once, or to remove/reap a worktree session, including an agent deleting its own.
---

# Sow — dispatch a task to a new worktree + agent

`sow` creates a worktree for a task (via `wt`, so worktrunk hooks run), opens
it as a Herdr worktree workspace, starts a coding agent in it, and submits the
task as that agent's opening prompt. One command, fire and forget.

Preconditions: `test "${HERDR_ENV:-}" = 1` and the current directory is inside
the git repository the worktree should belong to. If either fails, say so and
stop.

## Invocation

Always pass an explicit branch name and the prompt on stdin:

```bash
sow --no-focus -b <branch-name> --agent <claude|codex> - <<'EOF'
<self-contained task prompt>
EOF
```

- `--no-focus` keeps the user's focus where it is; Herdr shows a toast when the
  work lands. Omit it only when the user asks to switch to the new workspace.
- `--agent` (or `--claude`/`--codex`): use the kind the user named; default to
  the configured default (claude) otherwise.
- `--base REF` bases the new branch on REF; `--here` uses the current branch.
  Default is the repo's default branch.

On success `sow` prints the branch, workspace id, and agent name. Report those
to the user and continue your own work — do not wait for the spawned agent.
To check on it later, use `herdr agent get/read/wait` (see the herdr skill).

## Naming the branch

Derive a kebab-case branch from the task's substance, the way the user would
name it (`fix-token-refresh`, `issue-1423-avatar-crop`), and follow the repo's
branch conventions — including any personal namespace prefix like `you/`.
Prefer an issue or ticket id when one is in play. Without `-b`, `sow` pays a
model call to name the branch from the prompt alone — slower, and blinder
than a name you can infer from the whole conversation, so always pass `-b`.

## Composing the prompt

The spawned agent starts cold: no conversation history, a fresh checkout, no
knowledge of what you and the user just discussed. Write the prompt as a
complete handoff:

- the task and its acceptance criteria;
- decisions already made (and rejected alternatives, when they'd re-derive
  them wrongly);
- pointers the spawn would otherwise have to rediscover: relevant files,
  symbols, commands, error text;
- anything the user said verbatim that constrains the work.

## Reaping — removing a session, including your own

`reap` removes the worktree containing the current directory and closes its
Herdr workspace — the CLI form of the user's prefix+shift+d keybinding.
Worktrunk still refuses dirty or unmerged work and runs teardown hooks.

Closing the workspace kills **every pane in it, including the one running
`reap`**. For an agent removing its own session that is the point — but it
means:

- Only reap on the user's instruction, or when your dispatch prompt
  explicitly told you to clean up after landing. Cleanup and exit are
  different intents; when a request could mean either, ask.
- Confirm the work has landed (merged or pushed) before reaping. If `reap`
  refuses because of uncommitted or unmerged work, report that instead of
  forcing anything.
- Say goodbye first: deliver your final summary, then run `reap` as the very
  last command of your final message. Nothing after it will execute, and you
  will not see its output.
- To remove a session other than your own, use `wt remove <branch>` from
  outside it instead; `reap` always targets the worktree you stand in.

## Failure modes

- `sow` retries prompt submission through agent startup dialogs; if it still
  reports the task was not submitted, tell the user the workspace and agent
  it named — the agent is up and needs a human look, not a re-dispatch.
- Worktree-creation hooks that ask for interactive approval can stall a
  dispatch from a non-interactive shell. If `wt switch` output shows an
  approval prompt, surface it; approve the hook commands in the repo's
  worktrunk config before retrying.
- A failed `sow` can leave a worktree without an agent. Read its output before
  re-running; `wt remove <branch>` reclaims a half-opened session.
