# Stage: Synthesize

## Input

- Issue number from arguments
- All issue comments (all expert reviews, pushbacks, and responses)
- Latest meta tag with `"phase":"all_reviews_complete"`

## Process

1. **Gather all expert perspectives**: read every review, pushback, and response comment
2. **Write synthesis comment** (600-1000 words) containing:
   - **Convergence**: points where multiple experts agree
   - **Divergence**: points of disagreement and why they differ
   - **Consolidated recommendations**: actionable next steps ranked by priority
   - **Risk summary**: key risks identified across all reviews
3. **Post comment** with meta tag: `<!-- bot-expert-review-meta: {"phase":"synthesis_complete","experts":[...],"current_expert_index":N} -->`

## Output

One synthesis comment posted to the issue with updated meta tag.

## Completion

Stage complete. On next invocation, stage 04 (`04-complete`) handles label swap.
