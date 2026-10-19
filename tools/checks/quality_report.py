"""Code quality metrics in one place: quality-report.json plus a markdown summary.

usage: python3 tools/checks/quality_report.py [--from checks.json] [--coverage coverage.json]
                                              [--gate-results results.json] [--out quality-report.json]
                                              [--markdown FILE]

Aggregates lint findings, complexity, duplication, dead code, tech debt markers, module
boundary violations, test counts and coverage, and lines of code per area. --from reuses the
results of `run_all.py --json` (CI does this); without it the checks run here (gdlint included).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402


def area_of(path: str) -> str:
    parts = path.split("/")
    if parts[0] == "scripts":
        if len(parts) > 3 and parts[1] == "fp":
            return f"scripts/fp/{parts[2]}"
        if len(parts) > 2:
            return f"scripts/{parts[1]}"
        return "scripts"
    if parts[0] == "tools" and len(parts) > 2:
        return f"tools/{parts[1]}"
    return parts[0] if len(parts) > 1 else "(root)"


def loc(root: Path) -> dict[str, dict[str, int]]:
    """{area: {"gd": lines, "py": lines, "files": n}} counting non-blank lines."""
    out: dict[str, dict[str, int]] = {}
    for f in common.list_files(root, ("*.gd", "*.py")):
        a = out.setdefault(area_of(f), {"files": 0, "gd": 0, "py": 0})
        n = sum(1 for line in common.read_text(root, f).split("\n") if line.strip())
        a["files"] += 1
        a["gd" if f.endswith(".gd") else "py"] += n
    return dict(sorted(out.items()))


def test_counts(root: Path) -> dict:
    files = common.list_files(root)
    godot = [f for f in files if f.startswith("tools/tests/") and f.endswith("_test.gd")]
    pytests = [f for f in files if common.matches(f, ["tools/pytests/**"]) and f.endswith(".py")]
    pyfuncs = sum(len(re.findall(r"^\s*def test_", common.read_text(root, f), re.M)) for f in pytests)
    return {"godot_test_scripts": len(godot), "pytest_files": len(pytests), "pytest_functions": pyfuncs}


def build(root: Path, checks: dict, coverage: dict | None = None, gate: dict | None = None) -> dict:
    def stats(name: str) -> dict:
        return (checks.get(name) or {}).get("stats", {}) or {}

    report = {
        "checks": {
            n: {"ok": c.get("ok"), "new": len(c.get("new", [])), "baselined": c.get("known_count", 0), "skipped": c.get("skipped", "")}
            for n, c in sorted(checks.items())
        },
        "lint": {"findings": stats("gdlint").get("findings"), "by_rule": stats("gdlint").get("by_rule", {})},
        "complexity": {k: stats("complexity").get(k) for k in ("functions", "mean", "p95", "max", "over_threshold", "threshold", "grades")},
        "duplication": {k: stats("duplicates").get(k) for k in ("duplicated_lines", "duplication_pct", "clusters", "lines")},
        "dead_code": {k: stats("dead_code").get(k) for k in ("definitions", "dead", "dead_by_kind")},
        "tech_debt": {k: stats("todo_scan").get(k) for k in ("markers", "linked", "unlinked", "by_tag")},
        "boundaries": {k: stats("boundaries").get(k) for k in ("files", "edges", "violations", "baselined")},
        "tests": dict(test_counts(root), test_map_gaps=stats("test_map").get("gaps")),
        "loc": loc(root),
    }
    if coverage:
        totals = coverage.get("totals", {})
        report["tests"]["python_line_coverage_pct"] = round(float(totals.get("percent_covered", 0.0)), 1)
    if gate:
        steps = gate.get("steps", [])
        report["gate"] = {
            "mode": gate.get("mode"),
            "result": gate.get("result"),
            "steps": len(steps),
            "flaky": sum(1 for s in steps if s.get("result") == "PASS(flaky)"),
            "secs": sum(int(s.get("secs", 0)) for s in steps),
        }
    report["loc_total"] = {
        "gd": sum(a["gd"] for a in report["loc"].values()),
        "py": sum(a["py"] for a in report["loc"].values()),
    }
    return report


def markdown(r: dict) -> str:
    cx, dup, dead, debt = r["complexity"], r["duplication"], r["dead_code"], r["tech_debt"]
    rows = [
        ["gdlint findings (all baselined unless a check failed)", r["lint"].get("findings")],
        ["Functions / mean / p95 / max complexity", f"{cx.get('functions')} / {cx.get('mean')} / {cx.get('p95')} / {cx.get('max')}"],
        [f"Functions over complexity {cx.get('threshold')}", cx.get("over_threshold")],
        ["Duplicated lines", f"{dup.get('duplicated_lines')} ({dup.get('duplication_pct')}%) in {dup.get('clusters')} clusters"],
        ["Dead definitions", f"{dead.get('dead')} of {dead.get('definitions')}"],
        ["TODO/FIXME/HACK/XXX", f"{debt.get('markers')} ({debt.get('unlinked')} unlinked)"],
        ["Boundary violations (baselined)", f"{r['boundaries'].get('violations')} ({r['boundaries'].get('baselined')})"],
        ["Godot test scripts / pytest tests", f"{r['tests']['godot_test_scripts']} / {r['tests']['pytest_functions']}"],
        ["Untested slices or features", r["tests"].get("test_map_gaps")],
        ["Lines of GDScript / Python", f"{r['loc_total']['gd']} / {r['loc_total']['py']}"],
    ]
    if "python_line_coverage_pct" in r["tests"]:
        rows.append(["Python line coverage (tools/checks, tools/ops)", f"{r['tests']['python_line_coverage_pct']}%"])
    if "gate" in r:
        g = r["gate"]
        rows.append([f"Gate {g['mode']}", f"{g['result']} ({g['steps']} steps, {g['flaky']} flaky, {g['secs']} s)"])
    checks = [[n, "SKIP" if c["skipped"] else ("PASS" if c["ok"] else "FAIL"), c["new"], c["baselined"]] for n, c in r["checks"].items()]
    areas = [[a, v["files"], v["gd"], v["py"]] for a, v in r["loc"].items()]
    return "\n".join(
        [
            "## Code quality",
            "",
            common.markdown_table(["Metric", "Value"], rows),
            "",
            "<details><summary>Checks</summary>",
            "",
            common.markdown_table(["Check", "Result", "New", "Baselined"], checks),
            "",
            "</details>",
            "",
            "<details><summary>Lines of code per area</summary>",
            "",
            common.markdown_table(["Area", "Files", "GDScript", "Python"], areas),
            "",
            "</details>",
            "",
        ]
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--from", dest="from_json", help="run_all.py --json output")
    ap.add_argument("--coverage", help="pytest-cov JSON report (--cov-report=json)")
    ap.add_argument("--gate-results", help="tools/gate.sh results.json")
    ap.add_argument("--out", default="quality-report.json")
    ap.add_argument("--markdown", help="append the markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    a = ap.parse_args(argv)
    root = Path(a.root)
    if a.from_json:
        checks = common.load_json(Path(a.from_json), {}).get("checks", {})
    else:
        from tools.checks import run_all

        checks = {res.name: res.to_dict() for res, _ in run_all.collect(root)}
    cov = common.load_json(Path(a.coverage), None) if a.coverage else None
    gate = common.load_json(Path(a.gate_results), None) if a.gate_results else None
    report = build(root, checks, cov, gate)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    md = markdown(report)
    print(md)
    if a.markdown:
        with open(a.markdown, "a", encoding="utf-8") as fh:
            fh.write(md + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
