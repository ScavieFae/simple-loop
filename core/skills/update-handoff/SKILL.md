---
name: update-handoff
description: Append an entry to HANDOFF.md — notes for collaborators about what changed and why
---

# Update HANDOFF.md

Append a new entry to `HANDOFF.md` at the top of the file (below the header). HANDOFF.md is reverse chronological — newest entries first.

## Entry format

```markdown
## [Date] — [Brief title or summary]

[What changed. What a collaborator (human or Claude) needs to know to understand and review this work. Be specific about files modified, decisions made, and anything that might surprise a reader.]

[If there are open questions or things the collaborator should verify, list them.]
```

## Rules

- **Always append, never edit or delete existing entries.** HANDOFF.md is append-only.
- **Write for someone who wasn't here.** They don't have your context. Be explicit.
- **Include the "why" not just the "what."** "Changed X because Y" is useful. "Changed X" is not.
- **Reference specific files and lines** when relevant.
- **Keep entries concise but complete.** A few paragraphs, not a page. Not a single line either.
- **Use today's date** in the entry header.
- **This is documentation.** It will be read by future collaborators. Write accordingly.
