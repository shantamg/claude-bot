#!/bin/bash
set -euo pipefail

# Socket Mode health check watchdog — runs every 5 minutes via cron.
#
# Checks:
#   1. Is the socket-listener process running?
#   2. Has it received an event recently (heartbeat file)?
#
# If the process is down, restarts it. If it appears hung (no heartbeat
# in 15+ minutes), kills and restarts it.
#
# If the process has restarted 3+ times in the last hour, alerts via Slack.

# ── Load framework config ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../core/config.sh"

# ── Paths ────────────────────────────────────────────────────────────────────
LOGFILE="$BOT_LOG_DIR/socket-mode.log"
HEARTBEAT_FILE="$STATE_DIR/socket-mode-heartbeat.txt"
PID_FILE="$STATE_DIR/socket-mode.pid"
RESTART_LOG="$STATE_DIR/socket-mode-restarts.log"
SOCKET_DIR="$SCRIPT_DIR"

log() {
  echo "[$(date)] $1" >> "$LOGFILE"
}

start_socket_mode() {
  log "Starting Socket Mode listener..."

  cd "$SOCKET_DIR"

  # Install deps if node_modules is missing
  if [ ! -d "node_modules" ]; then
    log "Installing dependencies..."
    npm install --production >> "$LOGFILE" 2>&1
  fi

  # Start the process in background, redirect output to log
  nohup node socket-listener.mjs >> "$LOGFILE" 2>&1 &
  local PID=$!
  echo "$PID" > "$PID_FILE"

  # Log the restart for rate limiting
  echo "$(date +%s)" >> "$RESTART_LOG"

  log "Socket Mode listener started (PID $PID)"
}

check_restart_rate() {
  # Count restarts in the last hour
  if [ ! -f "$RESTART_LOG" ]; then
    return
  fi

  local CUTOFF
  CUTOFF=$(($(date +%s) - 3600))
  local COUNT
  COUNT=$(awk -v cutoff="$CUTOFF" '$1 > cutoff' "$RESTART_LOG" 2>/dev/null | wc -l)

  if [ "$COUNT" -ge 3 ]; then
    log "WARNING: Socket Mode has restarted $COUNT times in the last hour — alerting"
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg count "$COUNT" --arg bot "$BOT_NAME" --arg logdir "$BOT_LOG_DIR" \
        '{channel: $ch, text: ("\u26a0\ufe0f Socket Mode listener has restarted " + $count + " times in the last hour on *" + $bot + "*. May need manual investigation. SSH in and check: `tail -100 " + $logdir + "/socket-mode.log`")}')" >/dev/null
  fi

  # Prune old entries (keep last 24h)
  local DAY_AGO
  DAY_AGO=$(($(date +%s) - 86400))
  if [ -f "$RESTART_LOG" ]; then
    awk -v cutoff="$DAY_AGO" '$1 > cutoff' "$RESTART_LOG" > "${RESTART_LOG}.tmp" 2>/dev/null
    mv "${RESTART_LOG}.tmp" "$RESTART_LOG"
  fi
}

# ── Main logic ───────────────────────────────────────────────────────────────

# Check if process is running
RUNNING=false
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    RUNNING=true
  fi
fi

if ! $RUNNING; then
  log "Socket Mode listener is not running — restarting"
  start_socket_mode
  check_restart_rate
  exit 0
fi

# Process is running — check heartbeat
if [ -f "$HEARTBEAT_FILE" ]; then
  LAST_HEARTBEAT=$(cat "$HEARTBEAT_FILE")
  LAST_EPOCH=$(date -d "$LAST_HEARTBEAT" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE=$(( NOW_EPOCH - LAST_EPOCH ))

  if [ "$AGE" -gt 900 ]; then
    # No heartbeat in 15+ minutes — process may be hung
    log "Socket Mode listener appears hung (no heartbeat in ${AGE}s) — killing and restarting"
    kill "$PID" 2>/dev/null || true
    sleep 2
    kill -9 "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    start_socket_mode
    check_restart_rate
    exit 0
  fi
fi

# All good
log "Socket Mode listener healthy (PID $PID)"
