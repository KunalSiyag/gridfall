#!/usr/bin/env python3
"""Isolated, smaller web exports. Never rewrites the source project or desktop imports."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

try:  # imported as tools.web_export (tests) or run as a script, where tools/ itself is on sys.path
    from tools.optimize_imports import image_info
except ImportError:
    from optimize_imports import image_info

CAP_TREES = (
    "models/characters/bodies/",
    "assets/posters/",
    "models/real/props/",
    "models/real/street/",
    "models/real/vehicles/",
    "models/real/zones/",
    "models/real/buildings/",
    "textures/real/",
    "env/",
)
## Textures players read up close stay at their source resolution; everything else caps at 256 px.
CAP_LIMIT = 256
## The tiling ground materials are 2048 px and would alone fill the boot pack; 1024 still tiles
## cleanly and is a quarter of the bytes. The sky HDRIs are 2048x1024 and import lossless (~11 MB
## each in the sky pack); 1024 px wide keeps the horizon smooth (the sky shader never reads finer
## detail) and quarters them too.
CAP_LIMITS = {"textures/real/": 1024, "env/": 1024}
## The zone and building GLBs ship about 1,450 texture imports of 115 distinct images. Their normal
## maps (RGTC, half the bytes) and ARM maps (roughness and metallic, read at mip 0 only within a few
## metres of a wall) cap by kind; the diffuse maps stay at source resolution. The patterns are the
## ones tools/optimize_imports.py uses to find normal maps (a test keeps them equal). Each rule is
## (pattern, size_limit, smallest source side it applies to): the one 256 px ARM map, the glossy
## solar-cell grid, keeps its resolution (a 128 cap would save about 33 KB and soften its glints).
TYPED_TREES = ("models/real/zones/", "models/real/buildings/")
NORMAL_MAP_RE = re.compile(r"(_nor_gl|_nor_dx|_normal)\.[a-z]+$", re.IGNORECASE)
ARM_MAP_RE = re.compile(r"_arm\.[a-z]+$", re.IGNORECASE)
TYPED_LIMITS = ((NORMAL_MAP_RE, 256, 0), (ARM_MAP_RE, 128, 512))
## The roads stay at source resolution (the surface under the player's feet) and ship five normal
## and five ARM images that the zone and building GLBs also use (asphalt, pavement, two concrete
## walls, grass). The pack aliases identical payloads only, so capping those in the typed trees would
## add a second, smaller copy beside the road's full-size one: they stay at source resolution too
## (the street GLBs already ship a 256 px copy of some, so this only avoids a further split). If the
## roads ever join CAP_TREES, drop SHARED_TREES: the exempt copies would then stay full size beside
## capped road copies and split the dedupe the other way.
SHARED_TREES = ("models/real/roads/",)
UNCAPPED_TREES = ("assets/posters/",)
UNCAPPED_NAMES = ("poster", "billboard")
STAGE_TREES = (
    "assets", "data", "env", "fonts", "models", "scenes", "scripts", "shaders", "sounds", "textures", "ui",
)


def cap_limit(relative: str, side: int = 0) -> int:
    """The size_limit a texture import gets by tree and file name; 0 keeps the source resolution.

    side is the longest side in pixels of the image behind it (0 when unknown) and only the typed
    trees read it. stage_project screens out posters (is_uncapped) and the images shared with the
    roads before it applies the limit."""
    if relative.startswith(TYPED_TREES):
        name = relative.removesuffix(".import")
        for pattern, limit, smallest in TYPED_LIMITS:
            if pattern.search(name):
                return 0 if 0 < side < smallest else limit
        return 0
    for prefix, limit in CAP_LIMITS.items():
        if relative.startswith(prefix):
            return limit
    return CAP_LIMIT


def is_uncapped(relative: str) -> bool:
    """Posters, hoardings and billboard art are meant to be legible from the pavement."""
    return relative.startswith(UNCAPPED_TREES) or any(n in Path(relative).name.lower() for n in UNCAPPED_NAMES)


def cap_import(text: str, limit: int = CAP_LIMIT) -> str:
    """Keep the existing compression and mipmaps; cap only the imported dimensions."""
    return re.sub(r"^process/size_limit=.*$", f"process/size_limit={limit}", text, flags=re.M)


def _source_digest(import_path: Path):
    """sha1 of the image behind a texture .import, or None when the image is not there."""
    source = import_path.with_suffix("")
    return hashlib.sha1(source.read_bytes()).digest() if source.is_file() else None


def _shared_digests(stage: Path) -> set:
    """The images the SHARED_TREES texture imports ship, which the typed trees must not cap."""
    found = set()
    for prefix in SHARED_TREES:
        for path in (stage / prefix).rglob("*.import"):
            if 'importer="texture"' in path.read_text():
                found.add(_source_digest(path))
    found.discard(None)
    return found


# Godot's WAV importer: 0 Detect, 1 Disabled, 2 Forward, 3 Ping-Pong, 4 Backward. Only 2-4 loop.
LOOP_MODES = {2, 3, 4}


def wav_loops(import_text: str) -> bool:
    """True when the WAV's .import asks for a loop (loop_mode Forward, Ping-Pong or Backward)."""
    found = re.search(r"^edit/loop_mode=(\d+)$", import_text, re.M)
    return bool(found) and int(found.group(1)) in LOOP_MODES


