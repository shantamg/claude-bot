# Incremental Docs Audit

Daily, lightweight audit that checks documentation affected by recent code changes.

## Steps

### 1. Identify Recent Changes

```bash
git log --since="24 hours ago" --name-only --pretty=format:"" | sort -u | grep -v '^$'
```

Collect the list of files changed in the last 24 hours.

### 2. Map Changed Files to Related Docs

For each changed file, identify documentation that may reference it:

- **README.md** files in the same directory or parent directories
- **API docs** if the changed file defines or modifies endpoints
- **Configuration docs** if the changed file modifies config schemas, env vars, or defaults
- **Architecture docs** if the changed file alters module structure or data flows

### 3. Check Each Related Doc for Drift

For each related doc found, verify:

- **Code references** — Do code snippets or file paths in the doc still match reality?
- **API signatures** — Do documented function/endpoint signatures match the current code?
- **Config values** — Do documented defaults, env var names, or config keys match the code?
- **Behavioral descriptions** — Does the doc describe behavior that the code change may have altered?

### 4. Report Findings

If drift is found, create a GitHub issue or post a Slack message with:

- **Title**: "Docs audit: [N] items need attention"
- **Body**: A list of findings, each with:
  - The doc file path
  - The related code change (commit + file)
  - What appears to be outdated or missing
  - Suggested fix (if straightforward)

If no drift is found, post a short confirmation to Slack: "Incremental docs audit: all clear."

## Notes

- Focus on substance, not formatting nits. Typos and style issues are out of scope.
- When uncertain whether something is truly outdated, flag it with a note explaining the uncertainty rather than silently skipping it.
