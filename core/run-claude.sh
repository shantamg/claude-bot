#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run-claude.sh — Agent executor for claude-bot framework
#
# Handles locking, resource gating + queueing, worktree creation, session
# support, active-agent coordination, provenance, rate-limit detection,
# and error reporting.
#
# Modes:
#   Command-slug mode (legacy, backward compatible):
#     run-claude.sh <COMMAND_SLUG> <PROMPT> [PROMPT_FILE] [MSG_TS]
#
#   Workspace mode:
#     run-claude.sh --workspace <name> <PROMPT> [PROMPT_FILE] [MSG_TS]
#     Claude runs inside the resolved workspace directory — its CLAUDE.md
#     handles routing.
#
#   Session-aware mode (add --session and/or --no-worktree to either mode):
#     run-claude.sh --workspace <name> --session <key> <PROMPT> ...
#     Uses --resume to continue a previous session, falling back to --session-id.
#     Session key is a human-readable string (e.g., "ws-milestone-builder-766")
#     that gets converted to a deterministic UUID v5.
# ---------------------------------------------------------------------------

# ── Load framework config ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
source "$LIB_DIR/parse-args.sh" "$@"

# ── Lock file ─────────────────────────────────────────────────────────────────
# Lock strategy: session > per-message > per-issue > per-command
# Include ISSUE_NUMBER in lock/log paths when set (dispatcher passes it as env var).
# Without this, all workspace dispatches to the same workspace (e.g., 8 issues routed
# to general-pr) collide on a single lockfile — only the first agent runs, the rest
# silently exit at the lock check below.
LOCK_SUFFIX="${ISSUE_NUMBER:+-issue-${ISSUE_NUMBER}}"
if [ -n "$SESSION_KEY" ]; then
  SAFE_KEY="${SESSION_KEY//[^a-zA-Z0-9_-]/_}"
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}-${SAFE_KEY}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}-${SAFE_KEY}.log"
elif [ -n "$MSG_TS" ]; then
  SAFE_TS="${MSG_TS//[^0-9.]/_}"
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}-${SAFE_TS}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}-${SAFE_TS}.log"
else
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}${LOCK_SUFFIX}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}${LOCK_SUFFIX}.log"
fi

# Lockfile — skip if already running
[ -f "$LOCKFILE" ] && exit 0
echo "$$" > "$LOCKFILE"

# Priority level — used when queuing (high > normal > low)
PRIORITY="${PRIORITY:-normal}"

# ── Rate limit gate (pre-invocation) ─────────────────────────────────────────
source "$LIB_DIR/rate-limit.sh"
rate_limit_gate

# ── Resource check gate ──────────────────────────────────────────────────────
if ! "$SCRIPT_DIR/check-resources.sh" > /dev/null 2>&1; then
  RESOURCE_MSG=$("$SCRIPT_DIR/check-resources.sh" 2>&1 || true)
  echo "[$(date)] QUEUED $COMMAND_SLUG — $RESOURCE_MSG" >> "$LOGFILE"

  # Write request to queue
  mkdir -p "$QUEUE_DIR"
  QUEUE_FILE="$QUEUE_DIR/queue-$(date +%s%N)-${COMMAND_SLUG}.json"
  jq -n \
    --arg command_slug "$COMMAND_SLUG" \
    --arg prompt "$PROMPT" \
    --arg prompt_file "$PROMPT_FILE" \
    --arg msg_ts "$MSG_TS" \
    --arg channel "${CHANNEL:-}" \
    --arg provenance_channel "${PROVENANCE_CHANNEL:-}" \
    --arg provenance_requester "${PROVENANCE_REQUESTER:-}" \
    --arg provenance_message "${PROVENANCE_MESSAGE:-}" \
    --arg slack_channel "${CHANNEL:-}" \
    --arg slack_ts "$MSG_TS" \
    --arg priority "$PRIORITY" \
    --arg queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{command_slug: $command_slug, prompt: $prompt, prompt_file: $prompt_file,
      msg_ts: $msg_ts, channel: $channel, provenance_channel: $provenance_channel,
      provenance_requester: $provenance_requester, provenance_message: $provenance_message,
      slack_channel: $slack_channel, slack_ts: $slack_ts, priority: $priority, queued_at: $queued_at}' \
    > "$QUEUE_FILE"

  # Swap emoji: remove :eyes:, add :hourglass_flowing_sand: to indicate queued state
  if [ -n "$MSG_TS" ] && [ -n "${CHANNEL:-}" ]; then
    curl -s -X POST https://slack.com/api/reactions.remove \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" '{channel: $ch, timestamp: $ts, name: "eyes"}')" > /dev/null 2>&1 || true
    curl -s -X POST https://slack.com/api/reactions.add \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" '{channel: $ch, timestamp: $ts, name: "hourglass_flowing_sand"}')" > /dev/null 2>&1 || true
  fi

  # ── Notify Slack + auto-remediate on disk failures ──────────────────────
  if [ -n "$MSG_TS" ] && [ -n "${CHANNEL:-}" ] && echo "$RESOURCE_MSG" | grep -q "disk"; then
    # Tell the user why the bot is paused
    DISK_PCT=$(echo "$RESOURCE_MSG" | grep -oP '\d+%' || echo "high")
    "$SCRIPT_DIR/slack-post.sh" --channel "$CHANNEL" --thread-ts "$MSG_TS" \
      --text "Paused — disk is ${DISK_PCT} full. Running automatic cleanup, will retry shortly." \
      2>/dev/null || true

    # Auto-remediate: run cache cleanup
    echo "[$(date)] Auto-remediating disk pressure..." >> "$LOGFILE"
    FREED=$("$SCRIPT_DIR/cleanup-caches.sh" 2>/dev/null || echo "0")
    echo "[$(date)] Cleanup freed ~${FREED}MB" >> "$LOGFILE"
  fi

  rm -f "$LOCKFILE"
  exit 0
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
WORKTREE_DIR=""
AGENT_HOME="${ACTIVE_DIR}/agent-$$"

