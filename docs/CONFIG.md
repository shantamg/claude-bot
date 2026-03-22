# Configuration Reference

## Overview

claude-bot uses four configuration files:

| File | Location | Purpose |
|------|----------|---------|
| `bot.yaml` | `<project>/bot/bot.yaml` | Project configuration (identity, AWS, schedules, thresholds) |
| `channel-config.json` | `<project>/bot/channel-config.json` | Slack channel routing |
| `label-registry.json` | `<project>/bot/label-registry.json` | GitHub label-to-workspace mapping |
| `.env` | `/opt/claude-bot/.env` (on instance) | Secrets (tokens, channel IDs) -- never in git |

All config files except `.env` are checked into the project repo and auto-synced to the instance via `git-pull.sh`.

## Config Resolution Order

When a script reads configuration, values are resolved in this order:

1. **bot.yaml** values (project-specific, highest priority)
2. **Environment variables** (e.g., `RESOURCE_MEMORY_THRESHOLD` overrides `resources.memory_threshold`)
3. **Framework defaults** (hardcoded fallbacks in scripts)

This means you can set reasonable defaults in `bot.yaml`, override per-instance via `.env`, and the framework always has safe fallbacks for anything unspecified.

---

## bot.yaml

The single source of truth for project configuration. The framework reads it at deploy time (to generate crontab, copy scripts) and at runtime (to check thresholds, resolve workspaces, route notifications).

### name

```yaml
name: my-bot
```

Instance name. Used for AWS resource tags, SSH host alias, log directory names, lock file prefixes, and process identification. Must contain only alphanumeric characters and hyphens.

### project

```yaml
project:
  repo: myorg/myrepo               # GitHub repo (owner/name) -- required
  checkout: ~/projects/myrepo       # Path to the repo checkout on the instance -- required
  path: ""                          # Subdirectory within the repo (for monorepos) -- optional
  bot_username: MyBot               # GitHub username for @mention filtering -- required
  default_branch: main              # Branch to sync from -- default: main
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `repo` | Yes | -- | GitHub repository in `owner/name` format |
| `checkout` | Yes | -- | Absolute path to the repo checkout on the EC2 instance |
| `path` | No | `""` | Subdirectory for monorepos. If `bot.yaml` is at `apps/backend/bot/bot.yaml`, set this to `apps/backend` |
| `bot_username` | Yes | -- | The GitHub username the bot authenticates as. Used to filter out the bot's own comments from notification processing |
| `default_branch` | No | `main` | Branch that `git-pull.sh` syncs from |

### aws

```yaml
aws:
  profile: default                  # AWS CLI profile name -- required
  region: us-west-2                 # EC2 region -- default: us-west-2
  instance_type: t3.medium          # Instance type -- default: t3.medium
  ami: ""                           # Ubuntu 24.04 AMI -- auto-detected if empty
  disk_gb: 30                       # EBS volume size in GB -- default: 30
  key_name: ""                      # SSH key pair name -- default: <name>
  security_group: ""                # Security group name -- default: <name>-sg
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `profile` | Yes | -- | AWS CLI profile from `~/.aws/credentials` |
| `region` | No | `us-west-2` | EC2 region for the instance |
| `instance_type` | No | `t3.medium` | EC2 instance type. `t3.medium` (2 vCPU, 4GB) handles up to 5 concurrent agents well |
| `ami` | No | Auto-detected | Ubuntu 24.04 amd64 AMI. Auto-detected per region when empty (recommended) |
| `disk_gb` | No | `30` | EBS volume size. 30GB is sufficient for most projects |
| `key_name` | No | `<name>` | SSH key pair name. Defaults to the instance name |
| `security_group` | No | `<name>-sg` | Security group name. Defaults to `<name>-sg` |

### resources

```yaml
resources:
  memory_threshold: 85              # Queue when memory > X% -- default: 85
  load_threshold: 3.0               # Queue when 1-min load > X -- default: 3.0
  disk_threshold: 90                # Queue when disk > X% -- default: 90
  disk_warn_threshold: 80           # Slack warning when disk > X% -- default: 80
  max_concurrent: 5                 # Max concurrent agents -- default: 5
  reserved_interactive: 2           # Slots reserved for human work -- default: 2
```

