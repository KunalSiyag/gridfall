"""Seeded randomness in the determinism-critical code (AGENTS.md: "no randomness without the sim
seed"). The sim and the AI layer must draw every random value from a RandomNumberGenerator seeded
off the city seed, never from Godot's process-global stream.

usage: python3 tools/checks/rng_seed.py [--update-baseline] [files...]

Flags, under scripts/sim/** and scripts/ai/**: a bare `randf()` / `randi()` / `randf_range()` /
`randi_range()` / `randfn()` / `randomize()` call, and any `.shuffle()` / `.pick_random()` (both
draw from the global stream). Calls on a generator (`rng.randf()`, `sim.rng.randi_range(...)`) are
fine, as is `RandomNumberGenerator.new()`. Comments and string literals are ignored.

A bare draw here means the same save can boot into a different city: that is exactly the class of
bug the sim_determinism_test guards at runtime. Known-safe exceptions live in
tools/checks/baselines/rng_seed.json, counted per (file, symbol).
"""
from __future__ import annotations

import re
import sys
from argparse import ArgumentParser
from collections import Counter
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "rng_seed"
BASELINE = "rng_seed.json"
## The determinism-critical tree: the pure sim and the AI layer that drives it.
SCOPE = ("scripts/sim", "scripts/ai")
PATTERNS = ("*.gd",)
EXCLUDE = ("tools/checks/baselines/**", "docs/api/**")
## Process-global helpers: a call not preceded by `.` or a name char is the global function.
GLOBALS = ("randf", "randi", "randf_range", "randi_range", "randfn", "randomize")
GLOBAL_RE = re.compile(r"(?<![A-Za-z0-9_.])(" + "|".join(GLOBALS) + r")\s*\(")
## Array methods that draw from the global stream (RandomNumberGenerator has neither).
METHODS = ("shuffle", "pick_random")
METHOD_RE = re.compile(r"\.(" + "|".join(METHODS) + r")\s*\(")


def scan(root: Path, files: list[str]) -> list[dict]:
    """One hit per flagged call: {path, line, symbol, snippet}."""
    items: list[dict] = []
    for f in files:
        lexed = common.lex_gd(common.read_text(root, f))
        for i, code in enumerate(lexed.code_lines, 1):
            src = lexed.src_lines[i - 1] if i - 1 < len(lexed.src_lines) else code
            for m in GLOBAL_RE.finditer(code):
                items.append(_hit(f, i, m.group(1), src))
            for m in METHOD_RE.finditer(code):
                items.append(_hit(f, i, m.group(1), src))
    return items


def _hit(path: str, line: int, symbol: str, src: str) -> dict:
    return {"path": path, "line": line, "symbol": symbol, "snippet": " ".join(src.split())[:120]}


def key_of(item: dict) -> str:
    return f"{item['path']}::{item['symbol']}"


def run(root: Path, files: list[str] | None = None, update: bool = False) -> common.Result:
    res = common.Result(NAME)
    all_files = [f for f in common.list_files(root, PATTERNS, EXCLUDE) if f.startswith(SCOPE)]
    targets = sorted(set(files) & set(all_files)) if files is not None else all_files
    if not all_files:
        res.skipped = "no scripts under scripts/sim or scripts/ai"
        return res
    items = scan(root, targets)
    bpath = common.baseline_path(root, BASELINE)
    baseline: dict = common.load_json(bpath, {})
    hits = Counter(key_of(i) for i in items)
    if update:
        if files is None:
            baseline = {}
        else:
            baseline = {k: v for k, v in baseline.items() if k.split("::")[0] not in set(targets)}
        baseline.update(hits)
        common.save_json(bpath, dict(sorted(baseline.items())))
    seen: Counter = Counter()
    for i in items:
        label = "%s:%d uses the global RNG (%s(...)): %s" % (i["path"], i["line"], i["symbol"], i["snippet"])
        k = key_of(i)
        seen[k] += 1
        if seen[k] > int(baseline.get(k, 0)):
            res.new.append(label + " - seed a RandomNumberGenerator from the city seed instead")
        else:
            res.known.append(label)
    res.stats = {
        "files": len(targets),
        "calls": len(items),
        "flagged": len(res.new),
        "by_symbol": dict(sorted(Counter(i["symbol"] for i in items).items())),
    }
    return res


def main(argv: list[str] | None = None) -> int:
    ap = ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    return common.report(run(Path(a.root), a.files or None, a.update_baseline), a.verbose)


if __name__ == "__main__":
    sys.exit(main())
