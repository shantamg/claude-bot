# Architecture

## Overview

claude-bot is a framework for running autonomous Claude Code agents on EC2 instances. It consists of:

- **Core scripts** that handle agent execution, resource gating, queuing, and process management
- **Adapters** that connect to external services (Slack, GitHub)
- **Infrastructure scripts** that provision and manage EC2 instances
- **Base workspaces** that define reusable task templates
- **Configuration files** that make the framework project-agnostic

## Repository Structure

```
claude-bot/
├── core/                        # Core scripts (project-agnostic)
│   ├── config.sh                # Config loader (reads bot.yaml, exports env vars)
│   ├── run-claude.sh            # Agent executor (orchestrator, sources lib/)
│   ├── lib/                     # Modular components sourced by run-claude.sh
│   │   ├── parse-args.sh        # Argument parsing (--workspace, --session, etc.)
│   │   ├── rate-limit.sh        # Rate limit gate + stream-json event detection
│   │   ├── invoke-claude.sh     # Claude invocation with session + raw stream capture
│   │   ├── setup-agent.sh       # Agent directory creation + meta.json
│   │   ├── setup-worktree.sh    # Git worktree creation + workspace resolution
│   │   └── cleanup-agent.sh     # EXIT trap cleanup
│   ├── workspace-dispatcher.sh  # Label-driven + scheduled workspace dispatch
│   ├── check-resources.sh       # Memory/CPU/disk threshold checks
│   ├── process-queue.sh         # Priority queue drain
│   ├── clear-stale-locks.sh     # 3-tier stale process cleanup
│   ├── agent-message.sh         # Inter-agent messaging
│   ├── check-pending-messages.sh# PostToolUse hook for mid-stream message injection
│   ├── slack-post.sh            # Slack message posting helper
│   ├── git-pull.sh              # Auto-sync framework + project repos
│   └── bug-fix-precheck.sh      # Pre-check script for bug-fix workspace
│
├── adapters/
│   ├── slack/
│   │   ├── socket-listener.mjs  # Socket Mode listener (reads channel-config.json)
│   │   ├── check-socket-mode.sh # Watchdog (restarts listener if dead)
│   │   └── package.json
│   └── github/
│       └── check-github.sh      # Notification monitor (mentions, reviews, comments)
│
├── infra/
│   ├── provision.sh             # AWS: create EC2, security group, key pair, elastic IP
│   ├── setup.sh                 # Instance: install packages, Claude Code, directories
│   ├── deploy.sh                # Deploy scripts + crontab to instance
│   ├── generate-crontab.sh      # Generate crontab from bot.yaml schedules
│   └── logrotate.conf           # Log rotation template
│
├── base-workspaces/             # Generic workspaces shipped with the framework
│   ├── health-check/
│   ├── bug-fix/
│   ├── pr-review/
│   ├── docs-audit/
│   ├── security-audit/
│   ├── daily-digest/
│   ├── stale-sweeper/
│   └── expert-review/           # Multi-expert analysis (extensible expert pool)
│
├── bot.yaml.example             # Annotated config template
├── channel-config.json.example  # Slack routing template
└── label-registry.json.example  # GitHub label routing template
```

## Project-Side Structure

Each project that uses claude-bot adds a `bot/` directory to its own repo:

```
your-project/
└── bot/
    ├── bot.yaml                 # Project config
    ├── channel-config.json      # Slack channel routing
    ├── label-registry.json      # GitHub label mapping
    └── workspaces/              # Project-specific workspaces
        ├── health-check/        # Overrides base/health-check (same name)
        ├── slack-triage/        # New workspace (project-only)
        └── daily-digest/        # Extends base (references it)
```

## On-Instance Layout

### Single-Project Mode

```
~/claude-bot/                           # Framework checkout (synced by git-pull)
~/projects/<name>/                      # Project checkout (synced by git-pull)

/opt/claude-bot/
├── scripts/                            # Active core scripts (copied from framework)
├── adapters/                           # Active adapters (copied from framework)
├── state/                              # Runtime state
│   ├── claims/                         # Message deduplication (atomic file creation)
│   └── heartbeats/                     # Agent activity tracking
├── queue/                              # Request queue (JSON files, priority-sorted)
├── workspaces -> <project>/bot/workspaces/  # Symlink to project workspaces
├── base-workspaces -> ~/claude-bot/base-workspaces/
├── .env                                # Secrets (never in git)
└── bot.yaml -> <project>/bot/bot.yaml  # Active config (symlink)
```

### Multi-Project Mode

When `/opt/claude-bot/config.yaml` exists, the instance serves multiple projects:

```
/opt/claude-bot/
├── scripts/                    # Shared core scripts
├── adapters/                   # Shared adapters
├── config.yaml                 # Instance-level config (project list)
├── .env                        # All secrets (shared)
└── projects/
    ├── project-a/
    │   ├── bot.yaml            # Symlink to project's bot.yaml
    │   ├── channel-config.json
    │   ├── label-registry.json
    │   ├── state/
    │   ├── queue/
    │   └── workspaces/
    └── project-b/
        ├── bot.yaml
        ├── state/
        ├── queue/
        └── workspaces/
```

Each project gets its own state, queue, and workspace directories. Core scripts, adapters, and base workspaces are shared.

## Data Flows

### Slack Message (Real-Time)

```
Slack WebSocket
  -> socket-listener.mjs
     -> reads channel-config.json (which workspace?)
     -> atomic claim (prevent double-processing)
     -> adds eye-reaction to message
     -> builds prompt (recent messages as context + new message)
     -> spawns run-claude.sh --workspace <name>
        -> check-resources.sh (memory/CPU/disk gate)
        -> if insufficient resources: queue to /opt/claude-bot/queue/
        -> if OK: create _active/agent-<PID>/ directory
        -> build active-agents context (prevent duplicate work)
        -> create worktree (if working on main branch)
        -> cd into workspace directory
        -> invoke claude --dangerously-skip-permissions -p
        -> stream output to log + _active/stream.log
        -> on exit: cleanup lock, _active/ dir, worktree
     -> on completion: remove eye-reaction, add checkmark
```

