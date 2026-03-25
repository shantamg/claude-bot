# Stage: Complete

## Input

- Issue number from arguments
- Latest meta tag with `"phase":"synthesis_complete"`

## Process

1. **Swap labels** on the issue:
   - Remove `bot:expert-review`
   - Add `expert-review-complete`
2. **Post final comment** confirming review is complete with meta tag: `<!-- bot-expert-review-meta: {"phase":"complete","experts":[...],"current_expert_index":N} -->`

## Output

Labels swapped and final comment posted.

## Completion

This is the final stage. The expert review process is complete.
