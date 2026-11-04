#!/usr/bin/env python3
"""Finds shipped textures, HDRIs and props that nothing loads.

usage: python3 tools/dead_assets.py [--root DIR] [--tree textures --tree models/real/props ...]

Every file in the scanned trees ships in the web pack (the export takes all resources), so a texture
nobody loads is pure download. A file counts as used when a script, shader, scene, resource, data
file or test names it, however the name is built:

  path    the res:// path appears whole
  name    its file name appears (TEX + "grass_albedo.jpg")
  format  a format string would build its name ("crack_%d" builds crack_0 and crack_1)
  parts   a quoted prefix and a quoted suffix that join to its name (name + "_albedo.jpg" with
          _pbr("sidewalk", ...) loads sidewalk_albedo.jpg)
  glb     a model embeds it: Godot extracts a GLB's images next to it as <model>_<image>.<ext>
  pool    a script lists the folder for models by name prefix (CityView._props("lamp") keeps every
          lamp*.glb, and the C_PROPS / I_PROPS / R_PROPS tables name those prefixes)

Anything else is reported dead. A directory a script lists in full (the vehicles, the people, the
baked mid-LOD twins) is outside the default trees; one it lists by prefix is read as a pool. Exit 1
when anything in the trees is dead.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
# Trees whose files are loaded by name (never by listing a directory).
TREES = ("textures", "models/real/props", "models/props", "env")
# Where a reference can live. tools/tests loads assets too (probes and test fixtures).
SOURCE_TREES = ("scripts", "shaders", "scenes", "data", "ui", "tools/tests")
SOURCE_FILES = ("project.godot", "export_presets.cfg")
SOURCE_EXT = {".gd", ".gdshader", ".tscn", ".tres", ".json", ".cfg", ".godot"}
ASSET_EXT = {".jpg", ".jpeg", ".png", ".webp", ".exr", ".hdr", ".glb", ".gltf", ".res", ".svg"}
# The recorded model answers run to megabytes and name nothing a scene loads.
MAX_SOURCE_BYTES = 8_000_000
TOKEN_RE = re.compile(r"[A-Za-z0-9_.\-/:]+")
LITERAL_RE = re.compile(r'"([^"\n]{1,200})"|\'([^\'\n]{1,200})\'')
FORMAT_RE = re.compile(r"%[0-9.]*[ds]")
# Prefix pools: a call that lists a folder by name prefix, and the tables of prefixes it is fed.
POOL_CALL_RE = re.compile(r'\b_props\s*\(\s*"([^"\n]+)"|\b_list_glbs\s*\([^\n]*?,\s*"([^"\n]+)"\s*\)')
POOL_TABLE_RE = re.compile(r"\bconst\s+[A-Z_]*PROPS\s*(?::\s*\w+\s*=|:?=)\s*\[([^\]]*)\]")
EXT_OF_MIME = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}


def _sources(root: Path) -> list[Path]:
    found: list[Path] = [root / name for name in SOURCE_FILES if (root / name).is_file()]
    for tree in SOURCE_TREES:
        base = root / tree
        if base.is_dir():
            found += [
                p
                for p in base.rglob("*")
                if p.is_file() and p.suffix in SOURCE_EXT and p.stat().st_size <= MAX_SOURCE_BYTES
            ]
    return found


def _glb_images(path: Path) -> list[tuple[str, str]]:
    """(name, extension) of each image a GLB embeds (the JSON chunk's images with no uri)."""
    data = path.read_bytes()
    if data[:4] != b"glTF" or len(data) < 20:
        return []
    size = struct.unpack("<I", data[12:16])[0]
    doc = json.loads(data[20 : 20 + size])
    return [
        (img["name"], EXT_OF_MIME.get(img.get("mimeType", ""), ".png"))
        for img in doc.get("images", [])
        if img.get("name") and not img.get("uri")
    ]


def _embedded(root: Path, trees: tuple[str, ...]) -> set[str]:
    """Project-relative paths of the files Godot extracts from the GLBs in the trees."""
    out: set[str] = set()
    for tree in trees:
        for glb in (root / tree).rglob("*.glb"):
            for name, ext in _glb_images(glb):
                out.add((glb.parent / f"{glb.stem}_{name}{ext}").relative_to(root).as_posix())
    return out


def _pools(text: str) -> set[str]:
    """Name prefixes the scripts list models by (an empty prefix would list the whole folder)."""
    found = {a or b for a, b in POOL_CALL_RE.findall(text)}
    for table in POOL_TABLE_RE.findall(text):
        found |= {a or b for a, b in LITERAL_RE.findall(table)}
    return {p for p in found if len(p) >= 3}


def _fixed_chars(literal: str) -> int:
    """Letters and digits a format string spells out itself (a bare "%s/%s" names nothing)."""
    return len(re.sub(r"[^A-Za-z0-9]", "", FORMAT_RE.sub("", literal)))


def _format_regex(literal: str) -> re.Pattern:
    """A regex for the names a format string builds: %d is digits, %s anything."""
    parts = FORMAT_RE.split(literal)
    marks = [m.group(0) for m in FORMAT_RE.finditer(literal)]
    out = re.escape(parts[0])
    for mark, part in zip(marks, parts[1:]):
        out += (r"\d+" if mark.endswith("d") else ".+") + re.escape(part)
    return re.compile("^" + out + "$")


def scan(root: Path = REPO, trees: tuple[str, ...] = TREES) -> dict:
    """{"used": {path: how}, "dead": [paths]} for the asset files under the trees."""
    root = Path(root)
    text = "\n".join(p.read_text(errors="ignore") for p in _sources(root))
    tokens = set(TOKEN_RE.findall(text))
    tokens |= {t.rsplit("/", 1)[-1] for t in list(tokens) if "/" in t}
    literals = {a or b for a, b in LITERAL_RE.findall(text)}
    formats = [_format_regex(lit) for lit in literals if FORMAT_RE.search(lit) and _fixed_chars(lit) >= 3]
    embedded = _embedded(root, trees)
    pools = _pools(text)
    used: dict[str, str] = {}
    dead: list[str] = []
    for tree in trees:
        for path in sorted((root / tree).rglob("*")):
            if not path.is_file() or path.suffix.lower() not in ASSET_EXT:
                continue
            rel = path.relative_to(root).as_posix()
            how = _how(rel, path, tokens, literals, formats, embedded, pools)
            if how:
                used[rel] = how
            else:
                dead.append(rel)
    return {"used": used, "dead": dead}


def _how(rel: str, path: Path, tokens: set, literals: set, formats: list, embedded: set, pools: set) -> str:
    if f"res://{rel}" in tokens:
        return "path"
    if path.name in tokens:
        return "name"
    if rel in embedded:
        return "glb"
    stem = path.stem
    if path.suffix.lower() in (".glb", ".gltf") and any(stem.startswith(p) for p in pools):
        return "pool"
    if any(f.match(stem) or f.match(path.name) or f.match(f"res://{rel}") for f in formats):
        return "format"
    cuts = [m.start() for m in re.finditer(r"[_\-]", stem)] + [len(stem)]
    for cut in cuts:
        prefix, suffix = stem[:cut], stem[cut:] + path.suffix
        if len(prefix) >= 3 and (prefix in literals or prefix + "_" in literals) and suffix in literals:
            return "parts"
    return ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(REPO))
    ap.add_argument("--tree", action="append", help="a tree to scan (default: %s)" % ", ".join(TREES))
    a = ap.parse_args(argv)
    result = scan(Path(a.root), tuple(a.tree) if a.tree else TREES)
    root = Path(a.root)
    total = 0
    for rel in result["dead"]:
        size = (root / rel).stat().st_size
        total += size
        print(f"dead  {size / 1e3:9.1f} KB  {rel}")
    print(f"{len(result['used'])} used, {len(result['dead'])} dead ({total / 1e6:.2f} MB)")
    return 1 if result["dead"] else 0


if __name__ == "__main__":
    sys.exit(main())
