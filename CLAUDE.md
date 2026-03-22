# claude-bot

A reusable framework for running autonomous Claude Code agents on EC2 instances. It handles Slack messages, GitHub notifications, and scheduled tasks — routing each to the right workspace, managing concurrency, and keeping everything in sync via git-pull.

---

## Interactive Setup

When the user says "set this up", "configure this for my project", or anything similar, walk them through the following phases in order. Ask questions conversationally, confirm before executing destructive or billable actions (like provisioning EC2), and provide exact commands for any manual steps.

### Phase 1: Gather Config

Ask the user these questions. Use sensible defaults where noted.

**Project basics:**
- What is your GitHub repo? (owner/name format, e.g. `shantamg/meet-without-fear`)
- Is it a monorepo? If so, which subdirectory contains the project? (leave blank for single-repo projects)
- What GitHub username will the bot use? (for filtering out its own comments from notifications)

**AWS:**
- Which AWS CLI profile should I use? (must already be configured in `~/.aws/credentials` — if not, guide them to run `aws configure --profile <name>`)
- AWS region? (default: `us-west-2`)
- Instance type? (default: `t3.medium` — 2 vCPU, 4 GB RAM, good for up to 5 concurrent agents. Suggest `t3.large` for heavier workloads)
- Bot instance name? (default: derive from project name, e.g. `meet-without-fear` becomes `mwf-bot`)

**Slack (optional):**
- Do you want Slack integration? (yes/no)
- If yes: Do you already have a Slack app with Socket Mode? (if not, walk them through creation — see the Slack App Creation Guide section below)
- Which Slack channels should the bot monitor? (get channel names and purposes — the actual channel IDs go in `.env` later)
- Which channel should receive ops alerts? (errors, health warnings, agent failures)

**Workspaces and schedules:**
- Which base workspaces do you want enabled? List them with descriptions:
  - `health-check` — audits production health every 6 hours
  - `bug-fix` — picks up untouched bug-labeled GitHub issues hourly
  - `pr-review` — reviews PRs when requested via GitHub
  - `docs-audit` — daily documentation drift detection
  - `daily-digest` — morning summary of overnight activity
  - `security-audit` — weekly security scan
- Any custom schedules or workspaces to create now? (can always add later)

### Phase 2: Generate Config

Based on the answers, generate these files in the user's **project repo** (not in the claude-bot framework repo):

1. **`bot/bot.yaml`** — Use `bot.yaml.example` (at the root of this repo) as the template. Fill in all values from Phase 1. Comment out disabled schedules. Set `slack.enabled` and `github.enabled` based on answers.

2. **`bot/channel-config.json`** — Only if Slack is enabled. One entry per monitored channel:
   ```json
   {
     "channels": [
       {
         "env_var": "CHANNEL_NAME_ID",
         "name": "#channel-name",
         "workspace": "slack-triage",
         "context_count": 10
       }
     ]
   }
   ```
   Use uppercase snake_case for `env_var` (derived from channel name). Default workspace is `slack-triage` unless the user specifies otherwise.

3. **`bot/label-registry.json`** — Based on enabled workspaces:
   ```json
   {
     "description": "Maps bot:* GitHub labels to workspace paths.",
     "labels": {
       "bot:bug-fix": {
         "workspace": "bug-fix/",
         "entry_stage": "01-select",
         "trigger": "cron"
       }
     }
   }
   ```
   Include entries for each enabled workspace that uses label-driven dispatch.

4. **`bot/workspaces/`** — Create the directory. It starts empty (base workspaces are used as-is until the user creates project-specific overrides).

Show the user the generated files and confirm before writing them.

### Phase 3: Provision the EC2 Instance

Run:
```bash
infra/provision.sh bot/bot.yaml
```

This creates: SSH key pair, security group (SSH-only), EC2 instance, Elastic IP, and local `~/.ssh/config` entry.

**Prerequisites**: AWS CLI must be installed and configured with the profile from Phase 1. If it is not, guide the user:
```bash
brew install awscli          # macOS
aws configure --profile <name>
```
They need an IAM user with EC2 permissions (RunInstances, CreateSecurityGroup, AllocateAddress, CreateKeyPair, DescribeInstances, etc.).

**Output to capture**: SSH hostname, instance ID, Elastic IP. Confirm SSH connectivity before proceeding.

### Phase 4: Set Up the Instance