def ogg_import(loop: bool) -> str:
    return (
        '[remap]\n\nimporter="oggvorbisstr"\ntype="AudioStreamOggVorbis"\n\n'
        "[params]\n\nloop=" + str(loop).lower() + "\nloop_offset=0\nbpm=0\nbeat_count=0\n"
    )


def stage_project(root: Path, stage: Path, ffmpeg: str = "ffmpeg") -> dict:
    for name in STAGE_TREES:
        if (root / name).exists():
            shutil.copytree(root / name, stage / name)
    for name in ("project.godot", "export_presets.cfg", "icon.png", "icon.png.import"):
        if (root / name).exists():
            shutil.copy2(root / name, stage / name)
    capped = 0
    kept_full = 0
    kept_typed = 0
    kept_shared = 0
    shared = _shared_digests(stage)
    for prefix in CAP_TREES:
        for path in (stage / prefix).rglob("*.import"):
            relative = path.relative_to(stage).as_posix()
            text = path.read_text()
            if 'importer="texture"' not in text:
                continue
            if is_uncapped(relative):
                kept_full += 1
                continue
            typed = relative.startswith(TYPED_TREES)
            limit = cap_limit(relative, max(image_info(str(path.with_suffix("")))[:2]) if typed else 0)
            if limit == 0:
                kept_typed += 1
                continue
            if typed and _source_digest(path) in shared:
                kept_shared += 1
                continue
            path.write_text(cap_import(text, limit))
            capped += 1
    audio_before = audio_after = 0
    converted = 0
    for wav in sorted((stage / "sounds").rglob("*.wav")):
        metadata = Path(str(wav) + ".import")
        text = metadata.read_text() if metadata.exists() else ""
        loop = wav_loops(text) or wav.parent.name == "music"
        ogg = wav.with_suffix(".ogg")
        subprocess.run(
            [ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(wav),
             "-c:a", "libvorbis", "-q:a", "4", str(ogg)],
            check=True,
        )
        Path(str(ogg) + ".import").write_text(ogg_import(loop))
        audio_before += wav.stat().st_size
        audio_after += ogg.stat().st_size
        converted += 1
        wav.unlink()
        metadata.unlink(missing_ok=True)
    # PWA assets are generated by Godot, with network-first HTML patched after export.
    preset = stage / "export_presets.cfg"
    text = preset.read_text()
    section = "[preset.2.options]"
    if section not in text:
        raise ValueError("export_presets.cfg no longer has a " + section + " section")
    text = text.replace(
        section, section + '\n\nprogressive_web_app/enabled=true\n'
        'progressive_web_app/ensure_cross_origin_isolation_headers=false\n',
    )
    preset.write_text(text)
    return {"capped_imports": capped, "kept_full_size": kept_full, "kept_typed_full_size": kept_typed,
            "kept_shared_with_roads": kept_shared, "converted_wav": converted,
            "wav_bytes": audio_before, "ogg_bytes": audio_after}


