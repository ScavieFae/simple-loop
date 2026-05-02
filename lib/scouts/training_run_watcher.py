#!/usr/bin/env python3
"""Training-run-watcher scout — deterministic core.

Discovers wiki/runs/*/index.md with status: running, polls Modal app status
and log mtime, appends per-run heartbeats to wiki/runs/<run-id>/heartbeats.jsonl,
and surfaces a rolling last-N summary in the run card's Heartbeats section.

Invoked by the daemon via the specialist file at .loop/specialists/training-run-watcher.md
(mode: deterministic) or directly for testing:
    python3 lib/scouts/training_run_watcher.py --project-dir <path>

Signal files written:
    .loop/state/signals/training-stale-<run-id>.json
    .loop/state/signals/training-failed-<run-id>.json
    .loop/state/signals/training-preempted-<run-id>.json
    .loop/state/signals/run-card-malformed-<run-id>.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

HEARTBEAT_SIDECAR = "heartbeats.jsonl"
STALE_THRESHOLD_SECONDS = 300  # 5 min
HEARTBEAT_SUMMARY_LINES = 5
SIGNAL_RATE_LIMIT_SECONDS = 1800  # 30 min per run per signal type

# Cost estimates: $/hr for each modal machine type (approximate; for preemption cost reporting)
_GPU_COST_PER_HOUR = {
    "modal:a10g": 1.10,
    "modal:a100-40gb": 2.78,
    "modal:h100": 4.00,
}
# ~1 step/sec measured on A10G (brief-118 smoke); used for wasted-cost estimate
_APPROX_STEPS_PER_HOUR = 3600


# ─── Project root discovery ─────────────────────────────────────────────

def find_project_root(start=None):
    """Walk up from start (or CWD) to find the root containing .loop/state/."""
    path = Path(start) if start else Path.cwd()
    path = path.resolve()
    while True:
        if (path / ".loop" / "state").exists():
            return path
        parent = path.parent
        if parent == path:
            return Path.cwd()
        path = parent


# ─── Run-card parsing ───────────────────────────────────────────────────

def _frontmatter(text):
    """Return dict of top-level YAML-lite scalars from frontmatter."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}
    out = {}
    for line in lines[1:end]:
        m = re.match(r"^([\w-]+)\s*:\s*(.*?)\s*$", line)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def discover_running_runs(project_root):
    """Return list of run-card paths with status: running.

    Skips dirs starting with _ (e.g. _template).
    Returns list of Path objects.
    """
    runs_dir = project_root / "wiki" / "runs"
    if not runs_dir.is_dir():
        return []
    found = []
    for run_dir in sorted(runs_dir.iterdir()):
        if run_dir.name.startswith("_"):
            continue
        idx = run_dir / "index.md"
        if not idx.is_file():
            continue
        try:
            text = idx.read_text()
        except (IOError, OSError):
            continue
        fm = _frontmatter(text)
        if fm.get("status") == "running":
            found.append(idx)
    return found


def parse_run_card(path):
    """Extract metadata needed by the scout from a run card.

    Returns dict with keys:
      run_id, policy, machine, app_id, log_path, watcher_cadence, watcher_off
    or None if the card is malformed (missing run-id).
    """
    try:
        text = path.read_text()
    except (IOError, OSError):
        return None

    fm = _frontmatter(text)
    run_id = fm.get("run-id")
    if not run_id:
        return None

    # watcher: off disables monitoring for this run
    watcher_off = fm.get("watcher", "").lower() == "off"
    watcher_cadence = fm.get("watcher_cadence", "5m")

    # App ID lives in the Receipts table as "Modal job ID" or "Modal app ID"
    app_id = None
    m = re.search(
        r"\|\s*Modal\s+(?:job|app)\s+ID\s*\|\s*`?([a-z]{2}-\w+)`?",
        text, re.IGNORECASE
    )
    if m:
        app_id = m.group(1)

    # Local log lives in Receipts as "Local log"
    log_path = None
    m = re.search(r"\|\s*Local log\s*\|\s*`?(/[^\s`|]+)`?", text)
    if m:
        log_path = m.group(1)

    return {
        "run_id": run_id,
        "policy": fm.get("policy", ""),
        "machine": fm.get("machine", ""),
        "app_id": app_id,
        "log_path": log_path,
        "watcher_cadence": watcher_cadence,
        "watcher_off": watcher_off,
        "run_card_path": path,
    }


