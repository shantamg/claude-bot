# Expert Review (L1)

Multi-expert issue analysis with devil's advocate pushback. Stateful — uses comment-based state tracking with HTML metadata. Each invocation performs exactly ONE action.

## What to Load

| Resource | When | Why |
|---|---|---|
| `stages/{current}/CONTEXT.md` | Always | Current stage contract |

## What NOT to Load

| Resource | Why |
|---|---|
| Source code | Only load if the issue discusses implementation details |
| Other workspaces | Irrelevant context |

## Stage Progression

1. `01-initialize` — Read issue, select 4 expert personas, post roster comment
2. `02-review-cycle` — Loop: expert review → devil's advocate → response (one action per tick)
3. `03-synthesize` — All experts done → post final synthesis combining all perspectives
4. `04-complete` — Swap labels (`bot:expert-review` → `expert-review-complete`), close out

## Orchestrator Rules

- Execute exactly ONE action per invocation, then exit
- State tracked via `<!-- bot-expert-review-meta: {...} -->` in issue comments
- Stage 02 is a loop — the label stays on the issue while it re-enters each tick
- The last expert to review should be the one closest to implementation (product engineer, systems architect, etc.)

## Expert Pool

The default expert pool ships with the framework. Projects can customize this by
overriding the workspace and editing the pool in `01-initialize/CONTEXT.md`.

The pool is intentionally broad — the initialize stage selects the 4 most relevant
experts for each issue's domain. If your project needs domain-specific experts
(e.g., "iOS accessibility specialist", "ML pipeline engineer"), add them to a
project-level override of this workspace.
