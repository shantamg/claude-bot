#!/bin/bash
# git-pull.sh — Auto-sync framework repo, project repo, adapters, and crontab.
#
# Runs on the instance every minute via cron. Keeps everything up to date:
#   1. Sync the claude-bot framework repo (~/claude-bot)
#   2. Copy framework scripts/adapters to /opt/claude-bot/
#   3. Sync the project repo
#   4. Sync Socket Mode listener (checksum-based restart on code change)
#   5. Auto-sync crontab (generated from bot.yaml, not a static file)
set -euo pipefail

# ── Load config ──────────────────────────────────────────────────────────────
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

LOGFILE="$BOT_LOG_DIR/git-pull.log"

# ── 1. Sync framework repo ──────────────────────────────────────────────────
FRAMEWORK_DIR="$HOME/claude-bot"
if [ -d "$FRAMEWORK_DIR/.git" ]; then
  cd "$FRAMEWORK_DIR"
  git fetch origin main && git reset --hard origin/main >> "$LOGFILE" 2>&1
fi

# ── 2. Copy framework scripts to /opt/claude-bot/ ───────────────────────────
if [ -d "$FRAMEWORK_DIR/core" ]; then
  cp "$FRAMEWORK_DIR"/core/*.sh "$SCRIPTS_DIR/" 2>/dev/null || true
  chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
  # Copy lib/ subdirectory (modular components sourced by run-claude.sh)
  if [ -d "$FRAMEWORK_DIR/core/lib" ]; then
    mkdir -p "$SCRIPTS_DIR/lib"
    cp "$FRAMEWORK_DIR"/core/lib/*.sh "$SCRIPTS_DIR/lib/" 2>/dev/null || true
    chmod +x "$SCRIPTS_DIR"/lib/*.sh 2>/dev/null || true
  fi
fi

if [ -d "$FRAMEWORK_DIR/adapters" ]; then
  cp -r "$FRAMEWORK_DIR"/adapters/ "$BOT_HOME/adapters/" 2>/dev/null || true
  # Ensure adapter shell scripts are executable
  find "$BOT_HOME/adapters" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
fi

# ── 3. Sync project repo ────────────────────────────────────────────────────
# Pull the current branch (not necessarily DEFAULT_BRANCH) so feature branches
# can be tested on the instance without being clobbered.
if [ -n "$PROJECT_CHECKOUT" ] && [ -d "$PROJECT_CHECKOUT/.git" ]; then
  cd "$PROJECT_CHECKOUT"
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    git fetch origin "$CURRENT_BRANCH" >> "$LOGFILE" 2>&1 && \
    git reset --hard "origin/$CURRENT_BRANCH" >> "$LOGFILE" 2>&1 || true
  fi
fi

# ── 4. Sync Socket Mode listener ────────────────────────────────────────────
SOCKET_SRC="$BOT_HOME/adapters/slack"
SOCKET_DST="$BOT_HOME/adapters/slack"
PID_FILE="$STATE_DIR/socket-mode.pid"

if [ -d "$SOCKET_SRC" ] && ls "$SOCKET_SRC"/*.mjs >/dev/null 2>&1; then
  # Snapshot checksums before copy to detect changes
  OLD_CHECKSUM=""
  if ls "$SOCKET_DST"/*.mjs >/dev/null 2>&1; then
    OLD_CHECKSUM=$(cat "$SOCKET_DST"/*.mjs | md5sum 2>/dev/null || md5 -q "$SOCKET_DST"/*.mjs 2>/dev/null || true)
  fi

  # Source and dest are the same dir after step 2 copies adapters,
  # so compute the new checksum from the freshly copied files
  NEW_CHECKSUM=$(cat "$SOCKET_DST"/*.mjs | md5sum 2>/dev/null || md5 -q "$SOCKET_DST"/*.mjs 2>/dev/null || true)

  # Install deps only if package.json changed
  if [ -f "$SOCKET_SRC/package.json" ]; then
    if ! diff -q "$SOCKET_SRC/package.json" "$SOCKET_DST/.package.json.last" >/dev/null 2>&1; then
      (cd "$SOCKET_DST" && npm install --production >> "$LOGFILE" 2>&1 && cp package.json .package.json.last)
    fi
  fi

  # Restart socket listener if code changed (it holds config in memory)
  if [ -n "$OLD_CHECKSUM" ] && [ "$OLD_CHECKSUM" != "$NEW_CHECKSUM" ]; then
    echo "[$(date)] Socket Mode listener code changed — restarting" >> "$LOGFILE"
    if [ -f "$PID_FILE" ]; then
      OLD_PID=$(cat "$PID_FILE")
      if kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null || true
        # Wait briefly for graceful shutdown, then force if needed
        sleep 2
        kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null || true
      fi
      rm -f "$PID_FILE"
    fi
    # Start the listener immediately (check-socket-mode.sh is the long-term watchdog)
    cd "$SOCKET_DST"
    if [ ! -d "node_modules" ]; then
      npm install --production >> "$LOGFILE" 2>&1
    fi
    source "$BOT_HOME/.env" 2>/dev/null || true
    nohup node socket-listener.mjs >> "$BOT_LOG_DIR/socket-mode.log" 2>&1 &
    echo "$!" > "$PID_FILE"
    echo "[$(date)] Socket Mode listener restarted (PID $!)" >> "$LOGFILE"
  fi
fi

# ── 5. Auto-sync crontab ────────────────────────────────────────────────────
# Generate crontab from bot.yaml (not a static file) and install if different
GENERATE_SCRIPT="$SCRIPTS_DIR/generate-crontab.sh"
if [ -x "$GENERATE_SCRIPT" ] && [ -f "$BOT_HOME/bot.yaml" ]; then
  GENERATED_CRON=$("$GENERATE_SCRIPT" "$BOT_HOME/bot.yaml" 2>/dev/null || true)
  if [ -n "$GENERATED_CRON" ]; then
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    if [ "$CURRENT_CRON" != "$GENERATED_CRON" ]; then
      echo "$GENERATED_CRON" | crontab -
      echo "[$(date)] Crontab updated from bot.yaml" >> "$LOGFILE"
    fi
  fi
fi