# ─── Modal status check ─────────────────────────────────────────────────

def check_modal_app_status(app_id):
    """Check Modal app state via `modal app list | grep <app_id>`.

    Returns one of: running | completed | failed | unknown
    Retries once on transient failure.

    Modal app list output (rich table) per-row:
      │ <app_id> │ <desc> │ <state> │ <tasks> │ <created> │
    State values: ephemeral (running jobs), deployed (services),
                  stopped (terminated), failed.
    A running ephemeral job has tasks > 0; completed has tasks = 0 + stopped state.
    """
    if not app_id:
        return "unknown"

    for _attempt in range(2):
        try:
            result = subprocess.run(
                ["modal", "app", "list"],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode != 0:
                continue

            # Find the row(s) containing this app_id
            for line in result.stdout.splitlines():
                if app_id not in line:
                    continue
                # Extract task count and state from the table row
                # Row format: │ app_id │ desc │ state │ tasks │ created │
                parts = [p.strip() for p in line.split("│") if p.strip()]
                if not parts or app_id not in parts[0]:
                    continue
                # parts[2] = state, parts[3] = tasks
                state_field = parts[2].lower() if len(parts) > 2 else ""
                tasks_field = parts[3] if len(parts) > 3 else "0"
                try:
                    tasks = int(tasks_field)
                except (ValueError, TypeError):
                    tasks = 0

                if "failed" in state_field:
                    return "failed"
                if "stopped" in state_field:
                    return "completed"
                if "ephemeral" in state_field or "deployed" in state_field:
                    return "running" if tasks > 0 else "completed"
                return "unknown"

        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    return "unknown"


# ─── Log state check ────────────────────────────────────────────────────

# Matches tqdm "| 3727/50000 [" (ACT, smolVLA progress bars)
_TQDM_STEP_RE = re.compile(r"\|\s*(\d+)/\d+\s*\[")
# Matches lerobot log "step:2K" or "step:2000"
_LEROBOT_STEP_RE = re.compile(r"\bstep:(\d+(?:\.\d+)?)(K?)\b")
# General "step: 241" / "step=241" fallback
_GENERIC_STEP_RE = re.compile(r"\bstep[:\s=]+(\d+)", re.IGNORECASE)
# Matches lerobot "loss:0.011" or generic "loss: 0.011"
_LOSS_RE = re.compile(r"\bloss[:\s=]+([0-9]+\.[0-9]+)", re.IGNORECASE)
_PREEMPT_RE = re.compile(r"Runner interrupted due to worker preemption", re.IGNORECASE)


def check_log(log_path):
    """Return log state dict: mtime_iso, last_step, last_loss, tail_lines, preempted."""
    if not log_path or not os.path.exists(log_path):
        return {
            "mtime": None,
            "last_step": None,
            "last_loss": None,
            "tail": [],
            "preempted": False,
        }

    st = os.stat(log_path)
    mtime = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat()

    # Read last 32KB — enough to find the last INFO loss line which is logged
    # every 200 steps. Tqdm-only lines at the very end won't have loss.
    try:
        with open(log_path, errors="replace") as f:
            f.seek(max(0, st.st_size - 32768))
            tail_text = f.read()
    except (IOError, OSError):
        return {"mtime": mtime, "last_step": None, "last_loss": None,
                "tail": [], "preempted": False}

    lines = tail_text.splitlines()
    tail_lines = lines[-20:] if len(lines) > 20 else lines

    last_step = None
    last_loss = None
    for line in reversed(tail_lines):
        if last_step is None:
            # Try tqdm format first (most common in lerobot): "| 3727/50000 ["
            m = _TQDM_STEP_RE.search(line)
            if m:
                last_step = int(m.group(1))
            else:
                # lerobot metrics line: "step:2K" or "step:2000"
                m = _LEROBOT_STEP_RE.search(line)
                if m:
                    val = float(m.group(1))
                    if m.group(2).upper() == "K":
                        val *= 1000
                    last_step = int(val)
                else:
                    m = _GENERIC_STEP_RE.search(line)
                    if m:
                        last_step = int(m.group(1))

        if last_loss is None:
            m = _LOSS_RE.search(line)
            if m:
                try:
                    last_loss = float(m.group(1))
                except ValueError:
                    pass

        if last_step is not None and last_loss is not None:
            break

    preempted = any(_PREEMPT_RE.search(l) for l in tail_lines)

    return {
        "mtime": mtime,
        "last_step": last_step,
        "last_loss": last_loss,
        "tail": tail_lines,
        "preempted": preempted,
    }


def log_stale(log_state):
    """True if log mtime is older than STALE_THRESHOLD_SECONDS."""
    mtime_str = log_state.get("mtime")
    if not mtime_str:
        return False  # no log → can't assess staleness
    try:
        mtime = datetime.fromisoformat(mtime_str)
        if mtime.tzinfo is None:
            mtime = mtime.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - mtime).total_seconds()
        return age > STALE_THRESHOLD_SECONDS
    except (ValueError, TypeError):
        return False


