---
name: pull
description: Post-pull orientation — absorb what changed, scan HANDOFF and RUNNING for new context, report to user. Use when starting a session, after a git pull, or when the user says "pull", "catch me up", "what changed", or "orient".
disable-model-invocation: true
user-invocable: true
---

# /pull — Orient, Absorb, Align

Post-pull intake workflow. The mirror of /push. Every pull is a reorientation — absorb what changed while we were away, pick up context, align on priorities.

This is a read-heavy workflow. The only file written is the last-pull state. Everything else is a briefing to the user.

## Step 1: Pull + Diff

Pull from origin and understand what came in.

```bash
git pull
git log --oneline HEAD@{1}..HEAD    # what landed
git diff --stat HEAD@{1}..HEAD      # scope of changes
```

If already up to date, skip to Step 2 (the scan is still valuable at session start).

## Step 2: Spawn Scanners

Launch two subagents **in parallel** to scan the living documents. HANDOFF.md and RUNNING.md grow over time — the primary agent should NOT read them directly once they're large. Subagents scan and return concise digests.

### Scanner A: HANDOFF Scanner

Spawn an **Explore** agent:

> Read `HANDOFF.md`. Find all entries that are new since [last pull timestamp from `.loop/state/last_pull.json`, or "the last 7 days" if no state file exists].
>
> For each new entry, extract:
> - **Summary**: 1-2 sentence summary of what changed and why
> - **Action items**: anything we need to do, review, or respond to
> - **Open questions**: anything directed at us that needs an answer
>
> Return a structured digest. Be concise — the primary agent will relay this to the user.

If HANDOFF.md doesn't exist or is empty, Scanner A reports "No HANDOFF entries."

### Scanner B: State Scanner

Spawn an **Explore** agent:

> Scan project state for changes since last pull. Check:
>
> 1. **`RUNNING.md`** — Read the 3 most recent entries. Summarize: what was worked on, key findings, open items.
>
> 2. **Recent git activity** — `git log --oneline -10` and `git log --oneline -5 --all` to catch branch activity.
>
> 3. **Any `.loop/state/` changes** — Check for modified state files (running.json, signals, etc.)
>
> Return a structured situation report. Be concise.

If RUNNING.md doesn't exist, Scanner B skips that section.

## Step 3: Update Last-Pull State

Write `.loop/state/last_pull.json`:

```json
{
  "timestamp": "2026-03-14T12:00:00",
  "commit": "abc1234",
  "branch": "main"
}
```

This is used by future /pull runs to filter "what's new." Create `.loop/state/` if it doesn't exist.

If there's no `.loop/` directory (project hasn't run `loop init`), write to `.claude/last_pull.json` instead (gitignore it).

## Step 4: Report

Combine the scanner results into a concise briefing:

```
## Pull Briefing

**Incoming:** [N commits / up to date]

### HANDOFF
[Digest from Scanner A — new entries, action items, open questions]

### State
[Digest from Scanner B — recent work, findings, branch activity]

### Suggested Focus
[Based on what's new: what should we work on this session?]
```

Keep it tight. The user wants to orient in 30 seconds, not read a report.

## Extending /pull

Projects with additional post-pull needs (experiment status scans, interface contract alerts, deployment state checks) can create a project-level `/pull` skill in `.claude/skills/pull/SKILL.md` that wraps or replaces this one. The core steps — pull, scan, report — are the foundation.
