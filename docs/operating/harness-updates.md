# Harness updates — decision tree + restart protocols

The simple-loop harness (daemon + conductor + worker + validator) is live infrastructure. Updating it while it's running is tricky because the thing running the update may be the thing being updated. This doc captures the decision tree we've worked out the hard way.

**Status: living document.** Add entries from every harness-update session. This reflects what we've tripped on, not what we've imagined.

## The decision tree

### 1. Where does the code live?

Three locations, different ownership semantics:

| Location | What's there | Who edits | Effect |
|---|---|---|---|
| `ScavieFae/simple-loop` master (GitHub) | Source of truth for harness code | Maintainer, agents via briefs | Authoritative; changes propagate via `loop update` |
| `~/.local/share/simple-loop/` | Installed copy on this machine | `loop update` pulls from master; can hand-edit for urgent patches | What the daemon actually runs |
| `.loop/prompts/` + `.loop/modules/*/state/` (project-local) | Per-project customization | Project maintainer | Read by daemon each tick; overrides install for this project only |

**The propagation direction:** master → installed (via `loop update`) → project-local (copied on `loop init`, edited per project after).

**Project-local takes precedence** for the daemon on THIS project. If you edit `.loop/prompts/conductor.md` here, the daemon reads your edit, not the installed template.

### 2. Brief vs manual?

Use this rubric:

| Situation | Fix mode |
|---|---|
| Harness isn't processing briefs | **Manual** — briefs can't unblock a queue that doesn't dispatch |
| Single-file prompt / config edit, text-only | **Manual** — 5-minute change, no test harness needed |
| New feature on a working harness | **Brief** — let the loop exercise itself, validator catches drift |
| State-migration / schema change | **Brief with test cases** — fabricate bad state, assert repair |
| Fix that would run through the daemon that's being fixed | **Manual** — circular dependency kills the brief flow |
| Refactor across multiple files with test coverage | **Brief, ideally with research cycle** |

**When unsure, ask:** "if this fix went wrong, would it make the harness *worse* than right now?" If yes → more test coverage, usually means a brief. If no → manual is fine.

### 3. Propagation for manual fixes

When you hand-patch the harness:

- **Project-local only** (`.loop/prompts/*`, `.loop/state/*`, `.loop/knowledge/*`): edit, commit to project, done. Daemon picks up on next tick.
- **Installed copy** (`~/.local/share/simple-loop/`): edit, but **also sync to simple-loop master** via clone-edit-push — otherwise next `loop update` overwrites your fix.
- **Template** (`~/.local/share/simple-loop/templates/`): same as installed — sync to master, or lose the change on next update.

The **"three-way sync"** pattern:

```bash
# 1. Edit project-local (takes effect next tick)
vi .loop/prompts/conductor.md
git commit -m "..." && git push

# 2. Sync to installed template (so `loop update` won't regress)
cp .loop/prompts/conductor.md ~/.local/share/simple-loop/templates/prompts/conductor.md

# 3. Push to simple-loop master (durable across any fresh install)
git clone https://github.com/ScavieFae/simple-loop /tmp/sl-$(date +%s)
cp ~/.local/share/simple-loop/templates/prompts/conductor.md /tmp/sl-*/templates/prompts/conductor.md
cd /tmp/sl-* && git add . && git commit -m "..." && git push
```

### 4. Restart protocols

When does a restart take effect?

| Edit target | Hot-reloaded | Needs daemon restart | Needs `loop update` |
|---|---|---|---|
| `.loop/prompts/*` (conductor, worker, validator) | ✅ next tick (~120s) | — | — |
| `.loop/knowledge/*`, `.loop/state/goals.md` | ✅ next tick | — | — |
| `~/.local/share/simple-loop/lib/daemon.sh` | — | ✅ `loop stop && loop start` | — |
| `~/.local/share/simple-loop/lib/actions.py` | — | ✅ actions invoked fresh per command | — |
| `~/.local/share/simple-loop/templates/*` | — | — | Template's only read by `loop init` / `loop update` |
| `~/.local/bin/loop` | N/A | Shell picks up immediately for new invocations | — |
| `ScavieFae/simple-loop` master | — | — | ✅ `loop update` pulls + installs |

