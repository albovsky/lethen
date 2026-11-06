#!/usr/bin/env python3
"""Self-check for corpus/drop_gate.py on fabricated baseline and current expectations.
Run with `python3 corpus/test_drop_gate.py`."""
import contextlib
import io
import json
import subprocess
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


class RevisionBaselineTest(unittest.TestCase):
    """The revision paths, on a throwaway repository with one commit of 100 rows."""

    def make_repo(self, directory):
        root = Path(directory)
        (root / "corpus/expected").mkdir(parents=True)
        (root / "corpus/projects.json").write_text(json.dumps([{"name": "demo"}]))
        (root / "corpus/expected/demo.json").write_text(json.dumps(rows(100)))
        commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"]
        for command in (["init", "-q"], ["add", "."], commit):
            subprocess.run(["git", "-C", str(root), *command], check=True, capture_output=True)
        return root

    def run_gate(self, root, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = drop_gate.main(["--current-dir", str(root), *extra])
        return status, out.getvalue(), err.getvalue()

    def test_unresolvable_base_exits_2_naming_it(self):
        with tempfile.TemporaryDirectory() as directory:
            status, _, err = self.run_gate(self.make_repo(directory), "--base", "definitely-not-a-revision")
        self.assertEqual(status, 2)
        self.assertIn("definitely-not-a-revision", err)

    def test_project_missing_at_a_valid_revision_is_new(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_repo(directory)
            (root / "corpus/projects.json").write_text(json.dumps([{"name": "demo"}, {"name": "brand-new"}]))
            (root / "corpus/expected/brand-new.json").write_text(json.dumps(rows(5)))
            status, out, _ = self.run_gate(root, "--base", "HEAD")
        self.assertEqual(status, 0)
        self.assertIn("brand-new has no expectation", out)

    def test_drop_against_a_valid_revision_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_repo(directory)
            (root / "corpus/expected/demo.json").write_text(json.dumps(rows(90)))
            status, _, err = self.run_gate(root, "--base", "HEAD")
        self.assertEqual(status, 1)
        self.assertIn("demo: 100 -> 90", err)

    def test_no_tag_falls_back_to_the_merge_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_repo(directory)
            subprocess.run(["git", "-C", str(root), "update-ref", "refs/remotes/origin/master", "HEAD"], check=True)
            self.assertEqual(self.run_gate(root)[0], 0)

    def test_no_baseline_at_all_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.run_gate(self.make_repo(directory))[0], 2)


if __name__ == "__main__":
    unittest.main()
