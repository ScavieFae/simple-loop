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
        "worktrees_dir": os.path.join(loop_dir, "worktrees"),
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
    """Load running.json, backfilling v2 fields with defaults for backward compatibility."""
    with open(paths["running_file"]) as f:
        rc = json.load(f)
    rc.setdefault("pending_merges", [])
    rc.setdefault("awaiting_review", [])
    return rc


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


# ─── Action: move-to-pending-merges ─────────────────────────────────

def move_to_pending_merges(paths, brief_id):
    """Move a brief from active[] to pending_merges[] (auto-merge path)."""
    rc = load_running(paths)
    active = rc.get("active", [])

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
    moved["auto_merge"] = True
    rc["active"] = new_active
    rc["pending_merges"].append(moved)
    save_running(paths, rc)

    log_action(paths, "move-to-pending-merges", {"brief": brief_id})
    print(f"Moved {brief_id} to pending_merges")
    return True


# ─── Action: move-to-awaiting-review ────────────────────────────────

def move_to_awaiting_review(paths, brief_id, reason=""):
    """Move a brief from active[] to awaiting_review[] (human approval path)."""
    rc = load_running(paths)
    active = rc.get("active", [])

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
    moved["auto_merge"] = False
    if reason:
        moved["reason"] = reason
    rc["active"] = new_active
    rc["awaiting_review"].append(moved)
    save_running(paths, rc)

    log_action(paths, "move-to-awaiting-review", {"brief": brief_id, "reason": reason})
    print(f"Moved {brief_id} to awaiting_review")
    return True


# ─── Action: process-pending-merges ─────────────────────────────────

def process_pending_merges(paths):
    """Pop one brief from pending_merges[], write pending-merge.json, execute merge."""
    rc = load_running(paths)
    queue = rc.get("pending_merges", [])

    if not queue:
        print("No pending_merges to process", file=sys.stderr)
        return False

    if os.path.exists(paths["pending_merge"]):
        print("pending-merge.json already exists — merge already in progress", file=sys.stderr)
        return False

    entry = queue[0]
    brief = entry.get("brief", "")
    branch = entry.get("branch", "")

    spec = {
        "brief": brief,
        "branch": branch,
        "title": brief,
        "evaluation": entry.get("evaluation", ""),
    }
    with open(paths["pending_merge"], "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")

    # Remove from queue before calling merge() (merge() will re-prune from pending_merges anyway)
    rc["pending_merges"] = queue[1:]
    save_running(paths, rc)

    log_action(paths, "process-pending-merges", {"brief": brief})
    print(f"Wrote pending-merge.json for {brief}, executing merge")

    return merge(paths)


# ─── Action: approve-brief ───────────────────────────────────────────

