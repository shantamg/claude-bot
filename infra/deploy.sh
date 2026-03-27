#!/bin/bash
# Deploy claude-bot framework scripts and crontab to the EC2 instance.
# Run from local machine (anywhere with SSH access to the instance).
#
# Usage:
#   infra/deploy.sh [bot.yaml]
#
# Reads the instance name from bot.yaml to determine the SSH host.
# Copies core scripts, adapters, generates crontab, and installs logrotate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Read config ──────────────────────────────────────────────────────────────
BOT_YAML="${1:-bot.yaml}"
if [ ! -f "$BOT_YAML" ]; then
  echo "Error: bot.yaml not found at '$BOT_YAML'"
  echo "Usage: $0 [path/to/bot.yaml]"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is not installed. Install with: brew install yq"
  exit 1
fi

HOST=$(yq -r '.name // "claude-bot"' "$BOT_YAML")
BOT_NAME="$HOST"
BOT_HOME="/opt/claude-bot"

echo "=== Deploying $BOT_NAME to $HOST ==="

# ── Sync core scripts ───────────────────────────────────────────────────────
echo "Syncing core scripts..."
scp -q "$REPO_ROOT"/core/*.sh "$HOST:$BOT_HOME/scripts/"
ssh "$HOST" "chmod +x $BOT_HOME/scripts/*.sh"

# Sync lib/ subdirectory (modular components sourced by run-claude.sh)
if [ -d "$REPO_ROOT/core/lib" ]; then
  echo "Syncing lib/ modules..."
  ssh "$HOST" "mkdir -p $BOT_HOME/scripts/lib"
  scp -q "$REPO_ROOT"/core/lib/*.sh "$HOST:$BOT_HOME/scripts/lib/"
  ssh "$HOST" "chmod +x $BOT_HOME/scripts/lib/*.sh"
fi

# Sync memory/ subdirectory (embedding pipeline)
if [ -d "$REPO_ROOT/core/memory" ]; then
  echo "Syncing memory/ scripts..."
  ssh "$HOST" "mkdir -p $BOT_HOME/scripts/memory"
  scp -q "$REPO_ROOT"/core/memory/*.py "$HOST:$BOT_HOME/scripts/memory/"
  scp -q "$REPO_ROOT"/core/memory/*.sh "$HOST:$BOT_HOME/scripts/memory/" 2>/dev/null || true
  scp -q "$REPO_ROOT"/core/memory/*.yaml "$HOST:$BOT_HOME/scripts/memory/" 2>/dev/null || true
  scp -q "$REPO_ROOT"/core/memory/README.md "$HOST:$BOT_HOME/scripts/memory/" 2>/dev/null || true
  ssh "$HOST" "chmod +x $BOT_HOME/scripts/memory/*.sh 2>/dev/null || true"
fi

# ── Sync adapters ────────────────────────────────────────────────────────────
echo "Syncing Slack adapter..."
ssh "$HOST" "mkdir -p $BOT_HOME/adapters/slack"
scp -q "$REPO_ROOT"/adapters/slack/* "$HOST:$BOT_HOME/adapters/slack/"
ssh "$HOST" "cd $BOT_HOME/adapters/slack && npm install --production"

echo "Syncing GitHub adapter..."
ssh "$HOST" "mkdir -p $BOT_HOME/adapters/github"
scp -q "$REPO_ROOT"/adapters/github/* "$HOST:$BOT_HOME/adapters/github/"
ssh "$HOST" "chmod +x $BOT_HOME/adapters/github/*.sh 2>/dev/null || true"

# ── Create symlinks ───────────────────────────────────────────────────────────
echo "Creating symlinks..."

# bot.yaml — resolve project checkout path from the yaml
PROJECT_CHECKOUT=$(yq -r '.project.checkout // ""' "$BOT_YAML")
if [ -n "$PROJECT_CHECKOUT" ]; then
  # Expand ~ to the remote user's home directory
  ssh "$HOST" "ln -sfn ${PROJECT_CHECKOUT}/bot/bot.yaml $BOT_HOME/bot.yaml"
  ssh "$HOST" "ln -sfn ${PROJECT_CHECKOUT}/bot/workspaces $BOT_HOME/workspaces 2>/dev/null || true"
  ssh "$HOST" "ln -sfn ${PROJECT_CHECKOUT}/bot/channel-config.json $BOT_HOME/channel-config.json 2>/dev/null || true"
  ssh "$HOST" "ln -sfn ${PROJECT_CHECKOUT}/bot/label-registry.json $BOT_HOME/label-registry.json 2>/dev/null || true"
fi

# base-workspaces — link to the framework's base workspaces on the instance
ssh "$HOST" "ln -sfn ~/claude-bot/base-workspaces $BOT_HOME/base-workspaces"

# ── Generate and install crontab ─────────────────────────────────────────────
echo "Generating crontab from bot.yaml..."
CRONTAB_TMP=$(mktemp)
"$SCRIPT_DIR/generate-crontab.sh" "$BOT_YAML" > "$CRONTAB_TMP"

echo "Installing crontab..."
scp -q "$CRONTAB_TMP" "$HOST:/tmp/$BOT_NAME-crontab.txt"
ssh "$HOST" "crontab /tmp/$BOT_NAME-crontab.txt && rm /tmp/$BOT_NAME-crontab.txt"
rm -f "$CRONTAB_TMP"

# ── Install logrotate config ────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/logrotate.conf" ]; then
  echo "Installing logrotate config..."
  # Render the template with the bot name
  LOGROTATE_TMP=$(mktemp)
  sed "s|{{BOT_NAME}}|$BOT_NAME|g" "$SCRIPT_DIR/logrotate.conf" > "$LOGROTATE_TMP"
  scp -q "$LOGROTATE_TMP" "$HOST:/tmp/$BOT_NAME-logrotate.conf"
  ssh "$HOST" "sudo mv /tmp/$BOT_NAME-logrotate.conf /etc/logrotate.d/$BOT_NAME && sudo chown root:root /etc/logrotate.d/$BOT_NAME"
  rm -f "$LOGROTATE_TMP"
fi

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "Deployed scripts:"
ssh "$HOST" "ls -1 $BOT_HOME/scripts/"
echo ""
echo "Deployed adapters:"
ssh "$HOST" "ls -1R $BOT_HOME/adapters/"
echo ""
echo "Active crontab:"
ssh "$HOST" "crontab -l"
echo ""
echo "=== Deploy complete ($BOT_NAME) ==="
