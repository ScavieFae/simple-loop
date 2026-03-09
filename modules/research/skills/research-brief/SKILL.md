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

## Initialize research state

After writing the brief, initialize all state files in `.loop/modules/research/state/`:

### findings.md
Create with section headers derived from the brief's questions:
```markdown
# Findings: [Topic]

## [Question 1 as heading]

(no findings yet)

## [Question 2 as heading]

(no findings yet)

...

## Sources
```

### sources.json
**Seed with starting points.** Parse any URLs, repo paths, paper titles, or file paths from the brief's "Starting points" section. Each becomes a pre-loaded source entry:

```json
[
  {
    "url": "https://example.com/paper",
    "type": "web_page",
    "title": "From starting points",
    "status": "found",
    "summary": "Provided as starting point — not yet read",
    "found_at_iteration": 0
  }
]
```

Use `"found_at_iteration": 0` to mark these as pre-seeded. The worker will see them as unread sources and prioritize reading them in early iterations.

For local file paths (e.g., a repo directory or a specific file the user points to), use `"type": "file"`. For GitHub repo URLs, use `"type": "repo"`.

If no starting points are provided, initialize as an empty array `[]`.

### coverage.json
Initialize with all questions from the brief set to "open":
```json
{
  "questions": [
    {
      "question": "The exact question text from the brief",
      "status": "open",
      "source_count": 0,
      "confidence": "low",
      "notes": ""
    }
  ],
  "overall_coverage": 0.0
}
```

### search-log.jsonl
Empty file.

### eval-log.jsonl
Empty file.
