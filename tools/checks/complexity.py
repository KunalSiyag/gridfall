"""Cyclomatic complexity of GDScript functions, with a baseline for legacy hot spots.

usage: python3 tools/checks/complexity.py [--threshold N] [--update-baseline] [--top N] [files...]

Complexity is 1 + decision points: if, elif, for, while, `and`/`or`/`&&`/`||`, `when` guards,
inline `x if c else y`, and every non-wildcard `match` branch (strings and comments are ignored).
gdtoolkit's `gdradon cc` is experimental (it converts GDScript to Python and fails on several
files here), so the count is computed directly from the source.

A function above --threshold (default 20, radon's "C" ceiling) fails unless the baseline lists it
(`path::Class.func`) with at least its current score; a baselined function that grows is a warning.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "complexity"
BASELINE = "complexity.json"
THRESHOLD = 20
DECISION_RE = re.compile(r"\b(?:if|elif|for|while|and|or|when)\b|&&|\|\|")
MATCH_RE = re.compile(r"^\s*match\b.*:\s*$")


def grade(score: int) -> str:
    for limit, g in ((5, "A"), (10, "B"), (20, "C"), (30, "D"), (40, "E")):
        if score <= limit:
            return g
    return "F"


def function_scores(src: str) -> list[tuple[common.GdFunc, int]]:
    lexed = common.lex_gd(src)
    lines = lexed.code_lines
    out = []
    for fn in common.gd_functions(lexed):
        body = lines[fn.start - 1 : fn.end]
        score = 1
        # The def line counts only from its body part (`func f(): return a if b else c`).
        first = body[0]
        colon = _def_colon(first)
        body = [first[colon + 1 :] if colon >= 0 else ""] + body[1:]
        match_stack: list[int] = []
        branch_indent: dict[int, int] = {}
        for line in body:
            if not line.strip():
                continue
            ind = common.indent_of(line)
            while match_stack and ind <= match_stack[-1]:
                branch_indent.pop(match_stack.pop(), None)
            if match_stack:
                m_ind = match_stack[-1]
                bi = branch_indent.setdefault(m_ind, ind)
                if ind == bi:
                    pattern = line.strip()
                    head = pattern.split(" when ", 1)[0].rstrip(":").strip()
                    if head != "_":
                        score += 1
                    score += len(DECISION_RE.findall(pattern))
                    continue
            score += len(DECISION_RE.findall(line))
            if MATCH_RE.match(line):
                match_stack.append(ind)
        out.append((fn, score))
    return out


def _def_colon(line: str) -> int:
    """Index of the `:` that ends a single-line func header, or -1 when the header continues."""
    depth = 0
    for i, ch in enumerate(line):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == ":" and depth == 0 and ")" in line[:i]:
            return i
    return -1


def run(
    root: Path, files: list[str] | None = None, threshold: int = THRESHOLD, update: bool = False
) -> common.Result:
    res = common.Result(NAME)
    tracked = common.list_files(root, ("*.gd",), ("addons/**",))
    targets = sorted(set(files) & set(tracked)) if files is not None else tracked
    bpath = common.baseline_path(root, BASELINE)
    baseline: dict = common.load_json(bpath, {})
    scores: dict[str, int] = {}
    where: dict[str, int] = {}
    for path in targets:
        for fn, score in function_scores(common.read_text(root, path)):
            key = f"{path}::{fn.qualname}"
            if key in scores:
                key = f"{key}@{fn.start}"
            scores[key] = score
            where[key] = fn.start
    over = {k: v for k, v in scores.items() if v > threshold}
    if update:
        if files is None:
            baseline = {}
        else:
            baseline = {k: v for k, v in baseline.items() if k.split("::")[0] not in set(targets)}
        baseline.update(over)
        common.save_json(bpath, dict(sorted(baseline.items())))
    for key, score in sorted(over.items(), key=lambda kv: -kv[1]):
        path = key.split("::")[0]
        label = f"{path}:{where[key]} {key.split('::', 1)[1]} complexity {score} ({grade(score)})"
        if key not in baseline:
            res.new.append(f"{label} > {threshold}")
        else:
            res.known.append(label)
            if score > int(baseline[key]):
                res.warnings.append(f"{label} grew from {baseline[key]}")
    vals = sorted(scores.values())
    dist: dict[str, int] = {}
    for v in vals:
        dist[grade(v)] = dist.get(grade(v), 0) + 1
    res.stats = {
        "functions": len(vals),
        "threshold": threshold,
        "over_threshold": len(over),
        "max": vals[-1] if vals else 0,
        "mean": round(sum(vals) / len(vals), 2) if vals else 0,
        "p95": vals[int(len(vals) * 0.95)] if vals else 0,
        "grades": dict(sorted(dist.items())),
        "top": [
            {"function": k, "score": v}
            for k, v in sorted(scores.items(), key=lambda kv: -kv[1])[:10]
        ],
    }
    res.scores = scores  # type: ignore[attr-defined]
    res.where = where  # type: ignore[attr-defined]
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--threshold", type=int, default=THRESHOLD)
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--top", type=int, default=0, help="print the N most complex functions")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.files or None, a.threshold, a.update_baseline)
    for item in res.stats["top"][: a.top]:
        print(f"{item['score']:4d} {grade(item['score'])} {item['function']}")
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
