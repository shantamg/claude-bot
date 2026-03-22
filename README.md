# claude-bot

A reusable framework for running autonomous Claude Code agents on EC2 instances. It handles Slack messages, GitHub notifications, scheduled jobs, and label-driven dispatch -- all driven by a single `bot.yaml` config file. Extracted from a production system with 30+ workspaces.

## Key Features

- **Config-driven**: One `bot.yaml` defines your project, AWS infra, schedules, and thresholds
- **Slack Socket Mode**: Real-time message handling via WebSocket
- **GitHub integration**: Notification monitoring, PR reviews, @mention responses
- **Label dispatch**: Apply `bot:*` labels to issues; the bot picks them up automatically
- **Workspace system**: Composable task definitions with cascade inheritance (project overrides framework defaults)
- **Resource gating**: Memory/CPU/disk checks with automatic queuing when the instance is busy
- **Scheduled jobs**: Cron-driven workspaces for health checks, bug fixes, docs audits, and more
- **Inter-agent coordination**: Multiple concurrent agents with messaging, deduplication, and stale process cleanup
- **Base workspaces included**: health-check, bug-fix, pr-review, docs-audit, security-audit, daily-digest, stale-sweeper

## Quick Start

```bash
git clone https://github.com/shantamg/claude-bot.git
cd claude-bot
claude
# Then say: "Set this up for my project <owner/repo>"
```

Claude Code reads the framework's `CLAUDE.md` and walks you through interactive setup -- from AWS provisioning to your first workspace. The whole process takes about 30 minutes.

For manual setup, see [docs/SETUP.md](docs/SETUP.md).

## Repository Structure

```
claude-bot/
├── CLAUDE.md                    # Interactive setup guide (Claude reads this)
├── bot.yaml.example             # Annotated config template
├── channel-config.json.example  # Slack channel routing template
├── label-registry.json.example  # GitHub label routing template
│
├── core/                        # Core scripts (project-agnostic)
│   ├── config.sh                # Config loader (reads bot.yaml, exports env vars)
│   ├── run-claude.sh            # Agent executor (locking, resource gate, worktrees)
│   ├── workspace-dispatcher.sh  # Label-driven + scheduled dispatch
│   ├── check-resources.sh       # Memory/CPU/disk threshold checks
│   ├── process-queue.sh         # Priority queue drain
│   ├── clear-stale-locks.sh     # 3-tier stale process cleanup
│   ├── agent-message.sh         # Inter-agent messaging
│   ├── check-pending-messages.sh# Mid-stream message injection (PostToolUse hook)
│   ├── slack-post.sh            # Slack message posting helper
│   ├── git-pull.sh              # Auto-sync framework + project repos
│   └── bug-fix-precheck.sh      # Pre-check for bug-fix workspace
│
├── adapters/                    # Input/output adapters
│   ├── slack/
│   │   ├── socket-listener.mjs  # Socket Mode listener (reads channel-config.json)
│   │   ├── check-socket-mode.sh # Watchdog
│   │   └── package.json
│   └── github/
│       └── check-github.sh      # Notification monitor
│
├── infra/                       # Infrastructure provisioning
│   ├── provision.sh             # AWS: EC2, security group, key pair, elastic IP
│   ├── setup.sh                 # Instance: packages, Claude Code, directories
│   ├── deploy.sh                # Deploy scripts + crontab to instance
│   ├── generate-crontab.sh      # Generate crontab from bot.yaml
│   └── logrotate.conf           # Log rotation template
│
├── base-workspaces/             # Generic workspaces shipped with the framework
│   ├── health-check/
│   ├── bug-fix/
│   ├── pr-review/
│   ├── docs-audit/
│   ├── security-audit/
│   ├── daily-digest/
│   └── stale-sweeper/
│
└── docs/
    ├── SETUP.md                 # Step-by-step manual setup guide
    ├── ARCHITECTURE.md          # System architecture and data flows
    ├── WORKSPACES.md            # Workspace creation and customization
    └── CONFIG.md                # bot.yaml and config file reference
```

## Documentation

| Document | Description |
|----------|-------------|
| [docs/SETUP.md](docs/SETUP.md) | Step-by-step setup guide for manual installation |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture, data flows, security model |
| [docs/WORKSPACES.md](docs/WORKSPACES.md) | How to create, extend, and customize workspaces |
| [docs/CONFIG.md](docs/CONFIG.md) | Complete bot.yaml and config file reference |

## How It Works

1. **You configure** your project in `bot.yaml` (repo, channels, schedules, thresholds)
2. **The framework provisions** an EC2 instance and deploys itself
3. **Adapters listen** for Slack messages and GitHub notifications
4. **The dispatcher** routes incoming work to the right workspace
5. **`run-claude.sh`** spawns Claude Code agents with resource gating, locking, and worktree isolation
6. **`git-pull.sh`** auto-syncs from git every minute -- push changes to main and they're live

## License

TBD
