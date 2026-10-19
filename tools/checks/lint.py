"""gdlint with a baseline: fails only on findings beyond the recorded legacy counts.

usage: python3 tools/checks/lint.py [--update-baseline] [--json OUT] [files...]

With no files it lints every tracked .gd file. Findings are counted per (file, rule, message
without line numbers), so moving code does not churn the baseline; adding a finding of a kind a
file already has, beyond its baselined count, fails. Rules and naming patterns live in gdlintrc.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "gdlint"
BASELINE = "gdlint.json"
LINE_RE = re.compile(r"^(?P<path>.+?):(?P<line>\d+): Error: (?P<msg>.*?) \((?P<rule>[a-z-]+)\)$")
EXCLUDE = ("addons/**",)


def gdlint_cmd() -> list[str]:
    """gdlint next to this interpreter (venv), else on PATH, else `python -m gdtoolkit.linter`."""
    local = Path(sys.executable).parent / "gdlint"
    if local.exists():
        return [str(local)]
    found = shutil.which("gdlint")
    if found:
        return [found]
    return [sys.executable, "-m", "gdtoolkit.linter"]


def parse_output(text: str) -> list[dict]:
    findings = []
    for line in text.splitlines():
        m = LINE_RE.match(line.strip())
        if m:
            findings.append(
                {"path": m["path"], "line": int(m["line"]), "rule": m["rule"], "msg": m["msg"]}
            )
    return findings


def run_gdlint(root: Path, files: list[str], jobs: int = 0) -> list[dict]:
    """Runs gdlint over files in parallel chunks (it lints one file at a time)."""
    if not files:
        return []
    jobs = jobs or max(1, min(8, os.cpu_count() or 1))
    chunks = [files[i::jobs] for i in range(jobs)]
    cmd = gdlint_cmd()

    def one(chunk: list[str]) -> str:
        if not chunk:
            return ""
        p = subprocess.run(cmd + chunk, cwd=root, capture_output=True, text=True)
        if p.returncode not in (0, 1):
            raise RuntimeError(f"gdlint failed ({p.returncode}): {p.stderr.strip()[:500]}")
        return p.stdout + "\n" + p.stderr

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        texts = list(ex.map(one, chunks))
    found = parse_output("\n".join(texts))
    found.sort(key=lambda f: (f["path"], f["line"], f["rule"]))
    return found


def key_of(f: dict) -> str:
    return f"{f['rule']}: {f['msg']}"


def run(root: Path, files: list[str] | None = None, update: bool = False, findings=None) -> common.Result:
    res = common.Result(NAME)
    all_files = common.list_files(root, ("*.gd",), EXCLUDE)
    targets = sorted(set(files) & set(all_files)) if files is not None else all_files
    if findings is None:
        findings = run_gdlint(root, targets)
    counts: dict[str, Counter] = {}
    for f in findings:
        counts.setdefault(f["path"], Counter())[key_of(f)] += 1
    bpath = common.baseline_path(root, BASELINE)
    baseline = common.load_json(bpath, {})
    if update:
        if files is None:
            baseline = {}
        else:
            for p in targets:
                baseline.pop(p, None)
        for p, c in counts.items():
            baseline[p] = dict(sorted(c.items()))
        common.save_json(bpath, dict(sorted(baseline.items())))
    for path in sorted(counts):
        allowed = baseline.get(path, {})
        for k, n in sorted(counts[path].items()):
            extra = n - int(allowed.get(k, 0))
            if extra > 0:
                lines = [str(f["line"]) for f in findings if f["path"] == path and key_of(f) == k]
                res.new.append(f"{path}: {k} x{extra} over baseline (lines {', '.join(lines[:20])})")
            res.known += [f"{path}: {k}"] * min(n, int(allowed.get(k, 0)))
    by_rule = Counter(f["rule"] for f in findings)
    res.stats = {
        "files": len(targets),
        "findings": len(findings),
        "by_rule": dict(sorted(by_rule.items())),
    }
    res.findings = findings  # type: ignore[attr-defined]
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--json", help="write the raw findings here")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    root = Path(a.root)
    res = run(root, a.files or None, a.update_baseline)
    if a.json:
        Path(a.json).write_text(json.dumps(res.findings, indent=1) + "\n")  # type: ignore[attr-defined]
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
