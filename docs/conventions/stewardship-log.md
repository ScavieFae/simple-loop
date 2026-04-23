# Stewardship log

`.loop/state/stewardship-log.md` is the append-only narrative record of non-automated interventions — actions taken on behalf of the human operator outside the daemon's normal flow.

## Format

Each entry is an H3 with timestamp, action, and rubric:

```markdown
### 2026-04-23 14:30 — hand-merged brief-015

**Action:** Merged `brief-015-nav-cleanup` manually.
**Why:** Daemon push was keychain-locked; brief had passed validation 2 hours earlier.
**Rubric:** Validator approved, eval clean — objective-green merge, no taste gate.
**What to know in the morning:** Push auth needs fixing. See daemon-push-auth.md.
```

## When to log

Log any intervention that touches the queue flow or project state outside the daemon's normal operation:

- Manual merges
- Writing `pending-dispatch.json` directly
- Moving a brief to `awaiting_review`
- Restarting the daemon
- Approving a brief outside the standard review window
- Editing `running.json` directly
- Archiving a resolved escalation signal

Skip: routine observations, reading state files, checking logs. The log is for actions, not observations.

## Intervention rubric

| Type | Act? | Note |
|------|------|------|
| Objective-green merge (validator passed, no open questions) | Yes | Log it |
| Taste-gated merge (aesthetic, voice, feel) | Hold | Human call |
| New brief, new priority, goals.md changes | Hold | Not a steward job |
| Code edits or non-routine patches | Hold | Not a steward job |
| Daemon restart when HUNG | Yes | Log it |
| Archive a resolved escalation signal | Yes | Log it |

## Why it exists

The daemon automates the repeatable; the stewardship log documents the exceptional. Together they make overnight work auditable: reading the log takes 60 seconds and tells you exactly what a session did on your behalf.
