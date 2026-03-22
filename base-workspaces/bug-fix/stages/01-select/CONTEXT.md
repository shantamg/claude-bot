# Stage 01: Select

Pick the highest-priority untouched bug issue to work on.

## Process

### 1. Fetch open bug issues

Search for open issues with bug-related labels. The exact labels vary by project, but common ones include `bug`, `Bug`, `type:bug`, and `type: bug`. Use `gh issue list` to find candidates:

```bash
gh issue list --label bug --state open --json number,title,body,labels,author,createdAt --limit 50
```

If the project uses additional bug labels (check the repo's label list with `gh label list`), query those too and deduplicate by issue number.

### 2. Filter to untouched issues only

An issue is **untouched** if it meets both criteria:

- **No non-author comments**: The only comments (if any) are from the issue author. Use the GitHub API to check:
  ```bash
  gh api "repos/{owner}/{repo}/issues/{number}/comments" --jq '[.[] | select(.user.login != "{author_login}")] | length'
  ```
  If the result is 0, the issue has no non-author comments.

- **No linked pull requests**: No PRs reference this issue (cross-referenced in the timeline):
  ```bash
  gh api "repos/{owner}/{repo}/issues/{number}/timeline" --jq '[.[] | select(.event == "cross-referenced") | select(.source.issue.pull_request != null)] | length'
  ```
  If the result is 0, no PRs are linked.

Keep only issues where both counts are zero.

### 3. Check active agents

Review the `[ACTIVE WORK-IN-PROGRESS]` block in your context (if present). If another agent is already working on an issue, skip it.

### 4. Pick the highest-priority issue

Priority order:
1. Issues with a `priority:high` or `critical` label
2. Issues with a `priority:medium` label
3. Oldest issues first (earliest `createdAt`)

Select **one** issue to work on.

### 5. Read the full issue

```bash
gh issue view {number}
```

Read the full issue body, comments (if any from author), and labels. Understand what the bug is and what area of the codebase it affects.

### 6. Proceed to investigate

Read `../02-investigate/CONTEXT.md` and continue with the selected issue.

## STANDALONE Mode

When this stage is invoked directly by the scheduler (not via a label trigger), you are the entry point. The pre-check script has already confirmed that at least one untouched bug exists, so proceed with the full process above.

If, despite the pre-check, you find no qualifying issues after filtering (e.g., race condition with another agent), exit cleanly with a brief message: "No untouched bug issues found."

## Exit Criteria

- One untouched bug issue selected with full context loaded -- proceed to Stage 02
- No qualifying issues found -- exit with a report
