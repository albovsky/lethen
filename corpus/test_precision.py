#!/usr/bin/env python3
"""Self-check for corpus/precision.py and corpus/sample.py on a synthetic corpus.
Run with `python3 corpus/test_precision.py`; CorpusAdjudicationTest runs it on macOS."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import precision  # noqa: E402
import sample  # noqa: E402

ROWS = [[f"Sources/File{i}.swift", i, 5, "function.free", f"f{i}()", ["unused"], [f"s:{i}"], "likely" if i % 4 == 0 else "certain"]
        for i in range(1, 201)]


def verdict(row, value="TP", **extra):
    return {"path": row[0], "line": row[1], "column": row[2], "kind": row[3], "name": row[4],
            "verdict": value, "note": "evidence", "adjudicated_on": "2026-09-29", "lethen_commit": "abc1234", **extra}


class SyntheticCorpus:
    def __init__(self, directory, rows=ROWS, rate=0.1, adjudications=()):
        self.root = Path(directory)
        (self.root / "corpus/expected").mkdir(parents=True)
        (self.root / "corpus/adjudications").mkdir()
        (self.root / "docs/validation").mkdir(parents=True)
        (self.root / "corpus/projects.json").write_text(json.dumps([{"name": "demo"}]))
        (self.root / "docs/validation/precision-corpus.md").write_text(
            "# Corpus\n\n<!-- precision-scorecard:begin -->\n<!-- precision-scorecard:end -->\n\nText.\n")
        (self.root / "README.md").write_text("It is <!-- precision-figure:begin --><!-- precision-figure:end -->.\n")
        self.write(rows, rate, adjudications)

    def write(self, rows, rate=0.1, adjudications=()):
        (self.root / "corpus/expected/demo.json").write_text(json.dumps(rows))
        (self.root / "corpus/adjudications/demo.json").write_text(
            json.dumps({"project": "demo", "sample_rate": rate, "adjudications": list(adjudications)}))

    def sampled(self, rate=0.1, rows=ROWS):
        return [row for row in rows if precision.is_sampled("demo", precision.row_key(row), rate)]

    def run(self, module, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = module.main([*args, "--root", str(self.root)])
        return status, out.getvalue(), err.getvalue()


class PrecisionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.corpus = SyntheticCorpus(self.directory.name)

    def test_membership_is_stable_when_other_rows_change(self):
        before = self.corpus.sampled()
        self.assertTrue(10 <= len(before) <= 30, len(before))
        changed = [row for row in ROWS if row not in before[:3]] + [[f"New{i}.swift", 1, 1, "struct", f"N{i}", ["unused"], []] for i in range(50)]
        after = self.corpus.sampled(rows=changed)
        self.assertEqual([row for row in after if row in ROWS], before[3:])
        self.assertEqual(before, self.corpus.sampled(), "sampling must be deterministic")

    def test_membership_depends_on_project(self):
        other = [row for row in ROWS if precision.is_sampled("other", precision.row_key(row), 0.1)]
        self.assertNotEqual(other, self.corpus.sampled())

    def test_counts_verdicts_in_sample_only(self):
        sampled = self.corpus.sampled()
        outside = next(row for row in ROWS if row not in sampled)
        verdicts = [verdict(sampled[0], "TP"), verdict(sampled[1], "FP"), verdict(sampled[2], "UNSURE"), verdict(outside, "FP")]
        self.corpus.write(ROWS, adjudications=verdicts)
        result = precision.evaluate(self.corpus.root, "demo")
        self.assertEqual((result["TP"], result["FP"], result["UNSURE"]), (1, 1, 1))
        self.assertEqual(len(result["pending"]), len(sampled) - 3)
        self.assertEqual(result["outside_sample"], 1)

    def test_check_fails_until_every_sampled_finding_has_a_verdict(self):
        sampled = self.corpus.sampled()
        self.corpus.write(ROWS, adjudications=[verdict(row) for row in sampled[1:]])
        status, out, _ = self.corpus.run(precision, "--check")
        self.assertEqual(status, 1)
        self.assertIn(f"needs a verdict: {sampled[0][0]}:", out)
        self.corpus.write(ROWS, adjudications=[verdict(row, "FP" if index % 4 == 0 else "TP") for index, row in enumerate(sampled)])
        self.assertEqual(self.corpus.run(precision, "--check")[0], 0)

    def test_retired_verdicts(self):
        gone = ROWS[0]
        self.corpus.write(ROWS[1:], adjudications=[verdict(gone)])
        status, out, _ = self.corpus.run(precision, "--check")
        self.assertEqual(status, 1, "a verdict on a finding that is gone must be marked retired")
        self.assertIn("mark its verdict retired", out)
        self.corpus.write(ROWS[1:], adjudications=[verdict(gone, retired="No longer reported after #1")])
        status, out, _ = self.corpus.run(precision)
        self.assertEqual(status, 0)
        self.assertIn("retired TP", out)
        self.corpus.write(ROWS, adjudications=[verdict(gone, retired="No longer reported after #1")])
        status, _, err = self.corpus.run(precision)
        self.assertEqual(status, 2)
        self.assertIn("is marked retired but is still reported", err)

    def test_rejects_malformed_adjudications(self):
        cases = {
            "verdict 'maybe'": [verdict(ROWS[0], "maybe")],
            "adjudicated twice": [verdict(ROWS[0]), verdict(ROWS[0], "FP")],
            "missing fields ['note']": [{k: v for k, v in verdict(ROWS[0]).items() if k != "note"}],
            "unknown fields ['extra']": [verdict(ROWS[0], extra=1)],
            "wrong type": [dict(verdict(ROWS[0]), line="1")],
        }
        for message, entries in cases.items():
            self.corpus.write(ROWS, adjudications=entries)
            status, _, err = self.corpus.run(precision)
            self.assertEqual(status, 2, message)
            self.assertIn(message, err)
        self.corpus.write(ROWS, rate=0)
        self.assertIn("sample_rate", self.corpus.run(precision)[2])

    def test_certain_precision_counts_only_certain_findings(self):
        sampled = self.corpus.sampled()
        certain = [row for row in sampled if row[7] == "certain"]
        likely = [row for row in sampled if row[7] == "likely"]
        self.assertTrue(certain and likely, "the synthetic sample must hold both confidences")
        # Every likely finding is a false positive and exactly one certain one is.
        verdicts = [verdict(row, "FP") for row in likely] + [verdict(row, "FP" if row is certain[0] else "TP") for row in certain]
        self.corpus.write(ROWS, adjudications=verdicts)
        result = precision.evaluate(self.corpus.root, "demo")
        self.assertEqual((result["TP"], result["FP"]), (len(certain) - 1, len(likely) + 1))
        self.assertEqual((result["certain_sampled"], result["certain_TP"], result["certain_FP"], result["certain_pending"]),
                         (len(certain), len(certain) - 1, 1, 0))
        self.assertGreater(precision.precision(result["certain_TP"], result["certain_FP"]), precision.precision(result["TP"], result["FP"]))
        self.assertIn(f"{100 * (len(certain) - 1) / len(certain):.1f} %", self.corpus.run(precision, "--markdown", "--stdout")[1])

    def test_certain_precision_waits_for_its_own_verdicts(self):
        sampled = self.corpus.sampled()
        likely = next(row for row in sampled if row[7] == "likely")
        # A missing verdict on a likely finding holds back the all-findings figure but not the certain one.
        self.corpus.write(ROWS, adjudications=[verdict(row) for row in sampled if row is not likely])
        result = precision.evaluate(self.corpus.root, "demo")
        self.assertEqual(result["certain_pending"], 0)
        self.assertEqual(len(result["pending"]), 1)
        out = self.corpus.run(precision, "--markdown", "--stdout")[1]
        self.assertIn("| **pending** |", out)
        self.assertIn("| **100.0 %** |", out)

    def test_expectations_recorded_without_confidence_still_load(self):
        old = [row[:7] for row in ROWS]
        sampled = [row for row in old if precision.is_sampled("demo", precision.row_key(row), 0.1)]
        self.corpus.write(old, adjudications=[verdict(row) for row in sampled])
        result = precision.evaluate(self.corpus.root, "demo")
        self.assertEqual((result["TP"], result["certain_sampled"]), (len(sampled), 0))
        self.assertIn("| 0 | n/a |", self.corpus.run(precision, "--markdown", "--stdout")[1])

    def test_markdown_publishes_precision_only_for_a_complete_sample(self):
        sampled = self.corpus.sampled()
        self.corpus.write(ROWS, adjudications=[verdict(row) for row in sampled[1:]])
        self.corpus.run(precision, "--markdown")
        self.assertIn("| **pending** |", (self.corpus.root / "docs/validation/precision-corpus.md").read_text())
        self.assertIn(f"being re-measured ({len(sampled) - 1} of {len(sampled)} sampled findings have a verdict)",
                      (self.corpus.root / "README.md").read_text())

        self.corpus.write(ROWS, adjudications=[verdict(row, "FP" if index == 0 else "TP") for index, row in enumerate(sampled)])
        self.assertEqual(self.corpus.run(precision, "--verify")[0], 1, "--verify must notice the stale scorecard")
        self.corpus.run(precision, "--markdown")
        expected = f"{100 * (len(sampled) - 1) / len(sampled):.1f} %"
        certain = [row for row in sampled if row[7] == "certain"]
        certain_expected = f"{100 * (len(certain) - (sampled[0][7] == 'certain')) / len(certain):.1f} %"
        doc = (self.corpus.root / "docs/validation/precision-corpus.md").read_text()
        self.assertIn(f"| demo | 200 | {len(sampled)} | {len(sampled) - 1} | 1 | 0 | 0 | {expected} | {len(certain)} | {certain_expected} |", doc)
        self.assertTrue(doc.endswith("<!-- precision-scorecard:end -->\n\nText.\n"))
        self.assertEqual((self.corpus.root / "README.md").read_text(),
                         f"It is <!-- precision-figure:begin -->{expected} over {len(sampled)} sampled findings, "
                         f"{certain_expected} over `certain` findings<!-- precision-figure:end -->.\n")
        self.assertEqual(self.corpus.run(precision, "--verify")[0], 0)
        status, out, _ = self.corpus.run(precision, "--markdown", "--stdout")
        self.assertEqual(status, 0)
        self.assertIn(f"**{expected}**", out)


class SampleTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.corpus = SyntheticCorpus(self.directory.name)

    def test_lists_sample_with_verdicts_and_pending_stubs(self):
        sampled = self.corpus.sampled()
        self.corpus.write(ROWS, adjudications=[verdict(sampled[0], "FP")])
        status, out, _ = self.corpus.run(sample, "demo")
        self.assertEqual(status, 0)
        lines = out.splitlines()
        self.assertEqual(len(lines), len(sampled))
        self.assertEqual(lines[0], f"| `{sampled[0][0]}:{sampled[0][1]}:5` | function.free `{sampled[0][4]}` | unused | FP | evidence |")
        self.assertTrue(lines[1].endswith("| unused | | |"))

        status, out, _ = self.corpus.run(sample, "demo", "--pending")
        stubs = [json.loads(line.rstrip(",")) for line in out.splitlines()]
        self.assertEqual([stub["name"] for stub in stubs], [row[4] for row in sampled[1:]])
        self.assertEqual(stubs[0]["verdict"], "")

    def test_seed_reproduces_the_positional_draw(self):
        status, out, _ = self.corpus.run(sample, "demo", "--seed", "2026", "--count", "3")
        self.assertEqual(status, 0)
        self.assertEqual(len(out.splitlines()), 3)
        self.assertTrue(out.startswith("| demo-1 | `Sources/File"))
        self.assertEqual(out, self.corpus.run(sample, "demo", "--seed", "2026", "--count", "3")[1])


if __name__ == "__main__":
    unittest.main()
