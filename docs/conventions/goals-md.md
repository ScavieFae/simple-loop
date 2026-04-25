# Goals.md — the queue

`.loop/state/goals.md` is the daemon's queue source and the human-readable overview of current priorities. Three sections, strictly structured.

## Structure

```markdown
# Goals

## Awaiting Mattie (not queued)

- [ ] brief-NNN-slug — [reason blocked]

## Credential-gated — NOT dispatchable

- [ ] brief-NNN-slug — needs X

## Queued next

- [ ] brief-NNN-slug
- [ ] brief-NNN-slug
```

## Queue semantics

- **Queued next** — daemon-dispatchable. The queen reads this section, picks the first unchecked item, and dispatches it. Order is priority order.
- **Awaiting** — human-in-the-loop dependency. Not dispatchable until the dependency resolves. The queen skips these.
- **Credential-gated** — requires live credentials (OAuth, API keys, SSH) the daemon can't hold. Not dispatchable. These are work items waiting for a human to ungate them.

## The "not dispatchable" philosophy

Some work shouldn't be automated. Credential-gated briefs are an explicit acknowledgment that automation has limits — not a failure state. Keeping them visible (rather than hiding them in a backlog) makes human-in-the-loop dependencies transparent.

## Updating the queue

The queen marks items complete (checks them off) when a brief merges. The human adds new items. Nothing else edits goals.md automatically.

When a brief completes: the queen moves it from `## Queued next` → checked off. The human decides what comes next and moves it up the queue.
