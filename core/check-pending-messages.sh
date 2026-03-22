#!/bin/bash
# PostToolUse hook: route detection + mid-stream message injection
#
# This hook runs after every tool call during a Claude session. It:
# 1. Detects workspace/stage routing from file_path in tool_input
# 2. Checks the _active/ inbox for messages from other agents
#
# Route detection: when the agent reads a CONTEXT.md inside a workspace stage,
# the hook auto-detects the workspace and stage, writes route.json, and creates
# a symlink from the stage's output/ directory to the agent home.
#
# The hook has zero impact when no routing or messages are pending — it checks
# the filesystem and exits cleanly with no output.
#
# NOTE: This script runs as a PostToolUse hook — it does NOT source config.sh.
# It relies on env vars exported by run-claude.sh.
#
# Environment:
#   CLAUDE_BOT_PID        — PID of the parent run-claude.sh process (required)
#   CLAUDE_BOT            — Set to "1" when running as the bot (used as guard)
#   CLAUDE_BOT_AGENT_HOME — Path to _active/agent-{PID}/ directory
#   CLAUDE_BOT_WORKSPACES — Path to the project workspaces directory
#   HEARTBEAT_DIR         — Path to heartbeat state directory

# Only run when invoked as the bot (skip interactive Claude sessions)
# Backward compat: accept LOVELY_BOT if CLAUDE_BOT is not set
[ "${CLAUDE_BOT:-${LOVELY_BOT:-}}" = "1" ] || exit 0

# Need the parent PID to find the right directories
# Backward compat: accept LOVELY_BOT_PID if CLAUDE_BOT_PID is not set
BOT_PID="${CLAUDE_BOT_PID:-${LOVELY_BOT_PID:-}}"
[ -n "$BOT_PID" ] || exit 0

# Touch heartbeat file — signals to clear-stale-locks.sh that this process is active
HEARTBEAT_DIR="${HEARTBEAT_DIR:-/opt/claude-bot/state/heartbeats}"
mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || true
touch "$HEARTBEAT_DIR/heartbeat-${BOT_PID}.txt" 2>/dev/null || true

# ── Read tool call JSON from stdin ──
# PostToolUse hook receives: {"tool_name": "...", "tool_input": {...}, "session_id": "..."}
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
fi

# ── Phase 2: Auto-detect workspace/stage from file_path ──
# Backward compat: accept LOVELY_BOT_AGENT_HOME if CLAUDE_BOT_AGENT_HOME is not set
AGENT_HOME="${CLAUDE_BOT_AGENT_HOME:-${LOVELY_BOT_AGENT_HOME:-}}"
BOT_WORKSPACES="${CLAUDE_BOT_WORKSPACES:-${WORKSPACES_DIR:-}}"

if [ -n "$HOOK_INPUT" ] && [ -n "$AGENT_HOME" ] && [ -d "$AGENT_HOME" ]; then
  TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
  FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

  # Route detection: match file_path against workspaces/*/stages/*/CONTEXT.md
  if [ -n "$FILE_PATH" ] && [ -n "$BOT_WORKSPACES" ]; then
    # Extract the workspaces directory basename for pattern matching
    WS_DIRNAME=$(basename "$BOT_WORKSPACES")

    # Normalize: handle both absolute and relative paths
    # Pattern: .../{workspaces_dir}/{workspace}/stages/{stage}/CONTEXT.md
    if [[ "$FILE_PATH" =~ ${WS_DIRNAME}/([^/]+)/stages/([^/]+)/CONTEXT\.md$ ]]; then
      DETECTED_WS="${BASH_REMATCH[1]}"
      DETECTED_STAGE="${BASH_REMATCH[2]}"

      # Skip _active/, shared/, and other non-workspace directories
      if [ "$DETECTED_WS" != "_active" ] && [ "$DETECTED_WS" != "shared" ]; then
        # Read current route to check if it changed
        CURRENT_WS=$(jq -r '.workspace // empty' "$AGENT_HOME/route.json" 2>/dev/null || true)
        CURRENT_STAGE=$(jq -r '.stage // empty' "$AGENT_HOME/route.json" 2>/dev/null || true)

        if [ "$DETECTED_WS" != "$CURRENT_WS" ] || [ "$DETECTED_STAGE" != "$CURRENT_STAGE" ]; then
          # Remove old symlink if agent moved to a different stage
          if [ -n "$CURRENT_WS" ] && [ -n "$CURRENT_STAGE" ]; then
            OLD_SYMLINK="${BOT_WORKSPACES}/${CURRENT_WS}/stages/${CURRENT_STAGE}/output/agent-${BOT_PID}"
            rm -f "$OLD_SYMLINK" 2>/dev/null || true
          fi

          # Write/update route.json
          jq -n \
            --arg workspace "$DETECTED_WS" \
            --arg stage "$DETECTED_STAGE" \
            --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{workspace: $workspace, stage: $stage, detectedAt: $detectedAt}' \
            > "$AGENT_HOME/route.json"

          # Create symlink from stage output/ to agent home
          OUTPUT_DIR="${BOT_WORKSPACES}/${DETECTED_WS}/stages/${DETECTED_STAGE}/output"
          mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
          # Use relative symlink so it works across mounts
          ln -snf "../../../_active/agent-${BOT_PID}" "$OUTPUT_DIR/agent-${BOT_PID}" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

# ── Check _active/ inbox for messages ──
MESSAGES=""
COUNT=0

if [ -n "$AGENT_HOME" ] && [ -d "$AGENT_HOME/inbox/unread" ]; then
  for MSG_FILE in "$AGENT_HOME/inbox/unread"/*.md; do
    [ -f "$MSG_FILE" ] || continue

    MSG_TEXT=$(cat "$MSG_FILE" 2>/dev/null) || continue

    if [ -n "$MSG_TEXT" ]; then
      if [ -n "$MESSAGES" ]; then
        MESSAGES="${MESSAGES}

---
"
      fi
      MESSAGES="${MESSAGES}${MSG_TEXT}"
      COUNT=$((COUNT + 1))
    fi

    # Move to read/ so it's not re-injected
    mv "$MSG_FILE" "$AGENT_HOME/inbox/read/" 2>/dev/null || true
  done
fi

# Nothing collected
[ "$COUNT" -gt 0 ] || exit 0

# Inject into the running session via additionalContext
CONTEXT="⚡ MID-STREAM MESSAGE (${COUNT} new message(s) arrived while you're working):

${MESSAGES}

Handle this now if it's urgent or related to your current work. If it's a redirect (\"stop, do this instead\"), pivot immediately. If it's a minor follow-up, acknowledge it and continue your current task — you can address it when you finish."

# Output JSON for Claude Code hooks additionalContext
jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
