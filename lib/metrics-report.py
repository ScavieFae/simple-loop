#!/usr/bin/env python3
"""Aggregate loop metrics into cost reports.

Reads .loop/state/metrics.jsonl and prints a markdown report.

Usage:
    python3 lib/metrics-report.py <project_dir>
    python3 lib/metrics-report.py <project_dir> --since 2026-02-19
"""

import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone


def load_metrics(metrics_file, since=None):
    """Load metrics entries, optionally filtered by date."""
    entries = []
    if not os.path.exists(metrics_file):
        return entries
    with open(metrics_file) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if since:
                ts = entry.get("timestamp", "")[:10]
                if ts < since:
                    continue
            entries.append(entry)
    return entries


def aggregate(entries):
    """Compute summary statistics from metrics entries."""
    total_cost = 0
    conductor_cost = 0
    worker_cost = 0
    conductor_count = 0
    worker_count = 0
    total_input = 0
    total_output = 0

    by_brief = defaultdict(lambda: {
        "cost": 0, "iterations": 0, "duration_ms": 0, "errors": 0,
    })
    by_day = defaultdict(lambda: {
        "total_cost": 0, "conductor_cost": 0, "worker_cost": 0,
        "conductors": 0, "iterations": 0,
    })

    for e in entries:
        cost = e.get("cost_usd", 0)
        source = e.get("source", "unknown")
        day = e.get("timestamp", "")[:10]

        total_cost += cost
        total_input += e.get("input_tokens", 0)
        total_output += e.get("output_tokens", 0)

        if source == "conductor":
            conductor_cost += cost
            conductor_count += 1
            by_day[day]["conductor_cost"] += cost
            by_day[day]["conductors"] += 1
        elif source == "worker":
            worker_cost += cost
            worker_count += 1
            brief = e.get("brief", "unknown")
            b = by_brief[brief]
            b["cost"] += cost
            b["iterations"] += 1
            b["duration_ms"] += e.get("duration_ms", 0)
            if e.get("is_error") or e.get("exit_code", 0) != 0:
                b["errors"] += 1
            by_day[day]["worker_cost"] += cost
            by_day[day]["iterations"] += 1

        by_day[day]["total_cost"] += cost

    overhead_pct = (conductor_cost / total_cost * 100) if total_cost > 0 else 0

    return {
        "total_cost": total_cost,
        "worker_cost": worker_cost,
        "conductor_cost": conductor_cost,
        "overhead_pct": overhead_pct,
        "conductor_count": conductor_count,
        "worker_count": worker_count,
        "total_input_tokens": total_input,
        "total_output_tokens": total_output,
        "by_brief": dict(by_brief),
        "by_day": dict(by_day),
    }


def format_duration(ms):
    secs = ms / 1000
    if secs < 60:
        return f"{secs:.0f}s"
    return f"{secs / 60:.0f}m"


def markdown_report(summary):
    lines = []
    lines.append("# Loop Metrics Report")
    lines.append("")

    lines.append("## Cost Summary")
    lines.append(f"- **Total:** ${summary['total_cost']:.2f}")
    prod_pct = 100 - summary["overhead_pct"]
    lines.append(f"- **Worker (productive):** ${summary['worker_cost']:.2f} ({prod_pct:.0f}%)")
    lines.append(f"- **Conductor (overhead):** ${summary['conductor_cost']:.2f} ({summary['overhead_pct']:.0f}%)")
    lines.append(f"- **Conductor sessions:** {summary['conductor_count']}")
    lines.append(f"- **Worker iterations:** {summary['worker_count']}")
    lines.append("")

    lines.append("## Token Usage")
    lines.append(f"- Input: {summary['total_input_tokens']:,}")
    lines.append(f"- Output: {summary['total_output_tokens']:,}")
    lines.append("")

    if summary["by_brief"]:
        lines.append("## Per-Brief Costs")
        lines.append("| Brief | Cost | Iters | Errors | Duration |")
        lines.append("|-------|------|-------|--------|----------|")
        for name, data in sorted(summary["by_brief"].items()):
            dur = format_duration(data["duration_ms"])
            lines.append(f"| {name} | ${data['cost']:.2f} | {data['iterations']} | {data['errors']} | {dur} |")
        lines.append("")

    if summary["by_day"]:
        lines.append("## Daily Breakdown")
        lines.append("| Date | Total | Conductors | Workers | Conductor $ | Worker $ |")
        lines.append("|------|-------|------------|---------|-------------|----------|")
        for day, data in sorted(summary["by_day"].items()):
            lines.append(
                f"| {day} | ${data['total_cost']:.2f} "
                f"| {data['conductors']} | {data['iterations']} "
                f"| ${data['conductor_cost']:.2f} | ${data['worker_cost']:.2f} |"
            )
        lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <project_dir> [--since DATE]", file=sys.stderr)
        sys.exit(1)

    project_dir = sys.argv[1]
    metrics_file = os.path.join(project_dir, ".loop", "state", "metrics.jsonl")

    since = None
    if "--since" in sys.argv:
        idx = sys.argv.index("--since")
        if idx + 1 < len(sys.argv):
            since = sys.argv[idx + 1]

    entries = load_metrics(metrics_file, since)
    if not entries:
        print("No metrics data yet.", file=sys.stderr)
        sys.exit(0)

    summary = aggregate(entries)
    print(markdown_report(summary))


if __name__ == "__main__":
    main()
