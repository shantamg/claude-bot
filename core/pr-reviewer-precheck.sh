#!/bin/bash
# pr-reviewer-precheck.sh — Label-driven pre-check for the pr-reviewer workspace.
# Exits 0 (with summary on stdout) if any PR needs bot action.
# Exits 1 if no PRs need attention (no Claude session needed).
#
# With the label lifecycle (bot:needs-review → bot:in-progress → bot:reviewed →
# bot:needs-human-review), Claude is only needed when a trigger label is present
# or a PR has drifted into conflict. Everything else is terminal state.
#
set -euo pipefail
source /opt/lovely-bot/.env 2>/dev/null || true

REPO="LvlyAI/lovely"
LOGFILE="/var/log/lovely-bot/pr-reviewer-precheck.log"
log() { echo "[$(date)] $1" >> "$LOGFILE" 2>/dev/null || true; }

NEEDS_ACTION=()

# 1. PRs with bot:needs-review — the primary trigger (new PRs needing initial review)
NEEDS_REVIEW=$(gh pr list --repo "$REPO" --label "bot:needs-review" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $NEEDS_REVIEW; do
  NEEDS_ACTION+=("#${N}: bot:needs-review")
done

# 2. PRs with bot:review-changes-needed — self-correction loop
CHANGES_NEEDED=$(gh pr list --repo "$REPO" --label "bot:review-changes-needed" --state open \
  --json number --jq '.[].number' 2>/dev/null) || true
for N in $CHANGES_NEEDED; do
  NEEDS_ACTION+=("#${N}: review-changes-needed")
done

# 3. PRs with explicit override labels (human requesting bot action)
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
CONFLICTING=$(gh pr list --repo "$REPO" --author LvlyBot --state open \
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

log "No trigger labels or conflicts found — skipping Claude"
exit 1
