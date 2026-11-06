#!/usr/bin/env python3
"""Fail when a corpus expectation lost more findings than its adjudication allows.

corpus/diff.sh already fails the nightly job on any row that differs from corpus/expected/<project>.json,
but corpus/accept.sh can rewrite an expectation that lost many findings. This gate compares each
committed expectation with its state at a baseline revision and fails when a project lost more than
the threshold (2 % by default) of its findings without an adjudication line in
docs/validation/precision-corpus.md. Growth never fails, and a project with no expectation at the
baseline is new and passes.

The baseline is the merge base with origin/master when the expectation differs there, otherwise the
newest release tag (`git tag --list '20*' --sort=-v:refname`, falling back to `git describe --tags
--abbrev=0`). `--base <rev>` names another revision.

An adjudication is a list item (`- ` after optional indentation) under the "### Finding-drop gate"
heading of that document, up to the next heading of the same or a higher level, holding

  <project>: <baseline count> -> <current count> findings, adjudicated

with thousands separators optional, for example (not recorded) `example-app: 2,567 -> 2,480 findings, adjudicated`.
Text in backticks is ignored. A drop is adjudicated when the items lead from the baseline count to the current
count: in one item, as a chain (`120 -> 100` and `100 -> 90` adjudicate 120 -> 90), or joined by changes that
need no adjudication themselves, growth or a drop within the threshold (`100 -> 90` still adjudicates 100 -> 91
and 100 -> 89, and 120 -> 100 when the item says `125 -> 100`). So a later drop past the threshold needs a new
item, and the earlier items stay valid once a branch merges and the baseline moves back to the release tag.

Usage:
  corpus/drop_gate.py                        compare with the merge base or the newest release tag
  corpus/drop_gate.py --base 2026.10.1       compare with a revision
  corpus/drop_gate.py --threshold 0.05       allow a larger drop share
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

DOC = Path("docs/validation/precision-corpus.md")
DEFAULT_THRESHOLD = 0.02
SECTION_HEADING = "### Finding-drop gate"


class GateError(Exception):
    pass


def run_git(root: Path, *arguments: str) -> Tuple[int, str, str]:
    """(exit status, stdout, stderr) of a git command run in `root`."""
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def resolve(root: Path, revision: str) -> str:
    """The commit `revision` names, or a GateError when it names none."""
    status, out, _ = run_git(root, "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}")
    if status != 0 or not out.strip():
        raise GateError(f"--base {revision!r} does not name a revision")
    return out.strip()


def show(root: Path, revision: str, path: str) -> Optional[str]:
    """The file at `revision`, None when the revision has no such path, a GateError on any other failure."""
    status, out, err = run_git(root, "show", f"{revision}:{path}")
    if status == 0:
        return out
    if "does not exist in" in err or "exists on disk, but not in" in err:
        return None
    raise GateError(f"git show {revision}:{path} failed: {err.strip()}")


def project_names(root: Path) -> List[str]:
    return [entry["name"] for entry in json.loads((root / "corpus/projects.json").read_text())]


def row_count(text: str, where: str) -> int:
    rows = json.loads(text)
    if not isinstance(rows, list):
        raise GateError(f"{where} is not a list of findings")
    return len(rows)


def latest_release_tag(root: Path) -> Optional[str]:
    status, tags, _ = run_git(root, "tag", "--list", "20*", "--sort=-v:refname")
    if status == 0 and tags.split():
        return tags.split()[0]
    status, described, _ = run_git(root, "describe", "--tags", "--abbrev=0")
    return described.strip() if status == 0 and described.strip() else None


def baseline_text(root: Path, project: str, current: str, base: Optional[str]) -> Tuple[str, Optional[str]]:
    """(revision, expectation text at that revision or None when absent) for one project."""
    path = f"corpus/expected/{project}.json"
    if base is not None:
        revision = resolve(root, base)
        return base, show(root, revision, path)
    status, out, _ = run_git(root, "merge-base", "HEAD", "origin/master")
    candidate = out.strip() if status == 0 and out.strip() else None
    text = show(root, candidate, path) if candidate else None
    if candidate and (text is None or text != current):
        return candidate, text
    tag = latest_release_tag(root)
    if tag is not None:
        return tag, show(root, tag, path)
    if candidate:
        # A checkout of origin/master without tags: nothing older to compare with.
        return candidate, text
    raise GateError("no baseline: origin/master and release tags are unavailable; pass --base <rev>")


def section_lines(document: str) -> List[str]:
    """The lines under the gate's heading, up to the next heading of the same or a higher level."""
    lines = document.splitlines()
    if SECTION_HEADING not in lines:
        return []
    level = len(SECTION_HEADING) - len(SECTION_HEADING.lstrip("#"))
    found = []
    for line in lines[lines.index(SECTION_HEADING) + 1:]:
        heading = re.match(r"(#+) ", line)
        if heading and len(heading.group(1)) <= level:
            break
        found.append(line)
    return found


