<!-- simple-loop:autoresearch -->

## Autoresearch Module

This project has the simple-loop **autoresearch** module installed. It runs an autonomous experiment loop: a hypothesis agent proposes one change at a time, a research-director gates the proposal, an executor runs it, and the director evaluates the result against a tracked best.

### How it works

The loop is a heartbeat — invoke `/conductor` to run one tick, or schedule it (e.g., `/loop 60m /conductor`). Each tick:

1. Reads `running.json`, `budget.json`, `signals/`, recent decisions.
2. Closes out any finished in-flight experiments (Director evaluates, updates `best.json` if kept).
3. If slots and budget allow, runs a new cycle: Hypothesis proposes → Director approves/rejects → Executor implements on a branch → experiment launches.

The full step-by-step lives in `.loop/modules/autoresearch/prompts/conductor.md`.

### Agent roles

| Agent | File | Job |
|-------|------|-----|
| Hypothesis | `.loop/modules/autoresearch/agents/hypothesis.md` | Propose one falsifiable experiment per cycle, grounded in prior results and literature |
| Research Director | `.loop/modules/autoresearch/agents/research-director.md` | Gate hypotheses (single-variable, falsifiable, not a repeat); evaluate completed results |
| Executor | `.loop/modules/autoresearch/agents/executor.md` | Take an approved run card, write the config, launch the experiment, capture results |

### Budget gate

The conductor refuses to dispatch new work when `daily_spent + estimated_cost > daily_limit`. Limits live in `.loop/modules/autoresearch/config.json`. Experiments above `scale_tier_threshold` always escalate to the human.

### State

All experiment state lives in `.loop/modules/autoresearch/state/`:
- `budget.json` — daily/weekly limits + spend tracking + experiment counts
- `best.json` — current best result, config, metrics, and history of kept experiments
- `running.json` — `experiments.in_flight[]`, `history`, `prior_best`

### The /consult-empirical skill

Available as `/loop-autoresearch-consult-empirical`. Use it before proposing a new experiment direction or when interpreting results — it queries the project's experiment history (run cards, decisions, hit rates) and answers from the actual records, not general knowledge.

### Project conventions this module assumes

- A `program.md` at the project root describing research directions and known results
- `docs/run-cards/` for individual experiment records
- `docs/decisions/` for hypothesis rejections and Director reasoning
- A `RUNBOOK.md` (or similar) documenting how to launch an experiment in this project's stack

If those don't exist yet, the conductor will still run but won't have much context to work from. Set them up before relying on autonomous cycles.

<!-- /simple-loop:autoresearch -->
