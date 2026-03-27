#!/bin/bash
# pr-reviewer-precheck.sh — Label-driven pre-check for the pr-reviewer workspace.
# Exits 0 (with summary on stdout) if any PR needs bot action.
# Exits 1 if no PRs need attention (no Claude session needed).
#
# Key principle: only invoke Claude when something CHANGED since the bot last
# looked. If the bot already reviewed and no new commits were pushed, skip.
#
set -euo pipefail
source /opt/claude-bot/.env 2>/dev/null || source /opt/lovely-bot/.env 2>/dev/null || true

REPO="${PROJECT_REPO:-LvlyAI/lovely}"
BOT_USER="${BOT_GITHUB_USER:-LvlyBot}"
LOGFILE="${BOT_LOG_DIR:-/var/log/lovely-bot}/pr-reviewer-precheck.log"
log() { echo "[$(date)] $1" >> "$LOGFILE" 2>/dev/null || true; }

# Helper: check if bot already reviewed a PR and nothing changed since
bot_already_reviewed() {
  local pr_num="$1"
  # Get last bot comment date and last commit date
  local last_bot_comment last_commit
  last_bot_comment=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
    --jq "[.comments[] | select(.author.login == \"$BOT_USER\")] | sort_by(.createdAt) | last | .createdAt // empty" 2>/dev/null)
  [ -z "$last_bot_comment" ] && return 1  # Bot never commented — needs review

  last_commit=$(gh pr view "$pr_num" --repo "$REPO" --json commits \
    --jq '.commits | last | .committedDate // empty' 2>/dev/null)
  [ -z "$last_commit" ] && return 1  # Can't determine — needs review

  # If bot commented AFTER the last commit, it already reviewed this state
  if [[ "$last_bot_comment" > "$last_commit" ]]; then
    return 0  # Already reviewed, nothing changed
  fi
  return 1  # New commits since bot's review
}

NEEDS_ACTION=()

# 1. PRs with bot:needs-review — only if bot hasn't already reviewed current state
NEEDS_REVIEW=$(gh pr list --repo "$REPO" --label "bot:needs-review" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $NEEDS_REVIEW; do
  if bot_already_reviewed "$N"; then
    log "Skipping #${N} — bot already reviewed, no new commits"
  else
    NEEDS_ACTION+=("#${N}: bot:needs-review")
  fi
done

# 2. PRs with bot:review-changes-needed — only if new commits since last bot comment
CHANGES_NEEDED=$(gh pr list --repo "$REPO" --label "bot:review-changes-needed" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $CHANGES_NEEDED; do
  if bot_already_reviewed "$N"; then
    log "Skipping #${N} — changes-needed but no new commits since last review"
  else
    NEEDS_ACTION+=("#${N}: review-changes-needed")
  fi
done

# 3. PRs with explicit override labels — always process (human is asking)
OVERRIDE=$(gh pr list --repo "$REPO" --label "bot:review-pr" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $OVERRIDE; do
  NEEDS_ACTION+=("#${N}: bot:review-pr override")
done
OVERRIDE2=$(gh pr list --repo "$REPO" --label "bot:pr-reviewer" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $OVERRIDE2; do
  NEEDS_ACTION+=("#${N}: bot:pr-reviewer override")
done

# 4. Bot PRs with merge conflicts — always auto-rebase regardless of labels
CONFLICTING=$(gh pr list --repo "$REPO" --author "$BOT_USER" --state open \
  --json number,mergeable --jq '.[] | select(.mergeable == "CONFLICTING") | .number' 2>/dev/null) || true
for N in $CONFLICTING; do
  NEEDS_ACTION+=("#${N}: conflicting")
done

# Deduplicate (a PR might match multiple criteria)
if [ ${#NEEDS_ACTION[@]} -gt 0 ]; then
  UNIQUE=$(printf '%s\n' "${NEEDS_ACTION[@]}" | sort -u -t: -k1,1)
  SUMMARY="$UNIQUE"
  COUNT=$(echo "$UNIQUE" | wc -l | tr -d ' ')
  log "Found ${COUNT} PRs needing action: ${SUMMARY}"
  echo "$SUMMARY"
  exit 0
fi

log "No actionable PRs — skipping Claude"
exit 1
