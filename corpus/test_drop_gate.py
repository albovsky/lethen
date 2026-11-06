#!/usr/bin/env python3
"""Self-check for corpus/drop_gate.py on fabricated baseline and current expectations.
Run with `python3 corpus/test_drop_gate.py`."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import drop_gate  # noqa: E402


def rows(count):
    return [[f"Sources/File{i}.swift", i, 5, "function.free", f"f{i}()", ["unused"], [f"s:{i}"], "certain"] for i in range(count)]


class DropGateTest(unittest.TestCase):
    def run_gate(self, base, current, projects=("demo",), note="", base_projects=None, extra=()):
        """Fabricate both sides in temporary directories and return (status, stdout, stderr)."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for side, counts in (("base", base_projects or {name: base for name in projects}),
                                 ("current", {name: current for name in projects})):
                (root / side / "corpus/expected").mkdir(parents=True)
                for name, count in counts.items():
                    (root / side / f"corpus/expected/{name}.json").write_text(json.dumps(rows(count)))
            (root / "current/corpus/projects.json").write_text(json.dumps([{"name": name} for name in projects]))
            (root / "current/docs/validation").mkdir(parents=True)
            (root / "current/docs/validation/precision-corpus.md").write_text(f"# Corpus\n\n{note}\n")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = drop_gate.main(["--current-dir", str(root / "current"), "--base-dir", str(root / "base"), *extra])
            return status, out.getvalue(), err.getvalue()

    def test_small_drop_passes(self):
        self.assertEqual(self.run_gate(100, 99)[0], 0)

    def test_drop_past_threshold_fails_naming_project_counts_and_line(self):
        status, _, err = self.run_gate(100, 97)
        self.assertEqual(status, 1)
        self.assertIn("demo: 100 -> 97 findings, 3.0% lost", err)
        self.assertIn("`demo: 100 -> 97 findings, adjudicated`", err)

    def test_matching_adjudication_line_passes(self):
        self.assertEqual(self.run_gate(100, 97, note="demo: 100 -> 97 findings, adjudicated")[0], 0)

    def test_adjudication_with_thousands_separator_passes(self):
        self.assertEqual(self.run_gate(2567, 2480, note="demo: 2,567 -> 2,480 findings, adjudicated")[0], 0)

    def test_adjudication_with_other_counts_or_project_fails(self):
        self.assertEqual(self.run_gate(100, 97, note="demo: 100 -> 98 findings, adjudicated")[0], 1)
        self.assertEqual(self.run_gate(100, 97, note="other: 100 -> 97 findings, adjudicated")[0], 1)

    def test_growth_passes(self):
        self.assertEqual(self.run_gate(100, 150)[0], 0)

    def test_new_project_passes_with_a_note(self):
        status, out, _ = self.run_gate(None, 10, projects=("demo", "fresh"), base_projects={"demo": 10})
        self.assertEqual(status, 0)
        self.assertIn("fresh has no expectation", out)

    def test_threshold_option(self):
        self.assertEqual(self.run_gate(100, 97, extra=("--threshold", "0.05"))[0], 0)


if __name__ == "__main__":
    unittest.main()
