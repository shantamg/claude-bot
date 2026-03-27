#!/bin/bash
# git-pull.sh — Auto-sync framework repo, project repo, adapters, and crontab.
#
# Runs on the instance every minute via cron. Keeps everything up to date:
#   1. Sync the claude-bot framework repo (~/claude-bot)
#   2. Copy framework scripts/adapters to /opt/claude-bot/
#   3. Sync the project repo
#   3c. Trigger incremental code embedding sync (background)
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
  # Copy memory/ subdirectory (vector DB scripts: ingest, search, sync, embed)
  if [ -d "$FRAMEWORK_DIR/core/memory" ]; then
    mkdir -p "$SCRIPTS_DIR/memory"
    cp "$FRAMEWORK_DIR"/core/memory/*.py "$SCRIPTS_DIR/memory/" 2>/dev/null || true
    cp "$FRAMEWORK_DIR"/core/memory/*.sh "$SCRIPTS_DIR/memory/" 2>/dev/null || true
    cp "$FRAMEWORK_DIR"/core/memory/*.yaml "$SCRIPTS_DIR/memory/" 2>/dev/null || true
    chmod +x "$SCRIPTS_DIR"/memory/*.sh "$SCRIPTS_DIR"/memory/*.py 2>/dev/null || true
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

# ── 3b. Ensure bot/staging branch exists and stays in sync ────────────────
# Bot PRs target bot/staging by default. If the branch doesn't exist, create
# it from the default branch. Periodically merge the default branch into it
# so staging doesn't drift too far behind.
if [ -n "$PROJECT_CHECKOUT" ] && [ -d "$PROJECT_CHECKOUT/.git" ]; then
  cd "$PROJECT_CHECKOUT"
  git fetch origin "bot/staging" >> "$LOGFILE" 2>&1 || true
  if ! git rev-parse --verify "origin/bot/staging" >/dev/null 2>&1; then
    # Branch doesn't exist yet — create it from the default branch
    git branch "bot/staging" "origin/${DEFAULT_BRANCH:-main}" >> "$LOGFILE" 2>&1
    git push origin "bot/staging" >> "$LOGFILE" 2>&1
    echo "[$(date)] Created bot/staging from ${DEFAULT_BRANCH:-main}" >> "$LOGFILE"
  fi
fi

# ── 3c. Sync code embeddings (incremental) ──────────────────────────────────
# Only run if: (a) no sync already running, (b) system load is low, (c) there
# are actually changed files to sync. A full initial sync of 600+ files can
# consume 120MB+ RAM and saturate Bedrock API for 30+ minutes — too much for
# a t3.medium alongside active agents.
SYNC_SCRIPT="$SCRIPTS_DIR/memory/sync-code.py"
SYNC_LOCK="/tmp/${BOT_NAME:-claude-bot}-code-sync.lock"
if [ -f "$SYNC_SCRIPT" ] && [ -n "$PROJECT_CHECKOUT" ] && [ -d "$PROJECT_CHECKOUT/.git" ]; then
  if [ -f "$SYNC_LOCK" ] && kill -0 "$(cat "$SYNC_LOCK" 2>/dev/null)" 2>/dev/null; then
    : # Sync already running — skip
  else
    # Only sync if load is low enough (< 1.5 on a 2-vCPU machine)
    LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "99")
    if awk "BEGIN {exit !($LOAD < 1.5)}" 2>/dev/null; then
      (
        echo "$$" > "$SYNC_LOCK"
        # Use nice to lower CPU priority so agents aren't starved
        nice -n 15 python3 "$SYNC_SCRIPT" --repo "$PROJECT_CHECKOUT" >> "$BOT_LOG_DIR/code-sync.log" 2>&1
        rm -f "$SYNC_LOCK"
      ) &
    fi
  fi
fi

# ── 3d. Sync issues/PRs embeddings (incremental) ─────────────────────────────
# Re-embed issues that changed since last run. Each issue is a single Bedrock
# call (~0.5s), so even 5-10 changed issues is trivial. Same lockfile pattern.
ISSUES_SYNC_SCRIPT="$SCRIPTS_DIR/memory/sync-issues.py"
ISSUES_SYNC_LOCK="/tmp/${BOT_NAME:-claude-bot}-issues-sync.lock"
ISSUES_REPO="${PROJECT_REPO:-}"
if [ -f "$ISSUES_SYNC_SCRIPT" ] && [ -n "$ISSUES_REPO" ]; then
  if [ -f "$ISSUES_SYNC_LOCK" ] && kill -0 "$(cat "$ISSUES_SYNC_LOCK" 2>/dev/null)" 2>/dev/null; then
    : # Sync already running — skip
  else
    LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "99")
    if awk "BEGIN {exit !($LOAD < 1.5)}" 2>/dev/null; then
      (
        echo "$$" > "$ISSUES_SYNC_LOCK"
        nice -n 15 python3 "$ISSUES_SYNC_SCRIPT" --repo "$ISSUES_REPO" >> "$BOT_LOG_DIR/issues-sync.log" 2>&1
        rm -f "$ISSUES_SYNC_LOCK"
      ) &
    fi
  fi
fi

# ── 3e. Backup vector database to S3 (daily) ─────────────────────────────────
# The sqlite-vec database is a local file — back it up daily to S3.
MEMORY_DB="${DATA_DIR:-/opt/claude-bot/data}/memory.db"
BACKUP_MARKER="/tmp/${BOT_NAME:-claude-bot}-memory-backup-$(date +%Y%m%d).done"
if [ -f "$MEMORY_DB" ] && [ ! -f "$BACKUP_MARKER" ]; then
  S3_BUCKET="${MEMORY_BACKUP_BUCKET:-}"
  if [ -n "$S3_BUCKET" ]; then
    (
      BACKUP_FILE="/tmp/memory-backup-$(date +%Y%m%d-%H%M%S).db"
      # Use sqlite3 .backup for a consistent snapshot (not just cp)
      sqlite3 "$MEMORY_DB" ".backup '$BACKUP_FILE'" 2>/dev/null
      if [ -f "$BACKUP_FILE" ]; then
        aws s3 cp "$BACKUP_FILE" "s3://${S3_BUCKET}/memory-backups/memory-$(date +%Y%m%d).db" \
          --region "${AWS_DEFAULT_REGION:-us-west-2}" >> "$BOT_LOG_DIR/memory-backup.log" 2>&1 \
          && touch "$BACKUP_MARKER"
        rm -f "$BACKUP_FILE"
      fi
    ) &
  fi
fi

# ── 3f. Ingest converted PDFs from S3 ─────────────────────────────────────────
# The pdf-to-markdown Lambda converts PDFs in s3://bucket/inbox/ and outputs
# markdown to s3://bucket/converted/. Check for new conversions and ingest.
INGEST_SCRIPT="$SCRIPTS_DIR/memory/ingest.py"
S3_BUCKET="${MEMORY_BACKUP_BUCKET:-}"
CONVERTED_MARKER_DIR="${STATE_DIR}/ingested"
if [ -f "$INGEST_SCRIPT" ] && [ -n "$S3_BUCKET" ]; then
  mkdir -p "$CONVERTED_MARKER_DIR"
  # List converted files
  CONVERTED_FILES=$(/home/ubuntu/.local/bin/aws s3 ls "s3://${S3_BUCKET}/converted/" --region us-west-2 2>/dev/null \
    | awk '{print $NF}' | grep '\.md$') || true
  for MD_FILE in $CONVERTED_FILES; do
    MARKER_FILE="$CONVERTED_MARKER_DIR/$MD_FILE.ingested"
    if [ ! -f "$MARKER_FILE" ]; then
      LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "99")
      if awk "BEGIN {exit !($LOAD < 1.5)}" 2>/dev/null; then
        (
          LOCAL_FILE="/tmp/ingest-${MD_FILE}"
          /home/ubuntu/.local/bin/aws s3 cp "s3://${S3_BUCKET}/converted/${MD_FILE}" "$LOCAL_FILE" \
            --region us-west-2 >> "$BOT_LOG_DIR/ingest.log" 2>&1
          if [ -f "$LOCAL_FILE" ]; then
            TITLE=$(echo "$MD_FILE" | sed 's/\.md$//' | tr '_-' '  ')
            nice -n 15 python3 "$INGEST_SCRIPT" --file "$LOCAL_FILE" --collection science \
              --title "$TITLE" >> "$BOT_LOG_DIR/ingest.log" 2>&1 \
              && touch "$MARKER_FILE"
            rm -f "$LOCAL_FILE"
          fi
        ) &
      fi
    fi
  done
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
