#!/bin/bash
# process-queue.sh — Process queued agent requests when system resources are available.
#
# Designed to run as a cron job every minute. Picks up the oldest queued request
# and dispatches it if resources are available.
#
# Queue directory: $QUEUE_DIR (from config.sh)
# Each queued request is a JSON file: queue-<timestamp>.json
# Fields: command_slug, prompt, prompt_file, msg_ts, channel,
#         provenance_channel, provenance_requester, provenance_message,
#         queued_at, slack_channel (for emoji), slack_ts (for emoji),
#         thread_ts (optional — thread parent ts for thread-aware ordering)

set -euo pipefail

# Load configuration (paths, thresholds, secrets)
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

LOGFILE="$BOT_LOG_DIR/process-queue.log"

# Nothing to do if queue directory doesn't exist or is empty
if [ ! -d "$QUEUE_DIR" ]; then
  exit 0
fi

# Get the highest-priority queued request.
# Priority order: high > normal > low, then FIFO within each level.
# Queue filenames include nanosecond timestamps, so sort gives FIFO.
# Uses jq to read priority from JSON (handles any formatting).
NEXT=""
for PRIO in high normal low; do
  for f in "$QUEUE_DIR"/queue-*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.priority // "normal"' "$f" 2>/dev/null)" = "$PRIO" ]; then
      NEXT="$f"
      break
    fi
  done
  [ -n "$NEXT" ] && break
done

# Fallback: if no files matched (empty queue or all lack priority), use plain FIFO
if [ -z "$NEXT" ]; then
  NEXT=$(find "$QUEUE_DIR" -name "queue-*.json" -type f 2>/dev/null | sort | head -1)
fi

if [ -z "$NEXT" ]; then
  exit 0
fi
OLDEST="$NEXT"

# Check resources before processing
if ! "$SCRIPTS_DIR/check-resources.sh" > /dev/null 2>&1; then
  echo "[$(date)] Resources still insufficient, keeping $(find "$QUEUE_DIR" -name "queue-*.json" -type f 2>/dev/null | wc -l) items queued" >> "$LOGFILE"
  exit 0
fi

# Parse the queued request
COMMAND_SLUG=$(jq -r '.command_slug // empty' "$OLDEST")
WORKSPACE=$(jq -r '.workspace // empty' "$OLDEST")
PROMPT=$(jq -r '.prompt // empty' "$OLDEST")
PROMPT_FILE=$(jq -r '.prompt_file // empty' "$OLDEST")
MSG_TS=$(jq -r '.msg_ts // empty' "$OLDEST")
CHANNEL=$(jq -r '.channel // empty' "$OLDEST")
PROVENANCE_CHANNEL=$(jq -r '.provenance_channel // empty' "$OLDEST")
PROVENANCE_REQUESTER=$(jq -r '.provenance_requester // empty' "$OLDEST")
PROVENANCE_MESSAGE=$(jq -r '.provenance_message // empty' "$OLDEST")
SLACK_CHANNEL=$(jq -r '.slack_channel // empty' "$OLDEST")
SLACK_TS=$(jq -r '.slack_ts // empty' "$OLDEST")
QUEUED_AT=$(jq -r '.queued_at // empty' "$OLDEST")
PRIORITY=$(jq -r '.priority // "normal"' "$OLDEST")
THREAD_TS=$(jq -r '.thread_ts // empty' "$OLDEST")
export PRIORITY

if [ -z "$COMMAND_SLUG" ]; then
  echo "[$(date)] Invalid queue entry (no command_slug), removing: $OLDEST" >> "$LOGFILE"
  rm -f "$OLDEST"
  exit 0
fi