### GitHub Notification

```
cron (every minute)
  -> check-github.sh
     -> gh api /notifications?participating=true
     -> for each notification:
        -> atomic claim (prevent double-processing)
        -> add eye-reaction to triggering comment
        -> dispatch run-claude.sh with appropriate skill
           -> review_requested -> /review-pr
           -> mention/comment -> /respond-github
        -> on completion: remove eye-reaction
```

### Scheduled Workspace Job

```
cron (per bot.yaml schedule)
  -> workspace-dispatcher.sh --scheduled <workspace> <prompt>
     -> per-workspace lock (prevents duplicate runs)
     -> optional pre-check script (exit 0 = work found, exit 1 = skip)
     -> concurrency check (max - reserved_interactive slots)
     -> spawns run-claude.sh --workspace <name>
```

### Label-Driven Dispatch

```
cron (every minute)
  -> workspace-dispatcher.sh
     -> reads label-registry.json
     -> for each bot:* label in registry:
        -> gh issue list --label <label>
        -> for each matching issue:
           -> check concurrency limit
           -> check if already active (agent dir, claim, cooldown)
           -> check for duplicates
           -> atomic claim
           -> resolve workspace + entry stage (cascade)
           -> add bot:in-progress label
           -> spawn run-claude.sh --workspace <name>
           -> on completion: remove trigger label, check exit code
```

## Key Abstractions

### bot.yaml (Project Config)

Single source of truth for all project-specific configuration. Defines the project identity, AWS infrastructure, resource thresholds, Slack/GitHub integration, scheduled tasks, and Claude Code settings. See [CONFIG.md](CONFIG.md) for the complete reference.

### channel-config.json (Slack Routing)

Maps Slack channel IDs to workspace dispatch configuration. The socket listener reads this at startup to know which channels to monitor and where to route messages.

```json
{
  "channels": [
    {
      "env_var": "TEAM_CHANNEL_ID",
      "name": "#team",
      "workspace": "slack-triage",
      "context_count": 10
    }
  ]
}
```

### label-registry.json (GitHub Routing)

Maps GitHub labels to workspace paths. When the dispatcher finds an issue with a matching label, it routes it to the corresponding workspace and entry stage.

```json
{
  "labels": {
    "bot:bug-fix": {
      "workspace": "bug-fix/",
      "entry_stage": "01-select",
      "trigger": "cron"
    }
  }
}
```

### Workspace Cascade

When the dispatcher looks for a workspace, it checks two locations in order:

1. **Project workspaces** (`project/bot/workspaces/<name>/`) -- highest priority
2. **Base workspaces** (`claude-bot/base-workspaces/<name>/`) -- framework defaults

A project can fully replace a base workspace, extend it (by referencing the base instructions), or use the base as-is by not creating an override. See [WORKSPACES.md](WORKSPACES.md) for details.

### Adapter Pattern

Input adapters (Slack socket listener, GitHub notification monitor) and output adapters (Slack posting, GitHub reactions) are separated from core execution logic. The core scripts (`run-claude.sh`, `workspace-dispatcher.sh`) don't know or care where work came from. Adding a new input source (Discord, webhooks, email) means writing a new adapter without touching the core.

### Config Loader (config.sh)

Every core script starts by sourcing `config.sh`, which reads `bot.yaml` via `yq` and exports standardized environment variables (`BOT_HOME`, `BOT_NAME`, `BOT_LOG_DIR`, `PROJECT_DIR`, `GITHUB_REPO`, etc.). This is the single point where configuration is resolved.

### Active Directory System

Each running agent gets a directory at `_active/agent-<PID>/` containing:

- `meta.json` -- PID, workspace, channel, issueNumber, timestamps, session info
- `route.json` -- Current workspace and stage (auto-detected by PostToolUse hook)
- `inbox/unread/` -- Messages from other agents (pending injection)
- `inbox/read/` -- Processed messages
- `stream.log` -- Real-time output (text extracted from stream-json)
- `raw-stream.jsonl` -- Raw stream-json output (used for rate limit event detection)

This enables duplicate prevention (agents see what others are working on), inter-agent messaging, route tracking, and live output streaming. Completed agents are moved to `_archived/` and cleaned up by TTL.

## Security Model

- **Secrets isolation**: All secrets live in `/opt/claude-bot/.env` on the instance, never in any git repository
- **Permissions**: Claude runs with `--dangerously-skip-permissions` (appropriate for bot-only automated sessions, not interactive use)
- **Network access**: Security group allows SSH only (port 22); no inbound web traffic
- **SSH keys**: Instance access via key pair only, no password authentication
- **Process isolation**: Agent processes run as the `ubuntu` user, not root
- **Worktree isolation**: Each agent works in a separate git worktree, preventing conflicts with other agents and the main branch
- **Deduplication**: Atomic file-based claims prevent the same work from being processed twice

## Auto-Sync

The `git-pull.sh` script runs every minute via cron and:

1. Pulls the latest framework code from `~/claude-bot/`
2. Copies updated scripts to `/opt/claude-bot/scripts/`
3. Pulls the latest project code from the project checkout
4. Checks if the Socket Mode adapter code changed (restarts if so)
5. Regenerates the crontab from `bot.yaml` if schedules changed

This means any change pushed to either the framework repo or the project repo goes live on the instance within 1 minute of merging to main.
