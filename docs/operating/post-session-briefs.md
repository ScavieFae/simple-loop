# Post-session briefs: audit + capture

A pair of lightweight brief types for capturing what happened in a session. Not feature work — process archaeology.

## Types

| Type | Naming | Purpose |
|------|--------|---------|
| **audit** | `audit-YYYY-MM-DD-NNN` | Post-session code scrub. Did the session leave anything broken, half-applied, or inconsistent? |
| **capture** | `capture-YYYY-MM-DD-NNN` | Route observations to persistent homes. Learnings, memory files, wiki pages, decision docs. |

Templates live in `wiki/briefs/` after `loop init --wiki-full`. Add templates if they don't exist yet.

## When to fire

On demand. No schedule. Fire when:

- A session was dense (multiple briefs touched, several bugs debugged) and you don't want the observations to diffuse.
- Something surprising happened that should be generalized, not left in a commit message.
- You're about to leave the machine and want a record before context cools.

Don't fire for routine sessions where the briefs speak for themselves.

## Ceremony (lighter than feature briefs)

Audit and capture briefs skip some of the feature-brief ceremony:

- **No plan.md required** (unless the scope surprises you midway).
- **Validator is optional** — these are routing jobs, not implementation jobs. The completion criteria are self-checking.
- **4-cycle budget** is typical. If you're at cycle 6, either the scope crept or the brief wasn't clear.
- **Auto-merge: true by default** — there's nothing to eyeball before merge. All artifacts are plain markdown.

## Output contract

Each brief specifies its own output contract (`placements.md` for capture, `findings.md` for audit). See the templates.

## Relationship to other brief types

Post-session briefs are meta-briefs — they produce documentation artifacts, not product artifacts. They exist alongside feature briefs in the `cards/` directory but don't have a corresponding roadmap slot.

## Dispatch note

**Dispatch audit/capture briefs via the operator agent directly** (not via the daemon queue) — meta-work shouldn't block product work. The operator initiates; the daemon queue is for product briefs.
