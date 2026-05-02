"""Pin the parser to handle BOTH the prose form (`**Parallel-safe:** true`)
AND the YAML-frontmatter form (`Parallel-safe: true`).

Pre-fix: parser only matched the prose form, silently returning
parallel_safe=False on every YAML-frontmatter card. Effect: THROTTLE>1
was dead since brief-108 collapsed cards to YAML — daemon dispatch
enforcer always saw new_brief_not_parallel_safe and refused slot=1.

Discovered 2026-05-02 when manually forcing brief-094-cont to dispatch
alongside brief-119; concurrency_skip fired with reason
new_brief_not_parallel_safe despite frontmatter declaring true.
"""

import os
import tempfile
import unittest


def _write_card(body):
    fd, path = tempfile.mkstemp(suffix=".md")
    with os.fdopen(fd, "w") as f:
        f.write(body)
    return path


class ParseConcurrencyFrontmatter(unittest.TestCase):
    def setUp(self):
        import sys
        lib_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if lib_dir not in sys.path:
            sys.path.insert(0, lib_dir)
        from actions import parse_concurrency_frontmatter
        self.parse = parse_concurrency_frontmatter

    def test_yaml_frontmatter_parallel_safe_true(self):
        path = _write_card(
            "---\n"
            "ID: test-yaml\n"
            "Parallel-safe: true\n"
            "Edit-surface:\n"
            "  - foo/bar.py\n"
            "---\n"
        )
        try:
            ps, _ = self.parse(path)
            self.assertTrue(ps, "YAML 'Parallel-safe: true' should parse as True")
        finally:
            os.unlink(path)

    def test_yaml_frontmatter_parallel_safe_false(self):
        path = _write_card("---\nParallel-safe: false\n---\n")
        try:
            ps, _ = self.parse(path)
            self.assertFalse(ps)
        finally:
            os.unlink(path)

    def test_prose_form_still_parses(self):
        path = _write_card("**Parallel-safe:** true\n")
        try:
            ps, _ = self.parse(path)
            self.assertTrue(ps, "legacy prose form must continue to parse")
        finally:
            os.unlink(path)

    def test_yaml_edit_surface_inline(self):
        path = _write_card(
            "---\n"
            "Parallel-safe: true\n"
            "Edit-surface: foo/a.py, bar/b.py\n"
            "---\n"
        )
        try:
            ps, es = self.parse(path)
            self.assertTrue(ps)
            self.assertEqual(es, ["foo/a.py", "bar/b.py"])
        finally:
            os.unlink(path)

    def test_missing_frontmatter_defaults_to_false(self):
        path = _write_card("# Just a heading\n\nNo frontmatter at all.\n")
        try:
            ps, es = self.parse(path)
            self.assertFalse(ps)
            self.assertEqual(es, [])
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
