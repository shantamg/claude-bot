# Setup Guide

Step-by-step manual setup for claude-bot. If you prefer an interactive experience, open the repo in Claude Code and say "set this up for my project" -- Claude will walk you through everything below.

## Prerequisites

Install these on your local machine before starting:

| Tool | Install | Purpose |
|------|---------|---------|
| AWS CLI | `brew install awscli` | EC2 provisioning |
| Node.js 20+ | `brew install node` | Slack Socket Mode listener |
| yq | `brew install yq` | YAML parsing in scripts |
| gh | `brew install gh` | GitHub CLI (notifications, labels, PRs) |
| jq | `brew install jq` | JSON parsing in scripts |

You also need:

- An **AWS account** with EC2 permissions (create instances, security groups, key pairs, elastic IPs)
- A **GitHub account** with access to the target repo
- A **Slack workspace** (optional -- the bot can run GitHub-only)

## Step 1: Clone the Framework

```bash
git clone https://github.com/shantamg/claude-bot.git
cd claude-bot
```

## Step 2: Configure Your Project

### 2a. Create bot.yaml

Copy the example config into your project repo:

```bash
# In your project repo
mkdir -p bot
cp /path/to/claude-bot/bot.yaml.example bot/bot.yaml
```

Edit `bot/bot.yaml` with your project settings:

```yaml
name: my-bot                        # Instance name (alphanumeric + hyphens)

project:
  repo: myorg/myrepo                # GitHub repo (owner/name)
  checkout: ~/projects/myrepo       # Where to clone on the instance
  bot_username: MyBot               # GitHub username for @mention filtering
  default_branch: main

aws:
  profile: default                  # AWS CLI profile name
  region: us-west-2
  instance_type: t3.medium          # 2 vCPU, 4GB RAM -- good for up to 5 agents
  disk_gb: 30
```

See [CONFIG.md](CONFIG.md) for the complete field reference.

### 2b. Create channel-config.json (if using Slack)

```bash
cp /path/to/claude-bot/channel-config.json.example bot/channel-config.json
```

Edit to define which Slack channels the bot should monitor:

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

The `env_var` field references a variable in the `.env` file on the instance. You will set the actual channel ID there during deployment.

### 2c. Create label-registry.json

```bash
cp /path/to/claude-bot/label-registry.json.example bot/label-registry.json
```

Edit to map GitHub labels to workspaces. Start with the defaults and add custom entries as needed.

### 2d. Create the workspaces directory

```bash
mkdir -p bot/workspaces
```

This is where project-specific workspace overrides go. It can start empty -- the framework's base workspaces will be used as defaults.

### 2e. Commit the bot directory

```bash
git add bot/
git commit -m "Add claude-bot configuration"
git push
```

## Step 3: Configure AWS CLI

If you haven't already, configure an AWS CLI profile:

```bash
aws configure --profile my-bot
# Enter your AWS Access Key ID, Secret Access Key, region, and output format
```

The IAM user needs these permissions:
- `ec2:RunInstances`, `ec2:DescribeInstances`, `ec2:TerminateInstances`
- `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`
- `ec2:CreateKeyPair`, `ec2:DescribeKeyPairs`
- `ec2:AllocateAddress`, `ec2:AssociateAddress`
- `ec2:CreateTags`

## Step 4: Provision EC2

From the claude-bot directory:

```bash
infra/provision.sh /path/to/your-project/bot/bot.yaml
```

This creates:
- An SSH key pair (saved to `~/.ssh/<name>.pem`)
- A security group allowing SSH only (port 22)
- An EC2 instance with the specified size and disk
- An Elastic IP associated with the instance
- An entry in your local `~/.ssh/config` for easy SSH access

Note the SSH hostname printed at the end (e.g., `my-bot`). You will use this for all subsequent SSH commands.

## Step 5: Setup the Instance

```bash
ssh my-bot 'bash -s' < infra/setup.sh
```

This installs on the instance:
- System packages (git, curl, jq, build-essential, etc.)
- yq (YAML parser)
- Node.js 20 + pnpm
- GitHub CLI
- Claude Code
- Directory structure at `/opt/claude-bot/`
- Logrotate configuration
- Claude Code settings (permissions, hooks)

## Step 6: Clone Repos on the Instance

SSH into the instance and clone both repos:

```bash
ssh my-bot

# Clone the framework
git clone https://github.com/shantamg/claude-bot.git ~/claude-bot

# Clone your project
git clone https://github.com/myorg/myrepo.git ~/projects/myrepo
```

## Step 7: Set Up Authentication

### Claude Code

SSH in and run Claude Code interactively to authenticate:

```bash
ssh my-bot
claude
# Follow the authentication prompts, then exit
```

### GitHub CLI

```bash
ssh my-bot
echo 'YOUR_GITHUB_TOKEN' | gh auth login --with-token
```

Or run `gh auth login` interactively.

### Secrets (.env file)

Create the secrets file on the instance:

```bash
ssh my-bot
cat > /opt/claude-bot/.env << 'EOF'
# Slack (omit if not using Slack)
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...
BOT_USER_ID=U...
BOT_OPS_CHANNEL_ID=C...

# Channel IDs (must match env_var names in channel-config.json)
TEAM_CHANNEL_ID=C...

# GitHub (optional if gh auth login was used)
# GH_TOKEN=ghp_...
EOF
```

See [CONFIG.md](CONFIG.md) for the full `.env` format.

## Step 8: Deploy

From your local machine:

```bash
infra/deploy.sh /path/to/your-project/bot/bot.yaml
```

This:
1. Copies core scripts to `/opt/claude-bot/scripts/` on the instance
2. Copies adapters to `/opt/claude-bot/adapters/`
3. Creates symlinks for config files (bot.yaml, channel-config.json, label-registry.json, workspaces)
4. Generates a crontab from `bot.yaml` and installs it
5. Installs the logrotate config
6. Starts the Socket Mode listener (if Slack is enabled)
7. Installs npm dependencies for the Slack adapter

## Step 9: Verify

SSH in and run these checks:

```bash
ssh my-bot

# Check crontab is installed
crontab -l

# Check Socket Mode listener is running (if Slack enabled)
pgrep -f socket-listener

# Check git-pull is syncing (should see recent timestamps)
ls -la /var/log/my-bot/git-pull.log

# Trigger a test health check
/opt/claude-bot/scripts/workspace-dispatcher.sh --scheduled health-check "Run test health check"
```

## Step 10: Create Your First Workspace (Optional)

Create a project-specific workspace:

```bash
# In your project repo
mkdir -p bot/workspaces/my-task/stages/do-work

cat > bot/workspaces/my-task/CLAUDE.md << 'EOF'
# My Task

You are running the my-task workspace.

## Stages

- `do-work/` -- Main work stage

Read `stages/do-work/CONTEXT.md` for your instructions.
EOF

cat > bot/workspaces/my-task/stages/do-work/CONTEXT.md << 'EOF'
# Do Work

## Instructions

1. Read the GitHub issue for context
2. Perform the task
3. Create a PR with your changes
EOF

git add bot/workspaces/my-task/
git commit -m "Add my-task workspace"
git push
```

The bot's `git-pull.sh` will pick up the new workspace within 1 minute.

To trigger it via a label, add an entry to `bot/label-registry.json`:

```json
{
  "bot:my-task": {
    "workspace": "my-task/",
    "entry_stage": "do-work",
    "trigger": "label"
  }
}
```

See [WORKSPACES.md](WORKSPACES.md) for the full workspace guide.

## Troubleshooting

### Bot not responding to Slack messages

1. Check if Socket Mode listener is running: `pgrep -f socket-listener`
2. Check listener logs: `tail -50 /var/log/<name>/socket-mode.log`
3. Verify `.env` has correct `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN`
4. Verify channel IDs in `.env` match channel-config.json `env_var` names

### Bot not responding to GitHub notifications

1. Check `gh auth status` on the instance
2. Check GitHub adapter logs: `tail -50 /var/log/<name>/check-github.log`
3. Verify the bot username in `bot.yaml` matches the authenticated GitHub user

### Agent stuck or running too long

1. Check active agents: `ls /path/to/workspaces/_active/`
2. The 3-tier cleanup runs every 5 minutes and handles stuck processes automatically
3. To manually kill: `kill <PID>` (the cleanup script will handle the rest)

### Disk space running low

1. Clean archived agent directories: `rm -rf /path/to/workspaces/_active/_archived/*`
2. Clean old worktrees: `git worktree prune` in the project checkout
3. Clean old logs: logs rotate automatically via logrotate

### Auth expired

- **Claude Code**: SSH in and run `claude` interactively to re-authenticate
- **GitHub**: Run `gh auth login` again or update `GH_TOKEN` in `.env`
- **Slack**: Tokens don't expire, but if the app is reinstalled you need new tokens in `.env`

## Updating the Framework

The framework auto-syncs from git every minute via `git-pull.sh`. To update:

1. Pull the latest framework changes to your local clone
2. Push to the framework repo's main branch
3. Within 1 minute, all instances running the framework will pick up the changes

Script changes and crontab updates are applied automatically. Socket Mode listener restarts if its code changes.