## Which pack a source path rides in. The longest matching prefix wins; anything unmatched rides
## in the boot pack, which the engine loads itself. `env/` (the HDRIs) and `assets/` (the posters)
## are the two big trees no first view needs; the district buildings stay in boot so a loaded city
## never renders with holes.
PACK_RULES = (
    ("sky", "env/"),
    ("audio", "sounds/music/"),
    ("audio", "sounds/fp/"),
    ("posters", "assets/"),
    ("props", "models/real/props/"),
    ("props", "models/props/"),
    ("traffic", "models/real/vehicles_v2/"),
    ("traffic", "models/real/vehicles/"),
    ("traffic", "models/vehicles/"),
    ("traffic", "models/cars/"),
    ("people", "models/characters/bodies/"),
    ("wildlife", "models/real/animals/"),
    # Baked twins for the mid-LOD city: every caller falls back to a loaded scene when they are
    # absent, so they can land after the first view without leaving holes.
    ("midlod", "models/real/midlod/"),
)
BOOT_PACK = "boot"
## The hero bodies and the animation libraries they play ride in boot: the player sees itself first.
BOOT_PATHS = (
    "models/characters/anim/",
    "models/characters/bodies/Male_Adult_06.glb",
    "models/characters/bodies/Female_Adult_04.glb",
    "models/characters/roster.json",
    "models/characters/bonemap_ual.tres",
    "models/characters/bonemap_rocketbox.tres",
)


def pack_of(src: str) -> str:
    """The pack for a project-relative source path (for example models/real/zones/r1/a.glb)."""
    if src.startswith(BOOT_PATHS):
        return BOOT_PACK
    best, pack = "", BOOT_PACK
    for name, prefix in PACK_RULES:
        if src.startswith(prefix) and len(prefix) > len(best):
            best, pack = prefix, name
    return pack


def _read_directory(source) -> tuple:
    header = bytearray(source.read(112))
    if header[:4] != b"GDPC" or struct.unpack_from("<I", header, 4)[0] != 4:
        raise ValueError("Expected Godot 4.7 PCK format 4")
    if struct.unpack_from("<I", header, 20)[0] != 2:
        raise ValueError("Only unencrypted, relative-offset PCKs are supported")
    base, directory = struct.unpack_from("<QQ", header, 24)
    source.seek(directory)
    count = struct.unpack("<I", source.read(4))[0]
    entries = []
    for _ in range(count):
        length = struct.unpack("<I", source.read(4))[0]
        # Names are NUL-padded to a 4-byte boundary; the padding must not reach path matching.
        name = source.read(length).rstrip(b"\0")
        offset, size = struct.unpack("<QQ", source.read(16))
        digest = source.read(16)
        if struct.unpack("<I", source.read(4))[0]:
            raise ValueError("Encrypted or removed PCK entries are unsupported")
        entries.append({"name": name, "offset": offset + base, "size": size, "md5": digest})
    return header, base, entries


def _read_at(source, offset: int, size: int) -> bytes:
    source.seek(offset)
    return source.read(size)


def _source_paths(source, entries: list) -> dict:
    """Map every entry to the source path it belongs to, so an asset's imports share its pack."""
    dest_to_src = {}
    for entry in entries:
        name = entry["name"]
        if name.endswith(b".import") or name.endswith(b".remap"):
            text = _read_at(source, entry["offset"], entry["size"]).decode("utf-8", "replace")
            cut = len(".import") if name.endswith(b".import") else len(".remap")
            src = name[:-cut].decode("utf-8", "replace")
            for match in re.finditer(r"res://\.godot/imported/[^\"\n\]]+", text):
                dest_to_src[match.group(0)[6:]] = src
    return dest_to_src


def _write_pack(target: Path, header: bytearray, base: int, items: list, read, extra: dict) -> dict:
    """Write one PCK, aliasing identical payloads inside it. items are (name, size, md5, offset)."""
    unique = {}
    written = []
    with target.open("wb") as output:
        output.write(header)
        for name, size, digest, offset in items:
            key = (digest, size)
            if key not in unique:
                if name in extra:
                    data = extra[name]
                elif read is not None:
                    data = read(offset, size)
                else:
                    raise ValueError("No payload supplied for " + name.decode("utf-8", "replace"))
                if len(data) != size or hashlib.md5(data).digest() != digest:
                    raise ValueError("Corrupt PCK entry: " + name.rstrip(b"\0").decode())
                output.write(bytes((-output.tell()) % 16))
                unique[key] = output.tell() - base
                output.write(data)
            written.append((name, unique[key], size, digest))
        output.write(bytes((-output.tell()) % 16))
        directory = output.tell()
        output.write(struct.pack("<I", len(written)))
        for name, offset, size, digest in written:
            encoded = name + b"\0"
            encoded += bytes((-len(encoded)) % 4)
            output.write(struct.pack("<I", len(encoded)) + encoded)
            output.write(struct.pack("<QQ", offset, size) + digest)
            output.write(struct.pack("<I", 0))
        output.seek(32)
        output.write(struct.pack("<Q", directory))
    return {"bytes": target.stat().st_size, "entries": len(written), "unique": len(unique)}


