---
name: push
description: Pre-push workflow — update HANDOFF.md, capture notes in RUNNING.md, then commit and push. Use when the user says "push", "ship it", "send it", or asks to commit and push changes.
disable-model-invocation: true
user-invocable: true
---

# /push — Communicate, Capture, Ship

Pre-push workflow. Every push is a communication touchpoint — with collaborators, with future sessions, with the running record.

Do NOT skip steps or treat this as a formality. Each step exists because context gets lost without it. But DO skip steps that genuinely don't apply (marked with trigger conditions).

## Step 1: Scope Audit

Read the current state. Understand what's going out.

```
git diff --stat origin/$(git rev-parse --abbrev-ref HEAD)..HEAD   (committed but not pushed)
git diff --stat                                                    (unstaged changes to include)
git status                                                         (untracked files)
git log --oneline origin/$(git rev-parse --abbrev-ref HEAD)..HEAD  (commits to push)
```

Report the scope to the user before proceeding. Note whether changes are code, docs-only, config, tests, etc.

## Step 2: HANDOFF.md — Communicate with Collaborators

**Trigger:** Changes touch code, configuration, or anything that affects how other agents or humans interact with the project. Skip for trivial docs-only changes (typo fixes, comment cleanup).

Update `HANDOFF.md` with a new entry at the top (below the header, above the first `---`).

**Entry format** (match the existing style, or use this default):
```markdown
## [Verb]: [Description] ([Author], [Date])

**What changed:** [Substantive description. Not just file names — what the change DOES and WHY.]

**What to know:** [Anything a collaborator needs to understand before touching related code. Cross-boundary effects, assumptions, open questions.]

### Files changed
| File | Change |
|------|--------|
| ... | ... |

---
```

**Write for someone who wasn't here.** They don't have your context. Include the "why" not just the "what."

If HANDOFF.md doesn't exist, create it with:
```markdown
# HANDOFF

Notes between collaborators. Newest entries at top. Append-only.

---
```

## Step 3: RUNNING.md — Capture Notes and Findings

**Trigger:** The session involved reasoning, design decisions, implementation findings, dead ends, or anything worth preserving. Skip only for truly mechanical changes (typo fixes, dependency bumps).

Update `RUNNING.md` with a new entry at the top.

**Entry format:**
```markdown
## [Date] [Time] — [What you were doing]

[What you encountered. Decisions made and why. Dead ends hit. Surprises found. The texture of the work — not just outcomes, but the process.]

[If you changed approach mid-task, explain the pivot.]
```

**Rules:**
- Append-only. Never edit or delete existing entries.
- Write in first person. "Found that...", "Decided to..."
- Include friction and dead ends, not just successes.
- Note decisions with reasoning. "Chose approach A over B because..."
- Be honest about uncertainty. "I think this works but haven't verified edge case Z."
- State findings as observations, not editorials.

If RUNNING.md doesn't exist, create it with:
```markdown
# Running Log

Running notes from work sessions. Newest entries at top. Append-only.

---
```

## Step 4: Commit + Push

1. **Stage specific files.** Never `git add -A` or `git add .`. Name each file. Don't sweep in unrelated changes, secrets (.env), or large binaries.
2. **Write the commit message.** Lead with why, not what. Follow the repo's style (see `git log --oneline -10`).
3. **Commit.**
4. **Push** to origin.
5. **Verify** with `git status` after push.

Report what was pushed (commit hash, files, branch) so the user has a record.

## Extending /push

Projects with additional pre-push needs (experiment tracking, interface contract checks, deploy gates) can create a project-level `/push` skill in `.claude/skills/push/SKILL.md` that wraps or replaces this one. The core steps — scope audit, HANDOFF, RUNNING, commit+push — are the foundation.
