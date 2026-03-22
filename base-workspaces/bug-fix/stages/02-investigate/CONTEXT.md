# Stage 02: Investigate

Analyze the bug issue, search the codebase for relevant files, and determine the root cause.

## Input

- Issue number, title, body, and labels (from Stage 01 or from the label trigger prompt)

## Process

### 1. Read the issue details

If you have not already read the full issue, do so now:

```bash
gh issue view {number}
```

Identify:
- What the expected behavior is
- What the actual (buggy) behavior is
- Any error messages, stack traces, or reproduction steps provided
- Which area of the codebase is likely affected

### 2. Search the codebase

Use Grep and Glob to find relevant files:

- Search for error messages or keywords from the issue
- Search for function/class/component names mentioned in the issue
- Search for the affected endpoint, route, or feature area
- Check recent commits for regressions: `git log --oneline -20 -- {affected-path}`

Read the files you find. Understand the current implementation and how it relates to the reported bug.

### 3. Identify the root cause

Trace the code path that produces the buggy behavior. Look for:
- Logic errors (wrong condition, off-by-one, missing null check)
- State management issues (race condition, stale data)
- Missing error handling (unhandled exception, missing validation)
- Regression from a recent change
- Dependency issue (version mismatch, API change)

### 4. Assess fixability

| Assessment | Action |
|---|---|
| **Clear root cause, code-fixable** | Proceed to Stage 03 |
| **Needs more information from reporter** | Comment on the issue asking for clarification, add `needs-info` label, then stop |
| **Not code-fixable** (config, infrastructure, external service) | Comment on the issue explaining why, then stop |

### 5a. If fixable -- proceed

Document your findings mentally and proceed to the fix stage. Read `../03-fix/CONTEXT.md`.

### 5b. If needs info -- comment and stop

Post a comment on the issue:

```bash
gh issue comment {number} --body "## Investigation Report

**Area**: {affected area of codebase}
**Findings**: {what was discovered during investigation}
**Needs clarification**: {specific questions for the reporter}

Adding \`needs-info\` label -- will revisit once clarification is provided."
```

Add the label:

```bash
gh issue edit {number} --add-label needs-info
```

Then stop. Do not proceed to Stage 03.

## Standalone Mode (Label Trigger)

When entering via the `bot:investigate` label (no Stage 01 context), the issue number will be provided in the prompt. Run the full investigation above.

After investigation, post a structured comment on the issue with your findings regardless of the outcome. If the bug is code-fixable and you have clear root cause, proceed to Stage 03.

## Exit Criteria

- Root cause identified and fix approach determined -- proceed to Stage 03
- Issue needs more information -- commented on issue, added label, stopped
- Issue not code-fixable -- commented on issue, stopped
