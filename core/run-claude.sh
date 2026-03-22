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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

# Derive a deterministic UUID v5 from a human-readable session key.
# Same key always produces the same UUID across invocations.
session_key_to_uuid() {
  python3 -c "import uuid, sys; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))" "$1"
}

WORKSPACE_NAME=""
COMMAND_SLUG=""
SESSION_KEY=""
SKIP_WORKTREE=0

# Parse named flags (order-independent)
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --workspace)
      WORKSPACE_NAME="${2:?--workspace requires a workspace name}"
      WORKSPACE_NAME="${WORKSPACE_NAME//[^a-zA-Z0-9_-]/_}"
      COMMAND_SLUG="ws-${WORKSPACE_NAME}"
      shift 2
      ;;
    --session)
      SESSION_KEY="${2:?--session requires a session key}"
      shift 2
      ;;
    --no-worktree)
      SKIP_WORKTREE=1
      shift 1
      ;;
    *)
      break
      ;;
  esac
done

# Legacy positional: if no --workspace was found, first arg is COMMAND_SLUG
if [ -z "$COMMAND_SLUG" ]; then
  COMMAND_SLUG="${1//[^a-zA-Z0-9_-]/_}"
  shift 1
fi

PROMPT="${1:-}"
PROMPT_FILE="${2:-}"
MSG_TS="${3:-}"

# Lock strategy: session > per-message > per-command
if [ -n "$SESSION_KEY" ]; then
  # Per-session lock — same session key across ticks shares a lock
  SAFE_KEY="${SESSION_KEY//[^a-zA-Z0-9_-]/_}"
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}-${SAFE_KEY}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}-${SAFE_KEY}.log"
elif [ -n "$MSG_TS" ]; then
  # Per-message lock — allows parallel agents for different messages
  SAFE_TS="${MSG_TS//[^0-9.]/_}"
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}-${SAFE_TS}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}-${SAFE_TS}.log"
else
  # Global per-command lock — only one instance at a time
  LOCKFILE="${LOCK_PREFIX}-${COMMAND_SLUG}.lock"
  LOGFILE="$BOT_LOG_DIR/${COMMAND_SLUG}.log"
fi

# Lockfile — skip if already running
[ -f "$LOCKFILE" ] && exit 0
echo "$$" > "$LOCKFILE"

# Priority level — used when queuing (high > normal > low)
# Set by callers: check-github.sh / socket-listener.mjs set "high",
# workspace-dispatcher.sh sets "low" (scheduled) or "normal" (label-driven).
PRIORITY="${PRIORITY:-normal}"

# --- Resource check gate ---
# If memory > threshold or CPU load > threshold, queue the request instead of spawning
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
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" \
        '{channel: $ch, timestamp: $ts, name: "eyes"}')" > /dev/null 2>&1 || true
    curl -s -X POST https://slack.com/api/reactions.add \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" \
        '{channel: $ch, timestamp: $ts, name: "hourglass_flowing_sand"}')" > /dev/null 2>&1 || true
  fi

  # Remove the lockfile since we're not actually running
  rm -f "$LOCKFILE"
  exit 0
fi
# --- End resource check gate ---

# Worktree dir (set by pre-flight check if on main, empty otherwise)
WORKTREE_DIR=""

# Agent home directory in _active/
AGENT_HOME="${ACTIVE_DIR}/agent-$$"

