# Stage: Investigate

## Input

- Issue number (from prompt or `gh issue view`)
- Project docs routing table (from project CLAUDE.md)

## Process

1. **Read the issue** — understand what needs to be investigated. Look for:
   - Specific questions to answer
   - Features to verify ("does this work?", "how does this behave?")
   - Areas to explore before planning implementation
   - Vague requirements that need scoping

2. **Research the codebase** — use sub-agents for parallel exploration:
   - Read relevant docs (use the docs routing table)
   - Find related code (grep for key terms, read implementations)
   - Check test coverage for the area
   - Look at recent git history for context on how the area evolved
   - If the issue references other issues, read those too for context

3. **Assess current state** — for each aspect of the issue:
   - What exists today? (working, partial, missing)
   - What would need to change?
   - What are the dependencies or risks?
   - Are there related issues or PRs that overlap?

4. **Post findings as a comment** on the issue:

   ```
   ## Research Findings

   ### Current State
   - [What exists, what works, what doesn't]

   ### What Would Need to Change
   - [Specific files, components, APIs that would be affected]

   ### Dependencies & Risks
   - [Other issues, features, or systems this depends on]
   - [Potential conflicts or risks]

   ### Scope Estimate
   - [Small / Medium / Large]
   - [Key unknowns that affect scope]

   ### Recommendations
   - [Suggested approach, open questions for humans]

   ---
   *Researched by bot — no code changes made*
   ```

5. **Swap labels**:
   - Remove `bot:research`
   - Add `researched`

## Critical Rules

- **Do NOT create branches, modify files, commit, or create PRs**
- **Do NOT run commands that modify state** (no `git checkout -b`, no file writes)
- Only use read-only tools: Read, Grep, Glob, Bash (for `gh` CLI queries, `git log`, `git blame`)
- If the investigation reveals the issue is a duplicate, note it in findings but do NOT close the issue

## Output

- Structured findings comment posted on the issue
- Labels swapped (`bot:research` → `researched`)

## Completion

Single-stage workspace. Complete after findings are posted.
