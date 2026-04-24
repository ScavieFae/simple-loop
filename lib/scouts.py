#!/usr/bin/env python3
"""Specialist (scout) parser + scheduler helpers + output contract enforcement.

Brief-034 cycle 4. Single-file declarative scouts live at
`.loop/specialists/<name>.md` with YAML-lite frontmatter (cadence, model,
max_runs_per_day, max_runtime_seconds, outputs, kill_on). This module is the
script-over-inference layer: bash-side `invoke_scouts()` in daemon.sh calls
into here for every cadence/cap/kill-on check and for post-filtering scout
output against the declared `outputs` contract.

State-free by design: cadence + daily-cap tracking reads back from
`.loop/state/log.jsonl` (scout_fire / scout_noop / scout_failed events
written via `log_scout_event` below). No per-scout state files, matching the
plan.md §4 decision ("shared state via append-only").

CLI:
    python3 lib/scouts.py parse           <specialist_path>
    python3 lib/scouts.py get-field       <specialist_path> <field>
    python3 lib/scouts.py get-body        <specialist_path>
    python3 lib/scouts.py is-due          <specialist_path> <project_dir>
    python3 lib/scouts.py over-daily-cap  <specialist_path> <project_dir>
    python3 lib/scouts.py check           <specialist_path> <project_dir>
    python3 lib/scouts.py apply-output-contract <specialist_path> <scout_json> <project_dir>
    python3 lib/scouts.py record-fire     <specialist_path> <project_dir> \\
                                          <exit_code> <duration_ms> <wrote_flag>
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta

# Re-use actions.log_action for log.jsonl appends (same path cycle 3 took;
# when scripts/log-event.py lands in bundle via cycle 6, these call sites
# flip to it in one pass).
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
from actions import init_paths, log_action  # noqa: E402


# ─── Frontmatter parser ──────────────────────────────────────────────
# YAML-lite: scalars, nested single-level dicts, and simple lists. Enough
# for the scout schema (cadence, kill_on). Intentionally stdlib-only.

def parse_specialist(path):
    """Read a specialist file. Returns (frontmatter: dict, body: str).

    Frontmatter is the content between the first two `---` lines; body is
    everything after. Missing frontmatter → ({}, full_text). Malformed
    frontmatter is tolerated — keys that parse, parse; others are dropped.
    """
    if not path or not os.path.exists(path):
        return {}, ""
    with open(path) as f:
        text = f.read()
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, text
    fm_lines = lines[1:end]
    body = "\n".join(lines[end + 1:]).lstrip("\n")
    return _parse_yaml_lite(fm_lines), body


def _parse_yaml_lite(lines):
    """Parse a subset of YAML: scalar, nested dict (1 level), list of scalars.

    Examples handled:
        name: foo
        cadence:
          every: 30m
        kill_on:
          - daemon-stop
          - 3-consecutive-failures
    """
    out = {}
    i = 0
    n = len(lines)
    while i < n:
        raw = lines[i]
        # Skip blank/comment lines
        if not raw.strip() or raw.strip().startswith("#"):
            i += 1
            continue
        # Top-level key (no leading whitespace).
        if raw[0] in (" ", "\t"):
            i += 1
            continue
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*$", raw)
        if not m:
            i += 1
            continue
        key = m.group(1)
        inline = m.group(2).strip()
        if inline:
            # Trim quotes.
            out[key] = _scalar(inline)
            i += 1
            continue
        # Look ahead for a nested block (indented children).
        j = i + 1
        children = []
        while j < n:
            nxt = lines[j]
            if not nxt.strip():
                children.append(nxt)
                j += 1
                continue
            if nxt[0] in (" ", "\t"):
                children.append(nxt)
                j += 1
                continue
            break
        # Detect whether children are list items or a dict.
        list_items = []
        dict_items = {}
        is_list = False
        for c in children:
            stripped = c.strip()
            if not stripped:
                continue
            li = re.match(r"^-\s*(.*?)\s*$", stripped)
            if li:
                is_list = True
                if li.group(1):
                    list_items.append(_scalar(li.group(1)))
                continue
            di = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*$", stripped)
            if di:
                dict_items[di.group(1)] = _scalar(di.group(2))
        if is_list:
            out[key] = list_items
        elif dict_items:
            out[key] = dict_items
        else:
            out[key] = ""
        i = j
    return out


def _scalar(s):
    s = s.strip()
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    # Numeric coercion (int only — cadence-string parse handles duration).
    if re.match(r"^-?\d+$", s):
        try:
            return int(s)
        except ValueError:
            return s
    lower = s.lower()
    if lower in ("true", "false"):
        return lower == "true"
    return s


# ─── Cadence ─────────────────────────────────────────────────────────

_EVERY_RE = re.compile(r"^\s*(\d+)\s*([smhd])\s*$", re.IGNORECASE)


def cadence_seconds(fm):
    """Return the scout's cadence as a positive int second-interval.

    Reads `cadence.every` (preferred) or legacy top-level `cadence` scalar.
    `cron:` forms are not supported in v0 — if present, returns 0 and
    caller treats the scout as always-due (cron scheduling is follow-up).
    """
    cad = fm.get("cadence", {})
    every = None
    if isinstance(cad, dict):
        every = cad.get("every")
        if cad.get("cron") and not every:
            return 0
    elif isinstance(cad, str):
        every = cad
    if not every:
        return 0
    m = _EVERY_RE.match(str(every))
    if not m:
        return 0
    n = int(m.group(1))
    unit = m.group(2).lower()
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return max(1, n * mult)


# ─── log.jsonl scan for scout events ─────────────────────────────────

_SCOUT_ACTIONS = ("daemon:scout_fire", "daemon:scout_noop", "daemon:scout_failed")


def _iter_scout_events(paths, name=None):
    """Yield scout events from log.jsonl, newest-last. name filter optional."""
    log_path = paths["log_file"]
    if not os.path.exists(log_path):
        return
    try:
        with open(log_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                act = e.get("action", "")
                if act not in _SCOUT_ACTIONS:
                    continue
                if name and e.get("specialist") != name:
                    continue
                yield e
    except (IOError, OSError):
        return


def _parse_ts(ts_str):
    if not ts_str:
        return None
    try:
        if ts_str.endswith("Z"):
            return datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        dt = datetime.fromisoformat(ts_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def last_scout_event(paths, name):
    """Return the most recent scout event dict for `name`, or None."""
    last = None
    for e in _iter_scout_events(paths, name=name):
        last = e
    return last


def fire_count_today(paths, name):
    """Count scout events (fire+noop+failed) for today's UTC date."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    count = 0
    for e in _iter_scout_events(paths, name=name):
        ts_str = e.get("ts") or e.get("timestamp", "")
        if ts_str.startswith(today):
            count += 1
    return count