source "$LIB_DIR/cleanup-agent.sh"
trap cleanup EXIT

echo "=== [$(date)] START $COMMAND_SLUG${MSG_TS:+ (msg: $MSG_TS)} ===" >> "$LOGFILE"
START_LINE=$(wc -l < "$LOGFILE")

# Identity: let Claude know it's running as the bot
export CLAUDE_BOT=1
export CLAUDE_BOT_PID=$$
# Backward compatibility aliases
export LOVELY_BOT="$CLAUDE_BOT"
export LOVELY_BOT_PID="$CLAUDE_BOT_PID"

# Touch initial heartbeat so activity tracking starts immediately.
# Also start a background updater that touches the heartbeat every 30 seconds
# while this process is alive. Without this, the heartbeat is only set at startup,
# and clear-stale-locks.sh thinks the agent is idle during long thinking phases
# (no tool calls = no log output = process looks stuck and gets killed).
mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || true
HEARTBEAT_FILE="$HEARTBEAT_DIR/heartbeat-$$.txt"
touch "$HEARTBEAT_FILE" 2>/dev/null || true
( while kill -0 $$ 2>/dev/null; do touch "$HEARTBEAT_FILE" 2>/dev/null; sleep 30; done ) &
HEARTBEAT_UPDATER_PID=$!

# ── Create agent directory and setup worktree ────────────────────────────────
source "$LIB_DIR/setup-agent.sh"
source "$LIB_DIR/setup-worktree.sh"

