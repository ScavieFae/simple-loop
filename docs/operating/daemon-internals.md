# Daemon internals — conductor dedup cache

The daemon's conductor dedup cache prevents action-spam: if `assess.py` emits the same trigger two ticks in a row, the conductor only fires once.

## How it works

The cache is two bash variables in-process (`LAST_CONDUCTOR_TRIGGER`, `LAST_CONDUCTOR_TRIGGER_TS`). Both are lost on daemon restart.

```
LAST_CONDUCTOR_TRIGGER=""
LAST_CONDUCTOR_TRIGGER_TS=0
```

On each tick, when the conductor sees a `CONDUCTOR:*` trigger:

1. Compare incoming trigger to `LAST_CONDUCTOR_TRIGGER`.
2. If same AND age < `CONDUCTOR_DEDUP_TTL_SECS` → skip (log "dedup — same trigger").
3. If same AND age ≥ TTL → fire again (log "dedup TTL expired").
4. If different → fire, update both variables.

## TTL

Default: `CONDUCTOR_DEDUP_TTL_SECS=1800` (30 min). Configurable per-project in `.loop/config.sh`:

```bash
CONDUCTOR_DEDUP_TTL_SECS=3600   # project override
```

The 30-min default is conservative: it keeps dedup effective against assess-spam while bounding the maximum stuck-state duration to ~1 hour before the trigger self-heals.

## Clear-on-state-change

When `actions.py` moves a brief out of `active[]`, it writes a signal file:

```
.loop/state/signals/dedup-clear-<brief_id>.json
```

The daemon consumes these at the top of each tick (before the conductor check). If `LAST_CONDUCTOR_TRIGGER` contains the brief id, both variables are reset to empty. The signal file is always deleted after consumption.

Functions that write the signal:

| Function | Trigger |
|---|---|
| `move_to_awaiting_review()` | worker exit, timeout, staleness, rebase conflict |
| `reject_brief()` | human rejection |
| `merge()` | auto-merge or human-approved merge |

## Other reset paths

The cache also clears on:

- `escalate.json` resolved — daemon saw it present last tick, now it's gone.
- Validator fires (explicit reset in daemon Phase 3).
- Worker fires (explicit reset in daemon Phase 3).

## Why in-process bash, not a file

The dedup cache lives in-process intentionally: it can't survive a restart. A restart clears stuck state automatically — that's the escape hatch when the cache is wrong. A persistent cache would require manual invalidation.

The signal file pattern (`dedup-clear-*.json`) is the bridge: actions.py can't reach into the daemon's bash variables, so it drops a file that the daemon polls.

## KC2 sequencing

`signal_dedup_clear()` is called at the end of `move_to_awaiting_review()`, after `save_running()` commits the state change. This means the daemon can't see the signal before the state is durable on disk. Race avoided.
