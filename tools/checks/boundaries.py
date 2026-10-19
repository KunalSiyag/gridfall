"""Module boundaries from docs/fp/ARCHITECTURE.md §5, configured in tools/checks/boundaries.json.

usage: python3 tools/checks/boundaries.py [--graph] [--update-baseline] [-v]

A GDScript file depends on another when it names its path in a string (preload, load,
`extends "res://..."`, resource paths) or uses its `class_name` in code. Two kinds of rules:

- layers: files matching `from` must not depend on files matching `forbid` (the simulation and AI
  core stay headless and know nothing of the views, the HUD or the on-foot mode);
- slices: a file in one slice directory under scripts/fp/ (owners table) must not depend on
  another slice's files, except the shared contracts listed under `shared` (S0's core files,
  world_scale, asset_paths, and the documented cross-slice APIs).

Edges listed under `allow` (with a reason) are accepted; legacy edges found when the rules were
introduced are in tools/checks/baselines/boundaries.json. Any other violating edge fails.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.checks import common  # noqa: E402

NAME = "boundaries"
CONFIG = "tools/checks/boundaries.json"
BASELINE = "boundaries.json"
RES_RE = re.compile(r"^res://([^\s\"']+)$")


def dependency_graph(root: Path) -> dict[str, set[str]]:
    """{file: {files it depends on}} for every tracked .gd file."""
    files = common.list_files(root, ("*.gd",), ("addons/**",))
    lexed = {f: common.lex_gd(common.read_text(root, f)) for f in files}
    class_of: dict[str, str] = {}
    for f, lx in lexed.items():
        m = common.CLASS_NAME_RE.search(lx.code)
        if m:
            class_of[m.group(1)] = f
    known = set(files)
    graph: dict[str, set[str]] = {}
    for f, lx in lexed.items():
        deps: set[str] = set()
        for _, s in lx.strings:
            m = RES_RE.match(s.strip())
            if m and m.group(1) in known:
                deps.add(m.group(1))
        for ident in set(common.identifiers(lx.code)):
            target = class_of.get(ident)
            if target:
                deps.add(target)
        deps.discard(f)
        graph[f] = deps
    return graph


def slice_of(path: str, cfg: dict) -> str | None:
    sl = cfg.get("slices", {})
    for pat, owner in sl.get("file_owners", {}).items():
        if common.matches(path, [pat]):
            return owner
    root = sl.get("root", "scripts/fp").rstrip("/") + "/"
    if not path.startswith(root):
        return None
    rest = path[len(root) :]
    if "/" not in rest:
        return None
    return sl.get("owners", {}).get(rest.split("/", 1)[0], rest.split("/", 1)[0])


def violations(graph: dict[str, set[str]], cfg: dict) -> dict[str, str]:
    """{"from -> to": rule description} for every edge that breaks a rule and is not allowed."""
    out: dict[str, str] = {}
    shared = cfg.get("slices", {}).get("shared", [])
    allow = cfg.get("allow", [])

    def allowed(a: str, b: str) -> bool:
        return any(common.matches(a, [r["from"]]) and common.matches(b, [r["to"]]) for r in allow)

    for a, deps in graph.items():
        for b in sorted(deps):
            for layer in cfg.get("layers", []):
                if common.matches(a, layer["from"]) and common.matches(b, layer["forbid"]):
                    if not allowed(a, b):
                        out[f"{a} -> {b}"] = f"layer {layer['name']}: {layer.get('why', '')}".strip()
            sa, sb = slice_of(a, cfg), slice_of(b, cfg)
            if sa and sb and sa != sb and not common.matches(b, shared) and not allowed(a, b):
                out.setdefault(f"{a} -> {b}", f"slice {sa} uses slice {sb}'s internals")
    return out


def run(root: Path, update: bool = False) -> common.Result:
    res = common.Result(NAME)
    cfg = common.load_json(root / CONFIG, None)
    if cfg is None:
        res.skipped = f"no {CONFIG}"
        return res
    graph = dependency_graph(root)
    bad = violations(graph, cfg)
    bpath = common.baseline_path(root, BASELINE)
    baseline = set(common.load_json(bpath, []))
    if update:
        baseline = set(bad)
        common.save_json(bpath, sorted(baseline))
    for edge, why in sorted(bad.items()):
        (res.known if edge in baseline else res.new).append(f"{edge} ({why})")
    stale = sorted(baseline - set(bad))
    if stale:
        res.warnings.append(f"{len(stale)} baselined edges are gone (prune with --update-baseline)")
    res.stats = {
        "files": len(graph),
        "edges": sum(len(d) for d in graph.values()),
        "violations": len(bad),
        "baselined": len(set(bad) & baseline),
    }
    res.graph = graph  # type: ignore[attr-defined]
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(common.REPO))
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--graph", action="store_true", help="print every dependency edge")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    res = run(Path(a.root), a.update_baseline)
    if a.graph and not res.skipped:
        for f, deps in sorted(res.graph.items()):  # type: ignore[attr-defined]
            for d in sorted(deps):
                print(f"{f} -> {d}")
    return common.report(res, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
