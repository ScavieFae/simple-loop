#!/usr/bin/env python3
"""log-event.py — append a `daemon:<action>` entry to .loop/state/log.jsonl.

Shell-callable companion to `actions.log_action()` (Python). Same on-disk shape,
so Python callers (actions.py, scouts.py) and shell callers (daemon.sh, scripts)
can interleave without schema drift.

Usage:
    log-event.py <action> [--field key=value]... [--project-dir DIR]
    log-event.py <action> --json '{"k":"v"}' [--project-dir DIR]

Examples:
    # Concurrency skip
    log-event.py concurrency_skip \\
        --field brief_id=brief-032 \\
        --field blocked_by=brief-028 \\
        --field overlap_paths='["crates/"]'

    # Throttle reached
    log-event.py throttle_reached --field throttle=2 --field in_flight_count=2

    # Scout events
    log-event.py scout_fire  --field specialist=queue-steward --field duration_ms=1823
    log-event.py scout_noop  --field specialist=queue-steward --field duration_ms=210

--field values are parsed as JSON first (so `count=3` → int, `enabled=true` →
bool, and `paths=["a","b"]` → list). A parse failure falls back to string.

Action names are validated against the brief-034 cycle 6 observability set.
New events can be added to the ALLOWED set or passed through with --force.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from pathlib import Path


# brief-034 cycle 6 observability events. Keep grep-able + explicit — the point
# is that schema drift across emitters is visible in this file, not scattered.
ALLOWED = {
    "concurrency_skip",     # conductor declined to dispatch (edit-surface overlap)
    "throttle_reached",     # conductor declined to dispatch (THROTTLE cap hit)
    "scout_fire",           # specialist ran + wrote output to contract path
    "scout_noop",           # specialist ran + emitted noop sentinel
    "scout_failed",         # specialist exit != 0 OR contract rejected output
    "rate_limit_429",       # worker/conductor 429'd by the API
}


def parse_field(spec: str) -> tuple[str, object]:
    """Parse a key=value field. Value goes through JSON first, falls back to str."""
    if "=" not in spec:
        raise argparse.ArgumentTypeError(
            f"bad --field {spec!r}: expected key=value"
        )
    key, _, raw = spec.partition("=")
    key = key.strip()
    if not key:
        raise argparse.ArgumentTypeError(f"bad --field {spec!r}: empty key")
    try:
        return key, json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return key, raw


def resolve_log_file(project_dir: str | None) -> Path:
    """Locate .loop/state/log.jsonl starting from --project-dir or cwd."""
    if project_dir:
        base = Path(project_dir).resolve()
    else:
        base = Path.cwd().resolve()
    # Walk up until we find a .loop directory (or give up at filesystem root).
    for candidate in [base, *base.parents]:
        loop = candidate / ".loop"
        if loop.is_dir():
            return loop / "state" / "log.jsonl"
    # Fallback: expect .loop under the starting dir even if absent. The file
    # gets created on first write; the dir must exist.
    return base / ".loop" / "state" / "log.jsonl"


def emit(action: str, fields: dict, log_file: Path) -> None:
    """Append the entry. Matches actions.log_action() shape exactly."""
    entry = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc)
                      .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "action": f"daemon:{action}",
    }
    # Per-field wins over colliding reserved keys only if caller set them.
    entry.update(fields)
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a") as f:
        f.write(json.dumps(entry) + "\n")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="log-event.py",
        description="Append a structured event to .loop/state/log.jsonl.",
    )
    p.add_argument("action", help="Event name (e.g. scout_fire, concurrency_skip).")
    p.add_argument(
        "--field", action="append", default=[], type=parse_field,
        help="key=value pair. Value parsed as JSON with string fallback. Repeatable.",
    )
    p.add_argument(
        "--json", dest="json_blob", default=None,
        help="JSON object; merged with --field (field takes precedence on conflict).",
    )
    p.add_argument(
        "--project-dir", default=None,
        help="Project root (contains .loop/). Default: walk up from cwd.",
    )
    p.add_argument(
        "--force", action="store_true",
        help="Allow non-allowlisted action names. Default: reject with exit 2.",
    )
    args = p.parse_args(argv)

    if args.action not in ALLOWED and not args.force:
        allowed = ", ".join(sorted(ALLOWED))
        print(
            f"log-event.py: unknown action {args.action!r}. "
            f"Use --force to bypass. Known: {allowed}",
            file=sys.stderr,
        )
        return 2

    fields: dict = {}
    if args.json_blob:
        try:
            loaded = json.loads(args.json_blob)
        except json.JSONDecodeError as e:
            print(f"log-event.py: --json parse error: {e}", file=sys.stderr)
            return 2
        if not isinstance(loaded, dict):
            print("log-event.py: --json must be an object", file=sys.stderr)
            return 2
        fields.update(loaded)
    for k, v in args.field:
        fields[k] = v

    log_file = resolve_log_file(args.project_dir)
    try:
        emit(args.action, fields, log_file)
    except OSError as e:
        print(f"log-event.py: write failed to {log_file}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
