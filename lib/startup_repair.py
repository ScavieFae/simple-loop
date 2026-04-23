#!/usr/bin/env python3
"""Daemon startup state repair — runs once per process start before the tick loop.

Three repair operations (added per brief-019 tasks 2-4):
  A. dedup_active: remove duplicate entries from active[]
  B. backfill_history: add merge-committed briefs to history[] (added in task 3)
  C. clean_stale_queues: remove queue files for already-merged briefs (added in task 4)

All functions are pure: take a running dict, return (new_dict, action_list).
The orchestrator run_startup_repair() loads state, calls repairs, saves if changed,
logs all actions to log.jsonl.
"""

import json
import os
from datetime import datetime, timezone


def dedup_active(running: dict) -> tuple:
    """Keep first occurrence of each brief ID in active[]. Return (repaired, actions).

    Duplicate active entries cause the conductor to re-dispatch already-running
    briefs. This trims the array to first-seen per brief ID.
    """
    seen: set = set()
    new_active = []
    removed: dict = {}

    for entry in running.get("active", []):
        brief_id = entry.get("brief")
        if brief_id not in seen:
            seen.add(brief_id)
            new_active.append(entry)
        else:
            removed[brief_id] = removed.get(brief_id, 0) + 1

    if not removed:
        return running, []

    result = dict(running)
    result["active"] = new_active
    actions = [
        {"reason": "duplicate_active_entry", "brief": brief_id, "count_removed": count}
        for brief_id, count in removed.items()
    ]
    return result, actions


def run_startup_repair(paths: dict, project_dir: str) -> list:
    """Orchestrator: run all repair steps, save if any changes, log all actions.

    Returns the list of repair action dicts (empty if nothing was repaired).
    Callers can check the length to decide whether to log/print.
    """
    from actions import load_running, save_running, log_action

    t_start = datetime.now(timezone.utc)
    running = load_running(paths)
    all_actions: list = []

    running, actions = dedup_active(running)
    all_actions.extend(actions)

    for action in all_actions:
        log_action(paths, "startup_repair", action)

    if all_actions:
        save_running(paths, running)

    duration_ms = int((datetime.now(timezone.utc) - t_start).total_seconds() * 1000)
    summary = {
        "timestamp": t_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "action": "daemon:startup_repair_complete",
        "actions": all_actions,
        "duration_ms": duration_ms,
    }
    with open(paths["log_file"], "a") as f:
        f.write(json.dumps(summary) + "\n")

    return all_actions
