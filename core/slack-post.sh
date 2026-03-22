#!/bin/bash
# slack-post.sh — Post a message to Slack via the Slack API
# Uses jq for proper JSON encoding, which handles newlines correctly.
#
# Usage:
#   slack-post.sh --channel CHANNEL_ID --text "message text"
#   slack-post.sh --channel CHANNEL_ID --text "message text" --thread-ts 1234567890.123456
#
# Environment:
#   SLACK_BOT_TOKEN — Slack bot token (sourced from $BOT_HOME/.env if not set)

set -euo pipefail

# Configurable base directory with backward compat
BOT_HOME="${CLAUDE_BOT_HOME:-${LOVELY_BOT_DIR:-/opt/claude-bot}}"

# Source env if SLACK_BOT_TOKEN is not already set
if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  if [ -f "$BOT_HOME/.env" ]; then
    source "$BOT_HOME/.env"
  else
    echo "Error: SLACK_BOT_TOKEN not set and $BOT_HOME/.env not found" >&2
    exit 1
  fi
fi

if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  echo "Error: SLACK_BOT_TOKEN is not set" >&2
  exit 1
fi

# Parse arguments
CHANNEL=""
TEXT=""
THREAD_TS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="$2"
      shift 2
      ;;
    --text)
      TEXT="$2"
      shift 2
      ;;
    --thread-ts)
      THREAD_TS="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      echo "Usage: slack-post.sh --channel CHANNEL_ID --text \"message\" [--thread-ts TS]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$CHANNEL" ]; then
  echo "Error: --channel is required" >&2
  exit 1
fi

if [ -z "$TEXT" ]; then
  echo "Error: --text is required" >&2
  exit 1
fi

# Build JSON payload using jq (handles newlines and special characters correctly)
if [ -n "$THREAD_TS" ]; then
  PAYLOAD=$(jq -n --arg ch "$CHANNEL" --arg text "$TEXT" --arg ts "$THREAD_TS" \
    '{channel: $ch, text: $text, thread_ts: $ts}')
else
  PAYLOAD=$(jq -n --arg ch "$CHANNEL" --arg text "$TEXT" \
    '{channel: $ch, text: $text}')
fi

# Post to Slack
RESPONSE=$(curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

# Check response
OK=$(echo "$RESPONSE" | jq -r '.ok')
if [ "$OK" != "true" ]; then
  ERROR=$(echo "$RESPONSE" | jq -r '.error // "unknown error"')
  echo "Error: Slack API returned: $ERROR" >&2
  exit 1
fi

# Output the message timestamp (useful for thread replies)
echo "$RESPONSE" | jq -r '.ts'
