# Stage 03: Fix

Implement the fix, run tests, and create a pull request.

## Input

- Issue number, title, and labels
- Root cause analysis from Stage 02 (in your conversation context)
- Affected files identified during investigation

## Process

### 1. Implement the fix

Edit the relevant files to fix the bug. Follow these principles:
- **Minimal, focused changes** -- fix the bug, nothing more
- **Do not refactor** unrelated code in the same change
- **Preserve existing patterns** -- match the style and conventions of surrounding code
- **Add or update tests** if the project has a test suite

### 2. Run tests

If the project has a test command (look for `package.json` scripts, `Makefile` targets, or CI configuration), run it:

```bash
# Common test commands -- use whichever applies to the project
npm test
yarn test
pytest
go test ./...
cargo test
make test
```

If tests fail:
- If the failure is related to your change, fix it
- If the failure is pre-existing (unrelated to your change), note it in the PR description but proceed

### 3. Commit the changes

Write a descriptive commit message:

```bash
git add {changed-files}
git commit -m "fix: {concise description of what was fixed}

{Brief explanation of the root cause and how the fix addresses it}

Fixes #{issue-number}"
```

### 4. Push the branch

```bash
git push -u origin HEAD
```

### 5. Create a pull request

```bash
gh pr create --title "fix: {concise description}" --body "$(cat <<'EOF'
## Summary

Fixes #{issue-number}.

**Root cause**: {one-line root cause from investigation}

**Fix**: {what was changed and why}

## Changes

- {file1}: {what changed}
- {file2}: {what changed}

## Test plan

- [ ] {how to verify the fix}
- [ ] Existing tests pass

---

*Automated fix by claude-bot (bug-fix workspace)*
EOF
)"
```

Ensure the PR body contains `Fixes #{issue-number}` so GitHub automatically closes the issue when the PR is merged.

### 6. Comment on the issue

Post a summary comment on the original issue:

```bash
gh issue comment {number} --body "## Fix Submitted

**PR**: {pr-url}
**Root cause**: {one-line summary}
**Fix**: {what was changed}

The PR is ready for human review."
```

## Exit Criteria

- PR created with `Fixes #N` in the body
- Branch pushed to remote
- Comment posted on the issue linking to the PR
- All tests pass (or pre-existing failures documented)
