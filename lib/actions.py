#!/usr/bin/env python3
"""Daemon-side state transitions — mechanical operations that don't need Claude.

Called by daemon.sh to execute deterministic state changes
(JSON splices, git branch operations).

Usage:
    python3 lib/actions.py move-to-eval <brief_id> <project_dir>
    python3 lib/actions.py dispatch <project_dir>
    python3 lib/actions.py merge <project_dir>
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def init_paths(project_dir):
    """Initialize paths from project directory."""
    loop_dir = os.path.join(project_dir, ".loop")
    state_dir = os.path.join(loop_dir, "state")
    return {
        "project_dir": project_dir,
        "loop_dir": loop_dir,
        "state_dir": state_dir,
        "running_file": os.path.join(state_dir, "running.json"),
        "pending_dispatch": os.path.join(state_dir, "pending-dispatch.json"),
        "pending_merge": os.path.join(state_dir, "pending-merge.json"),
        "log_file": os.path.join(state_dir, "log.jsonl"),
        "progress_file": os.path.join(state_dir, "progress.json"),
    }


def read_config(loop_dir):
    """Read config.sh values into a dict."""
    config = {
        "GIT_REMOTE": "origin",
        "GIT_MAIN_BRANCH": "main",
    }
    config_file = os.path.join(loop_dir, "config.sh")
    if os.path.exists(config_file):
        with open(config_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                config[key] = val
    return config


def log_action(paths, action, details):
    """Append to log.jsonl."""
    entry = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "action": f"daemon:{action}",
        **details,
    }
    with open(paths["log_file"], "a") as f:
        f.write(json.dumps(entry) + "\n")


def git(project_dir, *args, check=True):
    """Run a git command in the project directory."""
    result = subprocess.run(
        ["git", "-C", project_dir] + list(args),
        capture_output=True, text=True, timeout=60,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, f"git {' '.join(args)}",
            output=result.stdout, stderr=result.stderr,
        )
    return result


def load_running(paths):
    """Load running.json."""
    with open(paths["running_file"]) as f:
        return json.load(f)


def save_running(paths, data):
    """Write running.json and commit."""
    with open(paths["running_file"], "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    git(paths["project_dir"], "add", paths["running_file"])
    git(paths["project_dir"], "commit", "-m", "loop: update running.json", check=False)


# ─── Action: move-to-eval ────────────────────────────────────────────

def move_to_eval(paths, brief_id):
    """Move a brief from active to completed_pending_eval."""
    rc = load_running(paths)
    active = rc.get("active", [])
    pending = rc.get("completed_pending_eval", [])

    moved = None
    new_active = []
    for entry in active:
        if entry.get("brief") == brief_id:
            moved = entry
        else:
            new_active.append(entry)

    if not moved:
        print(f"Warning: brief '{brief_id}' not found in active list", file=sys.stderr)
        return False

    moved["completed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    pending.append(moved)
    rc["active"] = new_active
    rc["completed_pending_eval"] = pending
    save_running(paths, rc)

    log_action(paths, "move-to-eval", {"brief": brief_id})
    print(f"Moved {brief_id} to completed_pending_eval")
    return True


# ─── Action: dispatch ─────────────────────────────────────────────────

def dispatch(paths):
    """Process pending-dispatch.json: create branch, init progress, update state."""
    if not os.path.exists(paths["pending_dispatch"]):
        print("No pending-dispatch.json found", file=sys.stderr)
        return False

    config = read_config(paths["loop_dir"])
    remote = config["GIT_REMOTE"]
    main_branch = config["GIT_MAIN_BRANCH"]

    with open(paths["pending_dispatch"]) as f:
        spec = json.load(f)

    brief = spec["brief"]
    branch = spec["branch"]
    brief_file = spec["brief_file"]
    notes = spec.get("notes", "")

    project_dir = paths["project_dir"]

    # Ensure on main branch
    git(project_dir, "checkout", main_branch, check=False)
    git(project_dir, "pull", "--ff-only", remote, main_branch, check=False)

    # Create branch
    git(project_dir, "checkout", "-b", branch, main_branch)

    # Initialize progress.json
    progress = {
        "brief": brief,
        "brief_file": brief_file,
        "iteration": 0,
        "status": "running",
        "tasks_completed": [],
        "tasks_remaining": [],
        "learnings": [],
    }
    with open(paths["progress_file"], "w") as f:
        json.dump(progress, f, indent=2)
        f.write("\n")

    git(project_dir, "add", paths["progress_file"])
    git(project_dir, "commit", "-m", f"Initialize brief {brief}")
    git(project_dir, "push", "-u", remote, branch)

    # Return to main branch
    git(project_dir, "checkout", main_branch)

    # Update running.json
    rc = load_running(paths)
    rc.setdefault("active", []).append({
        "brief": brief,
        "branch": branch,
        "brief_file": brief_file,
        "dispatched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    save_running(paths, rc)
    git(project_dir, "push", remote, main_branch, check=False)

    # Remove queue file
    os.remove(paths["pending_dispatch"])

    log_action(paths, "dispatch", {"brief": brief, "branch": branch, "notes": notes})
    print(f"Dispatched {brief} on branch {branch}")
    return True


# ─── Action: merge ────────────────────────────────────────────────────

def merge(paths):
    """Process pending-merge.json: merge branch to main."""
    if not os.path.exists(paths["pending_merge"]):
        print("No pending-merge.json found", file=sys.stderr)
        return False

    config = read_config(paths["loop_dir"])
    remote = config["GIT_REMOTE"]
    main_branch = config["GIT_MAIN_BRANCH"]

    with open(paths["pending_merge"]) as f:
        spec = json.load(f)

    brief = spec["brief"]
    branch = spec["branch"]
    title = spec.get("title", brief)
    evaluation = spec.get("evaluation", "")

    project_dir = paths["project_dir"]

    # Ensure on main branch with latest
    git(project_dir, "checkout", main_branch, check=False)
    git(project_dir, "pull", "--ff-only", remote, main_branch, check=False)
    git(project_dir, "fetch", remote, branch, check=False)

    # Merge
    merge_msg = f"Merge {brief}: {title}"
    if evaluation:
        merge_msg += f"\n\nEvaluation: {evaluation}"
    git(project_dir, "merge", f"{remote}/{branch}", "--no-ff", "-m", merge_msg)

    # Delete remote branch
    git(project_dir, "push", remote, "--delete", branch, check=False)
    git(project_dir, "branch", "-d", branch, check=False)

    # Push main
    git(project_dir, "push", remote, main_branch)

    # Update running.json
    rc = load_running(paths)
    pending = rc.get("completed_pending_eval", [])
    new_pending = [e for e in pending if e.get("brief") != brief]
    rc["completed_pending_eval"] = new_pending

    rc.setdefault("history", []).append({
        "brief": brief,
        "branch": branch,
        "merged_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "evaluation": evaluation,
    })
    save_running(paths, rc)
    git(project_dir, "push", remote, main_branch, check=False)

    # Remove queue file
    os.remove(paths["pending_merge"])

    log_action(paths, "merge", {"brief": brief, "branch": branch, "title": title})
    print(f"Merged {brief} to {main_branch}")
    return True


# ─── Main ─────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <action> <project_dir> [args]", file=sys.stderr)
        print("Actions: move-to-eval <brief_id>, dispatch, merge", file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]

    # project_dir is always the last positional arg before action-specific args
    if action == "move-to-eval":
        if len(sys.argv) < 4:
            print("move-to-eval requires <brief_id> <project_dir>", file=sys.stderr)
            sys.exit(1)
        brief_id = sys.argv[2]
        project_dir = sys.argv[3]
    else:
        project_dir = sys.argv[2]

    paths = init_paths(project_dir)

    try:
        if action == "move-to-eval":
            success = move_to_eval(paths, brief_id)
        elif action == "dispatch":
            success = dispatch(paths)
        elif action == "merge":
            success = merge(paths)
        else:
            print(f"Unknown action: {action}", file=sys.stderr)
            sys.exit(1)

        sys.exit(0 if success else 1)

    except subprocess.CalledProcessError as e:
        print(f"Git error in {action}: {e}", file=sys.stderr)
        if e.stderr:
            print(f"  stderr: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"Error in {action}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