Run:
```bash
ssh <bot-name> 'bash -s' < infra/setup.sh <bot-name>
```

This installs system packages (git, curl, jq, yq, build-essential), Node.js 20 + pnpm, GitHub CLI, Claude Code, creates the directory structure at `/opt/claude-bot/`, writes Claude Code settings, and configures logrotate.

Wait for completion and verify with a quick SSH check.

### Phase 5: Manual Auth Steps

These require interactive human action. Provide exact commands and wait for confirmation at each step.

**1. Clone repos on the instance:**
```bash
ssh <bot-name>
cd ~
git clone git@github.com:<framework-repo>.git claude-bot
git clone git@github.com:<project-repo>.git projects/<project-name>
```
If SSH keys are not set up on the instance, guide them through generating a deploy key or using HTTPS + token.

**2. Create `.env` with secrets:**
```bash
# On the instance at /opt/claude-bot/.env
cat > /opt/claude-bot/.env << 'ENVEOF'
# Slack (if enabled)
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...
BOT_USER_ID=U...
BOT_OPS_CHANNEL_ID=C...

# Per-channel IDs (must match env_var names in channel-config.json)
CHANNEL_NAME_ID=C...

# GitHub
GH_TOKEN=ghp_...
ENVEOF
```
Tell the user where to find each value:
- `SLACK_APP_TOKEN`: Slack app settings > Basic Information > App-Level Tokens
- `SLACK_BOT_TOKEN`: Slack app settings > OAuth & Permissions > Bot User OAuth Token
- `BOT_USER_ID`: Slack app settings > Basic Information > App ID (or use Slack API to look up)
- Channel IDs: Right-click channel in Slack > View channel details > scroll to bottom
- `GH_TOKEN`: GitHub > Settings > Developer Settings > Personal Access Tokens (needs `repo`, `notifications` scopes)

**3. Authenticate Claude Code:**
```bash
ssh <bot-name>
claude
# Follow the interactive auth flow in the terminal
# Then exit claude
```
The user must do this interactively — it cannot be automated.

**4. Authenticate GitHub CLI:**
```bash
ssh <bot-name>
echo '<GH_TOKEN>' | gh auth login --with-token
```

### Phase 6: Deploy

Run:
```bash
infra/deploy.sh bot/bot.yaml
```

This copies scripts to the instance, generates the crontab from `bot.yaml` schedules, installs the crontab, installs the logrotate config, creates symlinks (workspaces, base-workspaces, bot.yaml), and starts the Socket Mode listener if Slack is enabled.

### Phase 7: Verify

Check that everything is running:

```bash
# Verify crontab is installed
ssh <bot-name> 'crontab -l'

# Verify Socket Mode listener is running (if Slack enabled)
ssh <bot-name> 'pgrep -f socket-listener'

# Verify git-pull is working
ssh <bot-name> 'cat /opt/claude-bot/logs/git-pull.log | tail -5'

# Trigger a test health check
ssh <bot-name> '/opt/claude-bot/scripts/workspace-dispatcher.sh --scheduled health-check "Test health check"'
```

If Slack is enabled, suggest the user send a test message in a monitored channel and watch for the bot to respond.

Tell the user: "Setup is complete. Your bot is running." Then offer to create a custom workspace (e.g., a project-specific health check, a Slack triage workspace, or a custom scheduled task).

---

## After Setup

Everything below auto-syncs to the instance within 1 minute of merging to main (via `git-pull.sh`).

### Adding a Workspace

1. Create a directory in the project repo at `bot/workspaces/<workspace-name>/`
2. Add a `CLAUDE.md` with routing instructions and a `stages/<stage-name>/CONTEXT.md` with detailed instructions
3. If label-triggered: add an entry to `bot/label-registry.json`
4. If scheduled: add an entry to the `schedules` section of `bot/bot.yaml`
5. Push to main — the bot picks it up automatically

### Adding a Slack Channel

1. Edit `bot/channel-config.json` — add a new entry with `env_var`, `name`, `workspace`, and `context_count`
2. SSH into the instance and add the channel ID to `/opt/claude-bot/.env` using the `env_var` name
3. Push config to main — git-pull syncs it
4. The Socket Mode watchdog restarts the listener within 5 minutes, or manually kill the listener process to force an immediate restart

### Changing Schedules

