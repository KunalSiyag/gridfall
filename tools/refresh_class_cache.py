#!/usr/bin/env python3
"""Regenerate .godot/global_script_class_cache.cfg from the actual class_name declarations.

Godot only rewrites that cache during a full editor launch or `--import`. When a commit adds,
renames or deletes a `class_name` and the local cache predates it, headless runs fail to parse
dependent scripts ("Could not find type X in the current scope") or hang. Re-running a several-
minute import just for the cache is wasteful, so this tool rescans the project's GDScript files
and rewrites the cache directly. The file stays uncommitted (.godot/ is git-ignored).

usage: python tools/refresh_class_cache.py [--root PATH] [--quiet]
exit status: 0 on success (including "already in sync"), 1 on write/scan errors.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.checks.common import lex_gd  # noqa: E402

CACHE_REL = Path(".godot/global_script_class_cache.cfg")

CLASS_RE = re.compile(r"^(?:abstract\s+)?class_name\s+([A-Za-z_]\w*)")
EXTENDS_RE = re.compile(r'^extends\s+("[^"]+"|[A-Za-z_]\w*)')
TOOL_RE = re.compile(r"^@tool\b")

ENTRY = """{{
"base": &"{base}",
"class": &"{name}",
"icon": "",
"is_abstract": {abstract},
"is_tool": {tool},
"language": &"GDScript",
"path": "{path}"
}}"""


def iter_gd_scripts(root: Path) -> list[Path]:
    """Every .gd in the project except hidden dirs (notably .godot/); sorted for determinism."""
    out = []
    for p in root.rglob("*.gd"):
        if any(part.startswith(".") for part in p.relative_to(root).parts):
            continue
        out.append(p)
    return sorted(out)


def parse_global_class(src: str, resolve_base) -> dict | None:
    """Extract the global-class record from one script, or None when it declares none."""
    lexed = lex_gd(src)
    name = base = None
    abstract = False
    tool = False
    # lex_gd blanks string contents, so the extends keyword is matched on the lexed line but the
    # token itself (which may be a quoted path) is read from the raw line at the same position.
    for raw, code in zip(src.splitlines(), lexed.code_lines):
        s = code.strip()
        m = CLASS_RE.match(s)
        if m and name is None:
            name = m.group(1)
            abstract = s.startswith("abstract ")
            continue
        if s.startswith("@abstract"):
            abstract = True
            continue
        if TOOL_RE.match(s):
            tool = True
            continue
        if s.startswith("extends") and base is None:
            m = EXTENDS_RE.match(raw.strip())
            if m:
                base = m.group(1)
    if name is None:
        return None
    return {
        "name": name,
        "base": resolve_base(base) if base else "RefCounted",
        "abstract": abstract,
        "tool": tool,
    }


def build_entries(root: Path) -> list[dict]:
    """One cache entry per class_name found, sorted by class name as Godot writes them."""
    by_path: dict[str, dict] = {}

    def resolve_base(token: str | None, seen: frozenset = frozenset()) -> str:
        # Quoted `extends "res://..."`: Godot records the target script's class/base chain.
        if token and token.startswith('"'):
            target = token.strip('"')
            if target in seen:
                return "RefCounted"
            info = by_path.get(target)
            if info is None:
                t = root / target.removeprefix("res://")
                if t.is_file():
                    info = parse_global_class(
                        t.read_text(encoding="utf-8"),
                        lambda b: resolve_base(b, seen | {target}),
                    )
                    by_path[target] = info
            if info is None:
                return "RefCounted"
            return info["name"] if info else "RefCounted"
        return token or "RefCounted"

    entries = []
    for p in iter_gd_scripts(root):
        rel = "res://" + p.relative_to(root).as_posix()
        try:
            info = parse_global_class(p.read_text(encoding="utf-8"), resolve_base)
        except UnicodeDecodeError:
            continue
        by_path[rel] = info
        if info is None:
            continue
        entries.append({**info, "path": rel})
    entries.sort(key=lambda e: e["name"])
    return entries


def render(entries: list[dict]) -> str:
    if not entries:
        return "list=[]\n"
    body = ", ".join(
        ENTRY.format(
            base=e["base"],
            name=e["name"],
            abstract="true" if e["abstract"] else "false",
            tool="true" if e["tool"] else "false",
            path=e["path"],
        )
        for e in entries
    )
    return f"list=[{body}]\n"


def refresh(root: Path) -> tuple[list[str], list[str], bool, int]:
    """Rewrite the cache. Returns (added, removed, changed_any, total_classes)."""
    entries = build_entries(root)
    new_text = render(entries)
    cache = root / CACHE_REL
    old_text = cache.read_text(encoding="utf-8") if cache.is_file() else ""
    old_names = set(re.findall(r'"class": &"(\w+)"', old_text))
    new_names = {e["name"] for e in entries}
    if new_text != old_text:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(new_text, encoding="utf-8")
    return sorted(new_names - old_names), sorted(old_names - new_names), new_text != old_text, len(entries)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".", help="project root (default: cwd)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        added, removed, changed, total = refresh(root)
    except OSError as exc:
        print(f"refresh_class_cache: {exc}", file=sys.stderr)
        return 1
    if not args.quiet:
        if not changed:
            print(f"refresh_class_cache: in sync ({total} classes)")
        else:
            print(
                "refresh_class_cache: rewrote %s (%d classes; +%s -%s)"
                % (CACHE_REL, total, ",".join(added) or "none", ",".join(removed) or "none")
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
