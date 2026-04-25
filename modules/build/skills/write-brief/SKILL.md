---
name: write-brief
description: Write a build brief interactively — decompose work into scoped tasks for autonomous execution
---

# Write a Build Brief

Start an interactive session with the spec agent to write a build brief.

## Process

1. **Read SPEC.md** for project context and current priorities
2. **Read `.loop/briefs/`** to determine the next brief number
3. **Engage the spec agent** — use the spec agent prompt from the build module to help decompose the work
4. **Write the brief** to `.loop/briefs/brief-NNN-slug.md`
5. **Initialize progress.json** for the brief (status: "queued", empty tasks arrays)
6. **Show the brief** to the user for review before it's dispatched

## Notes

- The brief is not dispatched automatically. The user reviews and the queen picks it up.
- If the user provides a title as an argument, use it as the starting point.
- Reference SPEC.md priorities when helping scope the work.