| Field | Default | Description |
|-------|---------|-------------|
| `memory_threshold` | `85` | Queue new requests when memory usage exceeds this percentage |
| `load_threshold` | `3.0` | Queue when 1-minute load average exceeds this value. Rule of thumb: 1.5x your vCPU count (t3.medium = 2 vCPU, so 3.0) |
| `disk_threshold` | `90` | Queue when disk usage exceeds this percentage |
| `disk_warn_threshold` | `80` | Post a warning to the ops Slack channel when disk usage exceeds this percentage |
| `max_concurrent` | `5` | Maximum number of concurrent Claude Code agent processes |
| `reserved_interactive` | `2` | Slots reserved for human-triggered work (Slack messages, GitHub mentions). Scheduled jobs can only use `max_concurrent - reserved_interactive` slots, ensuring humans are never blocked by background work |

### process_cleanup

```yaml
process_cleanup:
  idle_threshold_min: 5             # No activity for this long = idle
  triage_min_age: 10                # Min age before AI triage kicks in
  hard_cap_min: 45                  # Kill regardless after this many minutes
  agent_archive_ttl_min: 60         # Keep archived agent dirs for debugging
```

The 3-tier stale process cleanup system (`clear-stale-locks.sh`) handles agents that hang or run too long:

| Field | Default | Description |
|-------|---------|-------------|
| `idle_threshold_min` | `5` | **Tier 1**: No heartbeat activity for this many minutes marks the process as idle |
| `triage_min_age` | `10` | **Tier 2**: Minimum process age (minutes) before AI triage evaluates whether the process is making progress |
| `hard_cap_min` | `45` | **Tier 3**: Unconditional kill after this many minutes, regardless of activity |
| `agent_archive_ttl_min` | `60` | How long to keep archived agent directories (for debugging) before cleanup |

### slack

```yaml
slack:
  enabled: true                     # Enable Slack integration
  socket_mode: true                 # Enable Socket Mode listener
  ops_channel_env: BOT_OPS_CHANNEL_ID   # Env var name for ops channel
```

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Master switch for all Slack functionality |
| `socket_mode` | `true` | Enable the Socket Mode listener for real-time message handling. When `true`, `socket-listener.mjs` stays connected via WebSocket |
| `ops_channel_env` | `BOT_OPS_CHANNEL_ID` | Name of the environment variable (in `.env`) that holds the Slack channel ID for ops alerts. The framework posts errors, health warnings, and status updates to this channel |

Requires `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN` in `.env`. Channel routing is configured separately in `channel-config.json`.

### github

```yaml
github:
  enabled: true                     # Enable GitHub integration
  notifications: true               # Poll GitHub notifications
  notification_interval: "* * * * *"  # Cron schedule for polling
  labels:
    in_progress: "bot:in-progress"  # Label applied when agent picks up an issue
    failed: "bot:failed"            # Label applied when agent fails
```

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Master switch for all GitHub functionality |
| `notifications` | `true` | Poll the GitHub notifications API for participating threads (mentions, review requests, comment replies) |
| `notification_interval` | `* * * * *` | Cron schedule for `check-github.sh`. Default: every minute |
| `labels.in_progress` | `bot:in-progress` | Label applied to an issue when an agent starts working on it |
| `labels.failed` | `bot:failed` | Label applied when an agent fails or errors out on an issue |

Requires `gh` CLI to be authenticated on the instance, or `GH_TOKEN` in `.env`.

### schedules

```yaml
schedules:
  health-check:
    enabled: true
    cron: "0 */6 * * *"
    prompt: "Run scheduled health check"
  bug-fix:
    enabled: true
    cron: "0 * * * *"
    prompt: "Fix untouched bug issues"
    precheck: true
```

Each key is a workspace name. At the scheduled time, the framework runs `workspace-dispatcher.sh --scheduled <name> <prompt>`. The workspace is resolved via the cascade (project workspaces first, then base workspaces).

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `enabled` | No | `false` | Whether this schedule is active |
| `cron` | Yes | -- | Cron expression (5 fields: minute hour day month weekday) |
| `prompt` | Yes | -- | Text passed to Claude when the job starts |
| `precheck` | No | `false` | If `true`, run `core/<workspace>-precheck.sh` first. Exit 0 = proceed, exit 1 = skip |

The framework ships base workspaces for: `health-check`, `bug-fix`, `pr-review`, `docs-audit`, `security-audit`, `daily-digest`, and `stale-sweeper`. You can add any custom workspace name here as long as the workspace exists.

### infrastructure

```yaml
infrastructure:
  git_pull_interval: "* * * * *"
  socket_watchdog_interval: "*/5 * * * *"
  stale_lock_interval: "*/5 * * * *"
  queue_drain_interval: "* * * * *"
  health_check_time: "0 6 * * *"
  label_dispatcher_interval: "* * * * *"
```