**The trap:** editing `~/.local/share/simple-loop/templates/...` doesn't affect the running daemon until you also copy to `.loop/prompts/...` or the daemon restarts and re-reads. Always edit *both* — or the change doesn't land.

### 5. Verification after a harness update

- Daemon alive: `cat .loop/state/daemon.pid | xargs -I{} ps -p {} -o pid,etime,command`
- Daemon ticking: heartbeat fresh — `cat .loop/state/heartbeat.json` shows `ts` within 2× tick interval
- Conductor running: `tail -5 .loop/state/log.jsonl` — expect `heartbeat_noop` or `daemon:*` events recently
- Queue moving: if something's queued, conductor writes pending-dispatch.json within a tick or two
- No stale signals: `ls .loop/state/signals/` returns clean or expected-live files only

If any of these are wrong post-update, **roll back first, diagnose second.** Harness regressions compound.

### 6. Recovery if a harness update breaks something

- `loop stop` — always first, stops the compounding
- Restore the previous version: `git checkout HEAD~1 -- <file>` for project-local, or pull from `~/.local/share/simple-loop/templates/` for local overrides
- For install-level damage: `loop update` pulls fresh from master — only works if master isn't what broke
- Hard reset of `~/.local/share/simple-loop/`: `rm -rf ~/.local/share/simple-loop && loop install` — last resort

### 7. Known escape hatches (ordered by "least invasive")

If the daemon's misbehaving but you need work to move:

1. **Write `pending-dispatch.json` manually** to unblock a specific brief (conductor failed to dispatch it)
2. **Write `pending-merge.json` manually** to approve a brief without daemon ceremony (or use `loop approve <brief-id>` which does the same thing — always prefer the CLI)
3. **Hand-merge a brief on main** via `git merge --no-ff <branch>` when the daemon's stuck in a state-mismatch or other internal error (see [hand-merge-brief.md](hand-merge-brief.md))
4. **Stop the daemon entirely** and run cycles by dispatching loop-coder agents directly from the main-thread session
5. **Clean running.json by hand** (pure-JSON edits) to prune stale active entries or backfill missed merges — last-resort because it's easy to corrupt state further

Each escape hatch is a signal the harness wanted something it didn't have. File that observation somewhere durable (`.loop/knowledge/learnings.md`, or a runway entry for the permanent fix).

## Script-over-inference

An emerging pattern: when an agent needs to produce a deterministic, repeatable output (a timestamp, a UUID, a hash, a structured log line in a fixed schema), **write a script the agent calls** instead of asking the LLM to produce the output directly. The agent passes fields; the script handles the mechanics.

### Why

LLMs hallucinate under token pressure, especially for values with statistical structure (round numbers, round minutes, plausible-looking IDs). Writing a script costs ~30 lines and ~0 inference tokens per call. Re-prompting the LLM to "please use real timestamps" costs tokens every invocation and works until it doesn't.

### When to reach for this

- The output is **deterministic** (wall-clock time, repo hash, env lookup, config read)
- The output has **statistical structure the LLM will drift toward** (round numbers, templated IDs, schema-shaped JSON)
- The call happens **often** (log event per tick, metrics emission per cycle) — per-call savings compound
- A **downstream consumer trusts the field** (TUI reading ts, validator reading verdict). Trust + hallucination is the combination that silently breaks things.

### When NOT to reach for this

- **Taste calls.** Deciding merge vs fix vs escalate *is* the LLM's job. Don't script a taste gate.
- **One-off operations.** Writing a script for a job that runs twice is over-engineering.
- **Inputs the LLM needs to reason about.** If the agent needs to synthesize the value from context, keep it in the prompt. Only script the *output plumbing* after the thinking is done.

### Companion discipline: pin model versions

Script-over-inference removes hallucination from one surface. Model-version drift removes reproducibility from another. When `claude --model opus` resolves to whatever ships as "latest opus," a silent upgrade can change agent behavior overnight. Pin specific model IDs in daemon invocations when the behavior matters.

Current scripts in simple-loop:
- `scripts/log-event.py` — injects wall-clock `ts`, appends to `.loop/state/log.jsonl`

## Contribution rule

**Add an entry here after any harness-update session.** Include: what you changed, where it lived, what propagation you did, what broke along the way, how you recovered. Running log of earned knowledge.