def approve_brief(paths, brief_id):
    """Move a brief from awaiting_review[] to pending_merges[]."""
    rc = load_running(paths)
    waiting = rc.get("awaiting_review", [])

    moved = None
    new_waiting = []
    for entry in waiting:
        if entry.get("brief") == brief_id:
            moved = entry
        else:
            new_waiting.append(entry)

    if not moved:
        print(f"Warning: brief '{brief_id}' not found in awaiting_review", file=sys.stderr)
        return False

    moved["approved_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    moved["auto_merge"] = True
    rc["awaiting_review"] = new_waiting
    rc["pending_merges"].append(moved)
    save_running(paths, rc)

    log_action(paths, "approve-brief", {"brief": brief_id})
    print(f"Approved {brief_id}: moved to pending_merges")
    return True


# ─── Action: reject-brief ────────────────────────────────────────────

def reject_brief(paths, brief_id, reason=""):
    """Move a brief from awaiting_review[] to history[] with rejected marker."""
    rc = load_running(paths)
    waiting = rc.get("awaiting_review", [])

    moved = None
    new_waiting = []
    for entry in waiting:
        if entry.get("brief") == brief_id:
            moved = entry
        else:
            new_waiting.append(entry)

    if not moved:
        print(f"Warning: brief '{brief_id}' not found in awaiting_review", file=sys.stderr)
        return False

    moved["rejected_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    moved["reject_reason"] = reason
    rc["awaiting_review"] = new_waiting
    rc.setdefault("history", []).append(moved)
    save_running(paths, rc)

    log_action(paths, "reject-brief", {"brief": brief_id, "reason": reason})
    print(f"Rejected {brief_id}: moved to history")
    return True


# ─── Action: dispatch ─────────────────────────────────────────────────

def worktree_dir_for(paths, brief):
    """Return the worktree path for a brief."""
    return os.path.join(paths["worktrees_dir"], brief)


def ensure_worktree(paths, brief, branch, config=None):
    """Create a worktree for a brief if it doesn't already exist. Returns worktree path."""
    wt_dir = worktree_dir_for(paths, brief)
    if os.path.exists(wt_dir):
        return wt_dir

    if config is None:
        config = read_config(paths["loop_dir"])
    remote = config["GIT_REMOTE"]
    main_branch = config["GIT_MAIN_BRANCH"]
    project_dir = paths["project_dir"]

    os.makedirs(paths["worktrees_dir"], exist_ok=True)

    # Try existing local branch, then remote tracking, then create new
    if git(project_dir, "show-ref", "--verify", "--quiet",
           f"refs/heads/{branch}", check=False).returncode == 0:
        git(project_dir, "worktree", "add", wt_dir, branch)
    elif git(project_dir, "show-ref", "--verify", "--quiet",
             f"refs/remotes/{remote}/{branch}", check=False).returncode == 0:
        git(project_dir, "worktree", "add", wt_dir, branch)
    else:
        git(project_dir, "worktree", "add", "-b", branch, wt_dir, main_branch)

    return wt_dir


def remove_worktree(paths, brief):
    """Remove a worktree for a brief."""
    wt_dir = worktree_dir_for(paths, brief)
    if os.path.exists(wt_dir):
        git(paths["project_dir"], "worktree", "remove", wt_dir, "--force", check=False)
    # Clean up any stale worktree entries
    git(paths["project_dir"], "worktree", "prune", check=False)


def dispatch(paths):
    """Process pending-dispatch.json: create worktree + branch, init progress, update state."""
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

    # Fetch latest (no checkout needed — main tree untouched)
    git(project_dir, "fetch", remote, check=False)

    # Create worktree with new branch
    wt_dir = ensure_worktree(paths, brief, branch, config)

    # Initialize progress.json in the worktree
    wt_progress = os.path.join(wt_dir, ".loop", "state", "progress.json")
    os.makedirs(os.path.dirname(wt_progress), exist_ok=True)

    progress = {
        "brief": brief,
        "brief_file": brief_file,
        "iteration": 0,
        "status": "running",
        "tasks_completed": [],
        "tasks_remaining": [],
        "learnings": [],
    }
    with open(wt_progress, "w") as f:
        json.dump(progress, f, indent=2)
        f.write("\n")

    git(wt_dir, "add", ".loop/state/progress.json")
    git(wt_dir, "commit", "-m", f"Initialize brief {brief}")
    git(wt_dir, "push", "-u", remote, branch)

    # Update running.json on main (main tree untouched except this state file)
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
    print(f"Dispatched {brief} on branch {branch} (worktree: {wt_dir})")
    return True


# ─── Action: merge ────────────────────────────────────────────────────

def merge(paths):
    """Process pending-merge.json: merge branch to main, remove worktree."""
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

    # Verify main tree is on main branch (should always be true with worktrees)
    current = git(project_dir, "branch", "--show-current", check=False).stdout.strip()
    if current != main_branch:
        git(project_dir, "checkout", main_branch)

    git(project_dir, "fetch", remote, check=False)
    git(project_dir, "pull", "--ff-only", remote, main_branch, check=False)

    # Merge the branch (using local ref if available, otherwise remote)
    merge_msg = f"Merge {brief}: {title}"
    if evaluation:
        merge_msg += f"\n\nEvaluation: {evaluation}"

    if git(project_dir, "show-ref", "--verify", "--quiet",
           f"refs/heads/{branch}", check=False).returncode == 0:
        git(project_dir, "merge", branch, "--no-ff", "-m", merge_msg)
    else:
        git(project_dir, "merge", f"{remote}/{branch}", "--no-ff", "-m", merge_msg)

    # Remove worktree before deleting branch
    remove_worktree(paths, brief)

    # Delete branches
    git(project_dir, "push", remote, "--delete", branch, check=False)
    git(project_dir, "branch", "-d", branch, check=False)

    # Push main
    git(project_dir, "push", remote, main_branch)

    # Update running.json — prune from both active and completed_pending_eval.
    # A brief may reach merge via either path (direct pending-merge stamp from
    # active, or the regular complete → eval → merge flow). If we don't prune
    # active, the conductor keeps seeing the merged brief as active, can't find
    # its branch (deleted above), and fires stale_brief every heartbeat forever.
    rc = load_running(paths)
    active = rc.get("active", [])
    new_active = [e for e in active if e.get("brief") != brief]
    rc["active"] = new_active
    pending = rc.get("completed_pending_eval", [])
    new_pending = [e for e in pending if e.get("brief") != brief]
    rc["completed_pending_eval"] = new_pending
    rc["pending_merges"] = [e for e in rc.get("pending_merges", []) if e.get("brief") != brief]
    rc["awaiting_review"] = [e for e in rc.get("awaiting_review", []) if e.get("brief") != brief]

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


# ─── Action: cleanup ─────────────────────────────────────────────────

def cleanup_worktrees(paths):
    """Remove worktrees for briefs that are no longer active."""
    project_dir = paths["project_dir"]
    worktrees_dir = paths["worktrees_dir"]

    if not os.path.exists(worktrees_dir):
        print("No worktrees directory.")
        return True

    # Prune stale git worktree entries
    git(project_dir, "worktree", "prune", check=False)

    # Get active brief IDs (all queues that still have a live worktree)
    rc = load_running(paths)
    active_briefs = set()
    for entry in rc.get("active", []):
        active_briefs.add(entry.get("brief", ""))
    for entry in rc.get("completed_pending_eval", []):
        active_briefs.add(entry.get("brief", ""))
    for entry in rc.get("pending_merges", []):
        active_briefs.add(entry.get("brief", ""))
    for entry in rc.get("awaiting_review", []):
        active_briefs.add(entry.get("brief", ""))

    cleaned = 0
    for name in os.listdir(worktrees_dir):
        wt_path = os.path.join(worktrees_dir, name)
        if not os.path.isdir(wt_path):
            continue
        if name not in active_briefs:
            print(f"  Removing worktree: {name}")
            git(project_dir, "worktree", "remove", wt_path, "--force", check=False)
            # Fallback if git worktree remove fails
            if os.path.exists(wt_path):
                import shutil
                shutil.rmtree(wt_path, ignore_errors=True)
            cleaned += 1

    if cleaned:
        git(project_dir, "worktree", "prune", check=False)
        print(f"  Cleaned {cleaned} worktree(s).")
    else:
        print("  Nothing to clean up.")

    log_action(paths, "cleanup", {"cleaned": cleaned})
    return True


# ─── Main ─────────────────────────────────────────────────────────────

def main():
    BRIEF_ACTIONS = ("move-to-eval", "move-to-pending-merges", "move-to-awaiting-review",
                     "approve-brief", "reject-brief")

    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <action> <project_dir> [args]", file=sys.stderr)
        print("Actions: move-to-eval <brief_id> <project_dir>", file=sys.stderr)
        print("         move-to-pending-merges <brief_id> <project_dir>", file=sys.stderr)
        print("         move-to-awaiting-review <brief_id> <project_dir> [reason]", file=sys.stderr)
        print("         process-pending-merges <project_dir>", file=sys.stderr)
        print("         approve-brief <brief_id> <project_dir>", file=sys.stderr)
        print("         reject-brief <brief_id> <project_dir> [reason]", file=sys.stderr)
        print("         dispatch <project_dir>", file=sys.stderr)
        print("         merge <project_dir>", file=sys.stderr)
        print("         cleanup <project_dir>", file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]

    # Actions that take <brief_id> <project_dir> [extra...]
    if action in BRIEF_ACTIONS:
        if len(sys.argv) < 4:
            print(f"{action} requires <brief_id> <project_dir>", file=sys.stderr)
            sys.exit(1)
        brief_id = sys.argv[2]
        project_dir = sys.argv[3]
        extra = sys.argv[4:]
    else:
        brief_id = ""
        project_dir = sys.argv[2]
        extra = sys.argv[3:]

    paths = init_paths(project_dir)

    try:
        if action == "move-to-eval":
            success = move_to_eval(paths, brief_id)
        elif action == "move-to-pending-merges":
            success = move_to_pending_merges(paths, brief_id)
        elif action == "move-to-awaiting-review":
            reason = " ".join(extra) if extra else ""
            success = move_to_awaiting_review(paths, brief_id, reason)
        elif action == "process-pending-merges":
            success = process_pending_merges(paths)
        elif action == "approve-brief":
            success = approve_brief(paths, brief_id)
        elif action == "reject-brief":
            reason = " ".join(extra) if extra else ""
            success = reject_brief(paths, brief_id, reason)
        elif action == "dispatch":
            success = dispatch(paths)
        elif action == "merge":
            success = merge(paths)
        elif action == "cleanup":
            success = cleanup_worktrees(paths)
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
