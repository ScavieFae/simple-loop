#!/usr/bin/env python3
"""Unit tests for lint.py — 2+ tests per check (pass + fail)."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from lint import (
    ERROR,
    WARNING,
    INFO,
    check_frontmatter_style,
    check_required_fields,
    check_budget_section,
    check_depends_on,
    check_dep_id_format,
    check_adr_resolution,
    check_mandatory_reading_links,
    check_status_consistency,
    check_goals_md_state_prose,
    lint_goals_md,
    lint_file,
    main,
)

MINIMAL_VALID = """\
# brief-001 — test brief

**ID:** brief-001-test
**Branch:** brief-001-test
**Status:** queued
**Model:** sonnet
**Auto-merge:** false
**Validator:** core/agents/reviewer.md
**Human-gate:** none

## Context

Test brief for unit tests.

## Budget

**3 cycles sonnet.** Basic test.

## Completion criteria

- [ ] Does the thing.
"""


def run_check(fn, content, brief_path=None, project_root=None):
    bp = brief_path or Path("/tmp/brief/index.md")
    pr = project_root or Path("/tmp")
    return fn(content, bp, pr)


# ── Check 1: frontmatter-style ────────────────────────────────────────────────

class TestFrontmatterStyle(unittest.TestCase):
    def test_md_fields_pass(self):
        issues = run_check(check_frontmatter_style, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_yaml_block_fails(self):
        content = "---\nid: brief-001\n---\n\n# brief-001\n"
        issues = run_check(check_frontmatter_style, content)
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)

    def test_lone_triple_dash_fails(self):
        content = MINIMAL_VALID + "\n---\n\nsome separator\n"
        issues = run_check(check_frontmatter_style, content)
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)


# ── Check 2: required-fields ──────────────────────────────────────────────────

class TestRequiredFields(unittest.TestCase):
    def test_all_fields_present_pass(self):
        issues = run_check(check_required_fields, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_missing_human_gate_fails(self):
        content = MINIMAL_VALID.replace("**Human-gate:** none\n", "")
        issues = run_check(check_required_fields, content)
        self.assertTrue(any("Human-gate" in i.message for i in issues))
        self.assertTrue(all(i.severity == ERROR for i in issues))

    def test_missing_multiple_fields_fails(self):
        content = "# brief-001\n\n**ID:** brief-001-test\n\n## Budget\n\n**2 cycles sonnet.**\n"
        issues = run_check(check_required_fields, content)
        # Missing: Branch, Status, Model, Auto-merge, Validator, Human-gate (6 fields)
        self.assertGreaterEqual(len(issues), 5)
        self.assertTrue(all(i.severity == ERROR for i in issues))


# ── Check 3: budget-section ───────────────────────────────────────────────────

class TestBudgetSection(unittest.TestCase):
    def test_valid_budget_pass(self):
        issues = run_check(check_budget_section, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_missing_budget_section_fails(self):
        content = MINIMAL_VALID.replace("## Budget\n\n**3 cycles sonnet.** Basic test.\n", "")
        issues = run_check(check_budget_section, content)
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)
        self.assertIn("Budget", issues[0].message)

    def test_budget_section_no_parseable_opener_fails(self):
        content = MINIMAL_VALID.replace(
            "## Budget\n\n**3 cycles sonnet.** Basic test.\n",
            "## Budget\n\nTodo: figure out how many cycles.\n",
        )
        issues = run_check(check_budget_section, content)
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)
        self.assertIn("parseable", issues[0].message)

    def test_budget_opener_plural_cycles_pass(self):
        content = MINIMAL_VALID.replace(
            "**3 cycles sonnet.**",
            "**6 cycles sonnet.**",
        )
        issues = run_check(check_budget_section, content)
        self.assertEqual(issues, [])

    def test_budget_opener_single_cycle_pass(self):
        content = MINIMAL_VALID.replace(
            "**3 cycles sonnet.**",
            "**1 cycle sonnet.**",
        )
        issues = run_check(check_budget_section, content)
        self.assertEqual(issues, [])


# ── Check 4: depends-on ───────────────────────────────────────────────────────

class TestDependsOn(unittest.TestCase):
    def test_no_depends_on_passes(self):
        issues = run_check(check_depends_on, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_valid_full_form_dep_passes(self):
        content = MINIMAL_VALID + "\n**Depends-on:** brief-042-camera-system\n"
        issues = run_check(check_depends_on, content)
        self.assertEqual(issues, [])

    def test_valid_short_form_dep_passes(self):
        content = MINIMAL_VALID + "\n**Depends-on:** brief-042\n"
        issues = run_check(check_depends_on, content)
        self.assertEqual(issues, [])

    def test_depends_on_none_fails(self):
        content = MINIMAL_VALID + "\n**Depends-on:** none\n"
        issues = run_check(check_depends_on, content)
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)
        self.assertIn("none", issues[0].message)

    def test_depends_on_none_in_comma_list_fails(self):
        content = MINIMAL_VALID + "\n**Depends-on:** brief-042, none\n"
        issues = run_check(check_depends_on, content)
        self.assertTrue(any("none" in i.message for i in issues))

    def test_malformed_dep_id_warns(self):
        content = MINIMAL_VALID + "\n**Depends-on:** not-a-brief-id\n"
        issues = run_check(check_depends_on, content)
        self.assertTrue(any(i.severity == WARNING for i in issues))


# ── Check 5: dep-id-format ────────────────────────────────────────────────────

class TestDepIdFormat(unittest.TestCase):
    def test_no_deps_passes(self):
        issues = run_check(check_dep_id_format, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_valid_full_form_passes(self):
        content = MINIMAL_VALID + "\n**Depends-on:** brief-042-camera-system\n"
        issues = run_check(check_dep_id_format, content)
        self.assertEqual(issues, [])

    def test_valid_short_form_passes(self):
        content = MINIMAL_VALID + "\n**Depends-on:** brief-042\n"
        issues = run_check(check_dep_id_format, content)
        self.assertEqual(issues, [])


# ── Check 6: adr-resolution ───────────────────────────────────────────────────

class TestAdrResolution(unittest.TestCase):
    def test_no_adrs_field_passes(self):
        issues = run_check(check_adr_resolution, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_adrs_none_passes(self):
        content = MINIMAL_VALID + "\n**ADRs:** none\n"
        issues = run_check(check_adr_resolution, content)
        self.assertEqual(issues, [])

    def test_existing_adr_file_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            decisions_dir = root / "wiki" / "decisions"
            decisions_dir.mkdir(parents=True)
            (decisions_dir / "099-test-adr.md").write_text("# ADR 099\n")
            content = MINIMAL_VALID + "\n**ADRs:** 099\n"
            issues = run_check(check_adr_resolution, content, project_root=root)
            self.assertEqual(issues, [])

    def test_missing_adr_file_warns(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            decisions_dir = root / "wiki" / "decisions"
            decisions_dir.mkdir(parents=True)
            # No 099-*.md created
            content = MINIMAL_VALID + "\n**ADRs:** 099\n"
            issues = run_check(check_adr_resolution, content, project_root=root)
            self.assertEqual(len(issues), 1)
            self.assertEqual(issues[0].severity, WARNING)
            self.assertIn("099", issues[0].message)


# ── Check 7: mandatory-reading-links ─────────────────────────────────────────

class TestMandatoryReadingLinks(unittest.TestCase):
    def test_no_mandatory_section_passes(self):
        issues = run_check(check_mandatory_reading_links, MINIMAL_VALID)
        self.assertEqual(issues, [])

    def test_http_links_in_mandatory_section_pass(self):
        content = MINIMAL_VALID + (
            "\n## MANDATORY reading\n\n"
            "1. [Some paper](https://arxiv.org/abs/2506.01844)\n"
        )
        issues = run_check(check_mandatory_reading_links, content)
        self.assertEqual(issues, [])

    def test_broken_relative_link_warns(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            brief_dir = root / "wiki/briefs/cards/brief-001"
            brief_dir.mkdir(parents=True)
            brief_path = brief_dir / "index.md"
            content = MINIMAL_VALID + (
                "\n## MANDATORY reading\n\n"
                "1. [Director context](../../operating-docs/director-context.md)\n"
            )
            issues = run_check(
                check_mandatory_reading_links, content,
                brief_path=brief_path, project_root=root,
            )
            self.assertEqual(len(issues), 1)
            self.assertEqual(issues[0].severity, WARNING)

    def test_valid_relative_link_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            brief_dir = root / "wiki/briefs/cards/brief-001"
            brief_dir.mkdir(parents=True)
            brief_path = brief_dir / "index.md"
            ops_dir = root / "wiki/operating-docs"
            ops_dir.mkdir(parents=True)
            (ops_dir / "director-context.md").write_text("# Director Context\n")
            # 3 levels up from wiki/briefs/cards/brief-001/ → wiki/
            content = MINIMAL_VALID + (
                "\n## MANDATORY reading\n\n"
                "1. [Director context](../../../operating-docs/director-context.md)\n"
            )
            issues = run_check(
                check_mandatory_reading_links, content,
                brief_path=brief_path, project_root=root,
            )
            self.assertEqual(issues, [])


# ── Check 8: status-consistency ──────────────────────────────────────────────

class TestStatusConsistency(unittest.TestCase):
    def _write_running(self, root: Path, running: dict):
        state_dir = root / ".loop" / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "running.json").write_text(json.dumps(running))

    def test_no_running_json_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            issues = run_check(check_status_consistency, MINIMAL_VALID, project_root=Path(tmpdir))
            self.assertEqual(issues, [])

    def test_status_queued_not_in_running_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self._write_running(root, {"active": [], "completed_pending_eval": [], "awaiting_review": [], "history": []})
            issues = run_check(check_status_consistency, MINIMAL_VALID, project_root=root)
            self.assertEqual(issues, [])

    def test_status_queued_but_active_in_running_info(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self._write_running(root, {
                "active": [{"brief": "brief-001-test"}],
                "completed_pending_eval": [],
                "awaiting_review": [],
                "history": [],
            })
            issues = run_check(check_status_consistency, MINIMAL_VALID, project_root=root)
            self.assertEqual(len(issues), 1)
            self.assertEqual(issues[0].severity, INFO)

    def test_status_queued_but_in_history_info(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self._write_running(root, {
                "active": [],
                "completed_pending_eval": [],
                "awaiting_review": [],
                "history": [{"brief": "brief-001-test"}],
            })
            issues = run_check(check_status_consistency, MINIMAL_VALID, project_root=root)
            self.assertEqual(len(issues), 1)
            self.assertEqual(issues[0].severity, INFO)


# ── Integration: lint_file and main ──────────────────────────────────────────

class TestLintFile(unittest.TestCase):
    def test_valid_brief_clean(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            p = Path(tmpdir) / "index.md"
            p.write_text(MINIMAL_VALID)
            issues = lint_file(p, Path(tmpdir))
            self.assertEqual(issues, [])

    def test_missing_file_returns_error(self):
        issues = lint_file(Path("/tmp/no-such-brief-xyz/index.md"), Path("/tmp"))
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)


class TestMain(unittest.TestCase):
    def test_help_exits_0(self):
        self.assertEqual(main(["--help"]), 0)

    def test_clean_brief_exits_0(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            p = Path(tmpdir) / "index.md"
            p.write_text(MINIMAL_VALID)
            self.assertEqual(main([str(p)]), 0)

    def test_drifted_brief_exits_1(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            p = Path(tmpdir) / "index.md"
            content = MINIMAL_VALID.replace("## Budget\n\n**3 cycles sonnet.** Basic test.\n", "")
            p.write_text(content)
            self.assertEqual(main([str(p)]), 1)

    def test_nonexistent_path_exits_1(self):
        self.assertEqual(main(["/tmp/does-not-exist-xyz/index.md"]), 1)


def _make_brief_content(brief_id: str, status: str = "queued") -> str:
    return (
        MINIMAL_VALID
        .replace("**ID:** brief-001-test", f"**ID:** {brief_id}")
        .replace("**Branch:** brief-001-test", f"**Branch:** {brief_id}")
        .replace("**Status:** queued", f"**Status:** {status}")
    )


class TestMainDirFilter(unittest.TestCase):
    """Tests for dir-mode status filtering and --all flag."""

    def _write_running(self, root: Path, history_ids):
        state_dir = root / ".loop" / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        running = {
            "active": [],
            "completed_pending_eval": [],
            "awaiting_review": [],
            "history": [{"brief": bid} for bid in history_ids],
        }
        (state_dir / "running.json").write_text(json.dumps(running))

    def test_dir_default_excludes_history_queued_briefs(self):
        """Dir mode skips briefs whose ID is in running.json history (even if Status: queued)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self._write_running(root, history_ids=["brief-001-old"])
            cards = root / "wiki/briefs/cards"
            (cards / "brief-001-old").mkdir(parents=True)
            (cards / "brief-001-old" / "index.md").write_text(
                _make_brief_content("brief-001-old", "queued")
            )
            (cards / "brief-002-new").mkdir(parents=True)
            (cards / "brief-002-new" / "index.md").write_text(
                _make_brief_content("brief-002-new", "queued")
            )
            # brief-001-old is in history → skipped; brief-002-new is clean → exit 0
            self.assertEqual(main([str(cards)]), 0)

    def test_dir_default_excludes_non_queued_briefs(self):
        """Dir mode skips briefs with Status != queued."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cards = root / "wiki/briefs/cards"
            (cards / "brief-001-active").mkdir(parents=True)
            (cards / "brief-001-active" / "index.md").write_text(
                _make_brief_content("brief-001-active", "active")
            )
            # Only non-queued brief → no queued briefs found, exit 0
            result = main([str(cards)])
            self.assertEqual(result, 0)

    def test_dir_all_flag_includes_non_queued(self):
        """--all flag scans briefs regardless of status."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cards = root / "wiki/briefs/cards"
            (cards / "brief-001-active").mkdir(parents=True)
            (cards / "brief-001-active" / "index.md").write_text(
                _make_brief_content("brief-001-active", "active")
            )
            # With --all: brief-001-active is scanned and clean → exit 0
            self.assertEqual(main(["--all", str(cards)]), 0)

    def test_dir_all_flag_includes_history_briefs(self):
        """--all scans merged briefs too (useful for audit)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            self._write_running(root, history_ids=["brief-001-old"])
            cards = root / "wiki/briefs/cards"
            (cards / "brief-001-old").mkdir(parents=True)
            # Use Status: merged so check 8 doesn't fire (no queued+history drift)
            (cards / "brief-001-old" / "index.md").write_text(
                _make_brief_content("brief-001-old", "merged")
            )
            # Default: excluded (status != queued); --all: included → clean, exit 0
            self.assertEqual(main([str(cards)]), 0)       # excluded by default
            self.assertEqual(main(["--all", str(cards)]), 0)  # included with --all


# ── Check 12: goals-state-prose ──────────────────────────────────────────────

CLEAN_GOALS = """\
# Goals

