#!/usr/bin/env python3
"""Compute sampled precision from the committed corpus verdicts.

Joins corpus/adjudications/<project>.json with corpus/expected/<project>.json. A finding is in
a project's sample when the hash of its key falls under the project's `sample_rate` (see
`is_sampled`), so a finding keeps its membership, and its verdict, for as long as it is reported.
Precision is TP / (TP + FP) over sampled findings with a verdict; UNSURE counts in neither.
`certain` and `likely` precision are the same ratio over the sampled findings of that confidence
(the expected rows carry it as their eighth field; a row without it is counted in neither tier), each
published with its 95 % Wilson score interval. The overall figure is also given weighted by each
project's number of findings, since the sample rates, and so each project's share of the pool, differ.
Verdicts on findings outside the sample are kept, but not counted, and verdicts on findings no
longer reported must be marked `retired`.

Usage:
  corpus/precision.py            print the scorecard, findings that need a verdict, and retired verdicts
  corpus/precision.py --check    also exit 1 when a sampled finding has no verdict or a verdict
                                 names a finding that is no longer reported but is not marked retired
  corpus/precision.py --markdown rewrite the scorecard in docs/validation/precision-corpus.md and
                                 the figure in README.md (--stdout prints the scorecard instead)
  corpus/precision.py --verify   exit 1 when the committed scorecard or figure differs from the computed one
"""
import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

VERDICTS = ("TP", "FP", "UNSURE")
TIERS = ("certain", "likely")
WILSON_Z = 1.959964  # two-sided 95 %
KEY_FIELDS = ("path", "line", "column", "kind", "name")
REQUIRED_FIELDS = KEY_FIELDS + ("verdict", "note", "adjudicated_on", "lethen_commit")
OPTIONAL_FIELDS = ("reference", "retired")
SCORECARD_DOC = Path("docs/validation/precision-corpus.md")
SCORECARD_MARKERS = ("<!-- precision-scorecard:begin -->", "<!-- precision-scorecard:end -->")
FIGURE_DOC = Path("README.md")
FIGURE_MARKERS = ("<!-- precision-figure:begin -->", "<!-- precision-figure:end -->")


class CorpusError(Exception):
    pass


def row_key(row):
    """The identity of an expected finding: [path, line, column, kind, name]. Stable because
    every corpus project is pinned to one commit."""
    return tuple(row[:5])


def is_sampled(project, key, rate):
    digest = hashlib.sha256(f"{project}\n{json.dumps(list(key))}".encode()).digest()
    return int.from_bytes(digest[:8], "big") / 2**64 < rate


def project_names(root):
    return [entry["name"] for entry in json.loads((root / "corpus/projects.json").read_text())]


def row_confidence(row):
    """The confidence field of an expected row, or None for a row recorded before the field existed."""
    return row[7] if len(row) > 7 else None


def load_expected_rows(root, project):
    return json.loads((root / f"corpus/expected/{project}.json").read_text())


def load_expected(root, project):
    return [row_key(row) for row in load_expected_rows(root, project)]


def load_adjudications(root, project):
    path = root / f"corpus/adjudications/{project}.json"
    if not path.exists():
        raise CorpusError(f"{path.relative_to(root)} is missing")
    data = json.loads(path.read_text())
    where = path.relative_to(root)
    if data.get("project") != project:
        raise CorpusError(f"{where}: project must be {project!r}")
    rate = data.get("sample_rate")
    if not isinstance(rate, (int, float)) or isinstance(rate, bool) or not 0 < rate <= 1:
        raise CorpusError(f"{where}: sample_rate must be a number in (0, 1]")
    verdicts = {}
    for entry in data.get("adjudications", []):
        missing = [field for field in REQUIRED_FIELDS if field not in entry]
        unknown = sorted(set(entry) - set(REQUIRED_FIELDS) - set(OPTIONAL_FIELDS))
        if missing or unknown:
            raise CorpusError(f"{where}: {entry.get('reference') or entry} has missing fields {missing} or unknown fields {unknown}")
        key = tuple(entry[field] for field in KEY_FIELDS)
        if not all(isinstance(entry[field], str) and entry[field] for field in ("path", "kind", "name", "note", "adjudicated_on", "lethen_commit")) \
                or not all(isinstance(entry[field], int) and not isinstance(entry[field], bool) for field in ("line", "column")):
            raise CorpusError(f"{where}: {list(key)} has a field of the wrong type or an empty string")
        if entry["verdict"] not in VERDICTS:
            raise CorpusError(f"{where}: {list(key)} has verdict {entry['verdict']!r}; expected one of {', '.join(VERDICTS)}")
        if key in verdicts:
            raise CorpusError(f"{where}: {list(key)} is adjudicated twice")
        verdicts[key] = entry
    return rate, verdicts


