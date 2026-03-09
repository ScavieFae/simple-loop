---
name: file-issue
description: Create a GitHub issue from structured input — used by agents to report bugs, request features, or track work
---

# File a GitHub Issue

Create a GitHub issue on the project's repository. Used by agents when they encounter something that should be tracked — a bug they can't fix inline, a feature gap, a design question that needs human input.

## Process

1. **Determine the repo** from git remote origin, or ask if ambiguous
2. **Classify**: bug, feature request, or discussion
3. **Write the issue:**
   - **Title**: Short, specific, starts with a verb ("Fix ...", "Add ...", "Investigate ...")
   - **Body**: Context, reproduction steps (for bugs), proposed approach (if known)
4. **Create with `gh issue create`**
5. **Report the issue URL back**

## Issue body format

For bugs:
```markdown
## Symptom
[What's broken]

## Reproduction
[Steps or conditions]

## Expected behavior
[What should happen]

## Context
[Relevant logs, file paths, commit hashes]
```

For feature requests:
```markdown
## Problem
[What's missing or painful]

## Proposed approach
[If known — otherwise "needs design"]

## Context
[Why this matters now]
```

## Rules

- **Be public-safe.** No secrets, credentials, or internal-only context in the issue body.
- **Link to related issues** if you know about them.
- **Don't file duplicates.** Check existing issues first with `gh issue list`.
- **Labels are optional.** Only add them if the repo has a clear labeling convention.