# --- Cancellation check (#562) ---
# Before processing, verify the message hasn't been cancelled (deleted or ❌ reacted)
if [ -n "$SLACK_CHANNEL" ] && [ -n "$SLACK_TS" ]; then
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    # Check if the original message still exists
    MSG_CHECK=$(curl -s -X GET \
      "https://slack.com/api/conversations.history?channel=${SLACK_CHANNEL}&oldest=${SLACK_TS}&latest=${SLACK_TS}&inclusive=true&limit=1" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null || echo '{}')

    MSG_COUNT=$(echo "$MSG_CHECK" | jq -r '.messages | length // 0' 2>/dev/null || echo "0")

    if [ "$MSG_COUNT" = "0" ] || [ "$MSG_COUNT" = "null" ]; then
      echo "[$(date)] CANCELLED $COMMAND_SLUG — original message deleted (channel=$SLACK_CHANNEL ts=$SLACK_TS)" >> "$LOGFILE"
      rm -f "$OLDEST"
      exit 0
    fi

    # Check if the message has a ❌ (x) reaction — user wants to cancel
    REACTIONS=$(echo "$MSG_CHECK" | jq -r '.messages[0].reactions // []' 2>/dev/null)
    HAS_CANCEL=$(echo "$REACTIONS" | jq -r '[.[] | select(.name == "x")] | length' 2>/dev/null || echo "0")

    if [ "$HAS_CANCEL" != "0" ] && [ "$HAS_CANCEL" != "null" ]; then
      echo "[$(date)] CANCELLED $COMMAND_SLUG — ❌ reaction found (channel=$SLACK_CHANNEL ts=$SLACK_TS)" >> "$LOGFILE"
      # Remove the hourglass emoji to indicate cancellation
      curl -s -X POST https://slack.com/api/reactions.remove \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg ch "$SLACK_CHANNEL" --arg ts "$SLACK_TS" \
          '{channel: $ch, timestamp: $ts, name: "hourglass_flowing_sand"}')" > /dev/null 2>&1 || true
      rm -f "$OLDEST"
      exit 0
    fi
  fi
fi
# --- End cancellation check ---

# Remove the queue file BEFORE any dispatch/re-queue logic to prevent double-processing.
# The re-queue path below creates a NEW file if it needs to defer, so the original must go.
rm -f "$OLDEST"

# Thread-aware deferral: if this queued item belongs to a thread and an agent
# is already active on the same thread, re-queue it so it runs after the
# active agent finishes — prevents parallel work on the same conversation.
if [ -n "$THREAD_TS" ] && [ -n "$CHANNEL" ]; then
  THREAD_BUSY=false
  for agent_dir in "$ACTIVE_DIR"/agent-*; do
    [ -d "$agent_dir" ] || continue
    pid=$(basename "$agent_dir" | sed 's/^agent-//')
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      AGENT_CHANNEL=$(jq -r '.channel // empty' "$agent_dir/meta.json" 2>/dev/null || echo "")
      AGENT_MSG_TS=$(jq -r '.messageTs // empty' "$agent_dir/meta.json" 2>/dev/null || echo "")
      # An agent is working on this thread if it's on the same channel and
      # its message ts matches our thread_ts (parent message) or its own
      # thread context matches.
      if [ "$AGENT_CHANNEL" = "$CHANNEL" ] && [ "$AGENT_MSG_TS" = "$THREAD_TS" ]; then
        THREAD_BUSY=true
        break
      fi
    fi
  done

  if [ "$THREAD_BUSY" = "true" ]; then
    echo "[$(date)] Deferring $COMMAND_SLUG — thread $THREAD_TS in $CHANNEL has active agent" >> "$LOGFILE"
    REQUEUE_FILE="$QUEUE_DIR/queue-$(date +%s%N)-${COMMAND_SLUG}.json"
    jq -n \
      --arg command_slug "$COMMAND_SLUG" --arg prompt "$PROMPT" --arg prompt_file "$PROMPT_FILE" \
      --arg msg_ts "$MSG_TS" --arg channel "$CHANNEL" --arg provenance_channel "$PROVENANCE_CHANNEL" \
      --arg provenance_requester "$PROVENANCE_REQUESTER" --arg provenance_message "$PROVENANCE_MESSAGE" \
      --arg slack_channel "$SLACK_CHANNEL" --arg slack_ts "$SLACK_TS" \
      --arg priority "$PRIORITY" --arg queued_at "$QUEUED_AT" --arg thread_ts "$THREAD_TS" \
      '{command_slug: $command_slug, prompt: $prompt, prompt_file: $prompt_file,
        msg_ts: $msg_ts, channel: $channel, provenance_channel: $provenance_channel,
        provenance_requester: $provenance_requester, provenance_message: $provenance_message,
        slack_channel: $slack_channel, slack_ts: $slack_ts, priority: $priority,
        queued_at: $queued_at, thread_ts: $thread_ts}' \
      > "$REQUEUE_FILE"
    exit 0
  fi
fi

