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
# Single source of truth for brief-id shape. assess.py owns the canonical regex
# (the daemon's parser is the runtime path that wedges); lint.py imports it so
# author-time and dispatch-time agree on what a brief id looks like.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from assess import BRIEF_ID_RE  # noqa: E402

ADR_FIELD_RE = re.compile(r"^\*\*ADRs?:\*\*\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)
ADR_NUMBER_RE = re.compile(r"\b(\d{3})\b")

MANDATORY_LINK_RE = re.compile(r"\[.*?\]\(((?!https?://)[^)]+\.md[^)]*)\)", re.MULTILINE)

YAML_FRONTMATTER_RE = re.compile(r"^---\s*$", re.MULTILINE)
MD_FIELD_RE = re.compile(r"^\*\*\w", re.MULTILINE)

# ── Sibling-field regexes (for check_sibling_fields) ─────────────────────────
_AUTO_MERGE_RE = re.compile(r"^\*\*Auto-merge:\*\*\s*(.+?)\s*$", re.MULTILINE)
_HUMAN_GATE_RE = re.compile(r"^\*\*Human-gate:\*\*\s*(.+?)\s*$", re.MULTILINE)
_BRANCH_FIELD_RE = re.compile(r"^\*\*Branch:\*\*\s*(.+?)\s*$", re.MULTILINE)
_VALIDATOR_FIELD_RE = re.compile(r"^\*\*Validator:\*\*\s*(.+?)\s*$", re.MULTILINE)
_STATUS_FIELD_RE = re.compile(r"^\*\*Status:\*\*\s*(.+?)\s*$", re.MULTILINE)
_MODEL_FIELD_RE = re.compile(r"^\*\*Model:\*\*\s*(.+?)\s*$", re.MULTILINE)
_TARGET_REPO_RE = re.compile(r"^\*\*Target repo:\*\*\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)
_FIELD_PAREN_RE = re.compile(r"\(")
_FIELD_ITALIC_RE = re.compile(r"^[_*]")
_ILLEGAL_PLACEHOLDERS = frozenset(("none", "empty", "n/a", "tbd"))


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
    """Depends-on must be absent, or a real brief-id — not 'none' or empty.

    Brief-082: extended to catch the empirical wedge shapes:
      - `none (annotation, more)` — author wrote 'none' with explanatory parens.
      - `_(intentionally empty)_` — italics-wrapped placeholder.
      - `none (...)` or any value with `(` before the first `,` — annotation-as-value.

    Each of these previously survived the parser intact and produced a phantom
    dep that never appeared in history → permanent `dispatch_blocked`. Both the
    parser (assess.py) and the linter now reject them; the parser drops with a
    warning at dispatch-time, the linter ERRORs at write-time.
    """
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

    issues = []

    # Annotation-as-value: a `(` appearing before the first `,` means the author
    # wrote prose-with-parenthetical instead of a comma-separated id list. The
    # daemon parser splits on the comma and treats both halves as brief ids,
    # producing a permanent dispatch block. Ref: brief-076 (2026-04-26).
    first_comma = raw.find(",")
    first_paren = raw.find("(")
    if first_paren >= 0 and (first_comma < 0 or first_paren < first_comma):
        issues.append(Issue(
            severity=ERROR,
            message="`**Depends-on:**` value contains a parenthetical annotation. The daemon's parser splits on commas inside the parens and treats each half as a brief ID, causing a permanent dispatch block until human edits frontmatter.",
            expected="List ONLY real brief IDs (e.g. `brief-042-slug`). Omit the field entirely when there are no dependencies.",
            fix="Remove the parenthetical. If there are no real deps, delete the `**Depends-on:**` line.",
        ))

    # Split on commas (mirroring parse_depends_on_value's pre-validation cleaning)
    tokens = [t.strip().strip(".,;") for t in raw.split(",") if t.strip().strip(".,;")]

    for tok in tokens:
        low = tok.lower()
        # Strip a parenthetical so `none (foo)` and `none(foo)` both surface.
        low_no_paren = re.sub(r"\s*\(.*$", "", low).strip()
        if low_no_paren == "none" or low.startswith("none "):
            issues.append(Issue(
                severity=ERROR,
                message="`**Depends-on:** none` — literal 'none' is treated as a brief ID by the daemon, causing a permanent dispatch block until human edits frontmatter.",
                expected="Omit the `**Depends-on:**` field entirely when there are no dependencies.",
                fix="Remove the `**Depends-on:**` line.",
            ))
            continue
        # Markdown italics-wrapped placeholders (`_..._`, `*...*`). Brief-082
        # used `_(intentionally empty — see Why)_`; parser kept it as one token.
        if tok.startswith(("_", "*")):
            issues.append(Issue(
                severity=ERROR,
                message=f"`**Depends-on:**` value `{tok}` is a markdown-italics placeholder, not a brief ID. The daemon's parser keeps it intact and the deps history-check never matches, causing a permanent dispatch block until human edits frontmatter.",
                expected="Either list real brief IDs or omit the `**Depends-on:**` field entirely.",
                fix="Remove the `**Depends-on:**` line if there are no dependencies.",
            ))
            continue
        if not BRIEF_ID_RE.match(tok):
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


# ── Check 9: Sibling-field format (parser-permissive, linter-strict) ─────────

def _check_sibling_field(
    content: str,
    field_name: str,
    pattern: "re.Pattern[str]",
    none_is_valid: bool = False,
) -> List[Issue]:
    """Enforce the parser-permissive + linter-strict discipline on a single-token field.

    Three pollution shapes caught:
      1. Parenthetical annotation  — `opus (comment)`, `true (rationale)`
      2. Italic-wrapped placeholder — `_intentionally empty_`
      3. Illegal literal            — `none`/`empty`/`n/a`/`tbd` where not valid

    `none_is_valid=True` exempts Human-gate from check #3 (`none` = explicit opt-out).
    Missing fields are caught upstream by check_required_fields — not repeated here.
    """
    m = pattern.search(content)
    if not m:
        return []

    raw = m.group(1).strip()
    if not raw:
        return []

    issues: List[Issue] = []

    if _FIELD_PAREN_RE.search(raw):
        bare = raw.split("(")[0].strip().rstrip(",;")
        issues.append(Issue(
            severity=ERROR,
            message=f"`**{field_name}:**` value contains a parenthetical annotation: `{raw[:80]}`. The daemon extracts the first token; parens-as-prose make the field unparseable by tools.",
            expected=f"A bare value with no parenthetical, e.g. `**{field_name}:** {bare}`. Move explanatory notes into a prose section of the brief.",
            fix=f"Remove the parenthetical: `**{field_name}:** {bare}`",
        ))

    if _FIELD_ITALIC_RE.match(raw):
        issues.append(Issue(
            severity=ERROR,
            message=f"`**{field_name}:**` value `{raw[:80]}` is an italic-wrapped placeholder, not a real value.",
            expected=f"A concrete value, or remove the `**{field_name}:**` line if the field is optional.",
            fix=f"Replace `{raw}` with the actual value, or remove the `**{field_name}:**` line.",
        ))

    if not none_is_valid:
        first_word = raw.lower().split()[0].rstrip(".,;") if raw.split() else ""
        if first_word in _ILLEGAL_PLACEHOLDERS:
            issues.append(Issue(
                severity=ERROR,
                message=f"`**{field_name}:** {raw}` — `{first_word}` is not a valid value for this field.",
                expected=f"A real value for `**{field_name}:**`, or omit the line entirely if the field is optional.",
                fix=f"Replace `{first_word}` with the actual value, or remove the `**{field_name}:**` line.",
            ))

    return issues


def check_sibling_fields(content: str, brief_path: Path, project_root: Path) -> List[Issue]:
    """Sibling frontmatter fields: parens-as-annotation, italic placeholders, illegal literals.

    Mirrors the graduated discipline from check_depends_on across the seven fields
    most likely to carry prose-pollution next: Auto-merge, Human-gate, Branch,
    Validator, Status, Model, Target-repo.

    Human-gate is the one exception: `none` IS a legitimate value (explicit opt-out).
    All other fields treat `none`/`empty`/`n/a`/`tbd` as illegal placeholders —
    canonical empty form is to omit the field entirely.
    """
    issues: List[Issue] = []
    issues.extend(_check_sibling_field(content, "Auto-merge",  _AUTO_MERGE_RE,    none_is_valid=False))
    issues.extend(_check_sibling_field(content, "Human-gate",  _HUMAN_GATE_RE,    none_is_valid=True))
    issues.extend(_check_sibling_field(content, "Branch",      _BRANCH_FIELD_RE,  none_is_valid=False))
    issues.extend(_check_sibling_field(content, "Validator",   _VALIDATOR_FIELD_RE, none_is_valid=False))
    issues.extend(_check_sibling_field(content, "Status",      _STATUS_FIELD_RE,  none_is_valid=False))
    issues.extend(_check_sibling_field(content, "Model",       _MODEL_FIELD_RE,   none_is_valid=False))
    issues.extend(_check_sibling_field(content, "Target repo", _TARGET_REPO_RE,   none_is_valid=False))
    return issues


# ── Check registry ────────────────────────────────────────────

CHECKS: List[Tuple[str, Callable]] = [
    ("frontmatter-style", check_frontmatter_style),
    ("required-fields", check_required_fields),
    ("budget-section", check_budget_section),
    ("depends-on", check_depends_on),
    ("dep-id-format", check_dep_id_format),
    ("sibling-fields", check_sibling_fields),
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


# ── Brief status reader ───────────────────────────────────────

def read_brief_status(path: Path) -> Optional[str]:
    """Read just the Status field from a brief file."""
    try:
        content = path.read_text(encoding="utf-8")
        m = re.search(r"^\*\*Status:\*\*\s*(\S+)", content, re.MULTILINE)
        return m.group(1).lower() if m else None
    except Exception:
        return None


def _brief_meta(path: Path) -> tuple:
    """Return (status, brief_id) from a brief file. Both may be None."""
    try:
        content = path.read_text(encoding="utf-8")
        status_m = re.search(r"^\*\*Status:\*\*\s*(\S+)", content, re.MULTILINE)
        id_m = re.search(r"^\*\*ID:\*\*\s*(\S+)", content, re.MULTILINE)
        status = status_m.group(1).lower() if status_m else None
        brief_id = id_m.group(1).lower() if id_m else None
        return status, brief_id
    except Exception:
        return None, None


def _load_history_ids(project_root: Path) -> set:
    """Load the set of brief IDs in running.json history (already merged)."""
    running_file = project_root / ".loop" / "state" / "running.json"
    if not running_file.exists():
        return set()
    try:
        with running_file.open() as f:
            data = json.load(f)
        return {e.get("brief", "").lower() for e in data.get("history", [])}
    except Exception:
        return set()


# ── Main entry point ──────────────────────────────────────────

def main(argv: List[str] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    # Parse flags before positional args
    all_statuses = "--all" in argv
    argv = [a for a in argv if a != "--all"]

    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        print("Usage: loop lint [--all] <brief-path-or-dir>")
        print()
        print("  loop lint wiki/briefs/cards/brief-049-scene-reset-on-run/index.md")
        print("  loop lint wiki/briefs/cards/              # queued briefs only")
        print("  loop lint --all wiki/briefs/cards/        # all briefs regardless of status")
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
        candidates = sorted(target.rglob("index.md"))
        if not candidates:
            candidates = sorted(target.glob("*.md"))

        if all_statuses:
            brief_files = candidates
        else:
            # Default: queued briefs that haven't been merged yet.
            # Many old briefs have a stale `Status: queued` field even after merge —
            # cross-check against running.json history to exclude them.
            history_ids = _load_history_ids(project_root)
            filtered = []
            for bf in candidates:
                status, brief_id = _brief_meta(bf)
                if status != "queued":
                    continue
                if brief_id and brief_id in history_ids:
                    continue
                filtered.append(bf)
            brief_files = filtered

    if not brief_files:
        if target.is_dir() and not all_statuses:
            print(f"No queued briefs found at {target_arg} (use --all to scan all statuses).", file=sys.stderr)
        else:
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
        print("\n\n".join(output_blocks))
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
