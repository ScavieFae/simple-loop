---
name: research-brief
description: Create a research brief — define questions, scope, and depth for autonomous research
---

# Create a Research Brief

Help the user write a research brief that can be executed autonomously by the research module.

## Process

1. **Ask what they want to research.** Get the core topic or question.
2. **Help decompose into specific questions** (3-7 questions is ideal).
   - Each question should be answerable with evidence, not opinion
   - Questions should be independent enough to research in parallel
   - Ask: "What would a good answer look like?" to sharpen vague questions
3. **Define scope:**
   - What sources are in scope? (web, papers, codebases, specific domains)
   - What's explicitly out of scope?
   - Any known starting points? (URLs, repos, authors)
4. **Set depth:**
   - Target iteration count (10-15 for shallow survey, 20-30 for deep investigation)
   - Coverage threshold — stop when N% of questions answered?
5. **Write the brief** to `.loop/briefs/`

## Brief format

```markdown
# Research: [Topic]

## Questions

1. [Specific, answerable question]
2. [Specific, answerable question]
...

## Scope

- **In scope:** [What to search]
- **Out of scope:** [What to skip]
- **Starting points:** [Known URLs, repos, papers if any]

## Depth

- **Target iterations:** [number]
- **Stop when:** [coverage threshold or specific condition]

## Output

- [What the findings doc should contain]
- [Any specific format requirements]
```

## Save location

Save the brief to `.loop/briefs/research-NNN-slug.md` where NNN is the next available number.

Initialize the research state:
- `.loop/modules/research/state/findings.md` — empty with section headers from questions
- `.loop/modules/research/state/sources.json` — empty array (or seed with starting points)
- `.loop/modules/research/state/coverage.json` — all questions "open"
- `.loop/modules/research/state/search-log.jsonl` — empty
- `.loop/modules/research/state/eval-log.jsonl` — empty
