"""Gate step timings against a baseline: a markdown table for the CI summary, regressions flagged.

usage: python3 tools/checks/build_timing.py <results.json> [--baseline FILE] [--previous FILE]
                                            [--threshold 0.5] [--min-secs 5] [--fail-on-regression]
                                            [--update-baseline] [--summary FILE]

results.json is what tools/gate.sh writes to $GATE_LOG_DIR. The reference for each step is the
previous run's results (--previous, e.g. the last main artifact) when given, else the stored
baseline (tools/checks/baselines/build_timing.json, seconds per step and mode). A step is a
regression when it is more than --threshold (50%) and --min-secs slower. Report-only unless
--fail-on-regression.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "build_timing"
BASELINE = "build_timing.json"


def load_results(path: Path) -> dict:
    data = common.load_json(path, None)
    if not isinstance(data, dict) or not isinstance(data.get("steps"), list):
        raise ValueError(f"{path}: not a gate results.json")
    return data


def step_secs(results: dict) -> dict[str, float]:
    return {s["step"]: float(s.get("secs", 0)) for s in results.get("steps", [])}


def compare(current: dict, reference: dict[str, float], threshold: float = 0.5, min_secs: float = 5.0):
    """[(step, secs, ref or None, delta fraction or None, regression)] in run order."""
    rows = []
    for s in current.get("steps", []):
        name, secs = s["step"], float(s.get("secs", 0))
        ref = reference.get(name)
        delta = (secs - ref) / ref if ref else None
        regression = ref is not None and secs - ref > min_secs and (delta or 0) > threshold
        rows.append((name, secs, ref, delta, regression, s.get("result", "")))
    return rows


def markdown(mode: str, rows, ref_label: str) -> str:
    total = sum(r[1] for r in rows)
    ref_total = sum(r[2] for r in rows if r[2] is not None)
    table = []
    for name, secs, ref, delta, reg, result in rows:
        d = "new" if ref is None else f"{delta * 100:+.0f}%" if ref else "-"
        table.append([name, result, f"{secs:.0f}", "-" if ref is None else f"{ref:.0f}", d, "REGRESSION" if reg else ""])
    lines = [
        f"## Gate timing ({mode})",
        "",
        f"Total {total:.0f} s (reference {ref_total:.0f} s, from {ref_label}).",
        "",
        common.markdown_table(["Step", "Result", "Secs", "Ref", "Delta", ""], table),
        "",
    ]
    regs = [r[0] for r in rows if r[4]]
    if regs:
        lines += [f"Regressions over 50%: {', '.join(regs)}", ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("results")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--baseline")
    ap.add_argument("--previous", help="results.json of an earlier run to compare against")
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--min-secs", type=float, default=5.0)
    ap.add_argument("--fail-on-regression", action="store_true")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--summary", help="append the markdown table here")
    a = ap.parse_args(argv)
    root = Path(a.root)
    current = load_results(Path(a.results))
    mode = current.get("mode", "quick")
    bpath = Path(a.baseline) if a.baseline else common.baseline_path(root, BASELINE)
    baseline = common.load_json(bpath, {})
    if a.update_baseline:
        baseline[mode] = {k: v for k, v in step_secs(current).items() if k != "import"}
        common.save_json(bpath, baseline)
    ref, label = baseline.get(mode, {}), f"baseline {bpath.name}"
    if a.previous and Path(a.previous).is_file():
        try:
            ref, label = step_secs(load_results(Path(a.previous))), "the previous run"
        except ValueError:
            pass
    rows = compare(current, ref, a.threshold, a.min_secs)
    md = markdown(mode, rows, label)
    print(md)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as fh:
            fh.write(md + "\n")
    regressions = [r for r in rows if r[4]]
    return 1 if regressions and a.fail_on_regression else 0


if __name__ == "__main__":
    sys.exit(main())