# ─── Heartbeat sidecar ──────────────────────────────────────────────────

def write_heartbeat(project_root, run_id, app_state, log_state, alert=None):
    """Append one JSON line to wiki/runs/<run-id>/heartbeats.jsonl.

    Returns (sidecar_path, heartbeat_dict).
    """
    heartbeat = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": app_state,
        "last_step": log_state.get("last_step"),
        "last_loss": log_state.get("last_loss"),
        "log_mtime": log_state.get("mtime"),
        "app_state": app_state,
    }
    if alert:
        heartbeat["alert"] = alert

    sidecar = project_root / "wiki" / "runs" / run_id / HEARTBEAT_SIDECAR
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    with open(sidecar, "a") as f:
        f.write(json.dumps(heartbeat) + "\n")
    return sidecar, heartbeat


def read_last_heartbeats(project_root, run_id, n=HEARTBEAT_SUMMARY_LINES):
    """Return list of last n heartbeat dicts from the sidecar (most-recent last)."""
    sidecar = project_root / "wiki" / "runs" / run_id / HEARTBEAT_SIDECAR
    if not sidecar.is_file():
        return []
    entries = []
    try:
        for line in sidecar.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                pass
    except (IOError, OSError):
        pass
    return entries[-n:]


def check_step_regression(project_root, run_id, current_step):
    """True if current_step < previous step in heartbeats — preemption indicator."""
    prev = read_last_heartbeats(project_root, run_id, n=2)
    if len(prev) < 1:
        return False
    prev_step = prev[-1].get("last_step")
    if prev_step is None or current_step is None:
        return False
    return current_step < prev_step


# ─── Signal files ───────────────────────────────────────────────────────

def _signal_path(project_root, name):
    sig_dir = project_root / ".loop" / "state" / "signals"
    sig_dir.mkdir(parents=True, exist_ok=True)
    return sig_dir / name


def _signal_rate_limited(sig_path):
    """True if this signal file was written within SIGNAL_RATE_LIMIT_SECONDS."""
    if not sig_path.exists():
        return False
    try:
        age = (datetime.now(timezone.utc) -
               datetime.fromtimestamp(sig_path.stat().st_mtime, tz=timezone.utc)
               ).total_seconds()
        return age < SIGNAL_RATE_LIMIT_SECONDS
    except OSError:
        return False


def fire_signal(project_root, signal_type, meta, log_state, extra=None):
    """Write a signal JSON file for queen to pick up.

    signal_type: stale | failed | preempted | run-card-malformed
    Rate-limited to 1 fire per SIGNAL_RATE_LIMIT_SECONDS per run per type.
    """
    run_id = meta.get("run_id", "unknown")
    sig_name = f"training-{signal_type}-{run_id}.json"
    sig_path = _signal_path(project_root, sig_name)

    if _signal_rate_limited(sig_path):
        return None

    payload = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "signal": f"training-{signal_type}",
        "run_id": run_id,
        "app_id": meta.get("app_id"),
        "last_step": log_state.get("last_step"),
        "last_loss": log_state.get("last_loss"),
        "log_mtime": log_state.get("mtime"),
        "log_tail": log_state.get("tail", [])[-20:],
        "suggested_action": _suggested_action(signal_type, meta),
    }
    if extra:
        payload.update(extra)

    sig_path.write_text(json.dumps(payload, indent=2))
    return sig_path


def _suggested_action(signal_type, meta):
    run_id = meta.get("run_id", "?")
    if signal_type == "stale":
        return f"Check modal app {meta.get('app_id')} — log hasn't updated in 5+ min. May be stalled."
    if signal_type == "failed":
        return f"Modal app {meta.get('app_id')} reports failed. Review logs and decide: retry or abandon."
    if signal_type == "preempted":
        return f"Run {run_id} was preempted (step counter reset). Check save_freq; decide: resume or re-dispatch."
    if signal_type == "run-card-malformed":
        return f"Fix run card frontmatter (missing run-id) at wiki/runs/{run_id}/index.md."
    return "Review run state."


