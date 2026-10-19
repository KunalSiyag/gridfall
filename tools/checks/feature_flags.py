"""Dead feature flags: every flag in data/feature_flags.json is read somewhere, and vice versa.

usage: python3 tools/checks/feature_flags.py [-v]

A flag is live when GDScript calls `FeatureFlags.enabled("<name>"` with it, or when it is the id
of a registered FpFeature (scripts/fp/fp_features.gd; FpMode skips a disabled feature by id).
Every literal `FeatureFlags.enabled("<name>"` must name a flag defined in the JSON. Skipped when
the JSON does not exist. Calls in tests (tools/tests/) are ignored both ways.
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
from tools.checks.test_map import features  # noqa: E402

NAME = "feature_flags"
FLAGS_JSON = "data/feature_flags.json"
TEST_PATHS = ("tools/tests/**", "tools/pytests/**")
CALL_RE = re.compile(r"FeatureFlags\s*\.\s*enabled\s*\(\s*[&]?([\"'])([^\"']+)\1")


def flag_names(data) -> list[str]:
    """Flag names from {"flags": {...}} or a flat {"name": ...} map (meta keys skipped)."""
    if isinstance(data, dict) and isinstance(data.get("flags"), dict):
        data = data["flags"]
    if not isinstance(data, dict):
        return []
    return sorted(k for k in data if not k.startswith(("_", "$")))


def run(root: Path) -> common.Result:
    res = common.Result(NAME)
    path = root / FLAGS_JSON
    if not path.is_file():
        res.skipped = f"no {FLAGS_JSON}"
        return res
    try:
        names = flag_names(json.loads(path.read_text(encoding="utf-8")))
    except ValueError as e:
        res.new.append(f"{FLAGS_JSON}: invalid JSON ({e})")
        return res
    used: dict[str, list[str]] = {}
    for f in common.list_files(root, ("*.gd",)):
        # Lexing would blank the flag literals; match calls on the raw text minus comments.
        lx = common.lex_gd(common.read_text(root, f))
        lines = lx.src_lines
        for ln, c in lx.comments:
            lines[ln - 1] = lines[ln - 1][: len(lines[ln - 1]) - len(c)]
        # Tests probe unknown names on purpose and do not make a flag live.
        if common.matches(f, list(TEST_PATHS)):
            continue
        for i, line in enumerate(lines, 1):
            for m in CALL_RE.finditer(line):
                where = used.setdefault(m.group(2), [])
                if f"{f}:{i}" not in where:
                    where.append(f"{f}:{i}")
    ids = {fid for fid, _ in features(root)}
    for n in names:
        if n not in used and n not in ids:
            res.new.append(f"flag {n} is defined in {FLAGS_JSON} but never read (remove it or use it)")
    for n, where in sorted(used.items()):
        if n not in names:
            res.new.append(f"FeatureFlags.enabled(\"{n}\") at {', '.join(where[:3])} has no entry in {FLAGS_JSON}")
        else:
            res.known.append(f"{n}: {', '.join(where[:3])}")
    res.stats = {"flags": len(names), "read_in_code": len(set(used) & set(names)), "feature_ids": len(set(names) & ids)}
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    return common.report(run(Path(a.root)), a.verbose)


if __name__ == "__main__":
    sys.exit(main())
