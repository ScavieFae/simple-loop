---
name: update-running
description: Append an entry to RUNNING.md — running log of what agents encounter during work
---

# Update RUNNING.md

Append a new entry to `RUNNING.md` at the top of the file (below the header). RUNNING.md is reverse chronological — newest entries first.

## Entry format

```markdown
## [Date] [Time] — [What you were doing]

[What you encountered. Decisions made and why. Dead ends hit. Surprises found. The texture of the work — not just outcomes, but the process.]

[If you changed approach mid-task, explain the pivot.]
```

## Rules

- **Always append, never edit or delete existing entries.** RUNNING.md is append-only.
- **Write in first person.** This is your running log. "I found..." / "I tried..."
- **Include friction and dead ends**, not just successes. "Searched for X, found nothing useful" is valuable context.
- **Note decisions with reasoning.** "Chose approach A over B because..." helps future agents understand why the codebase looks the way it does.
- **Be honest about uncertainty.** "I think this works but haven't verified edge case Z" is better than silence.
- **This becomes content.** RUNNING.md is a source of truth for understanding how the project evolved. Write with that in mind.