def consecutive_failures(paths, name, limit=10):
    """Count trailing scout_failed events in log (stops at first non-failed)."""
    events = list(_iter_scout_events(paths, name=name))
    count = 0
    for e in reversed(events[-limit:]):
        if e.get("action") == "daemon:scout_failed":
            count += 1
        else:
            break
    return count


# ─── Scheduler checks ─────────────────────────────────────────────────

def is_due(specialist_path, project_dir):
    """True if cadence has elapsed since the last scout event."""
    paths = init_paths(project_dir)
    fm, _ = parse_specialist(specialist_path)
    interval = cadence_seconds(fm)
    if interval <= 0:
        # No parseable cadence → never auto-fire.
        return False
    name = fm.get("name") or os.path.splitext(os.path.basename(specialist_path))[0]
    ev = last_scout_event(paths, name)
    if not ev:
        return True
    ts = _parse_ts(ev.get("ts") or ev.get("timestamp"))
    if not ts:
        return True
    age = (datetime.now(timezone.utc) - ts).total_seconds()
    return age >= interval


def over_daily_cap(specialist_path, project_dir):
    """True if today's fire count has reached `max_runs_per_day`."""
    paths = init_paths(project_dir)
    fm, _ = parse_specialist(specialist_path)
    cap = fm.get("max_runs_per_day", 0)
    try:
        cap = int(cap)
    except (ValueError, TypeError):
        cap = 0
    if cap <= 0:
        return False
    name = fm.get("name") or os.path.splitext(os.path.basename(specialist_path))[0]
    return fire_count_today(paths, name) >= cap


