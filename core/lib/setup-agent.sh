#!/bin/bash
# setup-agent.sh — Create _active/agent-$$ directory with meta.json and route.json.
# Sourced by run-claude.sh. Expects: WORKSPACE_NAME, COMMAND_SLUG, SESSION_KEY,
# MSG_TS, LOGFILE, ACTIVE_DIR, AGENT_HOME

mkdir -p "$AGENT_HOME/inbox/unread" "$AGENT_HOME/inbox/read"

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
  --arg issueNumber "${ISSUE_NUMBER:-}" \
  --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg logFile "$(basename "$LOGFILE")" \
  --arg sessionKey "$SESSION_KEY" \
  --arg sessionUuid "$SESSION_UUID" \
  '{pid: $pid, commandSlug: $commandSlug, workspace: $workspace, channel: $channel, messageTs: $messageTs, issueNumber: $issueNumber, startedAt: $startedAt, logFile: $logFile, sessionKey: $sessionKey, sessionUuid: $sessionUuid}' \
  > "$AGENT_HOME/meta.json"

# Initialize route.json — pre-populate with workspace name if in workspace mode
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