def deduplicate_pack(path: Path) -> dict:
    """Alias identical PCK payloads in one pack, preserving every resource name and import remap."""
    before = path.stat().st_size
    target = path.with_suffix(".dedup.tmp")
    with path.open("rb") as source:
        header, base, entries = _read_directory(source)
        report = _write_pack(
            target, header, base,
            [(e["name"], e["size"], e["md5"], e["offset"]) for e in entries],
            lambda offset, size: _read_at(source, offset, size),
            {},
        )
    target.replace(path)
    return {"pack_before": before, "pack_after": path.stat().st_size,
            "files": report["entries"], "unique_payloads": report["unique"]}


def split_packs(path: Path, out_dir: Path) -> dict:
    """Split one PCK into the boot pack plus background packs, and write the load manifest.

    The boot pack stays at `path` (the engine loads it as `<executable>.pck`); the others are
    content-addressed under `packs/`. A manifest entry inside the boot pack tells the runtime which
    pack holds an asset, because DirAccess cannot see a pack mounted after startup. Pack file names
    come from each pack's own entry list, so writing the manifest into the boot pack cannot feed
    back into a name.
    """
    packs_dir = out_dir / "packs"
    packs_dir.mkdir(parents=True, exist_ok=True)
    target = path.with_suffix(".split.tmp")
    with path.open("rb") as source:
        header, base, entries = _read_directory(source)
        dest_to_src = _source_paths(source, entries)
        groups: dict = {}
        for entry in entries:
            name = entry["name"]
            src = dest_to_src.get(name.decode("utf-8", "replace"), name.decode("utf-8", "replace"))
            groups.setdefault(pack_of(src), []).append(entry)
        manifest = {"boot": BOOT_PACK,
                    "rules": [[prefix, name] for name, prefix in
                              sorted(PACK_RULES, key=lambda rule: -len(rule[1]))],
                    "packs": {}}
        reports = {}
        for name in sorted(groups):
            if name == BOOT_PACK:
                continue
            items = [(e["name"], e["size"], e["md5"], e["offset"]) for e in groups[name]]
            digest = hashlib.sha256()
            for entry_name, size, md5, _ in sorted(items):
                digest.update(entry_name + str(size).encode() + md5)
            file_name = "%s-%s.pck" % (name, digest.hexdigest()[:16])
            report = _write_pack(
                packs_dir / file_name, header, base, items,
                lambda offset, size: _read_at(source, offset, size), {},
            )
            manifest["packs"][name] = {
                "file": "packs/" + file_name, "bytes": report["bytes"],
                "sha256": hashlib.sha256((packs_dir / file_name).read_bytes()).hexdigest(),
            }
            reports[name] = report
        # The manifest rides in the boot pack so the runtime never probes the filesystem for it.
        blob = json.dumps(manifest, sort_keys=True).encode()
        items = [(e["name"], e["size"], e["md5"], e["offset"]) for e in groups.get(BOOT_PACK, [])]
        items.append((b"web_manifest.json", len(blob), hashlib.md5(blob).digest(), -1))
        reports[BOOT_PACK] = _write_pack(
            target, header, base, items,
            lambda offset, size: _read_at(source, offset, size),
            {b"web_manifest.json": blob},
        )
    target.replace(path)
    return {"packs": reports, "manifest": manifest}


