#!/bin/bash
# workspace-dispatcher.sh — Universal label-driven workspace dispatcher
#
# Scans for open issues/PRs with bot:* labels, maps each to a workspace path
# using label-registry.json, and invokes run-claude.sh --workspace for each.
#
# Usage:
#   workspace-dispatcher.sh                              # Scan and dispatch bot:* labeled issues
#   workspace-dispatcher.sh --scheduled <ws> <prompt>    # Run a scheduled workspace job
#
# Cron entry (replaces all per-job scripts):
#   */5 * * * * /opt/claude-bot/scripts/workspace-dispatcher.sh
#
# Concurrency:
#   MAX_CONCURRENT controls the global limit (default 5).
#   RESERVED_INTERACTIVE_SLOTS (default 2) reserves slots for human-triggered work.
#   Scheduled jobs can only use (MAX_CONCURRENT - RESERVED_INTERACTIVE_SLOTS) = 3 slots.
#   Label-driven dispatch uses the full MAX_CONCURRENT limit.
#   Deduplication is handled by atomic claim files (not locks).
#
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

REGISTRY_FILE="${PROJECT_DIR}/bot/label-registry.json"
LOGFILE="$BOT_LOG_DIR/workspace-dispatcher.log"

# Ensure directories exist
mkdir -p "$CLAIMS_DIR" "$(dirname "$LOGFILE")" 2>/dev/null || true

# ─── Helper functions ────────────────────────────────────────────────────────

log() { echo "[$(date)] $1" >> "$LOGFILE"; }

