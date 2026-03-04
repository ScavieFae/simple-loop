# Simple Loop

An autonomous agent loop for Claude Code. Write a brief, start the daemon, watch it build.

Simple Loop gives any project a lightweight autonomous development loop: a daemon that runs Claude Code sessions to implement tasks from structured briefs, tracks progress, evaluates results, and reports costs.

## How it works

1. **You write a brief** — a short document that says what to build, broken into single-iteration tasks
2. **The daemon runs workers** — each worker is a fresh Claude Code session that does ONE task, verifies it, commits, and exits
3. **The conductor evaluates** — when a brief is done, the conductor reviews the work and decides: merge, fix, or escalate
4. **You get notified** — push notifications via ntfy.sh on completions, failures, and escalations

The human stays at the director level (WHAT to build), the agents handle the implementation (HOW to build it).

## Quick start

```bash
# Install
git clone <this-repo> ~/simple-loop
bash ~/simple-loop/install.sh

# Set up a project
cd your-project
loop init          # answer ~5 questions
loop brief "add user authentication"   # write a brief with the spec agent
loop start         # start the autonomous loop
loop status        # check progress
loop logs -f       # watch it work
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- Python 3.8+
- Git
- Bash

## CLI Reference

| Command | Description |
|---------|-------------|
| `loop init` | Interactive project setup — creates `.loop/` directory |
| `loop brief "title"` | Write a brief with the spec agent (interactive) |
| `loop brief --no-interactive "title"` | Create brief from template, open in `$EDITOR` |
| `loop start [interval]` | Start the daemon (default: 300s idle heartbeat) |
| `loop stop` | Stop the daemon |
| `loop status` | Show daemon state, active brief, recent logs |
| `loop logs [-f]` | Show/follow daemon logs |
| `loop pause [reason]` | Pause daemon — commits + pushes signal |
| `loop resume [instruction]` | Resume daemon — commits + pushes signal |
| `loop metrics [--since DATE]` | Cost report from metrics |
| `loop help` | Usage |

## Project structure

After `loop init`, your project gets a `.loop/` directory:

```
.loop/
├── config.sh          # Project settings (heartbeat interval, verify command, etc.)
├── agents/            # Agent definitions (customizable)
│   ├── spec.md        # Brief-writing partner
│   ├── coder.md       # Implementation agent
│   ├── reviewer.md    # Code review agent
│   └── researcher.md  # Investigation agent
├── prompts/
│   ├── worker.md      # Per-iteration rules for the coder
│   └── conductor.md   # Heartbeat prompt for the loop controller
├── briefs/            # Brief definitions go here
├── state/
│   ├── running.json   # Active/completed/history
│   ├── goals.md       # What to build (you write this)
│   ├── metrics.jsonl  # Cost and token data per session
│   ├── log.jsonl      # Decision log
│   └── signals/       # pause.json, resume.json, escalate.json
├── evaluations/       # Post-brief eval cards
├── knowledge/
│   └── learnings.md   # Agent-writable knowledge base
└── logs/              # Session logs (gitignored)
```

## Configuration

Edit `.loop/config.sh`:

```bash
PROJECT_NAME="my-project"
HEARTBEAT_INTERVAL=300        # Seconds between idle heartbeats
WORKER_COOLDOWN=30            # Seconds between worker iterations
MAX_ITERATIONS=20             # Safety limit per brief
NTFY_TOPIC="my-topic"        # ntfy.sh push notifications (empty = off)
VERIFY_CMD="npm test"         # Run after each task (empty = skip)
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
```

## Brief format

```markdown
# Brief: Add user login

**Branch:** brief-001-add-login
**Model:** sonnet

## Goal
Add JWT-based login to the API. Users POST credentials, get back a token.

## Tasks
1. Create auth middleware that validates JWT tokens
2. Add POST /login endpoint that issues tokens
3. Add token refresh endpoint

## Completion Criteria
- [ ] POST /login returns JWT with 1h expiry
- [ ] Protected routes reject invalid tokens
- [ ] Token refresh extends session

## Verification
- npm test passes
- No new lint warnings
```

## The four agents

| Agent | Role | When it runs |
|-------|------|-------------|
| **spec** | Brief-writing partner | `loop brief` — interactive session |
| **coder** | Implementation | Each worker iteration (daemon-spawned) |
| **reviewer** | Code review | Evaluation phase (conductor-spawned) |
| **researcher** | Investigation | On demand for unfamiliar territory |

Customize any agent by editing the files in `.loop/agents/`.

## Push notifications

Simple Loop uses [ntfy.sh](https://ntfy.sh) for push notifications. Set `NTFY_TOPIC` in config.sh and install the ntfy app on your phone.

Events that trigger notifications:
- Daemon started/stopped
- Worker iteration completed
- Worker failure
- Brief completed (awaiting evaluation)
- Brief merged
- Rate limit hit
- Escalation (needs human attention)

## Multi-machine support

The daemon commits state to git and pushes. You can:
- Run the daemon on a remote machine
- Pause/resume from any machine via `loop pause` / `loop resume` (signals are git-committed)
- Check status from anywhere via `loop status`

## Cost tracking

Every Claude Code session logs cost, tokens, and duration to `.loop/state/metrics.jsonl`. Run `loop metrics` for a report:

```
# Loop Metrics Report

## Cost Summary
- Total: $4.23
- Worker (productive): $3.81 (90%)
- Conductor (overhead): $0.42 (10%)
- Worker iterations: 12
```

## Philosophy

Simple Loop extracts a pattern that emerged over 40+ cycles of autonomous development: the daemon heartbeat, structured briefs, fresh sessions per task, cost tracking, and push notifications. It's not a framework — it's a kit. Take what works, customize what doesn't, delete what you don't need.

The key insight: **autonomous agents work best with clear, well-scoped briefs and mechanical iteration**. The daemon handles the boring parts (git sync, branch management, progress tracking, notifications). The human stays at the director level. The agents do the work.

## License

MIT
