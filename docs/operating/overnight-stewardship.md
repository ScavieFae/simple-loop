# Overnight stewardship — the pattern that works

**Status:** codified after trying and scrapping a remote-routine approach. Evolves as we learn.

## The honest constraint

The operator agent only runs when invoked. There is no mechanism by default for it to autonomously watch the local simple-loop daemon overnight. The daemon runs on the operator's machine; the agent runs in Claude Code sessions. These don't cross.

**Remote routines (cloud-scheduled Claude agents) don't fix this.** They execute in Anthropic's cloud with a fresh git clone — no access to the local daemon, no installed `loop` CLI, no visibility into local state files that aren't committed. They'd be watching a stale snapshot, unable to actually intervene.

If you want real-time overnight watchdog behavior, the only path is something running on the machine — launchd, a local cron, or a terminal that stays open with `/loop` self-pacing. All of those require participation to set up.

## What works instead

Trust the autonomous system + read the forensic trail in the morning.

1. **Daemon escalates itself when stuck.** The conductor writes `.loop/state/signals/escalate.json` when a brief hits a human-in-the-loop dependency, a hardware ceiling, or an unrecoverable failure. The operator acts on it when next available.
2. **Stewardship-log + metrics accumulate.** Every intervention and every state change leaves a trail. `.loop/state/stewardship-log.md` for narrative events, `.loop/state/log.jsonl` for daemon events.
3. **loop-report script renders the delta on wake.** Runs against existing data sources. `python3 scripts/loop-report.py --since 8h`.
4. **Missing the live window is a real cost** but a bounded one. "Catch a stopper at 3am" is lost; "clear a stopper at 8am with full context" is what you get instead. For a normal sleep duration (6-8h), that trade is fine.

## Morning workflow (the codified part)

Run these in order after an overnight run:

1. **`loop status`** — daemon RUNNING + active brief + recent log tail. First-glance health.
2. **`tail -80 .loop/state/stewardship-log.md`** — any interventions that happened. If clean, stewardship was quiet (good).
3. **`ls .loop/state/signals/`** — any live escalations. Archive files (`*.resolved-*`, `*.archived-*`) are history; anything else is active.
4. **`python3 scripts/loop-report.py --since {duration}`** — one-glance report card. Briefs merged, cycles, interventions, miss rate, flag pile delta. Read the Health Read line first.
5. **Address awaiting_review[] + escalations** — per stewardship rubric. Taste-gated stays with the human; objective-green can stamp.

Total time: ~3-5 min if quiet, longer if the night was eventful.

## Scope limits (for unattended operation)

- **Approve authority:** stewardship does NOT run `loop approve` on taste-gated briefs, or on anything where the approval is the brief's core artifact.
- **Intervention authority:** steward MAY write `pending-dispatch.json` for stuck conductors, MAY move briefs from active to awaiting_review for human-in-the-loop escalations, MAY archive resolved signals, MAY restart the daemon if HUNG.
- **Hands-off:** no code edits, no new briefs, no goals.md priority changes. Overnight stewardship is a watchdog role, not an implementer role.
- **Log everything:** stewardship-log entry per intervention, H3 with timestamp. Classification + action + rubric + what the human should know in the morning.

## When to revisit this pattern

Consider upgrading the overnight story when any of these hit:

- Multiple overnight losses in a row where a stopper could've been cleared in 10 min live but blocked 6h of queue work.
- Simple-loop ships a native alerting mechanism (SMS / push / email on escalation).
- You want to set up a launchd job that wakes a Claude Code session every N minutes.
- A second loop instance goes live and cross-instance coordination becomes load-bearing.

Until then: autonomous daemon + forensic trail + morning review is the pattern. Don't over-engineer past the real pain.

## Related

- [harness-updates.md](harness-updates.md) — escape hatches for when the daemon is actually stuck
- [multi-instance-loop.md](multi-instance-loop.md) — what simple-loop is becoming; how tools travel
- `.loop/state/stewardship-log.md` — the narrative trail
- `scripts/loop-report.py` — the morning report card