# Clean up lock, _active/ agent dir, worktree, and temp prompt file
cleanup() {
  rm -f "$LOCKFILE"
  # Remove heartbeat file for this process
  rm -f "$HEARTBEAT_DIR/heartbeat-$$.txt" 2>/dev/null || true

  # ── _active/ agent directory cleanup ──
  if [ -d "$AGENT_HOME" ]; then
    # Check for unread messages that were never delivered
    UNREAD_DIR="$AGENT_HOME/inbox/unread"
    UNREAD_COUNT=0
    if [ -d "$UNREAD_DIR" ]; then
      UNREAD_COUNT=$(find "$UNREAD_DIR" -name "*.md" 2>/dev/null | wc -l)
    fi

    if [ "$UNREAD_COUNT" -gt 0 ]; then
      echo "[$(date)] WARNING: $UNREAD_COUNT unread message(s) in agent-$$ inbox at exit" >> "$LOGFILE"
      # Log unread messages so they are not silently lost
      for UNREAD_FILE in "$UNREAD_DIR"/*.md; do
        [ -f "$UNREAD_FILE" ] || continue
        echo "[$(date)] Unread message ($(basename "$UNREAD_FILE")):" >> "$LOGFILE"
        cat "$UNREAD_FILE" >> "$LOGFILE" 2>/dev/null || true
      done
    fi

    # Remove symlinks from workspace stage output/ directories that point to this agent
    if [ -f "$AGENT_HOME/route.json" ]; then
      ROUTE_WS=$(jq -r '.workspace // empty' "$AGENT_HOME/route.json" 2>/dev/null)
      ROUTE_STAGE=$(jq -r '.stage // empty' "$AGENT_HOME/route.json" 2>/dev/null)
      if [ -n "$ROUTE_WS" ] && [ -n "$ROUTE_STAGE" ]; then
        # Try project workspaces first, then base workspaces
        RESOLVED_WS_PATH=$(resolve_workspace "$ROUTE_WS" 2>/dev/null || echo "")
        if [ -n "$RESOLVED_WS_PATH" ]; then
          SYMLINK_PATH="${RESOLVED_WS_PATH}/stages/${ROUTE_STAGE}/output/agent-$$"
          rm -f "$SYMLINK_PATH" 2>/dev/null || true
        fi
      fi
    fi

    # Archive agent directory for debugging (keep briefly, cleaned by clear-stale-locks.sh)
    ARCHIVE_DIR="${ACTIVE_DIR}/_archived"
    mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true
    ARCHIVE_NAME="agent-$$-$(date +%Y%m%dT%H%M%S)"
    mv "$AGENT_HOME" "$ARCHIVE_DIR/$ARCHIVE_NAME" 2>/dev/null || rm -rf "$AGENT_HOME" 2>/dev/null || true
  fi

  # Clean up temp prompt files generated by socket-listener.mjs
  if [ -n "$PROMPT_FILE" ] && [[ "$PROMPT_FILE" == /tmp/${BOT_NAME}-prompt-* ]]; then
    rm -f "$PROMPT_FILE"
  fi
  # Clean up worktree if one was created
  if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
    cd "$PROJECT_CHECKOUT" 2>/dev/null || true
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== [$(date)] START $COMMAND_SLUG${MSG_TS:+ (msg: $MSG_TS)} ===" >> "$LOGFILE"
START_LINE=$(wc -l < "$LOGFILE")

# Identity: let Claude know it's running as the bot
export CLAUDE_BOT=1
export CLAUDE_BOT_PID=$$
# Backward compatibility aliases
export LOVELY_BOT="$CLAUDE_BOT"
export LOVELY_BOT_PID="$CLAUDE_BOT_PID"

# Touch initial heartbeat so activity tracking starts immediately
mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || true
touch "$HEARTBEAT_DIR/heartbeat-$$.txt" 2>/dev/null || true

# ── Create _active/ agent directory (Phase 1: PID-based home) ──
mkdir -p "$AGENT_HOME/inbox/unread" "$AGENT_HOME/inbox/read"

# Write meta.json with job metadata
# Derive session UUID if session key was provided
SESSION_UUID=""
if [ -n "$SESSION_KEY" ]; then
  SESSION_UUID=$(session_key_to_uuid "$SESSION_KEY")
  echo "[$(date)] Session: key=$SESSION_KEY uuid=$SESSION_UUID" >> "$LOGFILE"
fi

jq -n \
  --argjson pid "$$" \
  --arg commandSlug "$COMMAND_SLUG" \
  --arg workspace "$WORKSPACE_NAME" \
  --arg channel "${CHANNEL:-}" \
  --arg messageTs "$MSG_TS" \
  --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg logFile "$(basename "$LOGFILE")" \
  --arg sessionKey "$SESSION_KEY" \
  --arg sessionUuid "$SESSION_UUID" \
  '{pid: $pid, commandSlug: $commandSlug, workspace: $workspace, channel: $channel, messageTs: $messageTs, startedAt: $startedAt, logFile: $logFile, sessionKey: $sessionKey, sessionUuid: $sessionUuid}' \
  > "$AGENT_HOME/meta.json"

# Initialize route.json — in workspace mode, pre-populate with the workspace name
# (the PostToolUse hook will refine with the specific stage when the agent reads a CONTEXT.md)
if [ -n "$WORKSPACE_NAME" ]; then
  jq -n --arg workspace "$WORKSPACE_NAME" '{workspace: $workspace}' > "$AGENT_HOME/route.json"
else
  echo '{}' > "$AGENT_HOME/route.json"
fi

# Export agent home path so the PostToolUse hook can find it
export CLAUDE_BOT_AGENT_HOME="$AGENT_HOME"
export CLAUDE_BOT_WORKSPACES="$WORKSPACES_DIR"
# Backward compatibility aliases
export LOVELY_BOT_AGENT_HOME="$CLAUDE_BOT_AGENT_HOME"

echo "[$(date)] Created _active/agent-$$ directory" >> "$LOGFILE"

# ── Build active agents context from _active/ directory ──
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

# Pre-flight: if on main, auto-create a worktree so agents never work on main directly.
# main gets `git pull` every minute on EC2 — direct edits would be clobbered.
cd "$PROJECT_DIR"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
# Session-aware invocations need a stable directory for --resume to work
# (sessions are tied to the project path — different worktree = different project).
if [ -n "$SESSION_KEY" ]; then
  SKIP_WORKTREE=1
fi

if [ "$SKIP_WORKTREE" -ne 1 ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  WORKTREE_BRANCH="feat/${COMMAND_SLUG}-$(date +%Y%m%d-%H%M%S)"
  WORKTREE_DIR="/tmp/${BOT_NAME}-worktree-${COMMAND_SLUG}-$$"
  echo "[$(date)] On $DEFAULT_BRANCH — creating worktree at $WORKTREE_DIR on branch $WORKTREE_BRANCH" >> "$LOGFILE"
  cd "$PROJECT_CHECKOUT"
  git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" 2>> "$LOGFILE"
  # Navigate into the project path within the worktree
  if [ -n "$PROJECT_PATH" ]; then
    cd "$WORKTREE_DIR/$PROJECT_PATH"
  else
    cd "$WORKTREE_DIR"
  fi
fi

# ── Workspace mode: cd into the resolved workspace directory ──
# The workspace CLAUDE.md (L1) provides routing context. Claude's native auto-loading
# reads it automatically when the cwd is inside the workspace.
WORKSPACE_DIR=""
if [ -n "$WORKSPACE_NAME" ]; then
  # Use cascade resolution: project workspaces first, then base-workspaces
  RESOLVED_WS=$(resolve_workspace "$WORKSPACE_NAME" 2>/dev/null || echo "")

  # If in a worktree, check workspace relative to the worktree project dir too
  if [ -z "$RESOLVED_WS" ] && [ -n "$WORKTREE_DIR" ]; then
    WORKTREE_PROJECT_DIR="$WORKTREE_DIR${PROJECT_PATH:+/$PROJECT_PATH}"
    WORKTREE_WS_DIR="$WORKTREE_PROJECT_DIR/bot/workspaces/$WORKSPACE_NAME"
    if [ -d "$WORKTREE_WS_DIR" ]; then
      RESOLVED_WS="$WORKTREE_WS_DIR"
    fi
  fi

  if [ -n "$RESOLVED_WS" ] && [ -d "$RESOLVED_WS" ]; then
    WORKSPACE_DIR="$RESOLVED_WS"
    cd "$WORKSPACE_DIR"
    echo "[$(date)] Workspace mode: cd into $WORKSPACE_DIR" >> "$LOGFILE"
  else
    echo "[$(date)] ERROR: Workspace directory not found: $WORKSPACE_NAME (checked project and base workspaces)" >> "$LOGFILE"
    exit 1
  fi
fi

# Build provenance block from env vars (set by socket-listener.mjs)
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

# Stream output to log file AND _active/ stream.log in real-time via stream-json
STREAM_LOG="$AGENT_HOME/stream.log"

# Build input from prompt file or inline prompt
if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  CLAUDE_INPUT=$({ echo "$ACTIVE_CONTEXT"; echo "$PROVENANCE_BLOCK"; cat "$PROMPT_FILE"; })
else
  CLAUDE_INPUT="${ACTIVE_CONTEXT}${PROVENANCE_BLOCK}${PROMPT}"
fi

# Base claude args (always used)
CLAUDE_BASE_ARGS="--dangerously-skip-permissions -p - --output-format stream-json --verbose"

# jq filter for extracting text from stream-json
JQ_FILTER='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty'

if [ -n "$SESSION_UUID" ]; then
  # Check if session file exists on disk to decide --resume vs --session-id
  if find ~/.claude/projects/ -name "${SESSION_UUID}.jsonl" 2>/dev/null | grep -q .; then
    echo "[$(date)] Resuming session: $SESSION_UUID" >> "$LOGFILE"
    echo "$CLAUDE_INPUT" | claude --resume "$SESSION_UUID" $CLAUDE_BASE_ARGS 2>> "$LOGFILE" \
      | jq -r --unbuffered "$JQ_FILTER" \
      | tee -a "$STREAM_LOG" >> "$LOGFILE" || true
  else
    echo "[$(date)] New session: $SESSION_UUID" >> "$LOGFILE"
    echo "$CLAUDE_INPUT" | claude --session-id "$SESSION_UUID" $CLAUDE_BASE_ARGS 2>> "$LOGFILE" \
      | jq -r --unbuffered "$JQ_FILTER" \
      | tee -a "$STREAM_LOG" >> "$LOGFILE" || true
  fi
else
  # Standard stateless invocation (current behavior)
  echo "$CLAUDE_INPUT" | claude $CLAUDE_BASE_ARGS 2>> "$LOGFILE" \
    | jq -r --unbuffered "$JQ_FILTER" \
    | tee -a "$STREAM_LOG" \
    >> "$LOGFILE" || true
fi

echo "" >> "$LOGFILE"

# Clear rate limit flag on successful output (limit has reset)
if [ -s "$STREAM_LOG" ] && ! grep -qi "hit your limit\|rate limit" "$STREAM_LOG" 2>/dev/null; then
  rm -f "${LOCK_PREFIX}-rate-limited.flag" 2>/dev/null || true
fi

# ── Rate limit detection ──
# Check if Claude hit the API usage limit (stream.log will contain the error text)
if grep -qi "hit your limit\|rate limit\|resets.*UTC" "$STREAM_LOG" 2>/dev/null; then
  echo "[$(date)] RATE LIMITED — Claude API limit reached" >> "$LOGFILE"
  # Add sleeping emoji on the Slack message if we have one
  if [ -n "$MSG_TS" ] && [ -n "${CHANNEL:-}" ]; then
    curl -s -X POST https://slack.com/api/reactions.remove \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" \
        '{channel: $ch, timestamp: $ts, name: "white_check_mark"}')" > /dev/null 2>&1 || true
    curl -s -X POST https://slack.com/api/reactions.add \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" \
        '{channel: $ch, timestamp: $ts, name: "zzz"}')" > /dev/null 2>&1 || true
  fi
  # Post to bot-ops channel (one-time, not per-message — use a throttle file)
  RATE_LIMIT_FLAG="${LOCK_PREFIX}-rate-limited.flag"
  if [ ! -f "$RATE_LIMIT_FLAG" ]; then
    touch "$RATE_LIMIT_FLAG"
    if [ -n "$BOT_OPS_CHANNEL_ID" ]; then
      curl -s -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" \
          --arg text "Claude API limit reached. Bot is sleeping until the next reset. Queued work will resume automatically." \
          '{channel: $ch, text: $text}')" > /dev/null 2>&1 || true
    fi
  fi
fi

# ── Supplementary messages (legacy, replaced by --session/--resume) ──
# Previously, follow-up messages were written to inbox/unread/ and processed
# here as a second stateless Claude invocation. With --session continuity,
# thread replies and multi-pass workspace ticks use --resume instead, which
# gives the agent full context from prior interactions automatically.
#
# The inbox/unread directory and agent-message.sh still exist for agent-to-agent
# coordination (parallel agents on related work), but the re-invocation loop
# has been removed. Any unread messages at exit are logged as warnings in cleanup().

echo "=== [$(date)] END $COMMAND_SLUG${MSG_TS:+ (msg: $MSG_TS)} ===" >> "$LOGFILE"

# Check only THIS run's output for errors
TAIL=$(tail -n +"$START_LINE" "$LOGFILE")

# Catch generic "Error:" output from Claude CLI
ERROR_MSG=$(echo "$TAIL" | grep -i "^Error:" | head -5)
if [ -n "$ERROR_MSG" ] && [ -n "$BOT_OPS_CHANNEL_ID" ]; then
  curl -s -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg err "$ERROR_MSG" --arg bot "$BOT_NAME" \
      '{channel: $ch, text: ($bot + " error running `" + $slug + "`:\n```\n" + $err + "\n```")}')"
  echo "[$(date)] CLI ERROR on $COMMAND_SLUG: $ERROR_MSG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi

if echo "$TAIL" | grep -qiE "login|sign in|authenticate|expired|unauthorized|APIError.*401"; then
  if [ -n "$BOT_OPS_CHANNEL_ID" ]; then
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg bot "$BOT_NAME" \
        '{channel: $ch, text: ($bot + ": Claude auth failed running \u0027" + $slug + "\u0027. SSH in and run \u0027claude\u0027 to re-authenticate.")}')"
  fi
  echo "[$(date)] AUTH FAILURE on $COMMAND_SLUG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi

if echo "$TAIL" | grep -qiE "gh auth|token.*expired|Bad credentials"; then
  if [ -n "$BOT_OPS_CHANNEL_ID" ]; then
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$BOT_OPS_CHANNEL_ID" --arg slug "$COMMAND_SLUG" --arg bot "$BOT_NAME" \
        '{channel: $ch, text: ($bot + ": GitHub token expired running \u0027" + $slug + "\u0027. SSH in and update GH_TOKEN.")}')"
  fi
  echo "[$(date)] GH_TOKEN FAILURE on $COMMAND_SLUG" >> "$BOT_LOG_DIR/auth-failures.log"
  exit 1
fi
