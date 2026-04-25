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


if __name__ == "__main__":
    unittest.main()