## Queued next

1. **brief-042 (scene reset)** — dispatchable now. Resets the sim on Run.
2. **brief-043 (camera polish)** — Depends-on brief-042.

## Done

- brief-001 — initial spike.
"""

STALE_GOALS_STRIKETHROUGH = """\
# Goals

## Queued next

~~1. **[MERGED abc1234 2026-04-28] brief-042 (scene reset)**~~
2. **brief-043 (camera polish)**
"""

STALE_GOALS_INLINE_STATE = """\
# Goals

## Current Priority

**brief-100 MERGED + INSTALLED + VERIFIED (`ce1fe7f`)** — daemon hole closed.

## Queued next

1. brief-042 — dispatchable now.
2. brief-043 — REJECTED — superseded.
"""


def run_goals_check(content: str, goals_path=None, project_root=None):
    gp = goals_path or Path("/tmp/.loop/state/goals.md")
    pr = project_root or Path("/tmp")
    return check_goals_md_state_prose(content, gp, pr)


class TestGoalsMdStateProse(unittest.TestCase):
    def test_clean_goals_passes(self):
        issues = run_goals_check(CLEAN_GOALS)
        self.assertEqual(issues, [])

    def test_strikethrough_warns(self):
        issues = run_goals_check(STALE_GOALS_STRIKETHROUGH)
        self.assertTrue(any("strikethrough" in i.message for i in issues))
        self.assertTrue(all(i.severity == WARNING for i in issues))

    def test_bracketed_merged_warns(self):
        content = "1. **[MERGED abc1234 2026-04-28] brief-042**\n"
        issues = run_goals_check(content)
        self.assertTrue(any("MERGED" in i.message for i in issues))
        self.assertEqual(issues[0].severity, WARNING)

    def test_bracketed_rejected_warns(self):
        content = "4. ~~**[REJECTED] brief-081**~~ — superseded.\n"
        issues = run_goals_check(content)
        self.assertTrue(len(issues) >= 1)
        self.assertTrue(all(i.severity == WARNING for i in issues))

    def test_merged_installed_verified_warns(self):
        content = "brief-100 MERGED + INSTALLED + VERIFIED (`ce1fe7f`)\n"
        issues = run_goals_check(content)
        self.assertTrue(any("MERGED+INSTALLED" in i.message for i in issues))
        self.assertEqual(issues[0].severity, WARNING)

    def test_merged_with_sha_warns(self):
        content = "- brief-001 — merged `58a3376`.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("merged+sha" in i.message for i in issues))

    def test_merged_with_date_warns(self):
        content = "- brief-042 merged 2026-04-28.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("merged+sha" in i.message for i in issues))

    def test_rejected_with_dash_warns(self):
        content = "4. brief-082 — REJECTED — methodology incomplete.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("REJECTED" in i.message for i in issues))

    def test_kill_disposition_warns(self):
        content = "- brief-057 KILL — roadmap wishlist.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("KILL" in i.message for i in issues))

    def test_absorbed_into_warns(self):
        content = "- brief-083 ABSORBED into brief-089 2026-04-27.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("ABSORBED" in i.message for i in issues))

    def test_completed_warns(self):
        content = "- brief-042 completed.\n"
        issues = run_goals_check(content)
        self.assertTrue(any("completed" in i.message for i in issues))

    def test_shipped_warns(self):
        content = "- brief-077 SHIPPED (commit `c4b7d3e`).\n"
        issues = run_goals_check(content)
        self.assertTrue(any("shipped" in i.message for i in issues))

    def test_one_issue_per_line(self):
        # Line has both strikethrough AND bracketed MERGED — should emit only 1 issue
        content = "~~[MERGED abc1234 2026-04-28] brief-042~~\n"
        issues = run_goals_check(content)
        self.assertEqual(len(issues), 1)

    def test_inline_state_in_priority_section_warns(self):
        issues = run_goals_check(STALE_GOALS_INLINE_STATE)
        # Should flag the MERGED+INSTALLED+VERIFIED line AND the REJECTED line
        self.assertGreaterEqual(len(issues), 2)
        self.assertTrue(all(i.severity == WARNING for i in issues))


class TestLintGoalsMd(unittest.TestCase):
    def test_clean_goals_exits_0(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            gp = Path(tmpdir) / "goals.md"
            gp.write_text(CLEAN_GOALS)
            self.assertEqual(main([str(gp)]), 0)

    def test_stale_goals_exits_1(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            gp = Path(tmpdir) / "goals.md"
            gp.write_text(STALE_GOALS_STRIKETHROUGH)
            self.assertEqual(main([str(gp)]), 1)

    def test_lint_goals_md_function_clean(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            gp = Path(tmpdir) / "goals.md"
            gp.write_text(CLEAN_GOALS)
            issues = lint_goals_md(gp, Path(tmpdir))
            self.assertEqual(issues, [])

    def test_lint_goals_md_function_stale(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            gp = Path(tmpdir) / "goals.md"
            gp.write_text(STALE_GOALS_INLINE_STATE)
            issues = lint_goals_md(gp, Path(tmpdir))
            self.assertGreater(len(issues), 0)

    def test_lint_goals_md_missing_file_errors(self):
        issues = lint_goals_md(Path("/tmp/no-such-goals-xyz.md"), Path("/tmp"))
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0].severity, ERROR)


if __name__ == "__main__":
    unittest.main()
