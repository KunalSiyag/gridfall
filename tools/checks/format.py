"""gdformat --check on new and changed GDScript only, with legacy files in a baseline.

usage: python3 tools/checks/format.py [--base REF | --all] [--update-baseline] [files...]

Files come from the arguments (pre-commit passes the staged ones), else from `git diff` against
--base (CI passes the PR base or the previous push), else every tracked .gd file with --all.
Files listed in tools/checks/baselines/gdformat.json were never formatted and are skipped until
someone formats them (then drop them from the list with --update-baseline).
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "gdformat"
BASELINE = "gdformat.json"


def gdformat_cmd() -> list[str]:
    local = Path(sys.executable).parent / "gdformat"
    if local.exists():
        return [str(local)]
    found = shutil.which("gdformat")
    if found:
        return [found]
    return [sys.executable, "-m", "gdtoolkit.formatter"]


def unformatted(root: Path, files: list[str]) -> list[str]:
    """The subset of files gdformat would rewrite (or cannot parse)."""
    cmd = gdformat_cmd()

    def one(f: str) -> bool:
        p = subprocess.run(cmd + ["--check", f], cwd=root, capture_output=True, text=True)
        return p.returncode != 0

    with ThreadPoolExecutor(max_workers=max(1, min(8, os.cpu_count() or 1))) as ex:
        flags = list(ex.map(one, files))
    return [f for f, b in zip(files, flags) if b]


def run(
    root: Path,
    files: list[str] | None = None,
    base: str | None = None,
    all_files: bool = False,
    update: bool = False,
) -> common.Result:
    res = common.Result(NAME)
    tracked = common.list_files(root, ("*.gd",), ("addons/**",))
    if files is not None:
        targets = sorted(set(files) & set(tracked))
    elif all_files or update:
        targets = tracked
    else:
        targets = [f for f in common.changed_files(root, base) if f in set(tracked)]
    bpath = common.baseline_path(root, BASELINE)
    legacy = set(common.load_json(bpath, []))
    if update:
        bad = unformatted(root, tracked)
        common.save_json(bpath, sorted(bad))
        legacy = set(bad)
    check = [f for f in targets if f not in legacy]
    bad = unformatted(root, check)
    res.new = [f"{f}: not gdformat-clean (run: gdformat {f})" for f in bad]
    res.known = sorted(set(targets) & legacy)
    gone = sorted(f for f in legacy if not (root / f).exists())
    if gone:
        res.warnings.append(f"baseline lists deleted files: {', '.join(gone[:10])}")
    res.stats = {"checked": len(check), "legacy_skipped": len(res.known), "legacy_total": len(legacy)}
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--base", help="diff base ref (default: merge-base with origin/main)")
    ap.add_argument("--all", action="store_true", help="check every tracked .gd file")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.files or None, a.base, a.all, a.update_baseline)
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
