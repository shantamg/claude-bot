# Stage: Initialize

## Input

- Issue number(s) from arguments
- Issue body and any existing comments

## Process

1. **Read the issue** body and all comments via `gh issue view` and `gh issue view --comments`
2. **Check for existing meta tag**: if `<!-- bot-expert-review-meta: ... -->` already exists with `phase` beyond `"roster"`, skip to the appropriate stage (02, 03, or 04)
3. **Select 4 expert personas** from the pool below. Choose the 4 most relevant to the issue's domain. The expert closest to implementation MUST go **last**.

### Expert Pool

These are the default experts. Projects can override this workspace to add
domain-specific experts (e.g., "iOS accessibility specialist", "database
reliability engineer", "compliance officer").

| Expert | Strength |
|---|---|
| Psychologist | User motivation, behavior patterns, mental models |
| Game developer | Engagement loops, progression systems, reward mechanics |
| UX designer | Interface clarity, interaction patterns, accessibility |
| Product engineer | Feasibility, technical debt, implementation tradeoffs |
| Data scientist | Metrics, experimentation, data-driven decisions |
| Security engineer | Threat modeling, auth, data protection |
| Behavioral economist | Incentive design, decision architecture, nudges |
| Educator | Learning curves, scaffolding, knowledge transfer |
| Clinical researcher | Evidence standards, study design, bias detection |
| Systems architect | Scalability, reliability, system boundaries |
| Business strategist | Market positioning, competitive analysis, ROI |
| Growth marketer | Acquisition funnels, retention, viral mechanics |
| DevOps engineer | Deployment, observability, incident response |
| Technical writer | Documentation clarity, API ergonomics, onboarding |
| Accessibility specialist | WCAG compliance, assistive tech, inclusive design |

> **Extending the pool**: To add project-specific experts, create a workspace
> override at `bot/workspaces/expert-review/` in your project repo and edit
> this table. The framework uses cascade resolution — your override takes priority.

4. **Post roster comment** to the issue with:
   - Numbered list of selected experts with one-line rationale for each
   - Meta tag: `<!-- bot-expert-review-meta: {"phase":"roster","experts":[...],"current_expert_index":0} -->`

## Output

One comment posted to the issue containing the expert roster and meta tag.

## Completion

Stage complete. On next invocation, stage 02 (`02-review-cycle`) takes over based on the `"roster"` phase in the meta tag.
