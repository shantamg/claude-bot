# Stage: Review Cycle (Looping)

## Input

- Issue number from arguments
- All issue comments (to find latest meta tag and prior reviews)
- Latest `<!-- bot-expert-review-meta: {...} -->` — contains `phase`, `experts`, `current_expert_index`

## Process

Read all issue comments, find the latest meta tag, and execute the NEXT action based on current phase:

| Current Phase | Next Action |
|---|---|
| `"roster"` | Write Expert 1's review |
| `"expert_review"` | Write devil's advocate pushback for current expert |
| `"pushback"` | Write expert's response to pushback |
| `"response"` | If more experts remain: advance `current_expert_index`, write next expert review. If all done: exit — stage 03 takes over |

### Review Quality Requirements

- **Expert reviews**: 500-1000 words. Substantive, domain-specific terminology. Later experts MUST reference and build on earlier reviews.
- **Pushback**: 200-400 words. 2-4 specific weaknesses. Constructive, citing concrete risks.
- **Response**: 200-400 words. Concede valid points, double down with evidence on strong points.

### Human Comments

If a non-bot comment appears since the last bot comment, acknowledge and incorporate it into the current action.

### Meta Tag Updates

Every comment must include an updated meta tag:
- After expert review: `{"phase":"expert_review","experts":[...],"current_expert_index":N}`
- After pushback: `{"phase":"pushback","experts":[...],"current_expert_index":N}`
- After response: `{"phase":"response","experts":[...],"current_expert_index":N}`
- After final expert's response: `{"phase":"all_reviews_complete","experts":[...],"current_expert_index":N}`

## Output

One comment posted to the issue with the review/pushback/response and updated meta tag.

## Completion

Execute ONE action per invocation. The cron re-invokes for the next step. When `phase` becomes `"all_reviews_complete"`, stage 03 (`03-synthesize`) takes over on next invocation.