Core framework cron jobs. You generally do not need to change these.

| Field | Default | Description |
|-------|---------|-------------|
| `git_pull_interval` | `* * * * *` | How often to sync framework + project repos from git |
| `socket_watchdog_interval` | `*/5 * * * *` | How often to check that the Socket Mode listener is alive |
| `stale_lock_interval` | `*/5 * * * *` | How often to run stale process cleanup |
| `queue_drain_interval` | `* * * * *` | How often to drain the request queue |
| `health_check_time` | `0 6 * * *` | When to run the daily system health check (UTC) |
| `label_dispatcher_interval` | `* * * * *` | How often to check for label-driven workspace dispatch |

### claude

```yaml
claude:
  permissions:
    allow:
      - "Bash(*)"
      - "Read(*)"
      - "Write(*)"
      - "Edit(*)"
      - "Glob(*)"
      - "Grep(*)"
      - "Agent(*)"
      - "WebFetch(*)"
      - "WebSearch(*)"
  mcp_servers: {}
  claude_md: ""
```

| Field | Default | Description |
|-------|---------|-------------|
| `permissions.allow` | (see above) | Tool permissions for bot-spawned Claude sessions. These are written to the Claude Code settings file on the instance |
| `mcp_servers` | `{}` | Additional MCP server configuration. Format follows Claude Code's MCP server spec |
| `claude_md` | `""` | Extra content appended to `~/.claude/CLAUDE.md` on the instance. Use for project-wide instructions that apply to every agent session |

### notifications

```yaml
notifications:
  slack:
    enabled: true
```

| Field | Default | Description |
|-------|---------|-------------|
| `slack.enabled` | `true` | Post operational alerts (errors, health warnings, agent failures) to the ops Slack channel |

---

## channel-config.json

Defines which Slack channels the socket listener monitors and how to route messages to workspaces. Lives at `<project>/bot/channel-config.json`.

```json
{
  "channels": [
    {
      "env_var": "ADMIN_SLACK_DM",
      "name": "DM (Admin)",
      "workspace": "slack-triage",
      "context_count": 10
    },
    {
      "env_var": "TEAM_CHANNEL_ID",
      "name": "#team",
      "workspace": "slack-triage",
      "context_count": 10
    }
  ]
}
```

### Channel Fields

| Field | Required | Description |
|-------|----------|-------------|
| `env_var` | Yes | Name of the environment variable in `.env` that holds the Slack channel ID. Example: if `env_var` is `TEAM_CHANNEL_ID`, then `.env` must contain `TEAM_CHANNEL_ID=C0123456789` |
| `name` | Yes | Human-readable channel name. Used in logging and provenance tracking |
| `workspace` | Yes | Workspace to route messages from this channel to. Resolved via the cascade |
| `context_count` | No | Number of recent messages to fetch as context when building the prompt. Default: 10 |

The socket listener reads this file at startup. Changes require a restart of the listener process. The watchdog (`check-socket-mode.sh`) will restart it automatically within 5 minutes, or you can kill the process manually to trigger an immediate restart.

---

## label-registry.json

Maps GitHub labels to workspace dispatch configuration. Lives at `<project>/bot/label-registry.json`. Read by `workspace-dispatcher.sh` every minute.

```json
{
  "description": "Maps bot:* GitHub labels to workspace paths.",
  "labels": {
    "bot:bug-fix": {
      "workspace": "bug-fix/",
      "entry_stage": "01-select",
      "trigger": "cron"
    },
    "bot:health-check": {
      "workspace": "health-check/",
      "entry_stage": "audit",
      "trigger": "cron"
    },
    "bot:pr-review": {
      "workspace": "pr-review/",
      "entry_stage": "review",
      "trigger": "label"
    },
    "bot:docs-audit": {
      "workspace": "docs-audit/",
      "entry_stage": "incremental",
      "trigger": "cron"
    },
    "bot:security-audit": {
      "workspace": "security-audit/",
      "entry_stage": "scan",
      "trigger": "cron"
    },
    "bot:daily-digest": {
      "workspace": "daily-digest/",
      "entry_stage": "compile",
      "trigger": "cron"
    }
  }
}
```

