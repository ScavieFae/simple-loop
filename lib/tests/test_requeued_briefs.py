#!/usr/bin/env python3
"""Unit tests for parse_requeued_briefs() — brief-102."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from actions import parse_requeued_briefs


def _write(tmp, name, content):
    p = tmp / name
    p.write_text(content)
    return str(p)


class TestParseRequeuedBriefs(unittest.TestCase):

    def test_no_requeued_entries_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-001 (some brief)** — do the thing.
""")
            result = parse_requeued_briefs(goals)
            self.assertEqual(result, [])

    def test_single_requeued_entry_parsed(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-001 (some brief)** — dispatchable.

2. **brief-099 (Recorder rebuild)** — blocked on brief-100.
   **Blocked-on:** brief-100

   More prose here.
""")
            result = parse_requeued_briefs(goals)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["brief_id"], "brief-099")
            self.assertEqual(result[0]["blocked_on"], "brief-100")
            self.assertFalse(result[0]["ready_to_dispatch"])
            self.assertIn("brief-099", result[0]["description"])

    def test_multiple_requeued_entries_all_returned(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-099 (Recorder rebuild)** — blocked on brief-100.
   **Blocked-on:** brief-100

2. **brief-098 (Other brief)** — blocked on brief-097.
   **Blocked-on:** brief-097
""")
            result = parse_requeued_briefs(goals)
            self.assertEqual(len(result), 2)
            ids = {r["brief_id"] for r in result}
            self.assertIn("brief-099", ids)
            self.assertIn("brief-098", ids)

    def test_blocking_brief_merged_sets_ready(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-099 (Recorder rebuild)** — blocked on brief-100.
   **Blocked-on:** brief-100
""")
            running = _write(tmp, "running.json", json.dumps({
                "active": [],
                "history": [
                    {"brief": "brief-100", "merge_sha": "abc1234"},
                ],
            }))
            result = parse_requeued_briefs(goals, running)
            self.assertEqual(len(result), 1)
            self.assertTrue(result[0]["ready_to_dispatch"])

    def test_blocking_brief_in_history_without_merge_sha_not_ready(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-099 (Recorder rebuild)** — blocked on brief-100.
   **Blocked-on:** brief-100
""")
            running = _write(tmp, "running.json", json.dumps({
                "active": [],
                "history": [
                    {"brief": "brief-100"},  # no merge_sha
                ],
            }))
            result = parse_requeued_briefs(goals, running)
            self.assertEqual(len(result), 1)
            self.assertFalse(result[0]["ready_to_dispatch"])

    def test_missing_goals_file_returns_empty(self):
        result = parse_requeued_briefs("/nonexistent/goals.md")
        self.assertEqual(result, [])

    def test_cont_suffix_brief_id_parsed(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            goals = _write(tmp, "goals.md", """\
# Goals

## Queued next

1. **brief-067-cont (ADR autoload continuation)** — blocked on brief-067.
   **Blocked-on:** brief-067
""")
            result = parse_requeued_briefs(goals)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["brief_id"], "brief-067-cont")
            self.assertEqual(result[0]["blocked_on"], "brief-067")


if __name__ == "__main__":
    unittest.main()