# Count currently running agents via _active/ directories and legacy lockfiles
count_running_agents() {
  local count=0
  for agent_dir in "$ACTIVE_DIR"/agent-*; do
    [ -d "$agent_dir" ] || continue
    local pid
    pid=$(basename "$agent_dir" | sed 's/^agent-//')
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  # Also count lockfiles for agents started by legacy scripts (not yet in _active/)
  for lock in ${LOCK_PREFIX}-ws-*.lock; do
    [ -f "$lock" ] || continue
    local lpid
    lpid=$(cat "$lock" 2>/dev/null || echo "")
    if [ -n "$lpid" ] && [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then
      # Only count if there is no matching _active/ dir (avoid double-counting)
      if [ ! -d "$ACTIVE_DIR/agent-${lpid}" ]; then
        count=$((count + 1))
      fi
    fi
  done
  echo "$count"
}

# Check if an issue is already being worked on (agent active or claim held)
is_issue_active() {
  local issue_number="$1"

  # Check _active/ agent directories for this issue number
  for agent_dir in "$ACTIVE_DIR"/agent-*; do
    [ -d "$agent_dir" ] || continue
    local pid
    pid=$(basename "$agent_dir" | sed 's/^agent-//')
    # Skip dead processes
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    # Check meta.json for issue number
    if [ -f "$agent_dir/meta.json" ]; then
      local agent_issue
      agent_issue=$(jq -r '.issueNumber // empty' "$agent_dir/meta.json" 2>/dev/null || echo "")
      if [ "$agent_issue" = "$issue_number" ]; then
        return 0  # Active
      fi
    fi
  done

  # Check dispatcher claim files (prevents re-dispatching within the same cycle
  # or across rapid cycles while the agent is still starting up)
  local claim_file="$CLAIMS_DIR/claimed-ws-dispatch-${issue_number}.txt"
  if [ -f "$claim_file" ]; then
    local claim_pid
    claim_pid=$(cat "$claim_file" 2>/dev/null || echo "")
    if [ -n "$claim_pid" ] && [[ "$claim_pid" =~ ^[0-9]+$ ]] && kill -0 "$claim_pid" 2>/dev/null; then
      return 0  # Claimed and still running
    fi
    # Stale claim — remove it
    rm -f "$claim_file"
  fi

  # Check cooldown for keep_label issues (prevents infinite relaunch loop).
  # After a keep_label agent finishes, it writes a cooldown timestamp.
  # Default cooldown: 30 minutes between re-dispatches of the same issue.
  local cooldown_file="$CLAIMS_DIR/cooldown-${issue_number}.txt"
  if [ -f "$cooldown_file" ]; then
    local last_completed
    last_completed=$(cat "$cooldown_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local elapsed=$(( now - last_completed ))
    local cooldown_secs="${KEEP_LABEL_COOLDOWN_SECS:-1800}"  # 30 min default
    if [ "$elapsed" -lt "$cooldown_secs" ]; then
      return 0  # Still in cooldown
    fi
  fi

  return 1  # Not active
}

# Resolve workspace name from a bot:* label via label-registry.json
resolve_workspace_from_label() {
  local label="$1"
  jq -r --arg label "$label" '.labels[$label].workspace // empty' "$REGISTRY_FILE" 2>/dev/null
}

# Resolve entry stage from a bot:* label
resolve_entry_stage() {
  local label="$1"
  jq -r --arg label "$label" '.labels[$label].entry_stage // empty' "$REGISTRY_FILE" 2>/dev/null
}

# ─── Scheduled mode (checked BEFORE the dispatcher lock) ─────────────────────
# Scheduled jobs use a per-workspace lock so they never race with the label scanner.
# Without this, once-a-day jobs (daily-digest, docs-audit, security-audit) were
# silently dropped when the label scanner (every minute) won the shared lock.
if [ "${1:-}" = "--scheduled" ]; then
  SCHED_WORKSPACE="${2:?--scheduled requires a workspace name}"
  SCHED_PROMPT="${3:-Process this scheduled workspace job.}"

  # Per-workspace lock prevents duplicate scheduled runs of the same workspace
  SCHED_LOCK="${LOCK_PREFIX}-scheduled-${SCHED_WORKSPACE}.lock"
  if [ -f "$SCHED_LOCK" ]; then
    SCHED_LOCK_PID=$(cat "$SCHED_LOCK" 2>/dev/null || echo "")
    if [ -n "$SCHED_LOCK_PID" ] && kill -0 "$SCHED_LOCK_PID" 2>/dev/null; then
      exit 0  # Previous scheduled run still active
    fi
    rm -f "$SCHED_LOCK"
  fi
  echo "$$" > "$SCHED_LOCK"
  trap 'rm -f "$SCHED_LOCK"' EXIT

  log "Scheduled dispatch: workspace=$SCHED_WORKSPACE"

  # Run bash pre-check if one exists for this workspace.
  # Pre-check scripts exit 0 = work found (proceed), exit 1 = nothing to do (skip Claude).
  PRECHECK_SCRIPT="$SCRIPTS_DIR/${SCHED_WORKSPACE}-precheck.sh"
  if [ -x "$PRECHECK_SCRIPT" ]; then
    if ! PRECHECK_OUTPUT=$("$PRECHECK_SCRIPT" 2>&1); then
      log "Pre-check for $SCHED_WORKSPACE found nothing to do — skipping Claude"
      exit 0
    fi
    log "Pre-check for $SCHED_WORKSPACE found work: $PRECHECK_OUTPUT"
  fi

  # Scheduled jobs use a reduced concurrency limit, reserving slots for interactive work
  SCHED_MAX=$((MAX_CONCURRENT - RESERVED_INTERACTIVE_SLOTS))
  RUNNING=$(count_running_agents)
  if [ "$RUNNING" -ge "$SCHED_MAX" ]; then
    log "Skipping scheduled $SCHED_WORKSPACE — $RUNNING agents already running (scheduled max $SCHED_MAX, reserving $RESERVED_INTERACTIVE_SLOTS for interactive)"
    exit 0
  fi

  PRIORITY=low "$SCRIPTS_DIR/run-claude.sh" --workspace "$SCHED_WORKSPACE" "$SCHED_PROMPT" &
  log "Launched scheduled workspace=$SCHED_WORKSPACE (PID $!, priority=low)"
  exit 0
fi

# No dispatcher lock needed — claim files (set -o noclobber) handle deduplication
# atomically. Overlapping label scans just race on claims; only one wins per issue.

# ─── Validate registry ──────────────────────────────────────────────────────
if [ ! -f "$REGISTRY_FILE" ]; then
  log "ERROR: Label registry not found: $REGISTRY_FILE"
  exit 1
fi

# ─── Clean up false bot:failed labels ────────────────────────────────────────
# Issues labeled bot:failed that already have a linked open PR are false positives
FAILED_ISSUES=$(gh issue list --repo "$PROJECT_REPO" --label "bot:failed" --state open \
  --json number --jq '.[].number' 2>/dev/null) || FAILED_ISSUES=""
for FAILED_NUM in $FAILED_ISSUES; do
  HAS_PR=$(gh pr list --repo "$PROJECT_REPO" --search "Fixes #$FAILED_NUM" --state open --json number --jq 'length' 2>/dev/null || echo "0")
  if [ "$HAS_PR" -gt 0 ]; then
    gh issue edit "$FAILED_NUM" --repo "$PROJECT_REPO" --remove-label "bot:failed" 2>/dev/null || true
    log "Removed false bot:failed from #$FAILED_NUM (PR exists)"
  fi
done

# ─── Fetch all open issues/PRs with bot:* labels ─────────────────────────────
log "Scanning for bot:* labeled items..."

# Get all label-triggered bot:* labels from the registry
WS_LABELS=$(jq -r '.labels | to_entries[] | select(.value.trigger == "label") | .key' "$REGISTRY_FILE" 2>/dev/null)

if [ -z "$WS_LABELS" ]; then
  log "No label-triggered entries in registry"
  exit 0
fi

DISPATCHED=0

for WS_LABEL in $WS_LABELS; do
  # Check concurrency before each label scan
  RUNNING=$(count_running_agents)
  if [ "$RUNNING" -ge "$MAX_CONCURRENT" ]; then
    log "Concurrency limit reached ($RUNNING/$MAX_CONCURRENT) — stopping dispatch"
    break
  fi

  # Fetch open issues with this label (exclude items already labeled 'duplicate')
  ITEMS=$(gh issue list --repo "$PROJECT_REPO" --label "$WS_LABEL" --state open \
    --json number,title,labels,assignees --limit 10 2>/dev/null) || {
    log "GitHub API error fetching issues with label $WS_LABEL"
    continue
  }

  ITEM_COUNT=$(echo "$ITEMS" | jq 'length' 2>/dev/null || echo "0")
  if [ "$ITEM_COUNT" -eq 0 ]; then
    continue
  fi

  log "Found $ITEM_COUNT item(s) with label $WS_LABEL"

  # Process each item — use process substitution to avoid subshell (keeps DISPATCHED in scope)
  while IFS= read -r ITEM; do
    ISSUE_NUMBER=$(echo "$ITEM" | jq -r '.number')
    ISSUE_TITLE=$(echo "$ITEM" | jq -r '.title')

    # Skip issues already labeled 'duplicate'
    IS_DUPLICATE=$(echo "$ITEM" | jq -r '.labels[]?.name' 2>/dev/null | grep -c '^duplicate$' || true)
    if [ "$IS_DUPLICATE" -gt 0 ]; then
      log "Skipping #$ISSUE_NUMBER ($ISSUE_TITLE) — labeled duplicate"
      continue
    fi

    # Re-check concurrency inside the loop
    RUNNING=$(count_running_agents)
    if [ "$RUNNING" -ge "$MAX_CONCURRENT" ]; then
      log "Concurrency limit ($RUNNING/$MAX_CONCURRENT) — deferring #$ISSUE_NUMBER"
      continue
    fi

    # Skip if already being worked on
    if is_issue_active "$ISSUE_NUMBER"; then
      log "Skipping #$ISSUE_NUMBER ($ISSUE_TITLE) — already active"
      continue
    fi

    # Resolve workspace name from label
    WORKSPACE=$(resolve_workspace_from_label "$WS_LABEL")
    if [ -z "$WORKSPACE" ]; then
      log "ERROR: No workspace mapped for label $WS_LABEL"
      continue
    fi

    # Remove trailing slash for the --workspace flag
    WORKSPACE="${WORKSPACE%/}"

    ENTRY_STAGE=$(resolve_entry_stage "$WS_LABEL")

    # Check if this workspace manages its own label lifecycle (multi-pass workspaces
    # like expert-review that need the label to persist across invocations)
    KEEP_LABEL=$(jq -r --arg label "$WS_LABEL" '.labels[$label].keep_label // false' "$REGISTRY_FILE" 2>/dev/null)

    # Verify workspace directory exists using cascade resolution (project → base-workspaces)
    RESOLVED_WS_PATH=$(resolve_workspace "$WORKSPACE") || true
    if [ -z "$RESOLVED_WS_PATH" ]; then
      log "ERROR: Workspace directory not found: $WORKSPACE (checked project and base-workspaces)"
      continue
    fi

    # Check for duplicate issues before spending an agent slot
    if "$SCRIPTS_DIR/check-duplicates.sh" "$ISSUE_NUMBER" 2>/dev/null; then
      : # No duplicates found — proceed with dispatch
    else
      DUP_EXIT=$?
      if [ "$DUP_EXIT" -eq 1 ]; then
        log "Skipping #$ISSUE_NUMBER — duplicate detected by check-duplicates.sh"
        # Remove the trigger label so it doesn't re-dispatch
        gh issue edit "$ISSUE_NUMBER" --repo "$PROJECT_REPO" --remove-label "$WS_LABEL" 2>/dev/null || true
        continue
      fi
      # Exit code 2 = error — proceed with dispatch to be safe
      log "Duplicate check error for #$ISSUE_NUMBER (exit=$DUP_EXIT) — proceeding with dispatch"
    fi

    # Claim this issue (atomic, prevents double dispatch)
    CLAIM_FILE="$CLAIMS_DIR/claimed-ws-dispatch-${ISSUE_NUMBER}.txt"
    if ! (set -o noclobber; echo "pending" > "$CLAIM_FILE") 2>/dev/null; then
      log "Skipping #$ISSUE_NUMBER — claim contention"
      continue
    fi

    # Build the prompt with issue context
    PROMPT="Process GitHub issue #${ISSUE_NUMBER} according to this workspace's instructions.

Issue: #${ISSUE_NUMBER}
Title: ${ISSUE_TITLE}
Label: ${WS_LABEL}
Workspace: ${WORKSPACE}
${ENTRY_STAGE:+Entry Stage: ${ENTRY_STAGE}}

IMPORTANT: First read the full issue with: gh issue view ${ISSUE_NUMBER} --repo ${PROJECT_REPO}
${ENTRY_STAGE:+Then read stages/${ENTRY_STAGE}/CONTEXT.md for your instructions. You are entering at stage ${ENTRY_STAGE} in STANDALONE mode (no prior stage output). Follow the standalone completion instructions in the CONTEXT.md.}
${ENTRY_STAGE:-Then follow the workspace CONTEXT.md instructions to process it.}"

    log "Dispatching #$ISSUE_NUMBER ($ISSUE_TITLE) -> workspace=$WORKSPACE${ENTRY_STAGE:+ stage=$ENTRY_STAGE}"

    # Signal on the issue that an agent has picked it up
    gh issue edit "$ISSUE_NUMBER" --repo "$PROJECT_REPO" --add-label "bot:in-progress" 2>/dev/null || true

    # Build session flag for multi-pass workspaces (keep_label = true).
    # Session continuity gives the agent memory across ticks.
    SESSION_FLAG=""
    if [ "$KEEP_LABEL" = "true" ]; then
      SESSION_FLAG="--session ws-${WORKSPACE}-${ISSUE_NUMBER}"
    fi

    # Launch in background, update claim with actual PID
    (
      set +e
      PRIORITY=normal "$SCRIPTS_DIR/run-claude.sh" --workspace "$WORKSPACE" $SESSION_FLAG "$PROMPT"
      EXIT_CODE=$?

      # Clean up claim on completion
      rm -f "$CLAIM_FILE"

      # Remove in-progress label
      gh issue edit "$ISSUE_NUMBER" --repo "$PROJECT_REPO" --remove-label "bot:in-progress" 2>/dev/null || true

      # Remove trigger label to prevent re-dispatch loop — UNLESS keep_label is set.
      # Multi-pass workspaces (e.g., expert-review) manage their own label lifecycle
      # and need the label to persist so the dispatcher picks them up on the next tick.
      #
      # Re-read keep_label from the registry at cleanup time (not just the inherited
      # variable from dispatch time) so that git-pull updates are reflected even if
      # the registry was updated after the agent was launched.
      KEEP_LABEL_NOW=$(jq -r --arg label "$WS_LABEL" '.labels[$label].keep_label // false' "$REGISTRY_FILE" 2>/dev/null || echo "")
      if [ "$KEEP_LABEL" = "true" ] || [ "$KEEP_LABEL_NOW" = "true" ]; then
        echo "[$(date)] Preserving label $WS_LABEL on #$ISSUE_NUMBER (keep_label=true, multi-pass workspace)" >> "$LOGFILE"
        # Write cooldown timestamp to prevent immediate re-dispatch
        date +%s > "$CLAIMS_DIR/cooldown-${ISSUE_NUMBER}.txt"
      else
        gh issue edit "$ISSUE_NUMBER" --repo "$PROJECT_REPO" --remove-label "$WS_LABEL" 2>/dev/null || true
      fi

      if [ $EXIT_CODE -eq 0 ]; then
        echo "[$(date)] Completed #$ISSUE_NUMBER (workspace=$WORKSPACE)" >> "$LOGFILE"
      else
        # Non-zero exit doesn't necessarily mean failure — Claude CLI exits non-zero
        # for benign reasons (context limit, tool errors). Check if work was actually done.

        # Check 1: PR exists in any state (open, merged, or closed)
        HAS_PR=$(gh pr list --repo "$PROJECT_REPO" --search "Fixes #$ISSUE_NUMBER" --state all --json number --jq 'length' 2>/dev/null || echo "0")
        if [ "$HAS_PR" -gt 0 ]; then
          echo "[$(date)] Agent exited $EXIT_CODE but PR exists for #$ISSUE_NUMBER — treating as success" >> "$LOGFILE"
        else
          # Check 2: Agent posted a comment (work was done even without a PR — audits, milestones, etc.)
          BOT_COMMENTED=$(gh api "repos/$PROJECT_REPO/issues/$ISSUE_NUMBER/comments?per_page=5&direction=desc" \
            --jq "[.[] | select(.user.login == \"$BOT_USERNAME\")] | length" 2>/dev/null || echo "0")
          if [ "$BOT_COMMENTED" -gt 0 ]; then
            echo "[$(date)] Agent exited $EXIT_CODE but posted comments on #$ISSUE_NUMBER — treating as success" >> "$LOGFILE"
          else
            echo "[$(date)] Failed #$ISSUE_NUMBER (workspace=$WORKSPACE, exit=$EXIT_CODE) — no PR or comments found" >> "$LOGFILE"
            gh issue edit "$ISSUE_NUMBER" --repo "$PROJECT_REPO" --add-label "bot:failed" 2>/dev/null || true
          fi
        fi
      fi
    ) &

    CHILD_PID=$!
    echo "$CHILD_PID" > "$CLAIM_FILE"

    log "Launched agent for #$ISSUE_NUMBER (PID $CHILD_PID, workspace=$WORKSPACE)"
    DISPATCHED=$((DISPATCHED + 1))

    # Small delay between dispatches to avoid overwhelming GitHub API
    sleep 1
  done < <(echo "$ITEMS" | jq -c '.[]')
done

log "Dispatch cycle complete. dispatched=$DISPATCHED running=$(count_running_agents)/$MAX_CONCURRENT"
