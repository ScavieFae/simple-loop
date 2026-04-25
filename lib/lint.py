#!/usr/bin/env python3
"""
loop lint — deterministic brief-format linter.

Checks brief files for format drift that the daemon can't parse.
No LLM calls. Subsecond per file. Read-only.

Exit codes:
  0 — clean
  1 — drift detected
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional, Tuple

# ── Severity ─────────────────────────────────────────────────

ERROR = "error"
WARNING = "warning"
INFO = "info"

SEVERITY_ICON = {
    ERROR: "❌",
    WARNING: "⚠️",
    INFO: "ℹ️",
}


@dataclass
class Issue:
    severity: str
    message: str
    expected: str = ""
    fix: str = ""


# ── Required field regexes ───────────────────────────────────

REQUIRED_FIELDS = {
    "ID": re.compile(r"^\*\*ID:\*\*\s*\S+", re.MULTILINE),
    "Branch": re.compile(r"^\*\*Branch:\*\*\s*\S+", re.MULTILINE),
    "Status": re.compile(r"^\*\*Status:\*\*\s*\S+", re.MULTILINE),
    "Model": re.compile(r"^\*\*Model:\*\*\s*\S+", re.MULTILINE),
    "Auto-merge": re.compile(r"^\*\*Auto-merge:\*\*\s*\S+", re.MULTILINE),
    "Validator": re.compile(r"^\*\*Validator:\*\*\s*\S+", re.MULTILINE),
    "Human-gate": re.compile(r"^\*\*Human-gate:\*\*\s*\S+", re.MULTILINE),
}

BUDGET_SECTION_RE = re.compile(r"^## Budget\s*$", re.MULTILINE)
BUDGET_OPENER_RE = re.compile(r"^\*\*\d+\s+cycles?\s+\w+\.\*\*", re.MULTILINE)

DEPENDS_ON_RE = re.compile(r"^\*\*Depends-on:\*\*\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)
BRIEF_ID_RE = re.compile(r"^brief-\d+(-[\w]+)*$")

ADR_FIELD_RE = re.compile(r"^\*\*ADRs?:\*\*\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)
ADR_NUMBER_RE = re.compile(r"\b(\d{3})\b")

MANDATORY_LINK_RE = re.compile(r"\[.*?\]\(((?!https?://)[^)]+\.md[^)]*)\)", re.MULTILINE)

YAML_FRONTMATTER_RE = re.compile(r"^---\s*$", re.MULTILINE)
MD_FIELD_RE = re.compile(r"^\*\*\w", re.MULTILINE)


# ── Check 1: Frontmatter style ───────────────────────────────

def check_frontmatter_style(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """Frontmatter must be markdown-emphasis lines, not YAML --- blocks."""
    if YAML_FRONTMATTER_RE.search(content):
        return [Issue(
            severity=ERROR,
            message="YAML frontmatter (`---` block) detected.",
            expected="Frontmatter uses markdown-emphasis lines: `**Field:** value`",
            fix="Remove the `---` delimiters. Each field should be a standalone bold-label line.",
        )]
    return []


# ── Check 2: Required fields ─────────────────────────────────

def check_required_fields(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """All required frontmatter fields must be present."""
    issues = []
    for field_name, pattern in REQUIRED_FIELDS.items():
        if not pattern.search(content):
            issues.append(Issue(
                severity=ERROR,
                message=f"Missing required field `**{field_name}:**`.",
                expected=f"`**{field_name}:** <value>` on its own line near the top of the brief.",
                fix=f"Add `**{field_name}:** <value>` after the title.",
            ))
    return issues


# ── Check 3: Budget section ──────────────────────────────────

def check_budget_section(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """## Budget section must exist with a parseable opener."""
    if not BUDGET_SECTION_RE.search(content):
        return [Issue(
            severity=ERROR,
            message="Missing `## Budget` section. Hive cycle-X/Y display will fall back to event count.",
            expected="A `## Budget` header followed by a line like `**N cycles sonnet.**`",
            fix="Insert `## Budget\\n\\n**N cycles sonnet.** [rationale]\\n` before `## Completion criteria`.",
        )]

    # Section exists — check for parseable opener
    # Find the content after ## Budget
    budget_match = BUDGET_SECTION_RE.search(content)
    after_budget = content[budget_match.end():]
    # Take up to the next ## section
    next_section = re.search(r"^##\s", after_budget, re.MULTILINE)
    budget_body = after_budget[:next_section.start()] if next_section else after_budget

    if not BUDGET_OPENER_RE.search(budget_body):
        return [Issue(
            severity=ERROR,
            message="`## Budget` section exists but has no parseable opener.",
            expected="First non-empty line after `## Budget` should be `**N cycles MODEL.**`",
            fix="Add e.g. `**3 cycles sonnet.**` as the first line of the Budget section.",
        )]
    return []


