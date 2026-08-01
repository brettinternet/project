@AGENTS.local.md

# Agent instructions

## Worktrees

- Agent-created branches MUST be created as worktrees under `.worktrees/`; do not create branches in the primary checkout.
- Create a worktree with `git worktree add -b <branch> .worktrees/<branch>` from the repository root.
- After a merged worktree branch is no longer needed, remove its worktree and delete its branch.

## Verification

- Use the smallest verification loop that covers the change. Do not run `task check` by default.
- Before committing, stage the intended files and run `task check:staged`. It runs only the applicable staged formatting and secret checks.
- Run `task check` only for cross-project changes, before a release, or when explicitly requested.
- Run relevant project-specific checks when they exist; do not start shared services from a worktree unless the project explicitly supports it.

## Git

- Do not push or open a pull request without explicit instruction.