def evaluate(root, project):
    rows = load_expected_rows(root, project)
    expected = [row_key(row) for row in rows]
    confidence = {row_key(row): row_confidence(row) for row in rows}
    rate, verdicts = load_adjudications(root, project)
    reported = set(expected)
    for key, entry in verdicts.items():
        if "retired" in entry and key in reported:
            raise CorpusError(f"corpus/adjudications/{project}.json: {list(key)} is marked retired but is still reported")
    sampled = [key for key in expected if is_sampled(project, key, rate)]
    in_sample = set(sampled)
    counts = {verdict: sum(1 for key in sampled if verdicts.get(key, {}).get("verdict") == verdict) for verdict in VERDICTS}
    tiers = {}
    for tier in TIERS:
        keys = [key for key in sampled if confidence[key] == tier]
        tiers.update({
            f"{tier}_sampled": len(keys),
            f"{tier}_TP": sum(1 for key in keys if verdicts.get(key, {}).get("verdict") == "TP"),
            f"{tier}_FP": sum(1 for key in keys if verdicts.get(key, {}).get("verdict") == "FP"),
            f"{tier}_pending": sum(1 for key in keys if key not in verdicts),
        })
    return {
        "project": project,
        "findings": len(expected),
        "sampled": len(sampled),
        **counts,
        **tiers,
        "pending": sorted(key for key in sampled if key not in verdicts),
        "outside_sample": sum(1 for key in reported if key in verdicts and key not in in_sample),
        "retired": sorted((key, entry) for key, entry in verdicts.items() if key not in reported and "retired" in entry),
        "unmarked": sorted(key for key in verdicts if key not in reported and "retired" not in verdicts[key]),
    }


def evaluate_all(root):
    return [evaluate(root, project) for project in project_names(root)]


def precision(tp, fp):
    return f"{100 * tp / (tp + fp):.1f} %" if tp + fp else "n/a"


def wilson(tp, fp):
    """The 95 % Wilson score interval of TP / (TP + FP), as fractions, or None without verdicts."""
    n = tp + fp
    if not n:
        return None
    p = tp / n
    z2 = WILSON_Z ** 2
    center = (p + z2 / (2 * n)) / (1 + z2 / n)
    half = WILSON_Z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return max(0.0, center - half), min(1.0, center + half)


def interval(tp, fp, pending):
    """The published interval, `95.5–100.0 %`, under the same rule as `published`."""
    if pending:
        return "pending"
    bounds = wilson(tp, fp)
    if bounds is None:
        return "n/a"
    return f"{100 * bounds[0]:.1f}–{100 * bounds[1]:.1f} %"


def weighted(results):
    """Overall precision with each project weighted by its number of findings rather than by its
    sample size, over the projects whose precision is published; None while any is pending or
    none has verdicts."""
    if any(r["pending"] for r in results):
        return None
    scored = [r for r in results if r["TP"] + r["FP"]]
    findings = sum(r["findings"] for r in scored)
    if not findings:
        return None
    return sum(r["findings"] * r["TP"] / (r["TP"] + r["FP"]) for r in scored) / findings


def weighted_text(results):
    if any(r["pending"] for r in results):
        return "pending"
    share = weighted(results)
    return "n/a" if share is None else f"{100 * share:.1f} %"