# ── Check 4: Depends-on validity ────────────────────────────

def check_depends_on(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """Depends-on must be absent, or a real brief-id — not 'none' or empty."""
    m = DEPENDS_ON_RE.search(content)
    if not m:
        return []  # absent is fine

    raw = m.group(1).strip()
    if not raw:
        return [Issue(
            severity=ERROR,
            message="`**Depends-on:**` field is present but empty.",
            expected="Either omit the field or list real brief IDs: `**Depends-on:** brief-042-slug`",
            fix="Remove `**Depends-on:**` entirely if there are no dependencies.",
        )]

    # Split on commas
    tokens = [t.strip().strip(".,;") for t in raw.split(",") if t.strip().strip(".,;")]

    issues = []
    for tok in tokens:
        if tok.lower() == "none":
            issues.append(Issue(
                severity=ERROR,
                message=f"`**Depends-on:** none` — literal 'none' is treated as a brief ID by the daemon, causing a permanent dispatch block.",
                expected="Omit the `**Depends-on:**` field entirely when there are no dependencies.",
                fix="Remove the `**Depends-on:**` line.",
            ))
        elif not BRIEF_ID_RE.match(tok):
            issues.append(Issue(
                severity=WARNING,
                message=f"`**Depends-on:**` value `{tok}` doesn't match `brief-NNN` or `brief-NNN-slug` format.",
                expected="Each dep should match `brief-\\d+(-\\w+)*` e.g. `brief-042` or `brief-042-camera-system`",
                fix=f"Check the spelling of `{tok}` against the actual brief ID.",
            ))
    return issues


# ── Check 5: Dep ID format consistency ──────────────────────

def check_dep_id_format(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """Each Depends-on value must be a well-formed brief ID."""
    # This overlaps check 4 — specifically the format regex check is already
    # in check 4 as a WARNING. Check 5 focuses on ID format *consistency* —
    # whether the ID is short-form vs full-form and whether that matters.
    # The daemon's history regex captures either form, so this is just a
    # formatting consistency warning, not an error.
    m = DEPENDS_ON_RE.search(content)
    if not m:
        return []

    raw = m.group(1).strip()
    tokens = [t.strip().strip(".,;") for t in raw.split(",") if t.strip().strip(".,;")]

    issues = []
    for tok in tokens:
        if tok.lower() == "none":
            continue  # already caught by check 4
        # Check for "brief-NNN" short form (no slug) — valid but note it
        # Short form is fine; this check passes. Only flag truly malformed IDs.
        if re.match(r"^brief-\d+$", tok):
            # Short form like brief-042 — valid
            pass
        elif re.match(r"^brief-\d+-", tok):
            # Full form like brief-042-slug — valid
            pass
        # Other formats already caught as WARNING in check 4
    return []


# ── Check 6: ADR resolution ──────────────────────────────────

def check_adr_resolution(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """ADRs field references must resolve to wiki/decisions/NNN-*.md."""
    m = ADR_FIELD_RE.search(content)
    if not m:
        return []

    raw = m.group(1).strip()
    if raw.lower() == "none":
        return []

    decisions_dir = project_root / "wiki" / "decisions"
    if not decisions_dir.exists():
        return []  # can't resolve without the decisions dir

    issues = []
    for num_match in ADR_NUMBER_RE.finditer(raw):
        adr_num = num_match.group(1)
        # Look for wiki/decisions/NNN-*.md
        matches = list(decisions_dir.glob(f"{adr_num}-*.md"))
        if not matches:
            issues.append(Issue(
                severity=WARNING,
                message=f"`**ADRs:** {adr_num}` — no file found at `wiki/decisions/{adr_num}-*.md`.",
                expected=f"A decision file at `wiki/decisions/{adr_num}-<slug>.md`",
                fix=f"Create `wiki/decisions/{adr_num}-slug.md` or fix the ADR number.",
            ))
    return issues


# ── Check 7: MANDATORY reading link resolution ───────────────

def check_mandatory_reading_links(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """MANDATORY reading section link paths must resolve."""
    # Find the MANDATORY reading section
    mandatory_match = re.search(r"^##\s+MANDATORY reading", content, re.MULTILINE | re.IGNORECASE)
    if not mandatory_match:
        return []

    # Extract section content up to next ##
    after = content[mandatory_match.end():]
    next_section = re.search(r"^##\s", after, re.MULTILINE)
    section = after[:next_section.start()] if next_section else after

    issues = []
    brief_dir = brief_path.parent

    for link_match in MANDATORY_LINK_RE.finditer(section):
        link_path_raw = link_match.group(1).split("#")[0]  # strip anchors
        if not link_path_raw:
            continue
        # Resolve relative to brief_path
        resolved = (brief_dir / link_path_raw).resolve()
        if not resolved.exists():
            issues.append(Issue(
                severity=WARNING,
                message=f"MANDATORY reading link `{link_path_raw}` does not resolve.",
                expected="All MANDATORY reading links must point to existing files.",
                fix=f"Check the path relative to `{brief_path}` or update the link.",
            ))
    return issues


# ── Check 8: Status consistency with running.json ────────────

def check_status_consistency(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """Brief Status field should be consistent with running.json's view."""
    status_m = re.search(r"^\*\*Status:\*\*\s*(\S+)", content, re.MULTILINE)
    if not status_m:
        return []  # missing field caught by check 2

    brief_status = status_m.group(1).lower()

    id_m = re.search(r"^\*\*ID:\*\*\s*(\S+)", content, re.MULTILINE)
    if not id_m:
        return []  # missing field caught by check 2
    brief_id = id_m.group(1).lower()

    running_file = project_root / ".loop" / "state" / "running.json"
    if not running_file.exists():
        return []

    try:
        with running_file.open() as f:
            running = json.load(f)
    except Exception:
        return []

    # Determine what running.json thinks about this brief
    active_ids = {e.get("brief", "").lower() for e in running.get("active", [])}
    pending_eval_ids = {e.get("brief", "").lower() for e in running.get("completed_pending_eval", [])}
    awaiting_review_ids = {e.get("brief", "").lower() for e in running.get("awaiting_review", [])}
    history_ids = {e.get("brief", "").lower() for e in running.get("history", [])}

    issues = []

    if brief_id in active_ids and brief_status == "queued":
        issues.append(Issue(
            severity=INFO,
            message=f"Brief `{brief_id}` says Status: queued but running.json has it active.",
            expected="Status field should be updated to `active` once dispatch happens.",
            fix="Update `**Status:** active` in the brief (or accept the drift as cosmetic).",
        ))
    elif brief_id in history_ids and brief_status == "queued":
        issues.append(Issue(
            severity=INFO,
            message=f"Brief `{brief_id}` says Status: queued but running.json shows it in history (merged).",
            expected="Status field should be `merged` or `complete` for finished briefs.",
            fix="Update `**Status:** merged` in the brief.",
        ))

    return issues


# ── Check registry ────────────────────────────────────────────

CHECKS: List[Tuple[str, Callable]] = [
    ("frontmatter-style", check_frontmatter_style),
    ("required-fields", check_required_fields),
    ("budget-section", check_budget_section),
    ("depends-on", check_depends_on),
    ("dep-id-format", check_dep_id_format),
    ("adr-resolution", check_adr_resolution),
    ("mandatory-reading-links", check_mandatory_reading_links),
    ("status-consistency", check_status_consistency),
]


# ── Lint a single file ────────────────────────────────────────

def lint_file(brief_path: Path, project_root: Path) -> List[Issue]:
    try:
        content = brief_path.read_text(encoding="utf-8")
    except Exception as e:
        return [Issue(severity=ERROR, message=f"Cannot read file: {e}")]

    issues: List[Issue] = []
    for _name, check_fn in CHECKS:
        issues.extend(check_fn(content, brief_path, project_root))
    return issues


# ── Find project root ─────────────────────────────────────────

def find_project_root(start: Path) -> Optional[Path]:
    """Walk up from start to find the dir containing .loop/."""
    p = start.resolve()
    while p != p.parent:
        if (p / ".loop").exists():
            return p
        p = p.parent
    return None


# ── Output formatting ─────────────────────────────────────────

def format_issues(rel_path: str, issues: List[Issue]) -> str:
    lines = [rel_path]
    for issue in issues:
        icon = SEVERITY_ICON.get(issue.severity, "  ")
        lines.append(f"  {icon} {issue.message}")
        if issue.expected:
            lines.append(f"     Expected: {issue.expected}")
        if issue.fix:
            lines.append(f"     Fix: {issue.fix}")
    return "\n".join(lines)


def count_by_severity(all_issues: List[Issue]) -> dict:
    counts = {ERROR: 0, WARNING: 0, INFO: 0}
    for issue in all_issues:
        counts[issue.severity] = counts.get(issue.severity, 0) + 1
    return counts


# ── Main entry point ──────────────────────────────────────────

def main(argv: List[str] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        print("Usage: loop lint <brief-path-or-dir>")
        print()
        print("  loop lint wiki/briefs/cards/brief-049-scene-reset-on-run/index.md")
        print("  loop lint wiki/briefs/cards/")
        print()
        print("Checks:")
        for name, _ in CHECKS:
            print(f"  {name}")
        return 0

    target_arg = argv[0]
    target = Path(target_arg).resolve()

    if not target.exists():
        print(f"Error: {target_arg} does not exist", file=sys.stderr)
        return 1

    project_root = find_project_root(target)
    if not project_root:
        # Try from cwd
        project_root = find_project_root(Path.cwd())
    if not project_root:
        # Fall back: use target's root or cwd
        project_root = Path.cwd()

    # Collect brief files to lint
    brief_files: List[Path] = []
    if target.is_file():
        brief_files = [target]
    elif target.is_dir():
        # Find all index.md files inside brief-* subdirs
        brief_files = sorted(target.rglob("index.md"))
        if not brief_files:
            # Fallback: any .md files directly
            brief_files = sorted(target.glob("*.md"))

    if not brief_files:
        print(f"No brief files found at {target_arg}", file=sys.stderr)
        return 0

    total_issues = 0
    files_with_issues = 0
    output_blocks: List[str] = []

    for bf in brief_files:
        issues = lint_file(bf, project_root)
        if issues:
            files_with_issues += 1
            total_issues += len(issues)
            try:
                rel = bf.relative_to(project_root)
            except ValueError:
                rel = bf
            output_blocks.append(format_issues(str(rel), issues))

    if output_blocks:
        print("\n".join(output_blocks))
        print()
        files_scanned = len(brief_files)
        issue_word = "issue" if total_issues == 1 else "issues"
        file_word = "file" if files_with_issues == 1 else "files"
        scanned_word = "file" if files_scanned == 1 else "files"
        print(f"{total_issues} {issue_word} across {files_with_issues} {file_word} ({files_scanned} {scanned_word} scanned).")
        return 1
    else:
        files_scanned = len(brief_files)
        scanned_word = "file" if files_scanned == 1 else "files"
        print(f"✓ Clean ({files_scanned} {scanned_word} scanned).")
        return 0


if __name__ == "__main__":
    sys.exit(main())
