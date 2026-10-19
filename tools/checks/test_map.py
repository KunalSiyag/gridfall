"""Test map: every on-foot slice directory and every registered FpFeature has a Godot test.

usage: python3 tools/checks/test_map.py [--update-baseline] [-v]

A slice directory scripts/fp/<dir>/ is covered when some tools/tests/fp_*_test.gd names a file in
it (res:// path) or uses a class_name defined in it. A feature in scripts/fp/fp_features.gd is
covered when a test names its script path, its class_name or its id as a string ("chat"). Legacy
gaps are in tools/checks/baselines/test_map.json; a new untested slice or feature fails.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "test_map"
BASELINE = "test_map.json"
SLICE_ROOT = "scripts/fp"
REGISTRY = "scripts/fp/fp_features.gd"
TEST_GLOB = "tools/tests/fp_*_test.gd"
FEATURE_RE = re.compile(r'\{[^{}]*"id"\s*:\s*"([^"]+)"[^{}]*"path"\s*:\s*"res://([^"]+)"[^{}]*\}')


def features(root: Path) -> list[tuple[str, str]]:
    """(id, repo path) for every entry in the FpFeature registry."""
    return FEATURE_RE.findall(common.read_text(root, REGISTRY))


def run(root: Path, update: bool = False) -> common.Result:
    res = common.Result(NAME)
    files = common.list_files(root, ("*.gd",))
    tests = [f for f in files if common.matches(f, [TEST_GLOB])]
    test_code: dict[str, set[str]] = {}
    test_strings: dict[str, set[str]] = {}
    for t in tests:
        lx = common.lex_gd(common.read_text(root, t))
        test_code[t] = set(common.identifiers(lx.code))
        test_strings[t] = {s.strip() for _, s in lx.strings}
    class_of: dict[str, str] = {}
    for f in files:
        if f.startswith(SLICE_ROOT + "/"):
            m = common.CLASS_NAME_RE.search(common.lex_gd(common.read_text(root, f)).code)
            if m:
                class_of[f] = m.group(1)

    def testers(paths: list[str], ids: list[str], prefix: str = "") -> list[str]:
        names = {class_of[p] for p in paths if p in class_of}
        res_paths = {"res://" + p for p in paths}
        out = []
        for t in tests:
            strs = test_strings[t]
            if (
                names & test_code[t]
                or strs & res_paths
                or strs & set(ids)
                or (prefix and any(s.startswith(prefix) for s in strs))
            ):
                out.append(t)
        return out

    feats = features(root)
    gaps: dict[str, str] = {}
    covered: dict[str, list[str]] = {}
    dirs = sorted({f.split("/")[2] for f in files if f.startswith(SLICE_ROOT + "/") and f.count("/") >= 3})
    for d in dirs:
        prefix = f"{SLICE_ROOT}/{d}/"
        members = [f for f in files if f.startswith(prefix)]
        ids = [fid for fid, p in feats if p.startswith(prefix)]
        hit = testers(members, ids, "res://" + prefix)
        key = f"slice::{d}"
        if hit:
            covered[key] = hit
        else:
            gaps[key] = f"no {TEST_GLOB} references {SLICE_ROOT}/{d}/"
    for fid, path in feats:
        key = f"feature::{fid}"
        hit = testers([path], [fid])
        if hit:
            covered[key] = hit
        else:
            gaps[key] = f"feature {fid} ({path}) has no test that names it"
    bpath = common.baseline_path(root, BASELINE)
    baseline = set(common.load_json(bpath, []))
    if update:
        baseline = set(gaps)
        common.save_json(bpath, sorted(baseline))
    for key, why in sorted(gaps.items()):
        (res.known if key in baseline else res.new).append(f"{key}: {why}")
    stale = sorted(baseline - set(gaps))
    if stale:
        res.warnings.append(f"now covered, prune from the baseline: {', '.join(stale)}")
    res.stats = {
        "godot_tests": len(tests),
        "slices": len(dirs),
        "features": len(feats),
        "covered": len(covered),
        "gaps": len(gaps),
        "map": {k: [Path(t).name for t in v] for k, v in sorted(covered.items())},
    }
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.update_baseline)
    if a.verbose:
        for k, v in res.stats.get("map", {}).items():
            print(f"{k}: {', '.join(v)}")
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
