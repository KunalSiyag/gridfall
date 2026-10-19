"""Flaky test report across gate runs (results.json files and flaky.txt next to them).

usage: python3 tools/checks/flaky_report.py <results.json or log dir>... [--summary FILE] [--json OUT]

A step is flaky when it reported PASS(flaky) (failed, then passed on a GATE_RETRIES re-run) or
when it both passed and failed across the given runs of the same commit. Prints a markdown
table (step, runs, passes, flaky passes, failures, flake rate) for the CI summary; exit 0.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402


def gather(paths: list[str]) -> list[dict]:
    runs = []
    for p in paths:
        path = Path(p)
        files = sorted(path.rglob("results.json")) if path.is_dir() else [path]
        for f in files:
            data = common.load_json(f, None)
            if isinstance(data, dict) and isinstance(data.get("steps"), list):
                data["_file"] = str(f)
                runs.append(data)
    return runs


def aggregate(runs: list[dict]) -> list[dict]:
    stats: dict[str, dict] = defaultdict(lambda: {"runs": 0, "pass": 0, "flaky": 0, "fail": 0, "commits": defaultdict(set)})
    for run in runs:
        for s in run["steps"]:
            st = stats[s["step"]]
            st["runs"] += 1
            res = str(s.get("result", ""))
            if res == "PASS(flaky)":
                st["flaky"] += 1
            elif res == "PASS":
                st["pass"] += 1
            else:
                st["fail"] += 1
            st["commits"][run.get("commit", "")].add("pass" if res.startswith("PASS") else "fail")
    out = []
    for name, st in sorted(stats.items()):
        mixed = sum(1 for v in st["commits"].values() if len(v) > 1)
        rate = (st["flaky"] + mixed) / st["runs"] if st["runs"] else 0.0
        out.append(
            {
                "step": name,
                "runs": st["runs"],
                "pass": st["pass"],
                "flaky": st["flaky"],
                "fail": st["fail"],
                "mixed_commits": mixed,
                "flake_rate": round(rate, 3),
            }
        )
    return out


def markdown(rows: list[dict], n_runs: int) -> str:
    flaky = [r for r in rows if r["flaky"] or r["mixed_commits"]]
    lines = ["## Flaky tests", "", f"{n_runs} gate runs, {len(flaky)} flaky steps.", ""]
    if flaky:
        table = [
            [r["step"], r["runs"], r["pass"], r["flaky"], r["fail"], f"{r['flake_rate'] * 100:.0f}%"]
            for r in sorted(flaky, key=lambda r: -r["flake_rate"])
        ]
        lines += [common.markdown_table(["Step", "Runs", "Pass", "Pass on retry", "Fail", "Flake rate"], table), ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--summary")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    runs = gather(a.paths)
    rows = aggregate(runs)
    md = markdown(rows, len(runs))
    print(md)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as fh:
            fh.write(md + "\n")
    if a.json:
        Path(a.json).write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
