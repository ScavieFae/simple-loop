# Brief: [title]

**ID:** brief-NNN-slug
**Branch:** brief-NNN-slug
**Status:** queued
**Model:** sonnet
**Auto-merge:** true
**Post-merge review:** [describe if eyes-on needed]
**Validator:** core/agents/reviewer.md

!!! abstract "Intent"
    One sentence. The artifact that exists when this brief is done.

## Motivation

Two or three sentences. Why this, why now, what breaks if we skip it.

## Starting context

!!! info "Pointers — read these first"
    1. `path/to/relevant/file.md` — what it contains
    2. `path/to/other/file` — what it contains

## Scope

### In

- Specific thing this brief covers

### Out

- Specific thing this brief does NOT touch

## Tasks

1. **Task one.** Description.
2. **Task two.** Description.
3. **Task three.** Description.

## Completion criteria

- [ ] Criterion one
- [ ] Criterion two
- [ ] Criterion three

## Escalation triggers

- Build fails three cycles in a row
- Dependency needed that isn't in the workspace
- Scope turns out to be 2× estimated

## Budget

**N cycles.** If at cycle N−2 and 3+ tasks are still incomplete, escalate rather than rushing.

## Anti-patterns

- Don't refactor beyond what the cycle requires
- Don't touch [specific area] — that's a different brief
- Don't add features not in scope

## Artifact

What lands when this brief closes? Where does it live?

## Verification

```bash
# Commands to confirm completion criteria pass
```
