#!/bin/bash
# First-time setup for a claude-bot EC2 instance
# Run ON the instance: ssh <bot-name> 'bash -s' < infra/setup.sh [bot-name]
# Or: ssh <bot-name> then: bash /opt/claude-bot/infra/setup.sh [bot-name]
set -euo pipefail

BOT_NAME="${1:-claude-bot}"

echo "=== ${BOT_NAME} Instance Setup ==="

# 1. System packages
echo "[1/6] Installing system packages..."
sudo apt update && sudo apt install -y \
  git curl jq yq zsh vim build-essential unzip ca-certificates gnupg

# 2. Node.js 20 + pnpm
echo "[2/6] Installing Node.js 20 + pnpm..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo corepack enable
sudo corepack prepare pnpm@10.0.0 --activate

# 3. GitHub CLI
echo "[3/6] Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update && sudo apt install -y gh

# 4. Claude Code
echo "[4/6] Installing Claude Code..."
sudo npm install -g @anthropic-ai/claude-code

# 5. Shell setup
echo "[5/6] Configuring shell..."
if ! grep -q "${BOT_NAME} aliases" ~/.bashrc; then
  cat >> ~/.bashrc << BASHRC

# ${BOT_NAME} aliases
alias c="claude --dangerously-skip-permissions"
PS1="\[\033[36m\][${BOT_NAME}]\[\033[0m\] \w \$ "
cd \$HOME 2>/dev/null || true
BASHRC
fi

# 6. Claude Code config
echo "[6/6] Writing Claude Code settings and instructions..."
mkdir -p ~/.claude
cat > ~/.claude/CLAUDE.md << EOF
# EC2 Bot Instance (${BOT_NAME})

This is the ${BOT_NAME} EC2 bot instance, powered by the claude-bot framework.

A cron job runs \`git pull\` on the default branch every minute and syncs scripts to \`/opt/claude-bot/scripts/\`. Any file changes on the default branch will be overwritten. Files outside the repo (e.g., \`/opt/claude-bot/.env\`) are not affected.

Configuration is loaded from \`bot.yaml\` via \`/opt/claude-bot/core/config.sh\`.
EOF

cat > ~/.claude/settings.json << 'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "Glob(*)",
      "Grep(*)",
      "Agent(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "mcp__slack__*"
    ],
    "deny": []
  },
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/claude-bot/scripts/check-pending-messages.sh"
          }
        ]
      }
    ]
  },
  "env": {},
  "includeCoAuthoredBy": true,
  "skipDangerousModePermissionPrompt": true
}
EOF

# Create framework directories (always under /opt/claude-bot)
echo "Creating framework directories..."
sudo mkdir -p \
  /opt/claude-bot/scripts \
  /opt/claude-bot/adapters/slack \
  /opt/claude-bot/state/heartbeats \
  /opt/claude-bot/state/claims \
  /opt/claude-bot/state/active \
  /opt/claude-bot/queue

# Create bot-specific log directory
sudo mkdir -p "/var/log/${BOT_NAME}"

sudo chown -R ubuntu:ubuntu /opt/claude-bot "/var/log/${BOT_NAME}"

# Logrotate
sudo tee "/etc/logrotate.d/${BOT_NAME}" > /dev/null << EOF
/var/log/${BOT_NAME}/*.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
}
EOF

echo ""
echo "=== Setup complete ==="
echo ""
echo "Remaining manual steps:"
echo "  1. Clone repo:  (see setup-repo.sh or do it manually)"
echo "  2. Copy secrets: scp .env files to the instance"
echo "  3. Run deploy:   ./infra/deploy.sh"
echo "  4. Auth Claude:  ssh ${BOT_NAME}, then run 'claude' interactively"
echo "  5. Auth GitHub:  echo 'TOKEN' | gh auth login --with-token"
