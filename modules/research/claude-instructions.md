<!-- simple-loop:research -->

## Research Module

This project has the simple-loop research module installed. It enables autonomous research — iterative search, reading, synthesis, and coverage evaluation.

### How it works

Research briefs in `.loop/briefs/research-*.md` define questions to investigate. The research loop iterates: search → read → synthesize → evaluate coverage → repeat until questions are answered or max iterations reached.

### Key files

- `.loop/modules/research/state/findings.md` — accumulated findings (the output)
- `.loop/modules/research/state/coverage.json` — which questions are answered
- `.loop/modules/research/state/sources.json` — sources examined
- `.loop/briefs/research-*.md` — research briefs

### Dispatching research agents

The core research agent (`core/agents/research.md`) is available for one-off research tasks within any workflow. Use the Agent tool to dispatch it:

```
Agent tool → subagent_type: "general-purpose"
Prompt: include core/agents/research.md content + the specific question
```

The research agent returns structured findings to the caller. The caller decides what to persist.

### Persistent docs

When doing research work:
- **RUNNING.md** — log what you searched, what you found, decisions made
- **HANDOFF.md** — summarize findings when a research brief completes
- **TROUBLESHOOTING.md** — if you hit errors during research (API failures, broken URLs, etc.)

### Agent Teams

This module works best with Agent Teams enabled (`claude config set enableAgentTeams true`). Research workers are dispatched as subagents, preserving the caller's context while the worker searches and reads independently.

<!-- /simple-loop:research -->
