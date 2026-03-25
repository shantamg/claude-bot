#!/bin/bash
# rate-limit.sh — Rate limit gate (pre-invocation) and detection (post-invocation).
# Sourced by run-claude.sh. Expects: COMMAND_SLUG, LOCKFILE, LOGFILE,
# QUEUE_DIR, ACTIVE_DIR, LOCK_PREFIX, BOT_OPS_CHANNEL_ID, SLACK_BOT_TOKEN, BOT_NAME

RATE_LIMIT_FLAG="${LOCK_PREFIX}-rate-limited.flag"
RATE_LIMIT_INVESTIGATE_PENDING="${LOCK_PREFIX}-rate-limit-investigate.pending"

# rate_limit_gate — Check if rate limited. Returns 1 (skip) or 0 (proceed).
rate_limit_gate() {
  [ -f "$RATE_LIMIT_FLAG" ] || return 0

  local rl_resets_at rl_now rl_remaining rl_remaining_min
  rl_resets_at=$(cat "$RATE_LIMIT_FLAG" 2>/dev/null || echo "0")
  rl_now=$(date +%s)

  if [ "$rl_now" -lt "$rl_resets_at" ]; then
    rl_remaining=$(( rl_resets_at - rl_now ))
    rl_remaining_min=$(( rl_remaining / 60 ))
    echo "[$(date)] RATE LIMIT GATE — skipping $COMMAND_SLUG (resets in ${rl_remaining_min}m ${rl_remaining}s)" >> "$LOGFILE"
    rm -f "$LOCKFILE"
    exit 0
  fi

  # Rate limit has reset — but investigation may still be pending
  if [ -f "$RATE_LIMIT_INVESTIGATE_PENDING" ]; then
    if [ "$COMMAND_SLUG" = "rate-limit-investigate" ]; then
      echo "[$(date)] Rate limit reset — running investigation" >> "$LOGFILE"
      rm -f "$RATE_LIMIT_FLAG" "$RATE_LIMIT_INVESTIGATE_PENDING" "${LOCK_PREFIX}-rate-limit-snapshot.txt" 2>/dev/null || true
    else
      echo "[$(date)] RATE LIMIT GATE — skipping $COMMAND_SLUG (investigation pending)" >> "$LOGFILE"
      rm -f "$LOCKFILE"
      exit 0
    fi
  else
    echo "[$(date)] Rate limit reset — clearing flag, resuming operations" >> "$LOGFILE"
    rm -f "$RATE_LIMIT_FLAG" "${LOCK_PREFIX}-rate-limit-snapshot.txt" 2>/dev/null || true
  fi
}