LOADER_CSS = """#status-progress { display: none !important; }
#gf-bar { position: absolute; left: 0; right: 0; bottom: 9%; width: min(440px, 62%); margin: 0 auto; }
/* What the game is and how to play it: static text, so it is on screen from the first paint and
   through the boot stall. Wider than the bar (negative side margins up to 640px or 92vw). */
#gf-explain { margin: 0 calc(50% - min(320px, 46vw)) 18px; text-align: center; }
#gf-pitch { margin: 0; font: 600 18px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
	color: #f4f6fa; letter-spacing: 0.01em; text-wrap: balance; }
#gf-keys { margin: 8px 0 0; font: 400 13px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
	color: #aeb6c4; text-wrap: balance; }
#gf-track { height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.16); overflow: hidden; }
#gf-fill { height: 100%; width: 0%; background: #d6ff3f; transition: width 0.25s ease; }
#gf-row { display: flex; align-items: center; justify-content: center; gap: 10px; margin-top: 10px; }
#gf-label { text-align: center; font: 500 13px/1.4 system-ui, -apple-system,
	"Segoe UI", Roboto, sans-serif; color: #e8ecf3; letter-spacing: 0.02em; }
/* The spinner animates transform only (and the reduced-motion pulse opacity only), so a compositor
   can keep it turning while the engine's boot holds the main thread. */
#gf-spin { display: none; box-sizing: border-box; width: 14px; height: 14px; border-radius: 50%;
	border: 2px solid rgba(255, 255, 255, 0.2); border-top-color: #d6ff3f; will-change: transform;
	animation: gf-spin 0.9s linear infinite; }
#gf-bar.gf-starting #gf-spin { display: block; }
#gf-hint { display: none; margin-top: 6px; text-align: center; color: #aeb6c4;
	font: 400 12px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
#gf-bar.gf-stalled #gf-spin { display: none; }
#gf-bar.gf-stalled #gf-hint { display: block; }
@keyframes gf-spin { to { transform: rotate(360deg); } }
@keyframes gf-pulse { 50% { opacity: 0.3; } }
@media (prefers-reduced-motion: reduce) { #gf-spin { animation: gf-pulse 1.8s ease-in-out infinite; } }
/* Forced colors (high contrast) make every border one colour, which hides the turning arc. */
@media (forced-colors: active) { #gf-spin { border-color: GrayText; border-top-color: Highlight; } }
"""

## What the game is and how to play it, in the loader before the engine starts (plain text, so it
## survives the boot stall). tools/pytests/test_web_export.py reads these two lines;
## tools/web_loader_check.js, the browser check of the loader, does not.
LOADER_PITCH = "Five AI mayors, five different models on GMI Cloud, one city you can walk in"
LOADER_KEYS = "WASD walk - Tab planner - J AI feed - Esc menu - click to capture the mouse"

LOADER_BAR = (
    '<div id="gf-bar"><div id="gf-explain"><p id="gf-pitch">' + LOADER_PITCH + '</p>'
    '<p id="gf-keys">' + LOADER_KEYS + '</p></div>\n'
    '\t\t\t\t<div id="gf-track"><div id="gf-fill"></div></div>\n'
    '\t\t\t\t<div id="gf-row"><span id="gf-spin"></span>'
    '<span id="gf-label">Loading GridFall\u2026</span></div>\n'
    '\t\t\t\t<div id="gf-hint">Taking longer than expected. '
    'If nothing changes soon, reload the page.</div></div>'
)

