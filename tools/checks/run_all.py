"""Runs every repo check and prints one summary table; the entry point for hooks, CI and agents.

usage: python3 tools/checks/run_all.py [--base REF] [--fast] [--only a,b] [--skip a,b]
                                       [--json OUT] [--summary FILE] [--debt-report FILE]

Checks: gdlint, gdformat (files changed since --base), complexity, dead_code, duplicates,
boundaries, large_files, todo_scan, agents_md, test_map, feature_flags, rng_seed, unused_deps,
workflows, api_docs, web_headers. --fast skips the slow parser-based gdlint and gdformat (pre-commit runs those on the
staged files itself). Exit 0 when every check passes; legacy findings are baselined under
tools/checks/baselines/ and only new ones fail. Each check is also a script of its own with
--update-baseline (see its --help).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import (  # noqa: E402
    agents_md,
    boundaries,
    common,
    complexity,
    dead_code,
    duplicates,
    feature_flags,
    format as gdformat_check,
    large_files,
    lint,
    rng_seed,
    test_map,
    todo_scan,
    unused_deps,
    web_headers,
    workflows,
)

SLOW = {"gdlint", "gdformat"}


def api_docs_check(root: Path) -> common.Result:
    from tools import gen_api_docs

    res = common.Result("api_docs")
    stale = gen_api_docs.stale(root)
    res.new = [f"docs/api is stale: {s} (run: python3 tools/gen_api_docs.py)" for s in stale]
    res.stats = {"pages": len(gen_api_docs.render(root))}
    return res


def registry(base: str | None):
    return [
        ("gdlint", lambda r: lint.run(r)),
        ("gdformat", lambda r: gdformat_check.run(r, base=base)),
        ("complexity", lambda r: complexity.run(r)),
        ("dead_code", lambda r: dead_code.run(r)),
        ("duplicates", lambda r: duplicates.run(r)),
        ("boundaries", lambda r: boundaries.run(r)),
        ("large_files", lambda r: large_files.run(r)),
        ("todo_scan", lambda r: todo_scan.run(r)),
        ("agents_md", lambda r: agents_md.run(r)),
        ("test_map", lambda r: test_map.run(r)),
        ("feature_flags", lambda r: feature_flags.run(r)),
        ("rng_seed", lambda r: rng_seed.run(r)),
        ("unused_deps", lambda r: unused_deps.run(r)),
        ("workflows", lambda r: workflows.run(r)),
        ("web_headers", lambda r: web_headers.run(r)),
        ("api_docs", api_docs_check),
    ]


def collect(root: Path, base: str | None = None, only=None, skip=None, fast=False, verbose=False):
    """[(Result, seconds)] for the selected checks; a crashing check becomes a failed result."""
    out = []
    for name, fn in registry(base):
        if only and name not in only:
            continue
        if (skip and name in skip) or (fast and name in SLOW and not only):
            continue
        t0 = time.monotonic()
        try:
            res = fn(root)
        except Exception as e:  # noqa: BLE001 - one broken check must not hide the others
            res = common.Result(name)
            res.new.append(f"check crashed: {e!r}")
            if verbose:
                traceback.print_exc()
        res.name = name
        out.append((res, round(time.monotonic() - t0, 2)))
    return out


def summary_markdown(results) -> str:
    rows = []
    for res, secs in results:
        status = "SKIP" if res.skipped else ("PASS" if res.ok else "FAIL")
        rows.append([res.name, status, len(res.new), len(res.known), len(res.warnings), secs])
    lines = ["## Repo checks", "", common.markdown_table(["Check", "Result", "New", "Baselined", "Warnings", "Secs"], rows), ""]
    for res, _ in results:
        if res.new:
            lines += [f"### {res.name}: new findings", ""] + [f"- {n}" for n in res.new[:50]] + [""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--base", help="diff base for changed-file checks (default: merge-base with origin/main)")
    ap.add_argument("--fast", action="store_true", help="skip gdlint and gdformat")
    ap.add_argument("--only", help="comma-separated check names")
    ap.add_argument("--skip", help="comma-separated check names")
    ap.add_argument("--json", help="write every result here (input for quality_report.py)")
    ap.add_argument("--summary", help="append a markdown summary (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--debt-report", help="write the tech debt markdown report here")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    root = Path(a.root)
    only = set(a.only.split(",")) if a.only else None
    skip = set(a.skip.split(",")) if a.skip else None
    results = collect(root, a.base, only, skip, a.fast, a.verbose)
    failed = 0
    for res, secs in results:
        failed += common.report(res, a.verbose)
    print()
    print(f"{'CHECK':<16} | {'RESULT':<6} | {'NEW':>4} | {'BASELINED':>9} | {'SECS':>6}")
    print("-" * 17 + "+" + "-" * 8 + "+" + "-" * 6 + "+" + "-" * 11 + "+" + "-" * 7)
    for res, secs in results:
        status = "SKIP" if res.skipped else ("PASS" if res.ok else "FAIL")
        print(f"{res.name:<16} | {status:<6} | {len(res.new):>4} | {len(res.known):>9} | {secs:>6}")
    if a.json:
        data = {"checks": {res.name: dict(res.to_dict(), secs=secs) for res, secs in results}}
        Path(a.json).parent.mkdir(parents=True, exist_ok=True)
        Path(a.json).write_text(json.dumps(data, indent=1, default=str) + "\n", encoding="utf-8")
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as fh:
            fh.write(summary_markdown(results) + "\n")
    if a.debt_report:
        todo = next((r for r, _ in results if r.name == "todo_scan"), None)
        items = getattr(todo, "items", None)
        if items is None:
            items = todo_scan.run(root).items  # type: ignore[attr-defined]
        Path(a.debt_report).write_text(todo_scan.markdown(items) + "\n", encoding="utf-8")
    print("CHECKS: " + ("PASS" if failed == 0 else f"FAIL ({failed} failed)"))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
