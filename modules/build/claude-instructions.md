<!-- simple-loop:build -->

## Build Module

This project has the simple-loop build module installed. It enables autonomous development — structured briefs dispatched to workers that implement, verify, and commit one task at a time.

### How it works

Build briefs in `.loop/briefs/brief-*.md` define scoped work. The build loop: queen dispatches → worker implements one task → verifies → commits → repeats until all tasks done → queen evaluates → merges or escalates.

### Key files

- `SPEC.md` — source of truth for what to build. Briefs derive from this.
- `.loop/briefs/` — build briefs (queued, active, completed)
- `.loop/modules/build/state/running.json` — brief lifecycle state
- `.loop/modules/build/state/learnings.md` — accumulated knowledge from workers
- `.loop/evaluations/` — post-brief evaluation cards

### Writing briefs

Use the `write-brief` skill or create manually in `.loop/briefs/`. Each brief has:
- Goal (from SPEC.md priorities)
- Tasks (3-7, each one worker iteration)
- Completion criteria (binary, observable)
- Verification (automated command)

### Dispatching research during builds

Workers can dispatch the core research agent when they need to understand unfamiliar code or APIs. Use the Agent tool to spawn a research subagent — it returns findings without disrupting the worker's context.

### Persistent docs

When doing build work:
- **RUNNING.md** — log each iteration: what was implemented, issues encountered
- **HANDOFF.md** — summarize completed briefs for collaborator review
- **TROUBLESHOOTING.md** — document bugs that required investigation

### Agent Teams

This module works best with Agent Teams enabled (`claude config set enableAgentTeams true`). Workers and the reviewer agent are dispatched as subagents via Agent Teams.

<!-- /simple-loop:build -->