1. Edit the `schedules` section in `bot/bot.yaml`
2. Push to main — git-pull syncs the file and auto-regenerates the crontab

### Overriding a Base Workspace

Create a workspace in `bot/workspaces/` with the same name as the base workspace you want to override. The project version takes priority. Two modes:

- **Full override**: Your workspace completely replaces the base version
- **Extend**: Your workspace's `CLAUDE.md` references the base workspace's instructions at `/opt/claude-bot/base-workspaces/<name>/` and adds project-specific content on top

---

## Troubleshooting

### Bot not responding to Slack messages

1. Is Socket Mode running? `ssh <bot-name> 'pgrep -f socket-listener'`
2. Is the channel in `channel-config.json`? Check that the `env_var` matches a variable in `.env`
3. Is the `.env` file correct? `ssh <bot-name> 'cat /opt/claude-bot/.env'` — verify `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN` are set
4. Check the socket listener log: `ssh <bot-name> 'tail -50 /opt/claude-bot/logs/socket-listener.log'`
5. Is the Slack app installed to the workspace? Check app settings on api.slack.com
6. Is the bot invited to the channel? The bot must be a member of any channel it monitors

### Bot not responding to GitHub notifications

1. Is `gh` authenticated? `ssh <bot-name> 'gh auth status'`
2. Is `check-github.sh` in the crontab? `ssh <bot-name> 'crontab -l | grep check-github'`
3. Is the `bot_username` correct in `bot.yaml`? Must match the GitHub account
4. Check the log: `ssh <bot-name> 'tail -50 /opt/claude-bot/logs/check-github.log'`

### Agent seems stuck or hung

1. Check active agents: `ssh <bot-name> 'ls /opt/claude-bot/state/_active/'`
2. Check if `clear-stale-locks.sh` is running: `ssh <bot-name> 'crontab -l | grep stale'`
3. Manually run cleanup: `ssh <bot-name> '/opt/claude-bot/scripts/clear-stale-locks.sh'`
4. Check agent logs: `ssh <bot-name> 'cat /opt/claude-bot/state/_active/agent-<PID>/stream.log'`
5. Nuclear option — kill all Claude processes: `ssh <bot-name> 'pkill -f "claude"'`

### Auth expired

- **Claude Code**: SSH in and run `claude` interactively to re-authenticate
- **GitHub**: Update `GH_TOKEN` in `/opt/claude-bot/.env`, or SSH in and run `gh auth login`
- **Slack**: Tokens do not expire unless revoked — if broken, regenerate in Slack app settings and update `.env`

### Disk space issues

1. Check usage: `ssh <bot-name> 'df -h'`
2. Clean archived agent dirs: `ssh <bot-name> 'rm -rf /opt/claude-bot/state/_active/_archived/*'`
3. Clean old logs: `ssh <bot-name> 'find /opt/claude-bot/logs -name "*.log" -mtime +7 -delete'`
4. Clean git worktrees: `ssh <bot-name> 'cd ~/projects/<name> && git worktree prune'`

---

## Slack App Creation Guide

If the user does not have a Slack app, walk them through these steps:

1. Go to **https://api.slack.com/apps** and click **Create New App** > **From Scratch**
2. Name the app (e.g., "MWF Bot") and select the target workspace
3. Go to **Settings > Socket Mode** and toggle it **ON**
   - This creates a WebSocket connection instead of requiring a public URL
4. Go to **Basic Information > App-Level Tokens** and click **Generate Token and Scopes**
   - Token name: "socket-mode"
   - Add scope: `connections:write`
   - Copy the `xapp-...` token — this is `SLACK_APP_TOKEN`
5. Go to **OAuth & Permissions > Scopes > Bot Token Scopes** and add:
   - `channels:history` — read messages in public channels
   - `channels:read` — list channels
   - `chat:write` — send messages
   - `reactions:read` — see reactions
   - `reactions:write` — add reactions (used for status indicators)
   - `users:read` — look up user info
   - `im:history` — read DMs (if you want DM support)
6. Go to **OAuth & Permissions** and click **Install to Workspace**
   - Copy the **Bot User OAuth Token** (`xoxb-...`) — this is `SLACK_BOT_TOKEN`
7. Go to **Basic Information** and note the **App ID**
   - To find `BOT_USER_ID`, you can also use the Slack API: look up the bot user in **OAuth & Permissions** > **Bot User**
