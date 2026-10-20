"""CHANGELOG.md from conventional commits (feat, fix, perf, refactor, docs, test, chore, ...).

usage: python3 tools/changelog.py [--version X.Y.Z] [--since REF] [--write CHANGELOG.md] [--date YYYY-MM-DD]

Collects non-merge commits since --since (default: the latest tag, else the whole history),
groups them by type and prints a markdown section; --write inserts it at the top of the
changelog (below its title) and keeps everything else. Subjects look like
`feat(fp/A): grounded crouch` (scope optional, `!` or a `BREAKING CHANGE:` footer marks a
breaking change). Other subjects land under "Other changes". tools/release.sh calls this.
"""
from __future__ import annotations

import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CC_RE = re.compile(r"^(?P<type>[a-zA-Z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?:\s*(?P<desc>.+)$")
GROUPS = [
    ("feat", "Features"),
    ("fix", "Bug fixes"),
    ("perf", "Performance"),
    ("refactor", "Refactoring"),
    ("docs", "Documentation"),
    ("test", "Tests"),
    ("build", "Build and CI"),
    ("ci", "Build and CI"),
    ("chore", "Chores"),
    ("style", "Chores"),
    ("revert", "Reverts"),
]
TITLE = "# Changelog\n\nAll notable changes to GridFall. Generated from conventional commits by tools/changelog.py.\n"


def git(*args: str, root: Path = ROOT) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True).stdout


def latest_tag(root: Path = ROOT) -> str:
    try:
        return git("describe", "--tags", "--abbrev=0", root=root).strip()
    except subprocess.CalledProcessError:
        return ""


def commits(since: str, root: Path = ROOT) -> list[tuple[str, str, str]]:
    """(short sha, subject, body) for non-merge commits in since..HEAD (all when since is "")."""
    rng = [f"{since}..HEAD"] if since else ["HEAD"]
    out = git("log", "--no-merges", "--format=%h%x1f%s%x1f%b%x1e", *rng, root=root)
    result = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        parts = rec.split("\x1f")
        while len(parts) < 3:
            parts.append("")
        result.append((parts[0], parts[1].strip(), parts[2]))
    return result


def section(version: str, date: str, items: list[tuple[str, str, str]]) -> str:
    titles = dict(GROUPS)
    order = []
    for _, t in GROUPS:
        if t not in order:
            order.append(t)
    buckets: dict[str, list[str]] = {t: [] for t in order + ["Other changes"]}
    breaking: list[str] = []
    for sha, subject, body in items:
        m = CC_RE.match(subject)
        if not m:
            buckets["Other changes"].append(f"- {subject} ({sha})")
            continue
        scope = f"**{m['scope']}**: " if m["scope"] else ""
        line = f"- {scope}{m['desc']} ({sha})"
        buckets[titles.get(m["type"].lower(), "Other changes")].append(line)
        if m["bang"] or "BREAKING CHANGE:" in body:
            breaking.append(line)
    out = [f"## [{version}] - {date}", ""]
    if breaking:
        out += ["### Breaking changes", ""] + breaking + [""]
    for title in order + ["Other changes"]:
        if buckets[title]:
            out += [f"### {title}", ""] + buckets[title] + [""]
    if len(out) == 2:
        out += ["No changes.", ""]
    return "\n".join(out)


def insert(changelog: str, new_section: str) -> str:
    """Puts new_section above the newest existing `## [` section (or after the title).

    A leading `## [Unreleased]` section is replaced: a release covers the same commits.
    """
    if not changelog.strip():
        return TITLE + "\n" + new_section
    k = changelog.find("\n## [")
    if k < 0:
        return changelog.rstrip("\n") + "\n\n" + new_section
    rest = changelog[k + 1 :]
    if rest.startswith("## [Unreleased]"):
        nxt = rest.find("\n## [")
        rest = rest[nxt + 1 :] if nxt >= 0 else ""
    if not rest:
        return changelog[: k + 1] + new_section
    return changelog[: k + 1] + new_section + "\n" + rest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--version", default="Unreleased")
    ap.add_argument("--since", help="start ref (default: latest tag)")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--write", help="changelog file to update in place")
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args(argv)
    root = Path(a.root)
    since = a.since if a.since is not None else latest_tag(root)
    text = section(a.version, a.date, commits(since, root))
    if a.write:
        p = Path(a.write)
        p = p if p.is_absolute() else root / p
        p.write_text(insert(p.read_text(encoding="utf-8") if p.exists() else "", text), encoding="utf-8")
        print(f"changelog: {a.version} written to {p}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
