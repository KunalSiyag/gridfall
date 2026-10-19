"""Duplicate code: identical 8-line windows (comments and whitespace stripped) in .gd and .py.

usage: python3 tools/checks/duplicates.py [--window N] [--update-baseline] [--top N] [-v]

Each file is normalised (comments removed, whitespace collapsed, blank lines dropped), then every
run of --window consecutive lines is hashed. A hash seen at two or more places is duplication;
overlapping windows are merged into clusters for the report. Windows with too little code
(closing brackets, `pass`, `else:`) are ignored. The baseline maps each known duplicated hash to
its occurrence count; a new hash, or more copies of a known one, fails.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import sys
import tokenize
from collections import defaultdict
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "duplicates"
BASELINE = "duplicates.json"
WINDOW = 8
MIN_CHARS = 160
PATTERNS = ("*.gd", "*.py")
EXCLUDE = ("tools/checks/baselines/**", "addons/**", "tools/pytests/fixtures/**")


def _py_code(src: str) -> list[str]:
    """Python source with comments blanked; falls back to the raw text when it does not tokenize."""
    lines = src.split("\n")
    try:
        for tok in tokenize.generate_tokens(io.StringIO(src).readline):
            if tok.type == tokenize.COMMENT:
                r, c = tok.start
                lines[r - 1] = lines[r - 1][:c]
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return lines


def normalized(path: str, src: str) -> list[tuple[int, str]]:
    """[(1-based source line, normalised text)] for the lines that carry code."""
    if path.endswith(".gd"):
        lx = common.lex_gd(src)
        # Keep string contents (two functions differing only in literals are not copies).
        code = lx.code_lines
        raw = lx.src_lines
        lines = []
        comment_at = {ln: text for ln, text in lx.comments}
        for i, (c, r) in enumerate(zip(code, raw), 1):
            if i in comment_at:
                cut = len(r) - len(comment_at[i])
                lines.append(r[:cut] if r.endswith(comment_at[i]) else c)
            else:
                lines.append(r)
    else:
        lines = _py_code(src)
    out = []
    for i, line in enumerate(lines, 1):
        norm = " ".join(line.split())
        if norm:
            out.append((i, norm))
    return out


def windows(path: str, src: str, size: int = WINDOW) -> list[tuple[str, int, int]]:
    """[(hash, first line, last line)] for every window with enough code in it."""
    norm = normalized(path, src)
    out = []
    for k in range(0, len(norm) - size + 1):
        chunk = norm[k : k + size]
        text = "\n".join(t for _, t in chunk)
        if len(text.replace(" ", "")) < MIN_CHARS:
            continue
        h = hashlib.sha1(text.encode()).hexdigest()[:16]
        out.append((h, chunk[0][0], chunk[-1][0]))
    return out


def clusters(index: dict[str, list[tuple[str, int, int]]], hashes: set[str]) -> list[list[tuple[str, int, int]]]:
    """Merges consecutive duplicated windows that move together into ranges per location."""
    by_loc: dict[tuple[str, ...], list] = defaultdict(list)
    for h in hashes:
        locs = sorted(index[h])
        by_loc[tuple(p for p, _, _ in locs)].append(locs)
    result = []
    for group in by_loc.values():
        group.sort(key=lambda locs: [(p, a) for p, a, _ in locs])
        merged: list[list[list]] = []
        for locs in group:
            if merged and all(
                cur[0] == p and a <= cur[2] + 1 for cur, (p, a, _) in zip(merged[-1], locs)
            ):
                for cur, (p, a, b) in zip(merged[-1], locs):
                    cur[2] = max(cur[2], b)
            else:
                merged.append([[p, a, b] for p, a, b in locs])
        result += [[tuple(x) for x in m] for m in merged]
    result.sort(key=lambda c: -(c[0][2] - c[0][1]))
    return result


def run(root: Path, update: bool = False, window: int = WINDOW) -> common.Result:
    res = common.Result(NAME)
    files = common.list_files(root, PATTERNS, EXCLUDE)
    index: dict[str, list[tuple[str, int, int]]] = defaultdict(list)
    total_lines = 0
    for f in files:
        src = common.read_text(root, f)
        total_lines += src.count("\n") + 1
        last_end: dict[str, int] = {}
        prev = ""
        for h, a, b in windows(f, src, window):
            # A window equal to the one before it (a run of identical lines), or overlapping an
            # earlier copy of itself, is the same copy and not a duplicate.
            same_as_prev, prev = h == prev, h
            if same_as_prev or last_end.get(h, -1) >= a:
                continue
            last_end[h] = b
            index[h].append((f, a, b))
    dup = {h: locs for h, locs in index.items() if len(locs) > 1}
    bpath = common.baseline_path(root, BASELINE)
    baseline: dict = common.load_json(bpath, {})
    if update:
        baseline = {h: len(locs) for h, locs in dup.items()}
        common.save_json(bpath, baseline)
    new_hashes = {h for h, locs in dup.items() if len(locs) > int(baseline.get(h, 0))}
    for c in clusters(index, new_hashes):
        res.new.append("duplicate block: " + " == ".join(f"{p}:{a}-{b}" for p, a, b in c))
    known = clusters(index, set(dup) - new_hashes)
    res.known = ["duplicate block: " + " == ".join(f"{p}:{a}-{b}" for p, a, b in c) for c in known]
    dup_lines = set()
    for locs in dup.values():
        for p, a, b in locs:
            dup_lines.update((p, i) for i in range(a, b + 1))
    res.stats = {
        "files": len(files),
        "lines": total_lines,
        "duplicated_lines": len(dup_lines),
        "duplication_pct": round(100.0 * len(dup_lines) / total_lines, 2) if total_lines else 0.0,
        "clusters": len(known) + len(res.new),
        "window": window,
    }
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--window", type=int, default=WINDOW)
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.update_baseline, a.window)
    print(
        f"duplicates: {res.stats['duplicated_lines']} duplicated lines "
        f"({res.stats['duplication_pct']}%) in {res.stats['clusters']} clusters"
    )
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
