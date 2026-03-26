#!/bin/bash
# invoke-claude.sh — Build input and run Claude with session-aware invocation.
# Sourced by run-claude.sh. Expects: PROMPT, PROMPT_FILE, PROVENANCE_BLOCK,
# ACTIVE_CONTEXT, AGENT_HOME, SESSION_UUID, LOGFILE

# Stream output to log file AND _active/ stream.log in real-time
STREAM_LOG="$AGENT_HOME/stream.log"
RAW_STREAM="$AGENT_HOME/raw-stream.jsonl"

# Build input from prompt file or inline prompt
if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  CLAUDE_INPUT=$({ echo "$ACTIVE_CONTEXT"; echo "${PERSONA_CONTEXT:-}"; echo "$PROVENANCE_BLOCK"; cat "$PROMPT_FILE"; })
else
  CLAUDE_INPUT="${ACTIVE_CONTEXT}${PERSONA_CONTEXT:-}${PROVENANCE_BLOCK}${PROMPT}"
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
      | tee -a "$RAW_STREAM" \
      | jq -r --unbuffered "$JQ_FILTER" \
      | tee -a "$STREAM_LOG" >> "$LOGFILE" || true
  else
    echo "[$(date)] New session: $SESSION_UUID" >> "$LOGFILE"
    echo "$CLAUDE_INPUT" | claude --session-id "$SESSION_UUID" $CLAUDE_BASE_ARGS 2>> "$LOGFILE" \
      | tee -a "$RAW_STREAM" \
      | jq -r --unbuffered "$JQ_FILTER" \
      | tee -a "$STREAM_LOG" >> "$LOGFILE" || true
  fi
else
  # Standard stateless invocation
  echo "$CLAUDE_INPUT" | claude $CLAUDE_BASE_ARGS 2>> "$LOGFILE" \
    | tee -a "$RAW_STREAM" \
    | jq -r --unbuffered "$JQ_FILTER" \
    | tee -a "$STREAM_LOG" \
    >> "$LOGFILE" || true
fi

echo "" >> "$LOGFILE"