def check(specialist_path, project_dir):
    """Evaluate kill_on conditions. Returns 'skip' | 'kill' | 'go'.

    'skip' — transient reason not to fire this tick (daemon-stop flag,
             missing-goals-md, etc.). Re-check next tick.
    'kill' — permanent reason to disable this scout (N-consecutive-failures,
             scout file malformed). Removal is owner-directed — scheduler
             just logs and skips until the condition clears.
    'go'   — proceed. Caller still checks is-due + over-daily-cap separately.
    """
    paths = init_paths(project_dir)
    fm, _ = parse_specialist(specialist_path)
    name = fm.get("name") or os.path.splitext(os.path.basename(specialist_path))[0]

    kill_on = fm.get("kill_on", [])
    if not isinstance(kill_on, list):
        kill_on = [kill_on] if kill_on else []

    signals_dir = os.path.join(paths["state_dir"], "signals")
    goals_file = os.path.join(paths["state_dir"], "goals.md")

    for cond in kill_on:
        cond = str(cond).strip().lower()
        if cond == "daemon-stop":
            # Skip only if a pause signal is active (daemon is being stopped).
            if os.path.exists(os.path.join(signals_dir, "pause.json")):
                return "skip"
        elif cond == "missing-goals-md":
            if not os.path.exists(goals_file):
                return "skip"
        else:
            m = re.match(r"^(\d+)-consecutive-failures$", cond)
            if m:
                threshold = int(m.group(1))
                if consecutive_failures(paths, name) >= threshold:
                    return "kill"
    return "go"


# ─── Output-contract enforcement ──────────────────────────────────────

_CONTRACTS = {
    "stewardship-log-append",
    "signals-issue-file",
    "brief-draft",
    "log-only",
}

_NOOP_MARKERS = (
    "__NOOP__",
    "(no observation)",
    "no observation",
    "nothing to report",
    "no-op",
)


def _extract_result(scout_json_path):
    """Pull the `result` string from claude -p JSON output."""
    if not os.path.exists(scout_json_path):
        return ""
    try:
        with open(scout_json_path) as f:
            data = json.load(f)
    except (IOError, OSError, json.JSONDecodeError, ValueError):
        return ""
    result = data.get("result", "")
    if not isinstance(result, str):
        return ""
    return result.strip()


def _is_noop(text):
    if not text.strip():
        return True
    low = text.strip().lower()
    return any(marker.lower() in low[:80] for marker in _NOOP_MARKERS)


def _today_str():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _stewardship_log_path(project_dir):
    return os.path.join(
        project_dir, ".loop", "state",
        f"stewardship-log-{_today_str()}.md",
    )


def _signals_issue_path(project_dir, name):
    return os.path.join(
        project_dir, ".loop", "state", "signals", "issues",
        f"{name}-{_today_str()}.md",
    )


def _brief_draft_path(project_dir, name):
    return os.path.join(
        project_dir, ".loop", "briefs", "drafts",
        f"{name}-{_today_str()}.md",
    )