def adjudications(document: str, project: str) -> List[Tuple[int, int]]:
    """The (before, after) counts of every list item in the gate's section that adjudicates a drop of `project`.
    Text in backticks never counts, so examples in prose cannot adjudicate a drop."""
    number = r"\d{1,3}(?:,\d{3})+|\d+"
    pattern = re.compile(rf"{re.escape(project)}: ({number}) (?:->|→) ({number}) findings, adjudicated")
    found = []
    for line in section_lines(document):
        item = re.match(r"\s*- (.*)", line)
        if not item:
            continue
        match = pattern.search(re.sub(r"`[^`]*`", "", item.group(1)))
        if match:
            found.append((int(match.group(1).replace(",", "")), int(match.group(2).replace(",", ""))))
    return found


def needs_no_adjudication(start: int, end: int, threshold: float) -> bool:
    """True for growth and for a drop within the threshold: a change the gate passes on its own."""
    return end >= start or (start - end) / start <= threshold


def adjudicated(document: str, project: str, before: int, after: int, threshold: float) -> bool:
    """True when the section's items for `project` lead from `before` to `after`.
    Items may chain (`120 -> 100`, `100 -> 90`), and the baseline, the items and the current count may be joined by
    changes that need no adjudication, so an item stays valid after its branch merges and the baseline moves back to
    the release tag, and after later growth or a small drop. At least one item must take part."""
    edges = adjudications(document, project)
    reached, frontier = set(), [before]
    while frontier:
        count = frontier.pop()
        for start, end in edges:
            if end not in reached and needs_no_adjudication(count, start, threshold):
                if needs_no_adjudication(end, after, threshold):
                    return True
                reached.add(end)
                frontier.append(end)
    return False


def check(root: Path, base: Optional[str], base_dir: Optional[Path], threshold: float) -> List[str]:
    """The failure messages for every project that dropped past the threshold without a note.
    Baselines come from `base_dir` (a tree holding corpus/expected/) when given, otherwise from the repository."""
    doc_path = root / DOC
    document = doc_path.read_text() if doc_path.exists() else ""
    failures = []
    for project in project_names(root):
        where = f"corpus/expected/{project}.json"
        current_text = (root / where).read_text()
        after = row_count(current_text, where)
        if base_dir is not None:
            old = base_dir / where
            revision, text = str(base_dir), (old.read_text() if old.exists() else None)
        else:
            revision, text = baseline_text(root, project, current_text, base)
        if text is None:
            print(f"corpus: {project} has no expectation at {revision}; treated as new")
            continue
        before = row_count(text, f"{where} at {revision}")
        if before == 0 or after >= before:
            continue
        share = (before - after) / before
        if share <= threshold:
            continue
        if adjudicated(document, project, before, after, threshold):
            print(f"corpus: {project} {before:,} -> {after:,} findings ({share:.1%} lost), adjudicated")
            continue
        failures.append(f"{project}: {before:,} -> {after:,} findings, {share:.1%} lost since {revision} "
                        f"(threshold {threshold:.1%}); adjudicate the drop and add the line "
                        f"`{project}: {before:,} -> {after:,} findings, adjudicated` to {DOC}")
    return failures


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="revision to compare with (default: merge base with origin/master, else the newest release tag)")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD, help="largest drop share allowed without a note")
    parser.add_argument("--current-dir", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="tree holding the current expectations and the document (for tests)")
    parser.add_argument("--base-dir", type=Path, help="tree holding the baseline expectations, instead of a revision (for tests)")
    args = parser.parse_args(argv)
    try:
        failures = check(args.current_dir, args.base, args.base_dir, args.threshold)
    except (GateError, OSError, ValueError) as error:
        print(f"corpus: {error}", file=sys.stderr)
        return 2
    for failure in failures:
        print(f"corpus: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
