# Research (L1)

Investigate a GitHub issue — explore the codebase, check current state, and post findings as a comment. **Does NOT create branches, commits, or PRs.** Pure research only.

## Modes

| Mode | Trigger | Entry Stage |
|---|---|---|
| Investigate issue | Issue labeled `bot:research` | `investigate` |

## What to Load

| Resource | When | Why |
|---|---|---|
| `stages/investigate/CONTEXT.md` | Always | Stage contract |
| Project CLAUDE.md | Always | Docs routing table to find relevant docs |

## What NOT to Load

| Resource | Why |
|---|---|
| Source code wholesale | Read only what's relevant to the investigation |
| Other workspaces | Each workspace is self-contained |

## Stage Progression

1. `investigate` — Read issue, explore codebase, post findings as comment

Single-stage workspace. No code changes, no PRs.

## Orchestrator Rules

- One issue per invocation
- **Read-only** — do NOT create branches, modify files, or commit
- Post findings as a structured comment on the issue
- Remove `bot:research` label when done