def apply_output_contract(specialist_path, scout_json_path, project_dir):
    """Filter the scout's output to match its declared `outputs` contract.

    Returns ("wrote", dest_path) on successful write, ("noop", "") when the
    scout intentionally produced nothing, or ("rejected", reason) when the
    output violates the contract (e.g. unknown contract name, log-only scout
    returning text). The daemon's `fire_scout` maps ("wrote", …) to a
    scout_fire event and everything else to scout_noop / scout_failed.
    """
    fm, _ = parse_specialist(specialist_path)
    contract = str(fm.get("outputs", "")).strip()
    name = fm.get("name") or os.path.splitext(os.path.basename(specialist_path))[0]

    if contract not in _CONTRACTS:
        return ("rejected", f"unknown_contract:{contract or 'missing'}")

    result = _extract_result(scout_json_path)
    if _is_noop(result):
        return ("noop", "")

    if contract == "log-only":
        # log-only scouts shouldn't produce a result payload; a filled result
        # is a contract violation worth surfacing (not writing — see scout_failed).
        return ("rejected", "log_only_scout_produced_text")

    if contract == "stewardship-log-append":
        dest = _stewardship_log_path(project_dir)
        header = f"\n## {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')} UTC — {name}\n\n"
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "a") as f:
            f.write(header + result.rstrip() + "\n")
        return ("wrote", dest)

    if contract == "signals-issue-file":
        dest = _signals_issue_path(project_dir, name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as f:
            f.write(result.rstrip() + "\n")
        return ("wrote", dest)

    if contract == "brief-draft":
        dest = _brief_draft_path(project_dir, name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as f:
            f.write(result.rstrip() + "\n")
        return ("wrote", dest)

    return ("rejected", f"unhandled_contract:{contract}")


# ─── Fire-recording (log event emission) ──────────────────────────────

def log_scout_event(paths, action, name, **fields):
    """Append a daemon:scout_{fire,noop,failed} line to log.jsonl."""
    assert action in ("scout_fire", "scout_noop", "scout_failed")
    details = {"specialist": name}
    details.update({k: v for k, v in fields.items() if v is not None})
    log_action(paths, action, details)


def record_fire(specialist_path, project_dir, exit_code, duration_ms,
                output_status, output_dest=""):
    """Map (exit_code, output_status) to the right scout_* event + log it."""
    paths = init_paths(project_dir)
    fm, _ = parse_specialist(specialist_path)
    name = fm.get("name") or os.path.splitext(os.path.basename(specialist_path))[0]
    outputs = fm.get("outputs", "")

    try:
        exit_code = int(exit_code)
    except (ValueError, TypeError):
        exit_code = 1
    try:
        duration_ms = int(duration_ms)
    except (ValueError, TypeError):
        duration_ms = 0

    if exit_code != 0:
        log_scout_event(paths, "scout_failed", name,
                        exit_code=exit_code, duration_ms=duration_ms,
                        outputs=outputs)
        return "scout_failed"
    if output_status == "wrote":
        log_scout_event(paths, "scout_fire", name,
                        duration_ms=duration_ms, outputs=outputs,
                        output_path=output_dest)
        return "scout_fire"
    if output_status == "rejected":
        log_scout_event(paths, "scout_failed", name,
                        duration_ms=duration_ms, outputs=outputs,
                        reason=output_dest or "contract_violation")
        return "scout_failed"
    log_scout_event(paths, "scout_noop", name,
                    duration_ms=duration_ms, outputs=outputs)
    return "scout_noop"


# ─── CLI ──────────────────────────────────────────────────────────────

def _print_field(fm, field):
    val = fm.get(field, "")
    if isinstance(val, (dict, list)):
        print(json.dumps(val))
    else:
        print(val)


def main():
    if len(sys.argv) < 2:
        print("Usage: scouts.py <command> [args...]", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]

    if cmd == "parse":
        fm, body = parse_specialist(sys.argv[2])
        print(json.dumps({"frontmatter": fm, "body_len": len(body)}))
        return
    if cmd == "get-field":
        fm, _ = parse_specialist(sys.argv[2])
        _print_field(fm, sys.argv[3])
        return
    if cmd == "get-body":
        _, body = parse_specialist(sys.argv[2])
        sys.stdout.write(body)
        return
    if cmd == "is-due":
        print("yes" if is_due(sys.argv[2], sys.argv[3]) else "no")
        return
    if cmd == "over-daily-cap":
        print("yes" if over_daily_cap(sys.argv[2], sys.argv[3]) else "no")
        return
    if cmd == "check":
        print(check(sys.argv[2], sys.argv[3]))
        return
    if cmd == "apply-output-contract":
        status, dest = apply_output_contract(sys.argv[2], sys.argv[3], sys.argv[4])
        print(f"{status}\t{dest}")
        # Exit code: 0 = wrote, 1 = noop, 2 = rejected
        if status == "wrote":
            sys.exit(0)
        if status == "noop":
            sys.exit(1)
        sys.exit(2)
    if cmd == "record-fire":
        # record-fire <spec> <project_dir> <exit_code> <duration_ms> <output_status> [output_dest]
        spec, pdir, ec, dms, ostat = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
        odest = sys.argv[7] if len(sys.argv) > 7 else ""
        ev = record_fire(spec, pdir, ec, dms, ostat, odest)
        print(ev)
        return

    print(f"Unknown command: {cmd}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