### Label Entry Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `workspace` | Yes | -- | Directory name under `bot/workspaces/` or `base-workspaces/`. Include the trailing slash |
| `entry_stage` | Yes | -- | Stage directory the agent enters first |
| `trigger` | Yes | -- | How the workspace is triggered: `label` (manual label application), `cron` (scheduled), `webhook` (external), `manual` |
| `keep_label` | No | `false` | If `true`, the trigger label is not removed after the agent completes. Used for multi-pass workspaces that process the same issue repeatedly |

The `description` field at the top level is optional and informational only.

Changes to this file are picked up automatically via `git-pull.sh` -- no restart required.

---

## .env (Secrets)

Secrets file on the EC2 instance at `/opt/claude-bot/.env`. This file is never committed to any repository.

```bash
# ─── Slack ───────────────────────────────────────────────────────────────────
SLACK_APP_TOKEN=xapp-1-...         # Socket Mode app-level token
                                   # Create at: api.slack.com/apps > Basic Info >
                                   # App-Level Tokens (connections:write scope)

SLACK_BOT_TOKEN=xoxb-...          # Bot User OAuth token
                                   # Create at: api.slack.com/apps > OAuth &
                                   # Permissions > Bot User OAuth Token

BOT_USER_ID=U0123456789           # The bot's Slack user ID
                                   # Find via: Slack profile > ... > Copy member ID

BOT_OPS_CHANNEL_ID=C0123456789   # Channel ID for ops alerts
                                   # Must match slack.ops_channel_env in bot.yaml

# ─── Per-Channel IDs ────────────────────────────────────────────────────────
# These must match the env_var names in channel-config.json
ADMIN_SLACK_DM=D0123456789
TEAM_CHANNEL_ID=C0123456789

# ─── GitHub ──────────────────────────────────────────────────────────────────
# Optional if you used `gh auth login` on the instance
# GH_TOKEN=ghp_...
```

### Required Variables (Slack)

| Variable | Description |
|----------|-------------|
| `SLACK_APP_TOKEN` | Socket Mode app-level token (starts with `xapp-`) |
| `SLACK_BOT_TOKEN` | Bot User OAuth token (starts with `xoxb-`) |
| `BOT_USER_ID` | The bot's Slack user ID (starts with `U`) |
| `BOT_OPS_CHANNEL_ID` | Channel ID for operational alerts |

### Required Variables (Per-Channel)

One variable for each `env_var` defined in `channel-config.json`. The variable name must match exactly.

### Optional Variables

| Variable | Description |
|----------|-------------|
| `GH_TOKEN` | GitHub personal access token. Alternative to `gh auth login` |

### Creating a Slack App

If you do not have a Slack app yet:

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app from scratch
2. **Socket Mode**: Settings > Socket Mode > Toggle ON
3. **App-Level Token**: Basic Information > App-Level Tokens > Generate with `connections:write` scope. This is your `SLACK_APP_TOKEN`
4. **Bot Scopes**: OAuth & Permissions > Scopes > Add: `channels:history`, `channels:read`, `chat:write`, `reactions:read`, `reactions:write`, `users:read`, `im:history` (for DMs)
5. **Install**: Install to your workspace
6. **Bot Token**: OAuth & Permissions > Bot User OAuth Token. This is your `SLACK_BOT_TOKEN`
7. **Bot User ID**: Open the bot's profile in Slack > ... > Copy member ID. This is your `BOT_USER_ID`

---

## config.yaml (Multi-Project)

Only needed when running multiple projects on a single instance. Lives at `/opt/claude-bot/config.yaml` on the instance.

```yaml
instance:
  name: my-bot-instance
  ops_channel_env: BOT_OPS_CHANNEL_ID

projects:
  - name: project-a
    repo: myorg/project-a
    checkout: ~/projects/project-a
    bot_dir: bot

  - name: project-b
    repo: myorg/project-b
    path: apps/backend
    checkout: ~/projects/project-b
    bot_dir: apps/backend/bot
```

| Field | Description |
|-------|-------------|
| `instance.name` | Instance-level name (for shared logging) |
| `instance.ops_channel_env` | Shared ops channel env var name |
| `projects[].name` | Project identifier (used in paths and logging) |
| `projects[].repo` | GitHub repository (owner/name) |
| `projects[].path` | Subdirectory within repo (for monorepos) |
| `projects[].checkout` | Path to the repo checkout on the instance |
| `projects[].bot_dir` | Path to the `bot/` directory within the repo |

When this file exists, all core scripts operate in multi-project mode: separate state, queues, and workspaces per project, with shared scripts and adapters. See [ARCHITECTURE.md](ARCHITECTURE.md) for the on-instance layout.
