"""Large files: fail on files over 12 MB, warn from 5 MB (tracked and new untracked files).

usage: python3 tools/checks/large_files.py [--max-mb 12] [--warn-mb 5] [files...]

Git history is forever and this repo ships models, textures and audio directly (no LFS). Files
that must stay big go in tools/checks/baselines/large_files.json as {"path": "reason"}.
The pre-commit hook check-added-large-files (--maxkb=12288) applies the same limit to staged files.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "large_files"
BASELINE = "large_files.json"
MAX_MB = 12.0
WARN_MB = 5.0
MB = 1024 * 1024


def run(
    root: Path, files: list[str] | None = None, max_mb: float = MAX_MB, warn_mb: float = WARN_MB
) -> common.Result:
    res = common.Result(NAME)
    targets = files if files is not None else common.list_files(root)
    allow: dict = common.load_json(common.baseline_path(root, BASELINE), {})
    sizes = []
    for f in targets:
        p = root / f
        if not p.is_file():
            continue
        size = p.stat().st_size
        sizes.append((size, f))
        mb = size / MB
        if mb > max_mb:
            msg = f"{f}: {mb:.1f} MB > {max_mb:g} MB"
            if f in allow:
                res.known.append(f"{msg} (allowed: {allow[f]})")
            else:
                res.new.append(msg + " (compress it, split it or keep it out of git)")
        elif mb >= warn_mb:
            res.warnings.append(f"{f}: {mb:.1f} MB (warn at {warn_mb:g} MB)")
    sizes.sort(reverse=True)
    res.stats = {
        "files": len(sizes),
        "total_mb": round(sum(s for s, _ in sizes) / MB, 1),
        "over_warn": sum(1 for s, _ in sizes if s / MB >= warn_mb),
        "largest": [{"path": f, "mb": round(s / MB, 2)} for s, f in sizes[:5]],
    }
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--max-mb", type=float, default=MAX_MB)
    ap.add_argument("--warn-mb", type=float, default=WARN_MB)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.files or None, a.max_mb, a.warn_mb)
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