## The engine boots the whole game inside startGame(): Godot's web main() runs the first main-loop
## iteration inside callMain, so Main._ready and the first frame's draw are one long task, and
## startGame() resolves right after it. The stock shell removed the overlay then, so it sat frozen
## through the whole stall. Here the overlay outlives startGame() and the game lifts it with
## window.gfBootDone() (BootClock.finish: three more frames). The timeout starts when startGame()
## resolves, so neither that task nor a slow download can trip it, and only has to cover those
## three frames (BootClock's table shows what they cost on a device). 30 s is a safety net for a
## game that never calls the hook (a boot that stops before BootClock.finish()): the player waits
## on the veil at most that long.
## The ordering (resolve after the boot task) is a fact about Godot's C++ web main(), which no CI job
## can see, so deploy/web/smoke.js checks it on every full run (gf:start_game_resolved must not come
## before gf:first_frame). If a Godot update ever moved the boot task after the resolve, a timer that
## comes due inside a long task can only fire once the task ends, so the veil would be lifted right
## after the stall, before the three frames (what the stock shell did), never during it.
## Before the engine starts, godot.js never rejects a wasm that fails to download or compile, so
## startGame() just never settles; START_STALL_MS without a progress tick (or a first byte) shows a
## hint instead of an endless bar or spinner (60 s: the wasm is compiled as it streams in, so this
## is long past the end of a normal compile). The hint claims no work in progress, because the page
## cannot tell a slow boot from a dead one. Progress or the engine starting takes the hint back.
LOADER_HELPER = """
\tconst progressFill = document.getElementById('gf-fill');
\tconst progressLabel = document.getElementById('gf-label');
\tconst progressBar = document.getElementById('gf-bar');
\tconst BOOT_VEIL_TIMEOUT_MS = 30000;
\tconst START_STALL_MS = 60000;
\tlet veilStarting = false;
\tlet veilReleased = false;
\tlet veilTimer = 0;
\tlet stallTimer = 0;
\tlet stallOver = false;

\tfunction timelineMark(name) {
\t\ttry {
\t\t\tperformance.mark('gf:' + name);
\t\t} catch (err) {
\t\t\t// User Timing is optional.
\t\t}
\t}

\t// Rounded, but 100 only once the last byte is in (99.6% of the bytes is not "Starting").
\tfunction setProgress(ratio) {
\t\tconst pct = ratio >= 1 ? 100 : Math.max(0, Math.min(99, Math.round(ratio * 100)));
\t\tif (progressFill) {
\t\t\tprogressFill.style.width = pct + '%';
\t\t}
\t\tif (progressLabel && !veilStarting) {
\t\t\tprogressLabel.textContent = 'Loading GridFall ' + pct + '%';
\t\t}
\t\twatchStall();
\t\tif (ratio >= 1) {
\t\t\tshowStarting();
\t\t}
\t}

\t// No progress tick (and nothing since the page loaded) for START_STALL_MS before the engine starts:
\t// show the hint, stop the spinner.
\tfunction watchStall() {
\t\tif (stallOver) {
\t\t\treturn;
\t\t}
\t\tclearTimeout(stallTimer);
\t\tstallTimer = setTimeout(() => setStalled(true), START_STALL_MS);
\t\tsetStalled(false);
\t}

\t// The engine started: from here the boot is the game's, and a last progress tick (rAF can run it
\t// after this) must not arm the watch again, or it would fire over the end of a very long boot.
\tfunction stopStall() {
\t\tstallOver = true;
\t\tclearTimeout(stallTimer);
\t\tsetStalled(false);
\t}

\tfunction setStalled(on) {
\t\ttry {
\t\t\tprogressBar.classList.toggle('gf-stalled', on);
\t\t} catch (err) {
\t\t\tconsole.error(err);
\t\t}
\t}

\t// The bytes are in: say what happens next and start the spinner.
\tfunction showStarting() {
\t\tif (veilStarting) {
\t\t\treturn;
\t\t}
\t\tveilStarting = true;
\t\ttry {
\t\t\ttimelineMark('bytes_done');
\t\t\t// Snap to full: a width transition needs the main thread, which the boot is about to take.
\t\t\tprogressFill.style.transition = 'none';
\t\t\tprogressFill.style.width = '100%';
\t\t\tprogressLabel.textContent = 'Starting your city';
\t\t\tprogressBar.classList.add('gf-starting');
\t\t} catch (err) {
\t\t\tconsole.error(err);
\t\t}
\t}

\t// Two frame callbacks (about 33 ms at 60 Hz) before the engine starts: the second runs after the
\t// first frame, with the starting state and the spinner, was committed, and from then on the
\t// compositor keeps the spinner turning while the boot holds the main thread. A hidden tab makes no
\t// frames, so a 250 ms timer lets the boot go ahead.
\tfunction afterFrames() {
\t\treturn new Promise((resolve) => {
\t\t\tconst fallback = setTimeout(resolve, 250);
\t\t\trequestAnimationFrame(() => requestAnimationFrame(() => {
\t\t\t\tclearTimeout(fallback);
\t\t\t\tresolve();
\t\t\t}));
\t\t});
\t}

\t// Idempotent: the first release wins, so gf:veil_released is when the overlay really went (smoke.js
\t// compares it with the game's gf:veil_frames) and a late hook call after the timeout changes nothing.
\tfunction releaseVeil() {
\t\tif (veilReleased) {
\t\t\treturn;
\t\t}
\t\tveilReleased = true;
\t\tclearTimeout(veilTimer);
\t\ttry {
\t\t\tsetStatusMode('hidden');
\t\t} catch (err) {
\t\t\t// The timer is spent, so nothing else would lift it: hide the overlay directly.
\t\t\tconsole.error(err);
\t\t\tstatusOverlay.style.display = 'none';
\t\t}
\t\ttimelineMark('veil_released');
\t}

\t// startGame() resolved: the timeout is armed before anything that could throw.
\tfunction engineStarted() {
\t\tif (!veilReleased) {
\t\t\tveilTimer = setTimeout(releaseVeil, BOOT_VEIL_TIMEOUT_MS);
\t\t}
\t\tshowStarting();
\t\ttimelineMark('start_game_resolved');
\t}

\twindow.gfBootDone = releaseVeil;
\tif (typeof engine !== 'undefined' && engine && typeof engine.start === 'function') {
\t\tconst engineStart = engine.start;
\t\tengine.start = function (...args) {
\t\t\tshowStarting();
\t\t\tstopStall();
\t\t\treturn afterFrames().then(() => engineStart.apply(this, args));
\t\t};
\t}
\t// Nothing may arrive at all (a download that hangs before its first byte never ticks, and fetch has
\t// no timeout), so the watch starts with the page, not with the first progress tick.
\twatchStall();
"""


