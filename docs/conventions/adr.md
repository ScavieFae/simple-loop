# Architecture decision records

ADRs are the permanent record of contested choices. When a technical or design direction gets committed — after a riff develops enough, or when a decision comes up in conversation — write it down.

## Why we write them

Decisions get revisited. Without a record of *why*, reversals feel arbitrary and history repeats. ADRs make the reasoning durable.

## Format

File name: `NNN-short-slug.md` in `wiki/decisions/`. Number sequentially from 001.

```markdown
# ADR-NNN: Title

**Date:** YYYY-MM-DD
**Status:** accepted | superseded by ADR-NNN

## Context

What's the situation? What problem does this decision address?

## Decision

What did we choose?

## Consequences

What does this decision close off? What does it enable? What do we live with?

## Alternatives considered

| Alternative | Why not |
|-------------|---------|
| Option A | Reason |
| Option B | Reason |
```

## When to write one

Write an ADR when:

- A contested technical choice gets resolved
- A riff reaches `tested` status and commits to a direction
- A decision reverses a previous one (new ADR supersedes the old)
- Someone asks "why did we do it this way?" and the answer isn't obvious from the code

Don't write an ADR for every micro-decision — just the ones where the *why* is non-obvious or the alternatives were real.

## Immutability

ADRs are not modified after recording. If a decision reverses, a new ADR supersedes the old one. The old ADR stays (marked `superseded by ADR-NNN`). History stays intact.
