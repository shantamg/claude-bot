# Workspaces

Workspaces are the fundamental unit of work in claude-bot. Each workspace is a self-contained directory with instructions that tell Claude what to do. The dispatcher routes work to workspaces; Claude reads the workspace's `CLAUDE.md` and stage `CONTEXT.md` files to understand its task.

## Workspace Structure

```
workspace-name/
├── CLAUDE.md                # Top-level routing instructions (entry point)
├── _active/                 # Runtime: active agent directories (auto-managed)
└── stages/
    ├── 01-gather/
    │   ├── CONTEXT.md       # Stage-specific instructions
    │   └── output/          # Symlinks to active agents (auto-managed)
    ├── 02-analyze/
    │   ├── CONTEXT.md
    │   └── output/
    └── 03-report/
        ├── CONTEXT.md
        └── output/
```

### CLAUDE.md (Workspace Root)

This is the workspace's entry point. Claude Code auto-loads it when the working directory is inside the workspace. It should:

- Describe the workspace's purpose
- List available stages
- Provide routing rules (which stage to enter based on the trigger)

### CONTEXT.md (Stage)

Each stage has a `CONTEXT.md` that provides detailed instructions for that specific step. The PostToolUse hook auto-detects when an agent reads a `CONTEXT.md` and updates the agent's `route.json` accordingly, so the framework always knows which stage each agent is in.

### Stages

Stages represent discrete steps in a workflow. Multi-stage workspaces allow Claude to complete complex tasks by following a defined pipeline. Stages are numbered for ordering (`01-`, `02-`, etc.). A workspace can have a single stage or many.

## Base Workspaces

The framework ships these generic workspaces that work for any project:

| Workspace | Stages | Default Schedule | Trigger |
|-----------|--------|------------------|---------|
| health-check | `audit` | Every 6 hours | Scheduled |
| bug-fix | `01-select`, `02-investigate`, `03-fix` | Hourly (with pre-check) | Scheduled + label |
| pr-review | `review` | On demand | GitHub `review_requested` |
| docs-audit | `incremental`, `full` | Daily | Scheduled |
| daily-digest | `compile` | Daily | Scheduled |
| security-audit | `scan` | Weekly | Scheduled |
| stale-sweeper | `identify` | Weekdays | Scheduled |

### health-check

Audits production health by checking logs, error rates, and service status. Reports findings to Slack.

- **Customize**: Which services to check, what logs to scan, what metrics matter.

### bug-fix

Finds untouched bug-labeled GitHub issues, investigates root cause, writes a fix, and creates a PR. Each bug gets a parallel sub-agent working in an isolated worktree.

- **Pre-check**: `bug-fix-precheck.sh` scans for open bugs with no non-author comments and no linked PRs. If no bugs are found, the run is skipped (saving API costs).

### pr-review

Performs structured code reviews on pull requests. Triggered when GitHub sends a `review_requested` notification.

- **Customize**: Review standards, areas of focus, domain-specific concerns.

### docs-audit

Audits documentation against the current codebase. Finds drift, missing coverage, and stale content.

- **`incremental` stage**: Daily, uses git history to find recently changed files.
- **`full` stage**: Manual trigger, performs a brute-force scan of the entire codebase.

### security-audit

Scans the codebase for security vulnerabilities (OWASP top 10, dependency issues, hardcoded secrets).

### daily-digest

Summarizes overnight activity (commits, PRs, Slack messages, issues) and posts a summary to Slack.

### stale-sweeper

Identifies stale issues, PRs, and branches. Nudges owners or cleans up as appropriate.

## Workspace Cascade (Inheritance)

When the dispatcher resolves a workspace name, it checks two locations in order:

1. **Project workspaces** (`<project>/bot/workspaces/<name>/`) -- highest priority
2. **Base workspaces** (`claude-bot/base-workspaces/<name>/`) -- framework fallback

If a project defines a workspace with the same name as a base workspace, the project version is used. If no project workspace exists, the base version is used automatically.

### Override Mode: Replace

Create a workspace in `bot/workspaces/` with the same name as a base workspace. The base version is completely ignored.