def patch_loader_html(html: str) -> str:
    """Give the boot page a branded progress bar instead of Godot's bare <progress> element, and
    keep its overlay up until the game is interactive (window.gfBootDone, or a timeout)."""
    replacements = (
        ("</style>", LOADER_CSS + "\t\t</style>"),
        ("<progress id=\"status-progress\"></progress>",
         "<progress id=\"status-progress\"></progress>\n\t\t\t\t" + LOADER_BAR),
        ("\tconst statusNotice = document.getElementById('status-notice');",
         "\tconst statusNotice = document.getElementById('status-notice');\n" + LOADER_HELPER),
        ("\t\tstatusNotice.style.display = mode === 'notice' ? 'block' : 'none';",
         "\t\tstatusNotice.style.display = mode === 'notice' ? 'block' : 'none';\n"
         "\t\tif (progressBar) {\n"
         "\t\t\tprogressBar.style.display = mode === 'progress' ? 'block' : 'none';\n"
         "\t\t}"),
        ("\t\t\t\t\tstatusProgress.max = total;",
         "\t\t\t\t\tstatusProgress.max = total;\n\t\t\t\t\tsetProgress(current / total);"),
        ("\t\t}).then(() => {\n\t\t\tsetStatusMode('hidden');\n\t\t}, displayFailureNotice);",
         "\t\t}).then(() => {\n\t\t\tengineStarted();\n\t\t}, displayFailureNotice);"),
    )
    for anchor, replacement in replacements:
        if anchor not in html:
            raise ValueError("Godot's HTML shell changed; cannot patch the loading screen: " + anchor[:60])
        html = html.replace(anchor, replacement, 1)
    return html


def rewrite_manifest(pack: Path, prefix: str) -> dict:
    """Point the manifest's pack paths at the published release directory.

    The split runs before the release hash exists, so the manifest is written with pack paths
    relative to the release root; once the version is known this rewrites them (and only them) so
    the runtime can fetch a pack relative to the loader page. Nothing else in the boot pack moves.
    """
    with pack.open("rb") as source:
        header, base, entries = _read_directory(source)
        payloads = {e["name"]: _read_at(source, e["offset"], e["size"]) for e in entries}
    manifest = json.loads(payloads[b"web_manifest.json"])
    for entry in manifest["packs"].values():
        file = str(entry["file"])
        if not file.startswith(prefix):
            entry["file"] = prefix + file
    blob = json.dumps(manifest, sort_keys=True).encode()
    items = [(e["name"], e["size"], e["md5"], e["offset"]) for e in entries
             if e["name"] != b"web_manifest.json"]
    items.append((b"web_manifest.json", len(blob), hashlib.md5(blob).digest(), -1))
    payloads[b"web_manifest.json"] = blob
    target = pack.with_suffix(".manifest.tmp")
    report = _write_pack(target, header, base, items, None, payloads)
    target.replace(pack)
    return report


def prune_releases(output: Path, keep: str) -> None:
    """Keep the release being published plus the most recent other one, so a boot in flight resolves."""
    root = output / "releases"
    older = sorted((p for p in root.iterdir() if p.is_dir() and p.name != keep), key=lambda p: p.stat().st_mtime)
    for path in older[:-1]:
        shutil.rmtree(path)