# Enforce slot reservation for low-priority items: scheduled jobs can only use
# (MAX_CONCURRENT - RESERVED_INTERACTIVE_SLOTS) slots, matching the dispatcher's limit.
if [ "$PRIORITY" = "low" ]; then
  SCHED_MAX=$((MAX_CONCURRENT - RESERVED_INTERACTIVE_SLOTS))

  # Count running agents
  RUNNING=0
  for agent_dir in "$ACTIVE_DIR"/agent-*; do
    [ -d "$agent_dir" ] || continue
    pid=$(basename "$agent_dir" | sed 's/^agent-//')
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      RUNNING=$((RUNNING + 1))
    fi
  done

  if [ "$RUNNING" -ge "$SCHED_MAX" ]; then
    echo "[$(date)] Deferring low-priority $COMMAND_SLUG — $RUNNING agents running (scheduled max $SCHED_MAX)" >> "$LOGFILE"
    # Re-queue with a fresh timestamp to retry next cycle
    REQUEUE_FILE="$QUEUE_DIR/queue-$(date +%s%N)-${COMMAND_SLUG}.json"
    jq -n \
      --arg command_slug "$COMMAND_SLUG" --arg prompt "$PROMPT" --arg prompt_file "$PROMPT_FILE" \
      --arg msg_ts "$MSG_TS" --arg channel "$CHANNEL" --arg provenance_channel "$PROVENANCE_CHANNEL" \
      --arg provenance_requester "$PROVENANCE_REQUESTER" --arg provenance_message "$PROVENANCE_MESSAGE" \
      --arg slack_channel "$SLACK_CHANNEL" --arg slack_ts "$SLACK_TS" \
      --arg priority "$PRIORITY" --arg queued_at "$QUEUED_AT" --arg thread_ts "$THREAD_TS" \
      '{command_slug: $command_slug, prompt: $prompt, prompt_file: $prompt_file,
        msg_ts: $msg_ts, channel: $channel, provenance_channel: $provenance_channel,
        provenance_requester: $provenance_requester, provenance_message: $provenance_message,
        slack_channel: $slack_channel, slack_ts: $slack_ts, priority: $priority,
        queued_at: $queued_at, thread_ts: $thread_ts}' \
      > "$REQUEUE_FILE"
    exit 0
  fi
fi

echo "[$(date)] Processing queued request: $COMMAND_SLUG (priority=$PRIORITY, queued at $QUEUED_AT)" >> "$LOGFILE"

# Remove clock emoji and add eyes emoji on Slack message if applicable
if [ -n "$SLACK_CHANNEL" ] && [ -n "$SLACK_TS" ]; then
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    # Remove hourglass_flowing_sand, add eyes
    curl -s -X POST https://slack.com/api/reactions.remove \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$SLACK_CHANNEL" --arg ts "$SLACK_TS" \
        '{channel: $ch, timestamp: $ts, name: "hourglass_flowing_sand"}')" > /dev/null 2>&1 || true
    curl -s -X POST https://slack.com/api/reactions.add \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$SLACK_CHANNEL" --arg ts "$SLACK_TS" \
        '{channel: $ch, timestamp: $ts, name: "eyes"}')" > /dev/null 2>&1 || true
  fi
fi

# Dispatch via run-claude.sh
export CHANNEL="${CHANNEL}"
export PROVENANCE_CHANNEL="${PROVENANCE_CHANNEL}"
export PROVENANCE_REQUESTER="${PROVENANCE_REQUESTER}"
export PROVENANCE_MESSAGE="${PROVENANCE_MESSAGE}"

# Dispatch via workspace mode if workspace field is set, otherwise command-slug mode
if [ -n "$WORKSPACE" ]; then
  nohup "$SCRIPTS_DIR/run-claude.sh" --workspace "$WORKSPACE" "$PROMPT" "$PROMPT_FILE" "$MSG_TS" \
    >> "$LOGFILE" 2>&1 &
else
  nohup "$SCRIPTS_DIR/run-claude.sh" "$COMMAND_SLUG" "$PROMPT" "$PROMPT_FILE" "$MSG_TS" \
    >> "$LOGFILE" 2>&1 &
fi

echo "[$(date)] Dispatched queued $COMMAND_SLUG (PID $!)" >> "$LOGFILE"

# Count remaining items
REMAINING=$(find "$QUEUE_DIR" -name "queue-*.json" -type f 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
  echo "[$(date)] $REMAINING items still in queue" >> "$LOGFILE"
fi
