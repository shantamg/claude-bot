# Identify Stale Items

Find stale issues, PRs, and branches. Nudge owners where appropriate and post a summary.

## Steps

### 1. Find Stale Issues

```bash
# Issues with no activity for 30+ days
gh issue list --state open --json number,title,author,assignees,updatedAt,labels \
  --jq '[.[] | select(.updatedAt < (now - 30*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))]'
```

For each stale issue:
- Check if it has an assignee
- Check if it has any linked PRs (may be in progress despite no issue activity)
- If it has an assignee and no linked PR, add a comment: "This issue has had no activity for 30+ days. @[assignee] — is this still being worked on? If not, consider unassigning so someone else can pick it up."
- If it has no assignee, just note it in the report

### 2. Find Stale PRs

```bash
# PRs with no activity for 14+ days
gh pr list --state open --json number,title,author,assignees,updatedAt,reviewRequests \
  --jq '[.[] | select(.updatedAt < (now - 14*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))]'
```

For each stale PR:
- Check if it has pending review requests
- Check if CI is passing
- Add a review comment: "This PR has had no activity for 14+ days. Is it still relevant? If the work is paused, consider converting to draft. If abandoned, consider closing."

### 3. Find Stale Branches

```bash
# Branches with no commits for 30+ days (exclude main, master, develop, release branches)
git for-each-ref --sort=committerdate --format='%(committerdate:iso8601) %(refname:short)' refs/remotes/origin/ | \
  grep -v -E '(main|master|develop|release)' | \
  while read date branch; do
    if [ "$(date -d "$date" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S %z" "$date" +%s)" -lt "$(date -d '30 days ago' +%s 2>/dev/null || date -v-30d +%s)" ]; then
      echo "$date $branch"
    fi
  done
```

For stale branches:
- List them in the report but do NOT auto-delete
- Note the last commit date and author
- Note if there is an associated open PR

### 4. Post Summary to Slack

Compose a Slack message:

```
:broom: *Stale Sweeper Report — [DATE]*

*Stale Issues (30+ days inactive)*: [N] found
[list each: #number — title (last activity: date)]
[note which ones were nudged]

*Stale PRs (14+ days inactive)*: [N] found
[list each: #number — title (last activity: date)]
[note which ones were nudged]

*Stale Branches (30+ days inactive)*: [N] found
[list each: branch-name (last commit: date, author)]

*Actions Taken*:
- Commented on [N] issues
- Commented on [N] PRs
- [N] branches flagged for review
```

Post to the ops channel using `slack-post.sh`.

## Notes

- Be respectful in nudge comments. The goal is to prompt a decision, not shame anyone.
- Skip issues/PRs with labels like `on-hold`, `blocked`, `long-running`, or `wontfix` — these are intentionally inactive.
- If the `jq` date filtering doesn't work in your environment, fetch all items and filter in a loop using date comparison.
- On macOS, `date -d` is not available. Use `date -v-30d` for relative dates or compute timestamps with Python/Node.
