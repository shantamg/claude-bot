#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bug-fix-precheck.sh — Pre-check for scheduled bug-fix workspace runs.
#
# Verifies that at least one open bug issue exists with no non-author comments
# and no linked PRs. Runs before spawning Claude to avoid unnecessary cost.
#
# Exit codes:
#   0 — Untouched bug(s) found, proceed with Claude invocation
#   1 — Nothing to do, skip this run
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

if [ -z "$PROJECT_REPO" ]; then
  echo "[$(date)] bug-fix-precheck: PROJECT_REPO not configured" >&2
  exit 1
fi

# Fetch open issues with bug-related labels
BUG_ISSUES=$(gh issue list --repo "$PROJECT_REPO" --label bug --state open --json number,author --limit 50 2>/dev/null) || BUG_ISSUES="[]"

# Merge into a single list (deduplicate by issue number in case of overlap)
ALL_ISSUES=$(echo "$BUG_ISSUES" | jq -s 'add // [] | unique_by(.number)')

TOTAL=$(echo "$ALL_ISSUES" | jq 'length')
if [ "$TOTAL" -eq 0 ]; then
  # No open bug issues at all
  exit 1
fi

# Check each issue for activity (non-author comments and linked PRs)
for NUMBER in $(echo "$ALL_ISSUES" | jq -r '.[].number'); do
  AUTHOR=$(echo "$ALL_ISSUES" | jq -r --argjson n "$NUMBER" '.[] | select(.number == $n) | .author.login // ""')

  # Count non-author comments
  if [ -n "$AUTHOR" ]; then
    COMMENT_COUNT=$(gh api "repos/$PROJECT_REPO/issues/$NUMBER/comments" \
      --jq "[.[] | select(.user.login != \"$AUTHOR\")] | length" 2>/dev/null || echo "0")
  else
    COMMENT_COUNT=$(gh api "repos/$PROJECT_REPO/issues/$NUMBER/comments" \
      --jq 'length' 2>/dev/null || echo "0")
  fi

  [ "$COMMENT_COUNT" -gt 0 ] && continue

  # Check for linked PRs (cross-referenced events in timeline)
  OWNER=$(echo "$PROJECT_REPO" | cut -d/ -f1)
  REPO=$(echo "$PROJECT_REPO" | cut -d/ -f2)

  LINKED_PRS=$(gh api graphql -f query='
    query {
      repository(owner: "'"$OWNER"'", name: "'"$REPO"'") {
        issue(number: '"$NUMBER"') {
          timelineItems(itemTypes: CROSS_REFERENCED_EVENT, first: 10) {
            nodes {
              ... on CrossReferencedEvent {
                source {
                  ... on PullRequest { number state }
                }
              }
            }
          }
        }
      }
    }' --jq '.data.repository.issue.timelineItems.nodes | [.[] | select(.source.number != null)] | length' 2>/dev/null || echo "0")

  [ "$LINKED_PRS" -gt 0 ] && continue

  # Found at least one untouched bug — proceed
  exit 0
done

# All bug issues have activity — nothing to do
exit 1