# ── Build active agents context from _active/ directory ──────────────────────
ACTIVE_CONTEXT=""
ACTIVE_ENTRIES=""
for AGENT_DIR in "$ACTIVE_DIR"/agent-*; do
  [ -d "$AGENT_DIR" ] || continue
  AGENT_BASENAME=$(basename "$AGENT_DIR")
  AGENT_PID="${AGENT_BASENAME#agent-}"

  # Skip our own entry
  [ "$AGENT_PID" = "$$" ] && continue

  # Skip if PID is not running (stale)
  if [[ "$AGENT_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$AGENT_PID" 2>/dev/null; then
    continue
  fi

  # Read metadata
  A_SUMMARY=$(jq -r '.commandSlug // "unknown"' "$AGENT_DIR/meta.json" 2>/dev/null || echo "unknown")
  A_STARTED=$(jq -r '.startedAt // "unknown"' "$AGENT_DIR/meta.json" 2>/dev/null || echo "unknown")
  A_CHANNEL=$(jq -r '.channel // empty' "$AGENT_DIR/meta.json" 2>/dev/null || echo "")
  A_META_WS=$(jq -r '.workspace // empty' "$AGENT_DIR/meta.json" 2>/dev/null || echo "")

  # Read route if available
  A_WORKSPACE=$(jq -r '.workspace // empty' "$AGENT_DIR/route.json" 2>/dev/null || echo "")
  A_STAGE=$(jq -r '.stage // empty' "$AGENT_DIR/route.json" 2>/dev/null || echo "")

  ROUTE_INFO=""
  if [ -n "$A_WORKSPACE" ]; then
    ROUTE_INFO=" → workspace=${A_WORKSPACE}"
    [ -n "$A_STAGE" ] && ROUTE_INFO="${ROUTE_INFO} stage=${A_STAGE}"
  fi

  ACTIVE_ENTRIES="${ACTIVE_ENTRIES}
AGENT: pid=$AGENT_PID summary=\"$A_SUMMARY\" started=$A_STARTED${A_CHANNEL:+ channel=$A_CHANNEL}${ROUTE_INFO}"
done

if [ -n "$ACTIVE_ENTRIES" ]; then
  ACTIVE_CONTEXT="

[ACTIVE WORK-IN-PROGRESS]
Other agents are currently working on the following tasks. Review each entry and decide:
- If your task is **related or overlapping** with an active entry: defer — reply in Slack acknowledging the request, use agent-message.sh to leave a message for the working agent, and exit.
- If your task is **unrelated** (different feature, different area of the codebase): proceed normally — you will run in parallel.
- To send a message to another agent: \`$SCRIPT_DIR/agent-message.sh --to-pid PID --message \"your message\"\`
$ACTIVE_ENTRIES
[END WIP]

"
fi

# ── Load persona context if specified ─────────────────────────────────────────
# When a label-registry entry has a "persona" field, the dispatcher exports it
# as PERSONA env var. Load the persona's WHOAMI.md to give the agent an identity.
PERSONA_CONTEXT=""
if [ -n "${PERSONA:-}" ]; then
  # Cascade: project personas first, then base-workspaces personas
  PERSONA_DIR=""
  if [ -d "${WORKSPACES_DIR:-}/_personas/$PERSONA" ]; then
    PERSONA_DIR="${WORKSPACES_DIR}/_personas/$PERSONA"
  elif [ -d "${BASE_WORKSPACES_DIR:-}/_personas/$PERSONA" ]; then
    PERSONA_DIR="${BASE_WORKSPACES_DIR}/_personas/$PERSONA"
  fi
  if [ -n "$PERSONA_DIR" ] && [ -f "$PERSONA_DIR/WHOAMI.md" ]; then
    PERSONA_CONTEXT="
[PERSONA]
$(cat "$PERSONA_DIR/WHOAMI.md")
[END PERSONA]
"
    echo "[$(date)] Loaded persona: $PERSONA from $PERSONA_DIR" >> "$LOGFILE"
  fi
fi

# ── Build provenance block ───────────────────────────────────────────────────
PROVENANCE_BLOCK=""
if [ -n "${PROVENANCE_REQUESTER:-}" ] || [ -n "${PROVENANCE_CHANNEL:-}" ]; then
  PROVENANCE_BLOCK="
[PROVENANCE]
The following provenance metadata was resolved programmatically at dispatch time. Use these EXACT values (do not paraphrase or re-derive) when writing Provenance sections in PRs or issues:
- Channel: ${PROVENANCE_CHANNEL:-unknown}
- Requester: ${PROVENANCE_REQUESTER:-unknown}
- Original message: ${PROVENANCE_MESSAGE:-(not available)}
[END PROVENANCE]
"
fi

# ── Invoke Claude ─────────────────────────────────────────────────────────────
source "$LIB_DIR/invoke-claude.sh"

# ── Rate limit detection (post-invocation) ───────────────────────────────────
rate_limit_detect

echo "=== [$(date)] END $COMMAND_SLUG${MSG_TS:+ (msg: $MSG_TS)} ===" >> "$LOGFILE"

# ── Error checking ────────────────────────────────────────────────────────────
TAIL=$(tail -n +"$START_LINE" "$LOGFILE")

# Catch generic "Error:" output from Claude CLI
ERROR_MSG=$(echo "$TAIL" | grep -i "^Error:" | head -5)
if [ -n "$ERROR_MSG" ] && [ -n "$BOT_OPS_CHANNEL_ID" ]; then
  curl -s -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg err "$ERROR_MSG" --arg bot "$BOT_NAME" \
      '{channel: $ch, text: ($bot + " error running `" + $slug + "`:\n```\n" + $err + "\n```")}')"
  echo "[$(date)] CLI ERROR on $COMMAND_SLUG: $ERROR_MSG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi

if echo "$TAIL" | grep -qiE "login|sign in|authenticate|expired|unauthorized|APIError.*401"; then
  if [ -n "$BOT_OPS_CHANNEL_ID" ]; then
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg bot "$BOT_NAME" \
        '{channel: $ch, text: ($bot + ": Claude auth failed running \u0027" + $slug + "\u0027. SSH in and run \u0027claude\u0027 to re-authenticate.")}')"
  fi
  echo "[$(date)] AUTH FAILURE on $COMMAND_SLUG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi

if echo "$TAIL" | grep -qiE "gh auth|token.*expired|Bad credentials"; then
  if [ -n "$BOT_OPS_CHANNEL_ID" ]; then
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg bot "$BOT_NAME" \
        '{channel: $ch, text: ($bot + ": GitHub token expired running \u0027" + $slug + "\u0027. SSH in and update GH_TOKEN.")}')"
  fi
  echo "[$(date)] GH_TOKEN FAILURE on $COMMAND_SLUG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi
