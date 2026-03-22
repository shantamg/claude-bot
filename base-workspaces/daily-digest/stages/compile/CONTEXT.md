# Compile Daily Digest

Gather the last 24 hours of project activity and post a summary to Slack.

## Steps

### 1. Gather Git Activity

```bash
git log --since="24 hours ago" --pretty=format:"- %h %s (%an)" --no-merges
```

Summarize: number of commits, key changes, active contributors.

### 2. Gather PR Activity

```bash
# Recently merged PRs
gh pr list --state merged --search "merged:>=$(date -u -d '24 hours ago' +%Y-%m-%d)" --json number,title,author,mergedAt

# Currently open PRs
gh pr list --state open --json number,title,author,createdAt

# Recently closed (not merged) PRs
gh pr list --state closed --search "closed:>=$(date -u -d '24 hours ago' +%Y-%m-%d)" --json number,title,author
```

Summarize: PRs merged, PRs opened, PRs closed without merge.

### 3. Gather Issue Activity

```bash
# Recently opened issues
gh issue list --state open --search "created:>=$(date -u -d '24 hours ago' +%Y-%m-%d)" --json number,title,author

# Recently closed issues
gh issue list --state closed --search "closed:>=$(date -u -d '24 hours ago' +%Y-%m-%d)" --json number,title,author
```

Summarize: issues opened, issues closed.

### 4. Gather Bot Activity

Check bot logs for completed tasks in the last 24 hours:

```bash
find /var/log/claude-bot/ -name '*.log' -mtime -1 -exec grep -l 'completed' {} \;
```

Summarize: which workspaces ran, how many tasks completed, any failures.

### 5. Format and Post

Compose a Slack message with this structure:

```
:newspaper: *Daily Digest — [DATE]*

*Commits*: [N] commits by [contributors]
[top 3-5 most notable commits, one line each]

*Pull Requests*:
- Merged: [N] — [titles if few, count if many]
- Opened: [N]
- Closed: [N]

*Issues*:
- Opened: [N]
- Closed: [N]

*Bot Activity*:
- [workspace]: [count] tasks ([pass]/[fail])

[Any notable items or anomalies worth highlighting]
```

Post to the ops channel using `slack-post.sh`.

## Notes

- If a category has zero activity, include it with "None" rather than omitting it — the absence of activity is information too.
- Keep the digest concise. Link to PRs/issues by number rather than repeating full details.
- If the date commands above fail (macOS vs Linux), adapt the syntax accordingly (`-d '24 hours ago'` on Linux, `-v-24H` on macOS).