# ─── Run card summary update ────────────────────────────────────────────

_HEARTBEATS_SECTION_RE = re.compile(
    r"(## Heartbeats\n).*?(?=\n## |\Z)",
    re.DOTALL
)

_HEARTBEATS_HEADER = "## Heartbeats\n"

_HEARTBEATS_TABLE_HEADER = (
    "<!-- scout-managed: do not edit manually -->\n"
    "| ts | step | loss | log mtime | app state |\n"
    "|---|---|---|---|---|\n"
)


def _heartbeat_row(hb):
    ts = hb.get("ts", "")
    step = hb.get("last_step", "—")
    loss = hb.get("last_loss", "—")
    mtime = hb.get("log_mtime", "—")
    if mtime and mtime != "—":
        mtime = mtime[:19].replace("T", " ")
    app_state = hb.get("app_state", "—")
    alert = hb.get("alert", "")
    if alert:
        app_state = f"{app_state} ⚠ {alert}"
    return f"| {ts[:19]} | {step} | {loss} | {mtime} | {app_state} |"


def update_run_card_summary(run_card_path, last_heartbeats):
    """Overwrite the ## Heartbeats section of the run card (rolling window, not append)."""
    try:
        text = run_card_path.read_text()
    except (IOError, OSError):
        return

    rows = "\n".join(_heartbeat_row(hb) for hb in last_heartbeats)
    section_body = _HEARTBEATS_TABLE_HEADER + rows + "\n"
    new_section = _HEARTBEATS_HEADER + section_body

    if _HEARTBEATS_SECTION_RE.search(text):
        updated = _HEARTBEATS_SECTION_RE.sub(new_section, text, count=1)
    else:
        # Inject before ## Outcome, or append at end
        if "\n## Outcome" in text:
            updated = text.replace("\n## Outcome", f"\n{new_section}\n## Outcome", 1)
        elif "\n## Receipts" in text:
            # Insert after Receipts section end
            idx = text.rfind("\n## ", text.index("\n## Receipts") + 1)
            if idx > 0:
                updated = text[:idx] + f"\n{new_section}" + text[idx:]
            else:
                updated = text.rstrip() + f"\n\n{new_section}"
        else:
            updated = text.rstrip() + f"\n\n{new_section}"

    try:
        run_card_path.write_text(updated)
    except (IOError, OSError) as e:
        print(f"scout: failed to update run card {run_card_path}: {e}", file=sys.stderr)


# ─── Completion handling ─────────────────────────────────────────────────

def handle_completion(project_root, meta, log_state):
    """On Modal status: completed, flip run card status and note checkpoint download needed."""
    run_card_path = meta["run_card_path"]
    run_id = meta["run_id"]

    try:
        text = run_card_path.read_text()
    except (IOError, OSError):
        return

    # Flip status: running → complete in frontmatter
    updated = re.sub(
        r"^(status:\s*)running(\s*)$",
        r"\1complete\2",
        text,
        flags=re.MULTILINE
    )

    # Fill in completion timestamp
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    updated = re.sub(
        r"^(completed-at:\s*)TBD(\s*)$",
        rf"\g<1>{now_iso}\2",
        updated,
        flags=re.MULTILINE
    )

    # Fill TBD scout fields in Receipts table
    if log_state.get("last_step"):
        updated = updated.replace(
            "| Total steps completed | TBD (scout) |",
            f"| Total steps completed | {log_state['last_step']} |"
        )
    if log_state.get("last_loss") is not None:
        updated = updated.replace(
            "| Final loss | TBD (scout) |",
            f"| Final loss | {log_state['last_loss']} |"
        )

    # Note that checkpoint download should be triggered
    checkpoint_note = (
        f"\n!!! note \"Training complete as of {now_iso}\"\n"
        f"    Modal app {meta.get('app_id')} reports completed. "
        f"Run the checkpoint download script to pull weights:\n"
        f"    `python tools/training-ground/scripts/download_checkpoint.py --run-id {run_id}`\n"
        f"    Then update the Checkpoint row in Receipts above.\n"
    )
    if "Training complete" not in updated:
        updated = updated.replace(
            "!!! warning \"Fill post-run\"",
            checkpoint_note + "!!! warning \"Fill post-run\"",
            1
        )

    try:
        run_card_path.write_text(updated)
        print(f"scout: {run_id} complete — run card updated, status: complete")
    except (IOError, OSError) as e:
        print(f"scout: failed to update run card on completion: {e}", file=sys.stderr)