def total(results):
    fields = ("findings", "sampled", "TP", "FP", "UNSURE") + tuple(f"{tier}_{field}" for tier in TIERS for field in ("sampled", "TP", "FP", "pending"))
    summed = {field: sum(result[field] for result in results) for field in fields}
    summed["pending"] = sum(len(result["pending"]) for result in results)
    summed["outside_sample"] = sum(result["outside_sample"] for result in results)
    summed["retired"] = sum(len(result["retired"]) for result in results)
    return summed


def published(tp, fp, pending):
    """A figure is published only once every sampled finding has a verdict: the findings that
    already have one are not a random subset of the sample (verdicts carried over from other
    work, such as a diff section, cluster in the classes that work touched)."""
    return "pending" if pending else precision(tp, fp)


def scorecard(results):
    """The Markdown scorecard block. It holds no dates, so it changes only when findings or verdicts do."""
    lines = [
        "| Project | Findings | Sampled | TP | FP | UNSURE | Needs a verdict | Precision | Sampled `certain` | `certain` precision |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for r in results:
        pending = len(r["pending"])
        lines.append(f"| {r['project']} | {r['findings']:,} | {r['sampled']} | {r['TP']} | {r['FP']} | {r['UNSURE']} | {pending} | {published(r['TP'], r['FP'], pending)} "
                     f"| {r['certain_sampled']} | {published(r['certain_TP'], r['certain_FP'], r['certain_pending'])} |")
    t = total(results)
    lines.append(f"| **All** | {t['findings']:,} | {t['sampled']} | {t['TP']} | {t['FP']} | {t['UNSURE']} | {t['pending']} | **{published(t['TP'], t['FP'], t['pending'])}** "
                 f"| {t['certain_sampled']} | **{published(t['certain_TP'], t['certain_FP'], t['certain_pending'])}** |")
    lines += [
        "",
        "| Project | Confidence | Sampled | TP | FP | Needs a verdict | Precision | 95 % interval |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, r in [(r["project"], r) for r in results] + [("**All**", t)]:
        for tier in TIERS:
            tp, fp, pending = r[f"{tier}_TP"], r[f"{tier}_FP"], r[f"{tier}_pending"]
            lines.append(f"| {name} | `{tier}` | {r[f'{tier}_sampled']} | {tp} | {fp} | {pending} | {published(tp, fp, pending)} | {interval(tp, fp, pending)} |")
    lines.append("")
    lines.append(
        f"Over every sampled finding, pooled: {published(t['TP'], t['FP'], t['pending'])}; "
        f"with each project weighted by its findings: {weighted_text(results)}. "
        "Generated by `corpus/precision.py --markdown` from `corpus/expected/` and `corpus/adjudications/`. "
        "Precision is TP / (TP + FP) over the sampled findings, published once each of them has a verdict; "
        "the `certain` columns count only the sampled findings Lethen reports as `certain`, the rest being `likely`, "
        "and the interval is the 95 % Wilson score interval of the tier's precision. "
        f"Verdicts kept but not counted: {t['outside_sample']} on reported findings outside the sample, "
        f"{t['retired']} on findings no longer reported."
    )
    return "\n".join(lines)


def figure(results):
    """The README phrase that quotes the overall figure."""
    t = total(results)
    if t["pending"]:
        return f"being re-measured ({t['sampled'] - t['pending']} of {t['sampled']} sampled findings have a verdict)"
    return (f"{precision(t['TP'], t['FP'])} over {t['sampled']} sampled findings, "
            f"{published(t['certain_TP'], t['certain_FP'], t['certain_pending'])} over {t['certain_sampled']} sampled `certain` findings "
            f"(95 % interval {interval(t['certain_TP'], t['certain_FP'], t['certain_pending'])})")


def replace_between(text, markers, body, where):
    begin, end = markers
    if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
        raise CorpusError(f"{where} must contain {begin} and then {end} exactly once")
    head, rest = text.split(begin)
    _, tail = rest.split(end)
    return head + begin + body + end + tail


def rendered(root, results):
    doc = (root / SCORECARD_DOC).read_text()
    readme = (root / FIGURE_DOC).read_text()
    return {
        SCORECARD_DOC: replace_between(doc, SCORECARD_MARKERS, "\n" + scorecard(results) + "\n", SCORECARD_DOC),
        FIGURE_DOC: replace_between(readme, FIGURE_MARKERS, figure(results), FIGURE_DOC),
    }


def describe(key):
    path, line, column, kind, name = key
    return f"{path}:{line}:{column} {kind} {name}"


def tiers_summary(r):
    """`certain 100.0 % (88.3–100.0 %) over 29, likely n/a over 0`, with intervals only for complete tiers."""
    parts = []
    for tier in TIERS:
        tp, fp, pending = r[f"{tier}_TP"], r[f"{tier}_FP"], r[f"{tier}_pending"]
        bounds = "" if pending or not tp + fp else f" ({interval(tp, fp, pending)})"
        parts.append(f"{tier} {precision(tp, fp)}{bounds} over {r[f'{tier}_sampled']}")
    return ", ".join(parts)


def report(results):
    for r in results:
        print(f"{r['project']}: {r['findings']} findings, {r['sampled']} sampled, "
              f"TP {r['TP']}, FP {r['FP']}, UNSURE {r['UNSURE']}, {len(r['pending'])} need a verdict, "
              f"precision {precision(r['TP'], r['FP'])}{' so far' if r['pending'] else ''}; {tiers_summary(r)}")
        for key in r["pending"]:
            print(f"  needs a verdict: {describe(key)}")
        for key in r["unmarked"]:
            print(f"  no longer reported; mark its verdict retired: {describe(key)}")
        for key, entry in r["retired"]:
            print(f"  retired {entry['verdict']}: {describe(key)} ({entry['retired']})")
    t = total(results)
    print(f"All: {t['findings']} findings, {t['sampled']} sampled, TP {t['TP']}, FP {t['FP']}, "
          f"UNSURE {t['UNSURE']}, {t['pending']} need a verdict, precision {precision(t['TP'], t['FP'])}{' so far' if t['pending'] else ''}; "
          f"{tiers_summary(t)}; weighted by findings {weighted_text(results)}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent, help=argparse.SUPPRESS)
    parser.add_argument("--check", action="store_true", help="fail when a sampled finding has no verdict")
    parser.add_argument("--markdown", action="store_true", help="rewrite the scorecard and the README figure")
    parser.add_argument("--stdout", action="store_true", help="with --markdown, print the scorecard instead of writing files")
    parser.add_argument("--verify", action="store_true", help="fail when the committed scorecard or figure is out of date")
    args = parser.parse_args(argv)
    if args.stdout and not args.markdown:
        parser.error("--stdout requires --markdown")
    try:
        results = evaluate_all(args.root)
        if args.markdown and args.stdout:
            print(scorecard(results))
        elif args.markdown:
            for path, text in rendered(args.root, results).items():
                (args.root / path).write_text(text)
            print(f"corpus: wrote the scorecard to {SCORECARD_DOC} and the figure to {FIGURE_DOC}")
        elif not args.verify:
            report(results)
        status = 0
        if args.verify:
            stale = [str(path) for path, text in rendered(args.root, results).items() if (args.root / path).read_text() != text]
            if stale:
                print(f"corpus: {', '.join(stale)} out of date; run corpus/precision.py --markdown", file=sys.stderr)
                status = 1
        if args.check:
            pending = sum(len(r["pending"]) for r in results)
            unmarked = sum(len(r["unmarked"]) for r in results)
            if pending or unmarked:
                print(f"corpus: {pending} sampled findings need a verdict and {unmarked} verdicts need a retired note "
                      "in corpus/adjudications/", file=sys.stderr)
                status = 1
        return status
    except CorpusError as error:
        print(f"corpus: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
