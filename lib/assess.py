#!/usr/bin/env python3
"""Assess daemon state — what should happen this tick?

Prints THREE lines:
  Line 1 (conductor): CONDUCTOR:<reason> or NONE
  Line 2 (worker):    WORKER:<brief>,<branch> or NONE
  Line 3 (validator): VALIDATOR:<brief>,<branch>,<commit> or NONE

Brief-003 Thread 1 added line 3: emits a VALIDATOR target when a builder
cycle has committed and no corresponding review exists. Conductor trigger
CONDUCTOR:validator_blocked:<brief> preempts brief_complete when the latest
review's verdict is `block` (precedence 3 — ahead of brief_complete, behind
pending_eval and active_signal).

Usage:
    python3 lib/assess.py <project_dir>
"""

import json
import os
import re
import subprocess
import sys
import time


REVIEW_CYCLE_RE = re.compile(r"-cycle-(\d+)\.md$")
AUTO_MERGE_LINE_RE = re.compile(r"^\s*\*\*Auto-merge:\*\*\s*(\S+)", re.IGNORECASE)


def git_show(project_dir, ref, path):
    try:
        r = subprocess.run(
            ["git", "-C", project_dir, "show", f"{ref}:{path}"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout
    except Exception:
        pass
    return None


def git_read_follow(project_dir, ref, path, _depth=0):
    """Like git_show, but follows git symlinks (mode 120000) up to 5 levels.

    Briefs can be symlinked from `.loop/briefs/brief-NNN.md` into the card
    dir's `index.md`. `git show` on a symlink returns the target path, not
    the file body — callers parsing frontmatter would see no match. Follow.
    """
    if _depth > 5:
        return None
    try:
        r = subprocess.run(
            ["git", "-C", project_dir, "ls-tree", ref, "--", path],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    mode = r.stdout.split(None, 1)[0]
    blob = git_show(project_dir, ref, path)
    if blob is None:
        return None
    if mode != "120000":
        return blob
    target = blob.strip()
    if target.startswith("/"):
        resolved = target.lstrip("/")
    else:
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
    return git_read_follow(project_dir, ref, resolved, _depth + 1)


def git_rev_parse(project_dir, ref):
    try:
        r = subprocess.run(
            ["git", "-C", project_dir, "rev-parse", ref],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return ""


def read_auto_merge_flag(project_dir, ref, brief_file_rel):
    """Thread 7: does this brief opt in to auto-merge?

    Parses `**Auto-merge:** true` from the brief frontmatter. Absent or any
    non-`true` value → False. Read via `git show <ref>:<path>` so the main
    worktree can inspect a brief-branch file without a checkout.
    """
    content = git_read_follow(project_dir, ref, brief_file_rel)
    if not content:
        return False
    for line in content.splitlines():
        m = AUTO_MERGE_LINE_RE.match(line)
        if m:
            return m.group(1).strip().lower().strip('"').strip("'") == "true"
    return False


def max_review_cycle(project_dir, ref, brief_id):
    """Find max cycle N of review files for brief_id visible on ref."""
    try:
        r = subprocess.run(
            ["git", "-C", project_dir, "ls-tree", "-r", "--name-only", ref,
             ".loop/modules/validator/state/reviews/"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            return 0
    except Exception:
        return 0
    best = 0
    for line in r.stdout.splitlines():
        name = os.path.basename(line)
        if not name.startswith(f"{brief_id}-cycle-"):
            continue
        m = REVIEW_CYCLE_RE.search(name)
        if m:
            best = max(best, int(m.group(1)))
    return best


def latest_review_verdict(project_dir, ref, brief_id, cycle):
    """Read the most recent review's `verdict:` frontmatter field from ref."""
    path = f".loop/modules/validator/state/reviews/{brief_id}-cycle-{cycle}.md"
    content = git_show(project_dir, ref, path)
    if not content:
        return None
    in_front = False
    for line in content.splitlines():
        s = line.strip()
        if s == "---":
            if not in_front:
                in_front = True
                continue
            else:
                break
        if in_front and s.lower().startswith("verdict:"):
            v = s.split(":", 1)[1].strip()
            v = v.split("#", 1)[0].strip().strip('"').strip("'")
            return v.lower() or None
    return None


def main():
    project_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    loop_dir = os.path.join(project_dir, ".loop")
    state_dir = os.path.join(loop_dir, "state")
    signals_dir = os.path.join(state_dir, "signals")
    running_file = os.path.join(state_dir, "running.json")

    conductor = "NONE"
    worker = "NONE"
    validator = "NONE"

    if not os.path.exists(running_file):
        print("CONDUCTOR:no_state")
        print("NONE")
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

    # High-priority conductor triggers (pending_eval, active_signal) cannot be
    # preempted by validator_blocked. Track so the later block check knows.
    high_priority = conductor in ("CONDUCTOR:pending_eval", "CONDUCTOR:active_signal")

    # No active briefs
    active = rc.get("active", [])
    if not active and conductor == "NONE":
        conductor = "CONDUCTOR:no_active"

    blocked_brief = ""  # populated below if any active brief has verdict: block

    # --- Check active briefs for conductor triggers, worker targets, validator targets ---
    for brief_entry in active:
        brief_id = brief_entry.get("brief", "")
        branch = brief_entry.get("branch", "")
        if not branch:
            continue

        status = "running"
        branch_exists = False
        iteration = 0
        used_ref = None
        for ref in [branch, f"{remote}/{branch}"]:
            prog_raw = git_show(project_dir, ref, ".loop/state/progress.json")
            if prog_raw is None:
                continue
            try:
                prog = json.loads(prog_raw)
            except (json.JSONDecodeError, ValueError):
                continue
            status = prog.get("status", "running")
            iteration = int(prog.get("iteration", 0) or 0)
            branch_exists = True
            used_ref = ref
            break

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

        # Validator logic — only meaningful if we actually found the branch.
        if not branch_exists or not used_ref:
            continue

        max_cycle = max_review_cycle(project_dir, used_ref, brief_id)

        # Review owed when builder has advanced past last reviewed cycle.
        if iteration > max_cycle and validator == "NONE":
            tip_sha = git_rev_parse(project_dir, used_ref)
            if tip_sha:
                validator = f"VALIDATOR:{brief_id},{branch},{tip_sha}"

        # Block verdict on the most recent review preempts other conductor triggers.
        if max_cycle > 0 and not blocked_brief:
            verdict = latest_review_verdict(project_dir, used_ref, brief_id, max_cycle)
            if verdict == "block":
                blocked_brief = brief_id

    # Precedence 3: validator_blocked preempts brief_complete / brief_blocked /
    # stale_brief / no_active, but not pending_eval or active_signal.
    if blocked_brief and not high_priority:
        conductor = f"CONDUCTOR:validator_blocked:{blocked_brief}"

    print(conductor)
    print(worker)
    print(validator)


if __name__ == "__main__":
    main()
