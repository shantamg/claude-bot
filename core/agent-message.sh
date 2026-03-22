#!/bin/bash
# Send a message to one or more active agents via their _active/ inbox
#
# Usage:
#   agent-message.sh --to-pid PID --message "..."        # Message a specific agent
#   agent-message.sh --to-workspace NAME --message "..."  # Message any agent in a workspace
#   agent-message.sh --broadcast --message "..."           # Message all active agents
#
# Messages are written as .md files to the target agent's inbox/unread/ directory.
# The PostToolUse hook (check-pending-messages.sh) picks them up on the next tool call
# and injects them as additionalContext into the running Claude session.
#
# Options:
#   --to-pid PID           Target a specific agent by process ID
#   --to-workspace NAME    Target agent(s) routed to a specific workspace
#   --broadcast            Send to all active agents
#   --message TEXT          The message content (required)
#   --from TEXT             Optional sender identifier (default: "system")
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# Parse arguments
TARGET_PID=""
TARGET_WORKSPACE=""
BROADCAST=0
MESSAGE=""
FROM="system"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-pid)       TARGET_PID="$2"; shift 2 ;;
    --to-workspace) TARGET_WORKSPACE="$2"; shift 2 ;;
    --broadcast)    BROADCAST=1; shift ;;
    --message)      MESSAGE="$2"; shift 2 ;;
    --from)         FROM="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$MESSAGE" ]; then
  echo "Usage: agent-message.sh (--to-pid PID | --to-workspace NAME | --broadcast) --message \"text\" [--from SENDER]" >&2
  exit 2
fi

if [ -z "$TARGET_PID" ] && [ -z "$TARGET_WORKSPACE" ] && [ "$BROADCAST" -eq 0 ]; then
  echo "Must specify --to-pid, --to-workspace, or --broadcast" >&2
  exit 2
fi

if [ ! -d "$ACTIVE_DIR" ]; then
  echo "No _active/ directory found at $ACTIVE_DIR" >&2
  exit 1
fi

# Generate a unique message filename
MSG_TIMESTAMP=$(date +%s%N 2>/dev/null || date +%s)
MSG_FILENAME="msg-${MSG_TIMESTAMP}.md"

# Build the message content with metadata header
MSG_CONTENT="[Message from ${FROM} at $(date -u +%Y-%m-%dT%H:%M:%SZ)]

${MESSAGE}"

# Deliver to target agent(s)
DELIVERED=0

deliver_message() {
  local AGENT_DIR="$1"
  local INBOX="$AGENT_DIR/inbox/unread"

  if [ ! -d "$INBOX" ]; then
    mkdir -p "$INBOX" 2>/dev/null || return 1
  fi

  echo "$MSG_CONTENT" > "$INBOX/$MSG_FILENAME"
  DELIVERED=$((DELIVERED + 1))
  echo "Delivered message to $(basename "$AGENT_DIR")"
}

if [ -n "$TARGET_PID" ]; then
  # ── Send to a specific agent by PID ──
  AGENT_DIR="$ACTIVE_DIR/agent-${TARGET_PID}"
  if [ ! -d "$AGENT_DIR" ]; then
    echo "No active agent with PID $TARGET_PID (directory $AGENT_DIR not found)" >&2
    exit 1
  fi
  deliver_message "$AGENT_DIR"

elif [ -n "$TARGET_WORKSPACE" ]; then
  # ── Send to agent(s) routed to a specific workspace ──
  for AGENT_DIR in "$ACTIVE_DIR"/agent-*; do
    [ -d "$AGENT_DIR" ] || continue
    # Skip archived
    [ "$(basename "$AGENT_DIR")" = "_archived" ] && continue

    ROUTE_WS=$(jq -r '.workspace // empty' "$AGENT_DIR/route.json" 2>/dev/null || true)
    if [ "$ROUTE_WS" = "$TARGET_WORKSPACE" ]; then
      # Verify PID is still running
      AGENT_PID="${AGENT_DIR##*agent-}"
      if [[ "$AGENT_PID" =~ ^[0-9]+$ ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
        deliver_message "$AGENT_DIR"
      fi
    fi
  done

  if [ "$DELIVERED" -eq 0 ]; then
    echo "Warning: no active agents found in workspace '$TARGET_WORKSPACE'" >&2
    exit 0
  fi

elif [ "$BROADCAST" -eq 1 ]; then
  # ── Broadcast to all active agents ──
  for AGENT_DIR in "$ACTIVE_DIR"/agent-*; do
    [ -d "$AGENT_DIR" ] || continue
    # Skip archived
    [ "$(basename "$AGENT_DIR")" = "_archived" ] && continue

    # Verify PID is still running
    AGENT_PID="${AGENT_DIR##*agent-}"
    if [[ "$AGENT_PID" =~ ^[0-9]+$ ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
      deliver_message "$AGENT_DIR"
    fi
  done

  if [ "$DELIVERED" -eq 0 ]; then
    echo "Warning: no active agents found to broadcast to" >&2
    exit 0
  fi
fi

echo "Delivered $DELIVERED message(s)"