# ─── Main scout loop ─────────────────────────────────────────────────────

def run(project_root=None, dry_run=False, verbose=False):
    """Main entry point. Called by daemon (mode: deterministic) or CLI."""
    if project_root is None:
        project_root = find_project_root()
    project_root = Path(project_root).resolve()

    run_cards = discover_running_runs(project_root)

    if not run_cards:
        if verbose:
            print("scout: no running runs found")
        return {"checked": 0, "heartbeats_written": 0, "signals_fired": []}

    results = {"checked": 0, "heartbeats_written": 0, "signals_fired": []}

    for run_card_path in run_cards:
        meta = parse_run_card(run_card_path)

        if meta is None:
            # Malformed card — fire signal and skip
            run_id = run_card_path.parent.name
            print(f"scout: {run_id} run card malformed (no run-id) — firing signal")
            if not dry_run:
                bad_meta = {"run_id": run_id, "app_id": None}
                fire_signal(project_root, "run-card-malformed", bad_meta, {})
            continue

        run_id = meta["run_id"]
        results["checked"] += 1

        if meta["watcher_off"]:
            if verbose:
                print(f"scout: {run_id} watcher: off — skipping")
            continue

        app_state = check_modal_app_status(meta["app_id"])
        log_state = check_log(meta["log_path"])

        if verbose or True:  # always log to stdout for daemon visibility
            print(
                f"scout: {run_id} app={app_state} "
                f"step={log_state['last_step']} loss={log_state['last_loss']} "
                f"stale={log_stale(log_state)}"
            )

        # Detect preemption: step regression + "Runner interrupted" in log
        current_step = log_state.get("last_step")
        step_regressed = check_step_regression(project_root, run_id, current_step)
        is_preempted = step_regressed and log_state.get("preempted", False)

        alert = None
        if is_preempted:
            alert = "preempted"
        elif log_stale(log_state):
            alert = "stale"
        elif app_state == "failed":
            alert = "failed"

        if not dry_run:
            sidecar, hb = write_heartbeat(project_root, run_id, app_state, log_state, alert)
            results["heartbeats_written"] += 1
            if verbose:
                print(f"scout: wrote heartbeat → {sidecar}")

            # Update run card rolling summary
            last_n = read_last_heartbeats(project_root, run_id)
            update_run_card_summary(run_card_path, last_n)

            # Fire signals
            if is_preempted:
                prev_hbs = read_last_heartbeats(project_root, run_id, n=3)
                prev_step = prev_hbs[-2].get("last_step") if len(prev_hbs) >= 2 else None
                wasted = (prev_step or 0) - (current_step or 0)
                gpu_cost_hr = _GPU_COST_PER_HOUR.get(meta.get("machine", ""), 1.10)
                cost_estimate = round(wasted / _APPROX_STEPS_PER_HOUR * gpu_cost_hr, 2)
                extra = {
                    "wasted_steps": wasted,
                    "previous_step": prev_step,
                    "cost_estimate_usd": cost_estimate,
                }
                sig = fire_signal(project_root, "preempted", meta, log_state, extra)
                if sig:
                    results["signals_fired"].append(str(sig))
                    print(f"scout: {run_id} preemption signal → {sig}")

            elif log_stale(log_state):
                sig = fire_signal(project_root, "stale", meta, log_state)
                if sig:
                    results["signals_fired"].append(str(sig))
                    print(f"scout: {run_id} stale signal → {sig}")

            elif app_state == "failed":
                sig = fire_signal(project_root, "failed", meta, log_state)
                if sig:
                    results["signals_fired"].append(str(sig))
                    print(f"scout: {run_id} failed signal → {sig}")

            elif app_state == "completed":
                handle_completion(project_root, meta, log_state)

    return results


# ─── CLI ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="training-run-watcher — deterministic scout for Modal training jobs"
    )
    parser.add_argument(
        "--project-dir", default=None,
        help="Project root (default: auto-discover from CWD)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Discover and check runs without writing heartbeats or signals"
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Extra output"
    )
    args = parser.parse_args()

    root = Path(args.project_dir) if args.project_dir else None
    result = run(root, dry_run=args.dry_run, verbose=args.verbose)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
