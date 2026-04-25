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

<!-- Hive parses this section for integers and uses MAX as the cycle budget shown in
     the active-brief indicator (`cycle X/Y`). Keep it short and only mention the
     cycle count integer. No "~200 LOC", "N=10 episodes", "3 days" — they get picked
     up as Y instead of the cycle count. Pattern that works (brief-061): "**6 cycles
     sonnet.** Two cycles per phase + integration tests + docs." -->

**N cycles.** Brief plan in prose; no other integers in this section.

## Anti-patterns

- Don't refactor beyond what the cycle requires
- Don't touch [specific area] — that's a different brief
- Don't add features not in scope

<!-- BRIEF-AUTHORING ANTI-PATTERN — avoid target-shape numerical examples in
     "what should feel if it lands right" or "what good looks like" sections.
     Workers pattern-match the numbers and paste them into review.md TL;DRs as
     if observed (the brief-037 confabulation pattern in narrative form). Use
     shape-only framing ("headline reads N/M with a Wilson CI") or qualitative
     outcomes ("the arm picks up the block"). Real numbers come from real runs,
     committed alongside the artifact. See TROUBLESHOOTING.md (2026-04-25). -->


## Artifact

What lands when this brief closes? Where does it live?

## Verification

```bash
# Commands to confirm completion criteria pass
```