def version_site(raw: Path, output: Path, report: dict) -> str:
    """Content-address engine assets without hand-editing Godot's internal file names."""
    digest = hashlib.sha256()
    for path in sorted(raw.iterdir()):
        if path.is_file():
            digest.update(path.name.encode())
            digest.update(path.read_bytes())
    packs = raw / "packs"
    if packs.is_dir():
        for path in sorted(packs.iterdir()):
            digest.update(b"packs/" + path.name.encode())
            digest.update(path.read_bytes())
    version = digest.hexdigest()[:16]
    prefix = "releases/" + version + "/"
    release = output / prefix
    release.mkdir(parents=True, exist_ok=True)
    prune_releases(output, version)
    # The split ran before the release hash existed; point the manifest's pack paths at it now.
    if (raw / "packs").is_dir() and (raw / "index.pck").exists():
        rewrite_manifest(raw / "index.pck", prefix)
    if packs.is_dir():
        shutil.copytree(packs, release / "packs", dirs_exist_ok=True)
    names = sorted((p.name for p in raw.iterdir() if p.is_file()))
    # These stay at the root so a reload always revalidates the loader and the PWA scope is /.
    loader = {"index.html", "index.service.worker.js", "index.manifest.json"}
    for name in names:
        if name not in loader:
            shutil.copy2(raw / name, release / name)
    # The page and the worker stay at the root; only immutable payloads move into the release.
    html = patch_loader_html((raw / "index.html").read_text())
    for name in names:
        html = re.sub(
            r'("' + re.escape(name) + r'"\s*:\s*)\d+',
            lambda match: match[1] + str((raw / name).stat().st_size),
            html,
        )
    for name in sorted(names, key=len, reverse=True):
        if name not in loader:
            html = html.replace('"' + name + '"', '"' + prefix + name + '"')
    # Engine constructs wasm/pck/worklet paths from this basename.
    html = html.replace('"executable":"index"', '"executable":"' + prefix + 'index"')
    html = html.replace('"executable": "index"', '"executable": "' + prefix + 'index"')
    (output / "index.html").write_text(html)
    # One PWA entry point at the root scope, pointing at this release's icons.
    manifest = json.loads((raw / "index.manifest.json").read_text())
    manifest["start_url"] = "./index.html"
    for icon in manifest.get("icons", []):
        icon["src"] = prefix + icon["src"]
    (output / "index.manifest.json").write_text(json.dumps(manifest) + "\n")
    worker = (raw / "index.service.worker.js").read_text()
    worker = re.sub(r"const CACHE_VERSION = .*?;", "const CACHE_VERSION = '" + version + "';", worker)
    # Keep the navigated HTML at the root, and cache all immutable payloads at their release URL.
    for name in sorted(names, key=len, reverse=True):
        if name not in loader:
            worker = worker.replace("'" + name + "'", "'" + prefix + name + "'")
            worker = worker.replace('"' + name + '"', '"' + prefix + name + '"')
    needle = "const cache = await caches.open(CACHE_NAME);"
    if needle not in worker:
        raise ValueError("Godot service worker template changed")
    worker = worker.replace(
        needle, needle + """
                // Always check the current release online; retain the last complete page offline.
                if (isNavigate) {
                    try { return await fetchAndCache(event, cache, true); }
                    catch (_) {
                        const previous = await cache.match(event.request);
                        if (previous) return previous;
                    }
                }
""", 1,
    )
    (output / "index.service.worker.js").write_text(worker)
    report["version"] = version
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return version


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--mode", choices=["--export-release", "--export-debug"], default="--export-release")
    parser.add_argument("--split", action="store_true",
                        help="also split the pack into boot plus background packs (needs the runtime loader)")
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        parser.error("ffmpeg with libvorbis is required for web audio")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Only the loader trio and the report live at the root; everything else is content-addressed.
    for stale in output.iterdir():
        if stale.is_file():
            stale.unlink()
    with tempfile.TemporaryDirectory(prefix="gridfall-web-export-") as tmp:
        stage = Path(tmp) / "project"
        stage.mkdir()
        report = stage_project(args.root.resolve(), stage)
        subprocess.run([args.godot, "--headless", "--path", str(stage), "--import"], check=True)
        raw = Path(tmp) / "raw"
        raw.mkdir()
        subprocess.run(
            [args.godot, "--headless", "--path", str(stage), args.mode, "Web", str(raw / "index.html")],
            check=True,
        )
        report.update(deduplicate_pack(raw / "index.pck"))
        if args.split:
            report["split"] = split_packs(raw / "index.pck", raw)["packs"]
        version_site(raw, output, report)
        print("WEB_EXPORT: " + json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
