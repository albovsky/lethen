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
Text in backticks is ignored, and both counts must match the ones computed, so a later drop needs a new item.

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


def adjudicated(document: str, project: str, before: int, after: int) -> bool:
    """True when the gate's section holds a list item with the adjudication line for exactly these counts.
    Text in backticks never counts, so examples in prose cannot adjudicate a drop."""
    number = r"\d{1,3}(?:,\d{3})+|\d+"
    pattern = re.compile(rf"{re.escape(project)}: ({number}) (?:->|→) ({number}) findings, adjudicated")
    for line in section_lines(document):
        item = re.match(r"\s*- (.*)", line)
        if not item:
            continue
        match = pattern.search(re.sub(r"`[^`]*`", "", item.group(1)))
        if match and int(match.group(1).replace(",", "")) == before and int(match.group(2).replace(",", "")) == after:
            return True
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
        if adjudicated(document, project, before, after):
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
