---
name: research-tick
description: Run one iteration of the research loop — search, read, or synthesize based on current coverage
---

# Research Tick

Execute one iteration of the research loop. This skill is called repeatedly — either by the daemon, by `/loop`, or manually.

## Process

1. **Read the active research brief** from `.loop/briefs/` (the most recent research-* brief with status "running")
2. **Read the research module config** from `.loop/modules/research/config.json`
3. **Dispatch a research worker** using the Agent tool:
   - Use `subagent_type: "general-purpose"`
   - Pass the research worker agent prompt from the module
   - Include paths to: brief, findings.md, sources.json, coverage.json, search-log.jsonl
   - The worker performs one action and updates state files
4. **Check if evaluation is due** (every `eval_interval` iterations):
   - If yes, dispatch the evaluator agent
   - Evaluator updates coverage.json and writes to eval-log.jsonl
   - If evaluator says STOP, mark the brief as "complete"
5. **Check iteration count** against max_iterations
   - If exceeded, mark brief as "complete" with note "max iterations reached"
6. **Update HANDOFF.md** if the brief completes (summary of findings)

## State paths

All state lives in `.loop/modules/research/state/`:
- `findings.md` — accumulated findings
- `sources.json` — sources examined
- `coverage.json` — per-question coverage
- `search-log.jsonl` — search history
- `eval-log.jsonl` — evaluator decisions

## Completion

When the brief is complete (evaluator STOP or max iterations):
1. Write a completion summary to HANDOFF.md
2. Mark the brief status as "complete" in progress tracking
3. Send notification if ntfy is configured