```
your-project/bot/workspaces/health-check/    # Replaces base/health-check entirely
```

Use this when the base workspace's approach does not fit your project at all.

### Override Mode: Extend

Create a workspace that references the base workspace's instructions and adds project-specific context on top.

```markdown
<!-- your-project/bot/workspaces/health-check/CLAUDE.md -->
# Health Check

## Base Instructions

Follow the standard health check procedure from the base workspace.
Read the base instructions at: /opt/claude-bot/base-workspaces/health-check/stages/audit/CONTEXT.md

## Additional Project-Specific Checks

After completing the base checks, also verify:
- Database connection pool status
- Third-party API availability (Stripe, SendGrid, etc.)
- Background job queue depth
- Cache hit rates
```

Use this when the base workspace is a good foundation but needs project-specific additions.

### Override Mode: Use Base As-Is

Do not create a workspace in `bot/workspaces/`. The dispatcher falls through to `base-workspaces/` automatically.

Use this when the base workspace works perfectly for your project without modification.

### How the Cascade Works

The dispatcher resolves workspace paths with this logic:

```bash
resolve_workspace_dir() {
  local workspace_name="$1"
  local project_dir="$2"

  # 1. Check project workspaces first
  if [ -d "$project_dir/bot/workspaces/$workspace_name" ]; then
    echo "$project_dir/bot/workspaces/$workspace_name"
    return
  fi

  # 2. Fall back to base workspaces
  if [ -d "/opt/claude-bot/base-workspaces/$workspace_name" ]; then
    echo "/opt/claude-bot/base-workspaces/$workspace_name"
    return
  fi

  # 3. Not found
  return 1
}
```

## Creating a Custom Workspace

### Minimal Example

Create the directory structure in your project repo:

```
your-project/bot/workspaces/my-task/
├── CLAUDE.md
└── stages/
    └── do-work/
        └── CONTEXT.md
```

**CLAUDE.md**:

```markdown
# My Task

You are processing a task in the my-task workspace.

## Stages

- `do-work/` -- Main work stage

Read `stages/do-work/CONTEXT.md` for your instructions.
```

**stages/do-work/CONTEXT.md**:

```markdown
# Do Work

## Instructions

1. Read the GitHub issue for context
2. Investigate the codebase
3. Implement the solution
4. Create a PR with your changes
```

### Multi-Stage Example

For tasks that benefit from a defined pipeline:

```
your-project/bot/workspaces/feature-build/
├── CLAUDE.md
└── stages/
    ├── 01-plan/
    │   └── CONTEXT.md
    ├── 02-implement/
    │   └── CONTEXT.md
    └── 03-test/
        └── CONTEXT.md
```

**CLAUDE.md**:

```markdown
# Feature Build

Multi-stage workspace for building new features from GitHub issues.

## Stages

1. `01-plan/` -- Read the issue, explore the codebase, draft an implementation plan
2. `02-implement/` -- Write the code following the plan
3. `03-test/` -- Run tests, fix failures, verify the feature works

Start at `stages/01-plan/CONTEXT.md`.
```

## Adding to label-registry.json

To trigger your workspace via a GitHub label, add an entry to `bot/label-registry.json`:

```json
{
  "bot:my-task": {
    "workspace": "my-task/",
    "entry_stage": "do-work",
    "trigger": "label"
  }
}
```

Fields:

| Field | Description |
|-------|-------------|
| `workspace` | Directory name under `bot/workspaces/` (or `base-workspaces/`) |
| `entry_stage` | Which stage directory the agent enters first |
| `trigger` | `label` (manual), `cron` (scheduled), `webhook` (external), `manual` |
| `keep_label` | Optional. Set to `true` for multi-pass workspaces (see below) |

After adding the entry, create the corresponding label on your GitHub repo (e.g., `bot:my-task`). When someone applies that label to an issue, the dispatcher picks it up within 1 minute.

## Adding a Schedule in bot.yaml

To run your workspace on a cron schedule, add an entry to the `schedules` section of `bot/bot.yaml`:

```yaml
schedules:
  my-task:
    enabled: true
    cron: "0 */4 * * *"           # Every 4 hours
    prompt: "Run my custom task"
    # precheck: true              # Optional: run <workspace>-precheck.sh first
```

The schedule key must match the workspace name. The `prompt` field is the text passed to Claude when the scheduled job starts.

After editing `bot.yaml`, push to main. The `git-pull.sh` auto-sync will regenerate the crontab within 1 minute.

## Multi-Pass Workspaces

Some workspaces need to process the same issue multiple times (e.g., an expert reviewer that checks in periodically, or a milestone tracker that updates as work progresses). These use:

- **`keep_label: true`** in label-registry.json -- the trigger label is not removed after the agent completes, so the dispatcher will pick it up again on the next tick
- **`--session` flag** -- session continuity gives the agent memory across runs, so it remembers what it did previously
- **Cooldown timer** -- prevents immediate re-dispatch after completion (default: 30 minutes), so the same issue is not processed in rapid succession

Example label-registry entry:

```json
{
  "bot:milestone-tracker": {
    "workspace": "milestone-tracker/",
    "entry_stage": "check",
    "trigger": "cron",
    "keep_label": true
  }
}
```

The agent runs, does its work, and exits. The label stays on the issue. After the cooldown period, the dispatcher picks it up again.

## Pre-Check Scripts

Scheduled workspaces can have a pre-check script that runs before spawning Claude. This avoids unnecessary Claude invocations (and API costs) when there is nothing to do.

Place the script at `core/<workspace>-precheck.sh`. The framework ships `core/bug-fix-precheck.sh` as an example.

```bash
#!/bin/bash
set -euo pipefail
# my-task-precheck.sh
# Exit 0 = work found, spawn Claude
# Exit 1 = nothing to do, skip this run

BUGS=$(gh issue list --repo "$GITHUB_REPO" --label "bug" --state open --json number --jq 'length')
if [ "$BUGS" -gt 0 ]; then
  echo "Found $BUGS open bugs"
  exit 0
else
  echo "No open bugs"
  exit 1
fi
```

Enable it in `bot.yaml`:

```yaml
schedules:
  my-task:
    enabled: true
    cron: "0 * * * *"
    prompt: "Process open tasks"
    precheck: true    # Looks for core/my-task-precheck.sh
```

## The _active/ Directory

Each running agent gets a runtime directory at `_active/agent-<PID>/`:

```
_active/
├── agent-12345/
│   ├── meta.json           # PID, workspace, channel, timestamps
│   ├── route.json          # Current workspace + stage
│   ├── inbox/
│   │   ├── unread/         # Messages from other agents (pending injection)
│   │   └── read/           # Processed messages
│   └── stream.log          # Real-time agent output
└── _archived/              # Completed agents (kept for debugging, cleaned by TTL)
```

This directory is managed automatically by `run-claude.sh`. You do not need to create or modify it. It enables:

- **Duplicate prevention**: Agents can see what other agents are currently working on
- **Inter-agent messaging**: One agent can send a message to another via its inbox (using `agent-message.sh`)
- **Route tracking**: The framework knows which workspace and stage each agent is in
- **Output streaming**: Live view of what each agent is doing

Completed agent directories are moved to `_archived/` and cleaned up after the TTL defined in `process_cleanup.agent_archive_ttl_min` (default: 60 minutes).

## Tips

- **Start simple**: A workspace with one stage and a clear `CONTEXT.md` is often enough. Add stages only when the task genuinely benefits from a defined pipeline.
- **Be specific in CONTEXT.md**: The more precise your instructions, the better Claude performs. Include the exact commands to run, files to check, and output format expected.
- **Use the base workspaces first**: Before building a custom workspace, check if a base workspace already does what you need. You can always extend it later with project-specific additions.
- **Test locally on the instance**: You can test a workspace by SSHing in and running `claude -p "your prompt"` from inside the workspace directory.
- **Check the logs**: Agent output is streamed to `_active/agent-<PID>/stream.log` during execution, and to `/var/log/<bot-name>/` for historical logs.
- **Push and wait**: After making workspace changes, push to main. The `git-pull.sh` auto-sync picks up changes within 1 minute.