8. Go to **Event Subscriptions** and toggle **ON**
   - Under **Subscribe to bot events**, add:
     - `message.channels` — messages in public channels
     - `message.im` — direct messages (if you want DM support)
9. Invite the bot to each channel it should monitor: in Slack, go to the channel, type `/invite @BotName`

---

## Repository Structure

```
claude-bot/                              # THE FRAMEWORK (shared across all projects)
├── CLAUDE.md                            # This file — setup guide + reference
├── bot.yaml.example                     # Annotated config template
│
├── core/                                # Core scripts (project-agnostic)
│   ├── run-claude.sh                    # Agent executor (locking, resource gate, coordination)
│   ├── check-resources.sh               # Memory/CPU/disk threshold checks
│   ├── process-queue.sh                 # FIFO queue drain with priority
│   ├── clear-stale-locks.sh             # 3-tier stale process cleanup
│   ├── agent-message.sh                 # Inter-agent messaging
│   ├── check-pending-messages.sh        # PostToolUse hook for message injection
│   ├── bot-health-check.sh              # System health reporting
│   ├── slack-post.sh                    # Slack message posting helper
│   ├── git-pull.sh                      # Auto-sync framework + project repos
│   └── workspace-dispatcher.sh          # Label-driven + scheduled dispatch
│
├── adapters/                            # Input/output adapters
│   ├── slack/
│   │   ├── socket-listener.mjs          # Socket Mode listener (reads channel-config.json)
│   │   ├── package.json
│   │   └── check-socket-mode.sh         # Watchdog
│   └── github/
│       └── check-github.sh              # Notification monitor
│
├── infra/                               # Infrastructure provisioning
│   ├── provision.sh                     # AWS: EC2, security group, key pair, elastic IP
│   ├── setup.sh                         # Instance: install packages, Claude Code, dirs
│   ├── deploy.sh                        # Deploy scripts + crontab to instance
│   ├── generate-crontab.sh              # Generate crontab from bot.yaml
│   └── logrotate.conf                   # Log rotation template
│
├── base-workspaces/                     # Generic workspaces shipped with the framework
│   ├── health-check/
│   ├── bug-fix/
│   ├── pr-review/
│   ├── docs-audit/
│   ├── security-audit/
│   └── daily-digest/
│
└── docs/                                # Human-readable documentation
```

Each project that uses claude-bot adds a `bot/` directory to its own repo:

```
your-project/
└── bot/
    ├── bot.yaml                         # Project config
    ├── channel-config.json              # Slack channel routing
    ├── label-registry.json              # GitHub label routing
    └── workspaces/                      # Project-specific workspace overrides
```

---

## Contributing to the Framework

When making changes to this repo (claude-bot itself):

- **`core/` scripts** — Changes flow to all bot instances via git-pull. Test thoroughly; a bug here affects every project.
- **`base-workspaces/`** — Changes flow to all instances that have not overridden the workspace. Safe to improve; projects can always override.
- **`adapters/`** — Changes flow to all instances. The socket listener requires a restart to pick up changes (watchdog handles this within 5 minutes).
- **`infra/`** — Provisioning and setup scripts. Changes only affect new deployments or explicit re-deployments.

Project-specific changes always go in the project's own `bot/` directory, never in the framework.

---

## Key Concepts

**Workspace cascade**: When the dispatcher looks for a workspace, it checks the project's `bot/workspaces/<name>/` first, then falls back to the framework's `base-workspaces/<name>/`. This lets projects override or extend any base workspace.

**Resource gate**: Before spawning a new agent, `check-resources.sh` checks memory, CPU load, and disk usage against the thresholds in `bot.yaml`. If any threshold is exceeded, the request goes into a priority queue and retries when resources free up.

**Reserved interactive slots**: Of the `max_concurrent` agent slots, `reserved_interactive` are held back from scheduled jobs. This ensures a human sending a Slack message or GitHub mention is never blocked by background work.

**Auto-sync**: `git-pull.sh` runs every minute via cron. It pulls the latest from both the framework repo and the project repo. If `bot.yaml` schedules have changed, it regenerates and reinstalls the crontab automatically. No manual redeployment needed for config or workspace changes.

**Secrets**: Tokens, channel IDs, and other secrets live in `/opt/claude-bot/.env` on the instance. They are never committed to any repo. The `.env` file is sourced by scripts at runtime.
