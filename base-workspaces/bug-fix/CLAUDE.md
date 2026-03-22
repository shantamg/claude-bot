# Bug Fix

Find untouched bug-labeled GitHub issues, investigate, fix, and create PRs. Each bug gets an isolated worktree so multiple fixes can run in parallel without interfering with each other.

## Stages

- `01-select` -- Find and pick the highest-priority untouched bug issue
- `02-investigate` -- Analyze the issue, search the codebase, identify root cause
- `03-fix` -- Implement the fix, run tests, create a PR

## Routing

**Scheduled runs** (cron / dispatcher):
Start at `01-select`. Read `stages/01-select/CONTEXT.md` for instructions.

**Label trigger** (`bot:investigate`):
Enter directly at `02-investigate`. The issue number will be in the prompt context. Read `stages/02-investigate/CONTEXT.md` for instructions.

## Worktree Isolation

Each bug fix runs in its own git worktree. The framework's `run-claude.sh` creates the worktree automatically when the agent is on the default branch. Do not merge or push to the default branch directly -- always create a PR.

## Pre-Check

The shell pre-check script (`core/bug-fix-precheck.sh`) runs before spawning Claude for scheduled runs. It verifies that at least one untouched bug issue exists. If nothing qualifies, the scheduled run is skipped entirely (no Claude invocation, no cost).
