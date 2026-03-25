# PR Creation Skill

Create a pull request with pre-flight checks, documentation updates, and issue linking.

## Stages

1. **Pre-flight** — verify not on the default branch, run the project's test and type-check commands
2. **Docs update** — review diff, update affected documentation
   1. Run `git diff main...HEAD --name-only` to identify all changed files
   2. If the project has a docs-to-code mapping file (e.g., `docs/code-to-docs-mapping.json`), check it for affected docs. Otherwise, scan the `docs/` directory for content related to the changed code.
   3. For each affected doc:
      - Read the doc and verify it still matches the code changes in this PR
      - Update any content that is now inaccurate or incomplete
      - If the project uses frontmatter, set the `updated` field to today's date
   4. If a new feature was built and no doc exists for it, create one in the appropriate `docs/` section
   5. Commit all doc updates on the feature branch before creating the PR
   6. The `## Docs updated` section in the PR body MUST list every doc that was created or modified, or explicitly state why no doc changes were needed (e.g., "No doc changes needed — test-only PR")
3. **Detect linked issues** — scan branch name, commit messages, and prompt context for `#<number>` references
4. **Analyze changes** — generate 3-7 user-friendly bullet points from diff
5. **Create PR** — push branch, `gh pr create` with HEREDOC body
6. **Tag for bot review** — if the project uses a pr-reviewer workspace, add the appropriate label:
   ```bash
   gh pr edit <number> --add-label "bot:needs-review"
   ```

## PR Body Format

```
## Changes
- Add: ...
- Fix: ...

Fixes #<issue-number>

## Provenance
- **Channel:** ...
- **Requested by:** ...
- **Original message:** ...
- **Prompt(s) used:** ...

## Docs updated
- `docs/path/...` (or "No doc changes needed")
```

## Critical Rules

- `Fixes #N` MUST appear for each linked issue (GitHub auto-close syntax)
- Provenance section required on all PRs (if provenance metadata was provided)
- Never force-push to someone else's branch
- Do NOT use `--reviewer` flags or @ mention specific people — let GitHub's CODEOWNERS and branch protection rules handle review assignment automatically
- Always add `bot:needs-review` label after creating a PR if the project uses a pr-reviewer workspace