# rate_limit_detect — Parse raw stream for rate_limit_event, set flag + notify.
# Expects: AGENT_HOME, MSG_TS, CHANNEL, ACTIVE_DIR, QUEUE_DIR,
#          SLACK_BOT_TOKEN, BOT_OPS_CHANNEL_ID, BOT_NAME
rate_limit_detect() {
  local raw_stream="$AGENT_HOME/raw-stream.jsonl"
  local rl_event rl_detected=false rl_resets_at=""

  [ -f "$raw_stream" ] || return 0

  rl_event=$(grep '"type":"rate_limit_event"' "$raw_stream" 2>/dev/null \
    | jq -r 'select(.rate_limit_info.status != "allowed") | .rate_limit_info | "\(.status) \(.resetsAt // "")"' 2>/dev/null \
    | tail -1)
  [ -n "$rl_event" ] || return 0

  rl_detected=true
  rl_resets_at=$(echo "$rl_event" | awk '{print $2}')
  echo "[$(date)] RATE LIMITED — Claude API limit reached" >> "$LOGFILE"

  # Add sleeping emoji on the Slack message
  if [ -n "$MSG_TS" ] && [ -n "${CHANNEL:-}" ]; then
    curl -s -X POST https://slack.com/api/reactions.remove \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" '{channel: $ch, timestamp: $ts, name: "white_check_mark"}')" > /dev/null 2>&1 || true
    curl -s -X POST https://slack.com/api/reactions.add \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$CHANNEL" --arg ts "$MSG_TS" '{channel: $ch, timestamp: $ts, name: "zzz"}')" > /dev/null 2>&1 || true
  fi

  # Only write flag + notify once per rate-limit window
  [ -f "$RATE_LIMIT_FLAG" ] && return 0

  # Use resetsAt from event; fall back to now+30min
  if [ -n "$rl_resets_at" ] && [ "$rl_resets_at" != "null" ] && [ "$rl_resets_at" != "" ]; then
    echo "$rl_resets_at" > "$RATE_LIMIT_FLAG"
  else
    echo $(( $(date +%s) + 1800 )) > "$RATE_LIMIT_FLAG"
  fi

  local bot_ops="${BOT_OPS_CHANNEL_ID:-}"
  local rl_resets_at_flag rl_reset_human
  rl_resets_at_flag=$(cat "$RATE_LIMIT_FLAG" 2>/dev/null || echo "0")
  rl_reset_human=$(date -u -d "@$rl_resets_at_flag" "+%H:%M UTC" 2>/dev/null \
    || date -u -r "$rl_resets_at_flag" "+%H:%M UTC" 2>/dev/null \
    || echo "unknown")

  # Snapshot active agents for investigation context
  {
    echo "Rate limit detected at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Triggered by: PID=$$ command=$COMMAND_SLUG"
    echo ""
    echo "Active agents at time of rate limit:"
    for rl_agent_dir in "$ACTIVE_DIR"/agent-*; do
      [ -d "$rl_agent_dir" ] || continue
      local rl_pid rl_slug rl_started rl_ws rl_running="dead"
      rl_pid=$(basename "$rl_agent_dir" | sed 's/^agent-//')
      rl_slug=$(jq -r '.commandSlug // "unknown"' "$rl_agent_dir/meta.json" 2>/dev/null || echo "unknown")
      rl_started=$(jq -r '.startedAt // "unknown"' "$rl_agent_dir/meta.json" 2>/dev/null || echo "unknown")
      rl_ws=$(jq -r '.workspace // "-"' "$rl_agent_dir/meta.json" 2>/dev/null || echo "-")
      if [[ "$rl_pid" =~ ^[0-9]+$ ]] && kill -0 "$rl_pid" 2>/dev/null; then rl_running="alive"; fi
      echo "  - PID=$rl_pid slug=$rl_slug workspace=$rl_ws started=$rl_started status=$rl_running"
    done
    echo ""
    echo "Queue contents:"
    if [ -d "$QUEUE_DIR" ]; then
      for qf in "$QUEUE_DIR"/queue-*.json; do
        [ -f "$qf" ] || continue
        echo "  - $(jq -r '"\(.command_slug) priority=\(.priority // "normal") queued_at=\(.queued_at // "unknown")"' "$qf" 2>/dev/null || basename "$qf")"
      done
    fi
  } > "${LOCK_PREFIX}-rate-limit-snapshot.txt" 2>/dev/null || true

  # Notify Slack
  if [ -n "$bot_ops" ]; then
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$bot_ops" \
        --arg text "$BOT_NAME: Claude API limit reached. Sessions paused until *${rl_reset_human}*. Investigation will run on resume. Triggered by \`$COMMAND_SLUG\`." \
        '{channel: $ch, text: $text}')" > /dev/null 2>&1 || true
  fi

  # Queue investigation task
  touch "$RATE_LIMIT_INVESTIGATE_PENDING"
  mkdir -p "$QUEUE_DIR"
  jq -n \
    --arg command_slug "rate-limit-investigate" \
    --arg prompt "You are investigating a rate-limit event on the Anthropic Claude API. Read the snapshot at ${LOCK_PREFIX}-rate-limit-snapshot.txt, check ${BOT_LOG_DIR}/ for recent logs (focus on agent start times and frequency), and post a summary to #bot-ops using slack-post.sh. Format: *Rate Limit Investigation* with When, Concurrent agents, Likely cause, and Recommendations sections. Channel: ${bot_ops}." \
    --arg priority "high" \
    --arg queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{command_slug: $command_slug, prompt: $prompt, prompt_file: "",
      msg_ts: "", channel: "", provenance_channel: "", provenance_requester: "",
      provenance_message: "", slack_channel: "", slack_ts: "",
      priority: $priority, queued_at: $queued_at}' \
    > "$QUEUE_DIR/queue-000000000-rate-limit-investigate.json"

  echo "[$(date)] Set rate limit flag (resets at $rl_reset_human) + queued investigation" >> "$LOGFILE"
}
