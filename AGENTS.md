@AGENTS.local.md

# Agents

## Tooling

- Install the project toolchain and hooks with `task init`.
- Use project `task` targets instead of reconstructing commands. Use `mise exec <tool> -- <command>` when a project-managed tool is not already on `PATH`.
- Use the smallest verification loop that covers the change. Do not run `task check` by default.
- Before committing, stage the intended files and run `task check:staged`. It runs only the applicable staged formatting and secret checks.
- Run `task check` only for cross-project changes, before a release, or when explicitly requested.
- Run relevant project-specific checks when they exist. `mise exec -- task test:worktree` covers the runnable worktree example.

## Git and GitHub

- Agent-created branches MUST be created as worktrees under `.worktrees/`; do not create branches in the primary checkout.
- Use `mise exec worktrunk -- wt switch --create <branch> --base main --no-cd --format=json`, then work from the returned path. Review/approve `.config/wt.toml` commands before unattended use; never bypass required setup.
- Blocking hooks install tools, copy only allowlisted dependencies, and run `task setup:worktree` without starting services. For plain Git-created worktrees, run `mise exec -- task setup:worktree` yourself.
- `wt shared` only inspects the primary stack, which runs primary-checkout code. Use `wt up` to start/reuse an isolated stack for worktree code. Use Hum to inspect/restart individual processes; do not restart shared services or point worktree migrations at primary data.
- `.env.worktree.local` owns checkout identity/ports. Do not copy primary environment files, database directories, or PID files into a worktree. Supply needed secrets explicitly through Varlock.
- Use Worktrunk removal so its pre-remove hook stops that checkout's Hum processes first. Check active agents/unsaved panes and close the matching Herdr workspace separately. Removing a checkout also discards its ignored local container data; export anything needed first.
- After a merged worktree branch is no longer needed, remove the worktree, delete the branch, and prune stale worktree metadata before handoff.
- Use `gh` for GitHub operations; do not construct raw API calls or open GitHub URLs in a browser.
- Do not push or open a pull request without explicit instruction.

## Scope

- Do not edit files outside the current task scope.
