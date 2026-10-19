"""AGENTS.md validation: required sections exist and every path and tool command it names is real.

usage: python3 tools/checks/agents_md.py [--file AGENTS.md] [--require REGEX ...]

Checks:
- the file exists and is not empty;
- for each required section pattern (default: setup/install, test, rules/conventions) some
  markdown heading matches it (case-insensitive);
- every inline `code` span that looks like a repo path (its first segment is a top-level entry of
  the repo, or it is a res:// path) exists; globs must match at least one file;
- every inline command whose program is a repo script (`tools/gate.sh quick`,
  `python3 tools/checks/run_all.py`, `godot ... -s tools/tests/x.gd`) points at an existing file.
Placeholders such as `<slice>` or `{name}` are skipped.
"""
from __future__ import annotations

import argparse
import re
import shlex
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "agents_md"
REQUIRED = (r"setup|install|getting started", r"test|validat", r"rule|convention|guideline")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
SPAN_RE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
PATHLIKE_RE = re.compile(r"^(?:\./)?[\w.@*?\[\]-]+(?:/[\w.@*?\[\]{},-]*)*$")


def strip_fences(text: str) -> str:
    """Drops fenced code blocks (their contents are examples, validated only as inline spans)."""
    out, fence = [], None
    for line in text.split("\n"):
        m = re.match(r"^\s*(```+|~~~+)", line)
        if m:
            if fence is None:
                fence = m.group(1)[0] * 3
            elif line.strip().startswith(fence):
                fence = None
            out.append("")
            continue
        out.append("" if fence else line)
    return "\n".join(out)


def candidate_paths(span: str, top: set[str]) -> list[str]:
    """Repo paths named in one code span (as a whole or as command arguments)."""
    if any(ch in span for ch in "<>{}$") or "://" in span and not span.startswith("res://"):
        return []
    try:
        tokens = shlex.split(span)
    except ValueError:
        tokens = span.split()
    out = []
    for tok in tokens:
        tok = tok.rstrip(".,;:)")
        if tok.startswith("res://"):
            tok = tok[len("res://") :]
            if tok:
                out.append(tok)
            continue
        if "=" in tok and not tok.startswith("-"):
            tok = tok.split("=", 1)[1]
        tok = re.sub(r":\d+(-\d+)?$", "", tok)
        if not tok or tok.startswith("-") or not PATHLIKE_RE.match(tok):
            continue
        first = tok[2:].split("/", 1)[0] if tok.startswith("./") else tok.split("/", 1)[0]
        if first in top and ("/" in tok or "." in first):
            out.append(tok[2:] if tok.startswith("./") else tok)
    return out


def exists(root: Path, rel: str) -> bool:
    rel = rel.rstrip("/")
    if any(ch in rel for ch in "*?["):
        return any(True for _ in root.glob(rel))
    return (root / rel).exists()


def run(root: Path, file: str = "AGENTS.md", required: tuple[str, ...] = REQUIRED) -> common.Result:
    res = common.Result(NAME)
    path = root / file
    if not path.is_file():
        res.new.append(f"{file} is missing")
        return res
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        res.new.append(f"{file} is empty")
        return res
    headings = [m.group(1) for m in map(HEADING_RE.match, text.split("\n")) if m]
    for pat in required:
        if not any(re.search(pat, h, re.I) for h in headings):
            res.new.append(f"{file}: no section heading matches /{pat}/ (headings: {', '.join(headings[:12])})")
    top = {p.name for p in root.iterdir()}
    checked = 0
    body = strip_fences(text)
    for lineno, line in enumerate(body.split("\n"), 1):
        for m in SPAN_RE.finditer(line):
            for rel in candidate_paths(m.group(1), top):
                checked += 1
                if not exists(root, rel):
                    res.new.append(f"{file}:{lineno}: `{m.group(1)}` names {rel}, which does not exist")
    res.stats = {"headings": len(headings), "paths_checked": checked}
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--file", default="AGENTS.md")
    ap.add_argument("--require", action="append", help="heading regex (repeatable)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.file, tuple(a.require) if a.require else REQUIRED)
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
