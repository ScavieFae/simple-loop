#!/usr/bin/env python3
"""Assess daemon state — what should happen this tick?

Prints TWO lines:
  Line 1 (conductor): CONDUCTOR:<reason> or NONE
  Line 2 (worker):    WORKER:<brief>,<branch> or NONE

Usage:
    python3 lib/assess.py <project_dir>
"""

import json
import os
import subprocess
import sys
import time


def main():
    project_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    loop_dir = os.path.join(project_dir, ".loop")
    state_dir = os.path.join(loop_dir, "state")
    signals_dir = os.path.join(state_dir, "signals")
    running_file = os.path.join(state_dir, "running.json")

    conductor = "NONE"
    worker = "NONE"

    if not os.path.exists(running_file):
        print("CONDUCTOR:no_state")
        print("NONE")
        return

    # If queue files exist (and not stale), let daemon process them first
    for qf in ["pending-dispatch.json", "pending-merge.json"]:
        qpath = os.path.join(state_dir, qf)
        if os.path.exists(qpath):
            age_min = (time.time() - os.path.getmtime(qpath)) / 60
            if age_min < 30:
                print("NONE")
                print("NONE")
                return

    with open(running_file) as f:
        rc = json.load(f)

    # Read config for git remote
    config_file = os.path.join(loop_dir, "config.sh")
    remote = "origin"
    if os.path.exists(config_file):
        with open(config_file) as f:
            for line in f:
                if line.strip().startswith("GIT_REMOTE="):
                    remote = line.strip().split("=", 1)[1].strip('"').strip("'")
                    break

    # --- Conductor triggers ---

    # Pending evaluation
    pending = rc.get("completed_pending_eval", [])
    if pending:
        conductor = "CONDUCTOR:pending_eval"

    # Active escalation signal
    if conductor == "NONE":
        esc_file = os.path.join(signals_dir, "escalate.json")
        if os.path.exists(esc_file):
            try:
                with open(esc_file) as f:
                    esc = json.load(f)
                if esc.get("type", "none") != "none":
                    conductor = "CONDUCTOR:active_signal"
            except (json.JSONDecodeError, KeyError):
                pass

    # No active briefs
    active = rc.get("active", [])
    if not active and conductor == "NONE":
        conductor = "CONDUCTOR:no_active"

    # --- Check active briefs for both conductor triggers and worker targets ---
    for brief_entry in active:
        brief_id = brief_entry.get("brief", "")
        branch = brief_entry.get("branch", "")
        if not branch:
            continue

        status = "running"
        branch_exists = False
        for ref in [branch, f"{remote}/{branch}"]:
            try:
                result = subprocess.run(
                    ["git", "-C", project_dir, "show", f"{ref}:.loop/state/progress.json"],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode == 0:
                    prog = json.loads(result.stdout)
                    status = prog.get("status", "running")
                    branch_exists = True
                    break
            except Exception:
                continue

        if status == "complete":
            if conductor == "NONE":
                conductor = f"CONDUCTOR:brief_complete:{brief_id}"
        elif status == "blocked":
            if conductor == "NONE":
                conductor = f"CONDUCTOR:brief_blocked:{brief_id}"
        elif status == "running" and branch_exists:
            if worker == "NONE":
                worker = f"WORKER:{brief_id},{branch}"
        elif not branch_exists:
            if conductor == "NONE":
                conductor = f"CONDUCTOR:stale_brief:{brief_id}"

    print(conductor)
    print(worker)


if __name__ == "__main__":
    main()
