"""Web staging and PCK aliasing never alter desktop source assets."""
import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path

import pytest

from tools.optimize_imports import NORMAL_RE, image_info
from tools.web_export import (
    ARM_MAP_RE,
    CAP_TREES,
    NORMAL_MAP_RE,
    TYPED_TREES,
    cap_import,
    cap_limit,
    deduplicate_pack,
    is_uncapped,
    ogg_import,
    wav_loops,
    pack_of,
    patch_loader_html,
    prune_releases,
    rewrite_manifest,
    split_packs,
    stage_project,
    version_site,
)


ROOT = Path(__file__).resolve().parents[2]
## The parts of Godot's godot.html (4.7) that patch_loader_html anchors on, verbatim.
SHELL_SCRIPT = (
    "<script>\n\tconst statusNotice = document.getElementById('status-notice');\n"
    "\tfunction setStatusMode(mode) {\n"
    "\t\tstatusNotice.style.display = mode === 'notice' ? 'block' : 'none';\n"
    "\t}\n"
    "\t\t\t\t\tstatusProgress.max = total;\n"
    "\t\t}).then(() => {\n\t\t\tsetStatusMode('hidden');\n\t\t}, displayFailureNotice);\n</script>"
)
SHELL_STUB = "<style></style>" + '<progress id="status-progress"></progress>' + SHELL_SCRIPT


def make_pack(path: Path, records: list[tuple[str, bytes]]) -> None:
    header = bytearray(112)
    struct.pack_into("<4s5IQQ", header, 0, b"GDPC", 4, 4, 7, 2, 2, 112, 0)
    rows = []
    with path.open("wb") as output:
        output.write(header)
        for name, data in records:
            offset = output.tell() - 112
            output.write(data)
            rows.append((name, offset, data))
        directory = output.tell()
        output.write(struct.pack("<I", len(rows)))
        for name, offset, data in rows:
            encoded = name.encode() + b"\0"
            encoded += bytes((-len(encoded)) % 4)
            output.write(struct.pack("<I", len(encoded)) + encoded)
            output.write(struct.pack("<QQ", offset, len(data)) + hashlib.md5(data).digest())
            output.write(struct.pack("<I", 0))
        output.seek(32)
        output.write(struct.pack("<Q", directory))


def read_pack(path: Path) -> dict:
    data = path.read_bytes()
    base, directory = struct.unpack_from("<QQ", data, 24)
    count = struct.unpack_from("<I", data, directory)[0]
    cursor = directory + 4
    rows = {}
    for _ in range(count):
        length = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        name = data[cursor:cursor + length].rstrip(b"\0").decode()
        cursor += length
        offset, size = struct.unpack_from("<QQ", data, cursor)
        cursor += 36
        rows[name] = (offset, data[base + offset:base + offset + size])
    return rows


def test_cap_preserves_other_import_settings():
    text = '[params]\nprocess/size_limit=0\ncompress/mode=2\nmipmaps/generate=true\n'
    assert cap_import(text) == text.replace("size_limit=0", "size_limit=256")
    assert cap_import(cap_import(text)) == cap_import(text)
    assert cap_import(text, 512) == text.replace("size_limit=0", "size_limit=512")
    assert "loop=true" in ogg_import(True)
    assert "loop=false" in ogg_import(False)


def test_posters_and_billboards_keep_their_resolution():
    assert is_uncapped("assets/posters/campaign_qwen.webp.import")
    assert is_uncapped("models/real/street/poster_frame_poster_portrait.png.import")
    assert is_uncapped("models/real/props/billboard_metal_plate_diff.jpg.import")
    assert not is_uncapped("models/characters/bodies/tex/Wood_Male_01_head_color.jpg.import")
    assert not is_uncapped("models/real/street/sidewalk_concrete_diff.jpg.import")
    assert not is_uncapped("models/real/vehicles/car_body_diff.png.import")


def test_ground_materials_get_their_own_cap():
    assert cap_limit("textures/real/grass_albedo.jpg.import") == 1024
    assert cap_limit("models/characters/bodies/tex/x.jpg.import") == 256
    assert cap_limit("models/real/props/x.jpg.import") == 256
    # The sky HDRIs import lossless (~11 MB each); the sky pack quarters at 1024 px wide.
    assert cap_limit("env/sky.hdr.import") == 1024
    assert cap_limit("env/sky_dusk.hdr.import") == 1024


def test_zone_and_building_textures_cap_by_kind():
    assert all(tree in CAP_TREES for tree in TYPED_TREES)
    assert "models/real/roads/" not in CAP_TREES
    for tree in ("models/real/zones/r1/", "models/real/buildings/"):
        for name in ("house_brick_wall_006_nor_gl.jpg", "house_x_nor_dx.png", "house_x_NORMAL.jpg"):
            assert cap_limit(tree + name + ".import") == 256
        assert cap_limit(tree + "house_brick_wall_006_arm.jpg.import") == 128
        assert cap_limit(tree + "house_car_atlas_arm.png.import") == 128
        # Diffuse, emission and the leaf-card alpha maps keep the source resolution (0 is no cap).
        for name in ("house_brick_wall_006_diff.jpg", "house_car_atlas_emit.png", "house_leafcluster_round.png",
                     "house_normalized_diff.jpg", "house_armrest_diff.jpg"):
            assert cap_limit(tree + name + ".import") == 0
    # Other trees keep their rules.
    assert cap_limit("models/real/props/bin_nor_gl.jpg.import") == 256
    assert cap_limit("models/real/street/bin_arm.jpg.import") == 256
    assert cap_limit("models/real/zones/r1/house_X_ARM.PNG.import") == 128


def test_arm_maps_below_512_px_keep_their_resolution_but_normals_do_not():
    arm = "models/real/zones/r2/midrise_solar_cells_arm.jpg.import"
    normal = "models/real/zones/r2/midrise_brick_nor_gl.jpg.import"
    assert cap_limit(arm, 512) == 128 and cap_limit(arm, 1024) == 128
    assert cap_limit(arm, 256) == 0 and cap_limit(arm, 128) == 0
    # An unknown source size (side 0) takes the rule, and the smallest-source rule is for ARM only.
    assert cap_limit(arm) == 128 and cap_limit(arm, 0) == 128
    assert cap_limit(normal, 256) == 256 and cap_limit(normal, 512) == 256
    # Only the typed trees read the size.
    assert cap_limit("models/real/props/bin_arm.jpg.import", 128) == 256


def test_typed_patterns_follow_the_optimizers_normal_map_rule():
    assert NORMAL_MAP_RE.pattern == NORMAL_RE.pattern
    assert NORMAL_MAP_RE.flags == NORMAL_RE.flags
    assert not ARM_MAP_RE.search("house_x_nor_gl.jpg") and not NORMAL_MAP_RE.search("house_x_arm.jpg")


def test_real_zone_and_building_imports_agree_with_the_typed_rule():
    """The rule keys on file names; the importer settings and the images behind them must agree,
    or a map would be capped as the wrong kind, and one image must get one rule in both trees (the
    pack aliases identical payloads, and a split between trees would store the image twice)."""
    kinds: dict = {}
    seen = 0
    for tree in TYPED_TREES:
        for path in sorted((ROOT / tree).rglob("*.import")):
            text = path.read_text()
            if 'importer="texture"' not in text:
                continue
            relative = path.relative_to(ROOT).as_posix()
            name = relative.removesuffix(".import")
            normal = NORMAL_MAP_RE.search(name) is not None
            arm = ARM_MAP_RE.search(name) is not None
            assert not (normal and arm), relative
            assert ("compress/normal_map=1" in text) == normal, relative
            assert cap_limit(relative) == (256 if normal else 128 if arm else 0), relative
            # The size rule needs the header of every image: a format image_info cannot read (WebP,
            # TGA) would silently take the plain rule, so the day one appears this test says so.
            side = max(image_info(str(path.with_suffix("")))[:2])
            assert side > 0, relative
            assert cap_limit(relative, side) == (256 if normal else 128 if arm and side >= 512 else 0), relative
            digest = hashlib.sha1(path.with_suffix("").read_bytes()).digest()
            assert kinds.setdefault(digest, (normal, arm)) == (normal, arm), relative
            seen += 1
    assert seen > 1000 and len(kinds) < seen


def png(side: int, tag: bytes = b"", height: "int | None" = None) -> bytes:
    """The header of a PNG, square unless height is given (all that image_info reads), then tag to
    give it its own digest."""
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(
        ">II", side, side if height is None else height) + bytes([8, 2, 0, 0, 0]) + tag


class StagedTextures:
    """A source project of texture imports (size_limit=0, as Godot writes them) and its staged copy."""

    META = '[remap]\nimporter="texture"\n[params]\nprocess/size_limit=0\n'

    def __init__(self, tmp_path: Path):
        self.root = tmp_path / "source"
        self.stage = tmp_path / "stage"
        self.root.mkdir()
        self.stage.mkdir()
        (self.root / "project.godot").write_text("[application]\n")
        (self.root / "export_presets.cfg").write_text("[preset.2.options]\n")

    def image(self, relative: str, content: "bytes | None") -> Path:
        """Add an import and its image; content None leaves the image out."""
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if content is not None:
            path.write_bytes(content)
        Path(str(path) + ".import").write_text(self.META)
        return path

    def run(self) -> dict:
        return stage_project(self.root, self.stage, ffmpeg="unused")

    def staged(self, path: Path) -> str:
        return Path(str(self.stage / path.relative_to(self.root)) + ".import").read_text()

    def limit(self, path: Path) -> str:
        return re.search(r"^process/size_limit=(\d+)$", self.staged(path), re.M)[1]


def test_stage_caps_normals_and_arm_but_not_diffuse_or_images_the_roads_share(tmp_path):
    project = StagedTextures(tmp_path)
    image = project.image
    brick = [image("models/real/zones/r1/house_brick_nor_gl.jpg", b"brick normal"),
             image("models/real/buildings/hall_brick_nor_gl.jpg", b"brick normal"),
             image("models/real/zones/r1/house_brick_arm.jpg", b"brick arm"),
             image("models/real/buildings/hall_brick_arm.jpg", b"brick arm")]
    plain = [image("models/real/zones/r1/house_brick_diff.jpg", b"brick diffuse"),
             image("models/real/buildings/hall_leafcluster_round.png", b"leaves")]
    # The asphalt maps ride in the zones, the buildings and the (uncapped) roads.
    asphalt = [image("models/real/zones/c1/shop_asphalt_nor_gl.jpg", b"asphalt normal"),
               image("models/real/buildings/hall_asphalt_nor_gl.jpg", b"asphalt normal"),
               image("models/real/zones/c1/shop_asphalt_arm.jpg", b"asphalt arm"),
               image("models/real/roads/road_straight_asphalt_nor_gl.jpg", b"asphalt normal"),
               image("models/real/roads/road_straight_asphalt_arm.jpg", b"asphalt arm")]

    report = project.run()

    assert [project.limit(p) for p in brick] == ["256", "256", "128", "128"]
    assert [project.limit(p) for p in plain + asphalt] == ["0"] * 7
    # Two trees, one image, one rule: the staged imports are byte-identical.
    assert project.staged(brick[0]) == project.staged(brick[1])
    assert project.staged(brick[2]) == project.staged(brick[3])
    assert report["capped_imports"] == 4
    # kept_full_size is still only the posters and billboards; the typed rule has its own counters.
    assert report["kept_full_size"] == 0
    assert report["kept_typed_full_size"] == 2
    assert report["kept_shared_with_roads"] == 3
    assert all("size_limit=0" in Path(str(p) + ".import").read_text() for p in brick + asphalt)


def test_stage_typed_rule_edge_cases(tmp_path):
    project = StagedTextures(tmp_path)
    image = project.image
    # The glossy solar-cell grid is a 256 px ARM map: below the rule's smallest source, it stays.
    solar = [image("models/real/zones/r2/midrise_solar_cells_arm.jpg", png(256, b"solar")),
             image("models/real/buildings/farm_solar_cells_arm.jpg", png(256, b"solar"))]
    # The pattern ignores case, the size rule starts at 512 px, and normals have no smallest source.
    capped = [image("models/real/zones/r2/midrise_brick_arm.jpg", png(512, b"brick")),
              image("models/real/zones/r2/midrise_plaster_ARM.PNG", png(1024, b"plaster")),
              image("models/real/zones/r2/midrise_plaster_nor_gl.png", png(256, b"small normal"))]
    # A size that cannot be read (not a PNG or JPEG header, or no image at all) takes the plain rule,
    # and an import with no image is never "shared" with a road import that has none either.
    unknown = [image("models/real/zones/r2/midrise_mystery_arm.jpg", b"not an image"),
               image("models/real/zones/r2/midrise_ghost_arm.jpg", None)]
    image("models/real/roads/road_ghost_arm.jpg", None)
    # Posters stay legible in every tree, even where the typed rule would cap their name.
    poster = image("models/real/zones/r2/midrise_poster_nor_gl.jpg", png(512, b"poster"))
    # The exemption is for the zone and building copies of an image the roads ship; the street GLBs
    # keep their own cap on the same image.
    shared = [image("models/real/roads/road_asphalt_nor_gl.jpg", png(512, b"asphalt")),
              image("models/real/zones/c1/shop_asphalt_nor_gl.jpg", png(512, b"asphalt")),
              image("models/real/street/street_asphalt_nor_gl.jpg", png(512, b"asphalt"))]
    # Only the roads exempt a typed copy: an image a street GLB alone ships is capped in both places,
    # so the zone copy (256 px, like the street's own) aliases it in the pack.
    street_only = [image("models/real/street/street_hydrant_nor_gl.jpg", png(512, b"hydrant")),
                   image("models/real/zones/c1/shop_hydrant_nor_gl.jpg", png(512, b"hydrant"))]
    # The exemption is by image, not by kind: a diffuse map the roads ship is already left alone by
    # the typed rule, so it counts there and not as an exemption.
    shared_diffuse = [image("models/real/roads/road_asphalt_diff.jpg", png(512, b"asphalt diffuse")),
                      image("models/real/zones/c1/shop_asphalt_diff.jpg", png(512, b"asphalt diffuse"))]
    # The smallest-source rule reads the longest side: a 512 px long ARM map is capped whichever way
    # round it is.
    lopsided = [image("models/real/zones/r2/midrise_wide_arm.jpg", png(512, b"wide", height=128)),
                image("models/real/zones/r2/midrise_tall_arm.jpg", png(128, b"tall", height=512))]

    report = project.run()

    assert [project.limit(p) for p in solar] == ["0", "0"]
    assert [project.limit(p) for p in capped] == ["128", "128", "256"]
    assert [project.limit(p) for p in unknown] == ["128", "128"]
    assert project.limit(poster) == "0"
    assert [project.limit(p) for p in shared] == ["0", "0", "256"]
    assert [project.limit(p) for p in street_only] == ["256", "256"]
    assert [project.limit(p) for p in shared_diffuse[1:]] == ["0"]
    assert [project.limit(p) for p in lopsided] == ["128", "128"]
    assert report["capped_imports"] == 10
    assert report["kept_full_size"] == 1
    assert report["kept_typed_full_size"] == 3
    assert report["kept_shared_with_roads"] == 1


def test_stage_changes_only_copied_web_assets(tmp_path, monkeypatch):
    root = tmp_path / "source"
    stage = tmp_path / "stage"
    root.mkdir()
    stage.mkdir()
    (root / "project.godot").write_text("[application]\n")
    (root / "export_presets.cfg").write_text("[preset.2.options]\n")
    body = root / "models/characters/bodies/head.jpg.import"
    body.parent.mkdir(parents=True)
    body.write_text('[remap]\nimporter="texture"\n[params]\nprocess/size_limit=0\n')
    ground = root / "textures/real/ground.jpg.import"
    ground.parent.mkdir(parents=True)
    ground.write_text(body.read_text())
    poster = root / "assets/posters/campaign_qwen.webp.import"
    poster.parent.mkdir(parents=True)
    poster.write_text(body.read_text())
    sky = root / "env/sky.hdr.import"
    sky.parent.mkdir(parents=True)
    sky.write_text(body.read_text())
    wav = root / "sounds/music/track.wav"
    wav.parent.mkdir(parents=True)
    wav.write_bytes(b"wav sample")
    Path(str(wav) + ".import").write_text("edit/loop_mode=0\n")

    def encode(command, check):
        assert check
        Path(command[-1]).write_bytes(b"OggS")

    monkeypatch.setattr("tools.web_export.subprocess.run", encode)
    report = stage_project(root, stage)
    assert report["capped_imports"] == 3
    assert report["kept_full_size"] == 1
    assert report["converted_wav"] == 1
    assert "size_limit=0" in body.read_text()
    assert wav.read_bytes() == b"wav sample"
    assert "size_limit=256" in (stage / body.relative_to(root)).read_text()
    # The tiling ground material keeps its own, larger cap.
    assert "size_limit=1024" in (stage / ground.relative_to(root)).read_text()
    # So do the sky HDRIs.
    assert "size_limit=1024" in (stage / sky.relative_to(root)).read_text()
    assert "size_limit=0" in sky.read_text()
    assert (stage / poster.relative_to(root)).read_text() == poster.read_text()
    assert not (stage / wav.relative_to(root)).exists()
    assert "loop=true" in (stage / "sounds/music/track.ogg.import").read_text()


def test_wav_loops_follows_godots_loop_mode_enum():
    assert wav_loops("edit/loop_mode=2\n")  # Forward: engine_run, siren
    assert wav_loops("edit/loop_mode=3\n") and wav_loops("edit/loop_mode=4\n")
    assert not wav_loops("edit/loop_mode=1\n")  # Disabled: the one-shots (footsteps, horns)
    assert not wav_loops("edit/loop_mode=0\n")  # Detect
    assert not wav_loops("")


def test_stage_project_loops_only_the_looping_wavs(tmp_path, monkeypatch):
    root, stage = tmp_path / "src", tmp_path / "stage"
    root.mkdir()
    stage.mkdir()
    (root / "project.godot").write_text("[application]\n")
    (root / "export_presets.cfg").write_text("[preset.2.options]\n")
    for name, mode in (("engine_run", 2), ("footstep", 1)):
        wav = root / f"sounds/fp/{name}.wav"
        wav.parent.mkdir(parents=True, exist_ok=True)
        wav.write_bytes(b"wav sample")
        Path(str(wav) + ".import").write_text(f"edit/loop_mode={mode}\n")
    monkeypatch.setattr("tools.web_export.subprocess.run", lambda c, check: Path(c[-1]).write_bytes(b"OggS"))
    stage_project(root, stage)
    assert "loop=true" in (stage / "sounds/fp/engine_run.ogg.import").read_text()
    assert "loop=false" in (stage / "sounds/fp/footstep.ogg.import").read_text()


def test_pack_aliases_duplicates_without_changing_paths(tmp_path):
    pack = tmp_path / "test.pck"
    sample = bytes(range(256)) * 16
    make_pack(pack, [("a.ctex", sample), ("b.ctex", sample), ("scene.res", b"scene")])
    report = deduplicate_pack(pack)
    result = read_pack(pack)
    assert report["pack_after"] < report["pack_before"]
    assert report["unique_payloads"] == 2
    assert result["a.ctex"] == result["b.ctex"]
    assert result["scene.res"][1] == b"scene"
    # Repeated postprocessing is safe.
    assert deduplicate_pack(pack)["pack_after"] == report["pack_after"]


def test_pack_rejects_corruption_without_replacing_original(tmp_path):
    pack = tmp_path / "test.pck"
    make_pack(pack, [("a", b"sample")])
    data = bytearray(pack.read_bytes())
    data[112] ^= 1
    pack.write_bytes(data)
    with pytest.raises(ValueError, match="Corrupt"):
        deduplicate_pack(pack)
    assert pack.read_bytes() == data


def test_versioned_site_updates_loader_sizes_and_worker(tmp_path):
    raw = tmp_path / "raw"
    output = tmp_path / "site"
    raw.mkdir()
    (raw / "index.pck").write_bytes(b"pack")
    (raw / "index.wasm").write_bytes(b"engine")
    (raw / "index.js").write_text("engine")
    (raw / "index.html").write_text(
        '<link rel="manifest" href="index.manifest.json">'
        '<script src="index.js"></script>{"executable":"index","fileSizes":{"index.pck":4},'
        '"serviceWorker":"index.service.worker.js"}'
        + SHELL_STUB
    )
    (raw / "index.service.worker.js").write_text(
        "const CACHE_VERSION = 'old';\nconst CACHED_FILES = ['index.html', 'index.js'];\n"
        "const CACHEABLE_FILES = ['index.pck'];\nconst cache = await caches.open(CACHE_NAME);"
    )
    (raw / "index.manifest.json").write_text(
        '{"start_url":"./index.html","icons":[{"src":"index.icon.png","sizes":"512x512"}]}'
    )
    report = {}
    version = version_site(raw, output, report)
    html = (output / "index.html").read_text()
    assert f'releases/{version}/index.js' in html
    assert f'"executable":"releases/{version}/index"' in html
    assert f'"releases/{version}/index.pck":4' in html
    assert '"serviceWorker":"index.service.worker.js"' in html
    assert 'href="index.manifest.json"' in html  # root scope, not the release copy
    # The loader trio stays at the root; the payloads are only in the release directory.
    assert (output / "index.html").exists() and (output / "index.service.worker.js").exists()
    assert (output / "index.manifest.json").exists()
    assert not (output / "index.js").exists() and not (output / "index.pck").exists()
    assert (output / f"releases/{version}/index.pck").exists()
    manifest = json.loads((output / "index.manifest.json").read_text())
    assert manifest["start_url"] == "./index.html"
    assert manifest["icons"][0]["src"] == f"releases/{version}/index.icon.png"
    worker = (output / "index.service.worker.js").read_text()
    assert f"const CACHE_VERSION = '{version}'" in worker
    assert f"'releases/{version}/index.pck'" in worker
    assert "fetchAndCache(event, cache, true)" in worker
    assert json.loads((output / "build-report.json").read_text())["version"] == version


def test_prune_keeps_the_previous_release(tmp_path):
    output = tmp_path / "site"
    (output / "releases/aaa").mkdir(parents=True)
    (output / "releases/bbb").mkdir()
    (output / "releases/bbb").touch()
    import os
    import time

    os.utime(output / "releases/aaa", (time.time() - 100, time.time() - 100))
    prune_releases(output, "ccc")
    assert (output / "releases/aaa").exists() is False  # oldest is dropped
    assert (output / "releases/bbb").exists() is True  # the one before the new release survives


def test_loader_page_gets_a_progress_bar():
    patched = patch_loader_html(SHELL_STUB)
    assert 'id="gf-fill"' in patched and 'id="gf-label"' in patched
    assert "function setProgress(ratio)" in patched
    assert "setProgress(current / total);" in patched
    assert patched.count("<progress id=\"status-progress\"></progress>") == 1
    # A changed shell must fail loudly rather than ship an unpatched page.
    with pytest.raises(ValueError, match="HTML shell changed"):
        patch_loader_html("<style></style>")


def test_loader_explains_the_game_before_the_engine_starts():
    from tools.web_export import LOADER_CSS, LOADER_KEYS, LOADER_PITCH

    plain = SHELL_STUB
    patched = patch_loader_html(plain)
    assert LOADER_PITCH == "Five AI mayors, five different models on GMI Cloud, one city you can walk in"
    assert LOADER_KEYS == "WASD walk - Tab planner - J AI feed - Esc menu - click to capture the mouse"
    assert patched.count(LOADER_PITCH) == 1 and patched.count(LOADER_KEYS) == 1
    # Static markup in the bar, above the track: it is in the first paint and in the boot stall,
    # and it goes with the bar (the veil's own logic hides and lifts the whole bar).
    bar = patched.index('<div id="gf-bar">')
    assert bar < patched.index(LOADER_PITCH) < patched.index(LOADER_KEYS) < patched.index('id="gf-track"')
    assert "#gf-explain" in LOADER_CSS and "#gf-pitch" in LOADER_CSS and "#gf-keys" in LOADER_CSS
    # No script touches the text, so it cannot depend on the boot clock or the engine.
    script = patched[patched.index("<script"):]
    assert "gf-pitch" not in script and "gf-keys" not in script and "gf-explain" not in script
    # The page grows by the text and its few rules only.
    from tools.web_export import LOADER_BAR

    rules = LOADER_CSS[LOADER_CSS.index("/* What the game is"):LOADER_CSS.index("#gf-track")]
    assert len(rules) < 900 and len(LOADER_BAR) < 1_200, (len(rules), len(LOADER_BAR))


def test_loader_keeps_the_overlay_until_the_game_is_interactive():
    patched = patch_loader_html(SHELL_STUB)
    # startGame() resolving no longer removes the overlay; only the game's hook or the timeout does.
    assert "}).then(() => {\n\t\t\tsetStatusMode('hidden');" not in patched
    assert "}).then(() => {\n\t\t\tengineStarted();\n\t\t}, displayFailureNotice);" in patched
    assert patched.count("setStatusMode('hidden')") == 1  # releaseVeil is the only caller
    assert "window.gfBootDone = releaseVeil;" in patched
    assert "const BOOT_VEIL_TIMEOUT_MS = 30000;" in patched
    assert "veilTimer = setTimeout(releaseVeil, BOOT_VEIL_TIMEOUT_MS);" in patched
    # A release that throws has already spent its timer, so it hides the overlay by hand.
    assert "statusOverlay.style.display = 'none';" in patched
    # The timeout is armed before anything that draws, so nothing after it can leave the veil up.
    started = patched[patched.index("function engineStarted()"):]
    assert started.index("setTimeout(releaseVeil") < started.index("showStarting()")
    # The label changes at the last byte, or when the engine is about to start, whichever is first.
    assert "Starting your city" in patched
    assert "engine.start = function (...args) {\n\t\t\tshowStarting();" in patched
    # A failure notice replaces the bar instead of sitting under it.
    notice = patched.index("statusNotice.style.display = mode === 'notice'")
    assert patched.index("progressBar.style.display", notice) > notice


def _js_function(source: str, name: str) -> str:
    """The body of `function name(...) { ... }` in source, nested braces included."""
    first = source.index("{", source.index("function " + name + "("))
    depth, i = 0, first
    while True:
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
        if depth == 0:
            return source[first + 1:i - 1]


def _engine_start_wrapper(patched: str) -> str:
    """The body of the `engine.start = function (...args) { ... };` the loader installs."""
    wrapper = patched[patched.index("engine.start = function"):]
    return wrapper[:wrapper.index("\n\t\t};")]


def test_loader_veil_timeout_starts_when_the_game_resolves_and_releases_once():
    patched = patch_loader_html(SHELL_STUB)
    started, released = _js_function(patched, "engineStarted"), _js_function(patched, "releaseVeil")
    # The one timeout that lifts the veil is armed when startGame() resolves, after the boot task, so
    # neither that task nor a slow download can trip it; none is armed at page load.
    assert patched.count("setTimeout(releaseVeil") == 1 and "setTimeout(releaseVeil" in started
    assert patched.count("BOOT_VEIL_TIMEOUT_MS") == 2  # the constant and that one use
    # A hook call that came first has released the veil: nothing is armed afterwards.
    assert "if (!veilReleased)" in started
    # The first release wins, so gf:veil_released is when the overlay really went (smoke.js reads it)
    # and the timeout and the hook cannot both mark it; the timer is cleared when the hook is first.
    assert released.lstrip().startswith("if (veilReleased) {\n\t\t\treturn;\n\t\t}")
    assert "clearTimeout(veilTimer);" in released


def test_loader_arms_only_the_three_timers_it_documents():
    from tools.web_export import LOADER_HELPER

    # "No timer runs at page load" is what lets neither the boot task nor a slow download trip the
    # veil. The helper arms exactly three timers, each inside the function that owns it, so a fourth
    # (a veil timer armed early, however it is spelled) changes the count or the place.
    assert LOADER_HELPER.count("setTimeout(") == 3 and "setInterval(" not in LOADER_HELPER
    assert "setTimeout(resolve, 250)" in _js_function(LOADER_HELPER, "afterFrames")
    assert "setTimeout(() => setStalled(true), START_STALL_MS)" in _js_function(LOADER_HELPER, "watchStall")
    assert "setTimeout(releaseVeil, BOOT_VEIL_TIMEOUT_MS)" in _js_function(LOADER_HELPER, "engineStarted")


def test_loader_starts_the_engine_two_frames_after_painting_the_starting_state():
    patched = patch_loader_html(SHELL_STUB)
    wrapper = _engine_start_wrapper(patched)
    assert wrapper.index("showStarting()") < wrapper.index("afterFrames()")
    assert "return afterFrames().then(() => engineStart.apply(this, args));" in wrapper
    assert patched.count("engineStart.apply(") == 1  # no way to start the engine without the wait
    frames = _js_function(patched, "afterFrames")
    assert frames.count("requestAnimationFrame(") == 2
    # A hidden tab draws no frames: a short timer lets the boot go ahead, and a frame cancels it.
    assert "setTimeout(resolve, 250)" in frames and "clearTimeout(fallback)" in frames


def test_loader_says_starting_only_when_the_last_byte_is_in():
    patched = patch_loader_html(SHELL_STUB)
    progress = _js_function(patched, "setProgress")
    # 99.6% of the bytes rounds to 100 but is not done: the shown percentage stops at 99 until then.
    assert "ratio >= 1 ? 100 : Math.max(0, Math.min(99, Math.round(ratio * 100)))" in progress
    assert re.search(r"if \(ratio >= 1\) \{\s*showStarting\(\);", progress)
    assert "pct >= 100" not in progress


def test_loader_flags_a_stalled_start_but_never_a_running_boot():
    from tools.web_export import LOADER_CSS

    patched = patch_loader_html(SHELL_STUB)
    assert "const START_STALL_MS = 60000;" in patched
    assert "stallTimer = setTimeout(() => setStalled(true), START_STALL_MS);" in patched
    # Every progress tick restarts the watch; the engine starting ends it for good.
    assert "watchStall();" in _js_function(patched, "setProgress")
    assert "stopStall();" in _engine_start_wrapper(patched)
    stop, watch = _js_function(patched, "stopStall"), _js_function(patched, "watchStall")
    assert "stallOver = true;" in stop and "clearTimeout(stallTimer);" in stop
    # It also starts with the page: a download that hangs before its first byte never ticks.
    after_hook = patched[patched.index("window.gfBootDone = releaseVeil;"):]
    assert "\n\twatchStall();\n" in after_hook
    # A progress tick (or the engine starting) takes a hint that is showing back.
    assert "setStalled(false);" in watch and "setStalled(false);" in stop
    # rAF can run one last progress tick after the engine start; it must not arm the watch again,
    # or a very long boot would end in a hint.
    assert watch.lstrip().startswith("if (stallOver) {\n\t\t\treturn;\n\t\t}")
    # The hint replaces the spinner while stalled.
    assert 'id="gf-hint"' in patched
    assert "#gf-bar.gf-stalled #gf-hint { display: block; }" in LOADER_CSS
    assert "#gf-bar.gf-stalled #gf-spin { display: none; }" in LOADER_CSS


def test_loader_spinner_arc_survives_forced_colors():
    from tools.web_export import LOADER_CSS

    forced = LOADER_CSS[LOADER_CSS.index("@media (forced-colors: active)"):]
    # High contrast makes every border one colour; system colours keep the arc apart from the ring.
    assert "border-color: GrayText" in forced and "border-top-color: Highlight" in forced
    assert forced.index("border-color: GrayText") < forced.index("border-top-color: Highlight")


def _css_blocks(css: str, at_rule: str) -> list[str]:
    """The bodies of every `@<at_rule> name { ... }` block, nested braces included."""
    bodies = []
    for found in re.finditer(r"@" + at_rule + r"\s+[\w-]+\s*\{", css):
        depth, i = 1, found.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(css[i], 0)
            i += 1
        bodies.append(css[found.end():i - 1])
    return bodies


def test_loader_spinner_animates_compositor_properties_only():
    from tools.web_export import LOADER_CSS

    frames = _css_blocks(LOADER_CSS, "keyframes")
    assert len(frames) == 2  # the spin and the reduced-motion pulse
    for body in frames:
        # transform and opacity are the properties a compositor can animate off the main thread.
        assert set(re.findall(r"([a-z-]+)\s*:", body)) <= {"transform", "opacity"}
    assert "animation: gf-spin" in LOADER_CSS and "will-change: transform" in LOADER_CSS
    assert "prefers-reduced-motion: reduce" in LOADER_CSS


@pytest.mark.parametrize(
    "anchor",
    [
        "</style>",
        '<progress id="status-progress"></progress>',
        "\tconst statusNotice = document.getElementById('status-notice');",
        "\t\tstatusNotice.style.display = mode === 'notice' ? 'block' : 'none';",
        "\t\t\t\t\tstatusProgress.max = total;",
        "\t\t}).then(() => {\n\t\t\tsetStatusMode('hidden');\n\t\t}, displayFailureNotice);",
    ],
)
def test_loader_patch_fails_loudly_when_an_anchor_moves(anchor):
    assert anchor in SHELL_STUB
    with pytest.raises(ValueError, match="HTML shell changed"):
        patch_loader_html(SHELL_STUB.replace(anchor, ""))


def _template_zip() -> Path:
    version = (ROOT / ".godot-version").read_text().strip()
    return Path.home() / ".local/share/godot/export_templates" / version / "web_release.zip"


@pytest.mark.skipif(not _template_zip().exists(), reason="the Godot web export template is not installed")
def test_loader_patch_fits_the_installed_godot_shell():
    with zipfile.ZipFile(_template_zip()) as templates:
        shell = templates.read("godot.html").decode()
    patched = patch_loader_html(shell)
    assert "engineStarted();" in patched and "window.gfBootDone" in patched
    assert patched.count("setStatusMode('hidden')") == 1  # releaseVeil is the only caller left


@pytest.mark.skipif(
    not _template_zip().exists(),
    reason="the Godot web export template is not installed (the engine ordering is then checked only by deploy/web/smoke.js)",
)
def test_installed_engine_starts_the_game_inside_callmain_then_resolves():
    # The JS half of what the loader's engine.start wrapper and its timeout rely on: startGame() calls
    # this.start(), and start() resolves only after callMain returns. It reads the installed template,
    # so it runs on developer machines only (the CI jobs have no web template and skip it). The C++
    # half, that the first main-loop iteration (Main._ready and the first frame) runs inside callMain,
    # is not in godot.js at all: it was measured in a real export, and
    # test_smoke_checks_the_engine_ordering_the_veil_timeout_rests_on pins the check that re-measures it.
    with zipfile.ZipFile(_template_zip()) as templates:
        engine = templates.read("godot.js").decode()
    assert "return me.start.apply(me);" in engine
    called = engine.index("me.rtenv['callMain'](me.config.args);")
    assert 0 < engine.index("resolve();", called) - called < 200


@pytest.mark.skipif(not _template_zip().exists(), reason="the Godot web export template is not installed")
def test_installed_engine_never_rejects_a_wasm_that_fails_to_load():
    # Why the loader watches for a stall: Engine.init() has no reject path, so a wasm that fails to
    # download or compile leaves startGame() pending for ever, with no notice (the stock shell hangs
    # the same way). If a Godot update adds one, the stall hint may be redundant.
    with zipfile.ZipFile(_template_zip()) as templates:
        engine = templates.read("godot.js").decode()
    init = engine[engine.index("function doInit(promise) {"):]
    init = init[:init.index("preloader.setProgressFunc")]
    assert "reject(" not in init and ".catch(" not in init
    assert "WebAssembly.instantiateStreaming(Promise.resolve(r), imports).then(done);" in engine


def _gd_body(source: str, name: str) -> str:
    """The indented body of `static func name(...)` in a GDScript file."""
    lines = source.splitlines()
    head = next(i for i, line in enumerate(lines) if line.startswith("static func " + name + "("))
    body = []
    for line in lines[head + 1:]:
        if line and not line.startswith("\t"):
            break
        body.append(line)
    return "\n".join(body)


def test_game_page_and_smoke_agree_on_the_boot_contract():
    patched = patch_loader_html(SHELL_STUB)
    hook = re.search(r"window\.(\w+) = releaseVeil;", patched).group(1)
    support = (ROOT / "scripts/ops/web_support.gd").read_text()
    clock = (ROOT / "scripts/ops/boot_clock.gd").read_text()
    main = (ROOT / "scripts/main.gd").read_text()
    smoke = (ROOT / "deploy/web/smoke.js").read_text()
    # The game calls the hook the page defines, and not through eval: a page whose Content-Security-
    # Policy forbids eval would never get the call and would keep its veil for the whole timeout.
    boot_done = _gd_body(support, "boot_done")
    assert "." + hook in boot_done and 'get_interface("window")' in boot_done
    assert "_eval(" not in boot_done and "JavaScriptBridge.eval" not in boot_done
    # BootClock.finish reports first and then lifts the veil, and its last mark is the one smoke.js
    # compares the page's release with.
    finish = _gd_body(clock, "finish")
    assert finish.index("print(COMPLETE_LINE)") < finish.index("WebSupport.boot_done()")
    assert finish.index('mark("veil_frames")') < finish.index("WebSupport.boot_done()")
    assert 'WebSupport.perf_mark("gf:" + label)' in clock
    # The windowed frames: the first frame's iteration ends at pre_draw and its draw at first_frame,
    # which splits the table's one big row in two (a headless run draws nothing and has no pre_draw,
    # so only this text can pin the order).
    windowed = finish[finish.index("await RenderingServer.frame_pre_draw"):]
    assert windowed.index('mark("pre_draw")') < windowed.index("await RenderingServer.frame_post_draw")
    assert windowed.index("await RenderingServer.frame_post_draw") < windowed.index('mark("first_frame")')
    # The line the harness waits for and the marks it reads are what the game and the page produce.
    line = re.search(r'const COMPLETE_LINE := "([^"]+)"', clock).group(1)
    assert "BOOT_DONE_RE = /^" + line + "$/;" in smoke
    assert '"gf:veil_frames"' in smoke and '"gf:veil_released"' in smoke
    assert "timelineMark('veil_released')" in patched
    # smoke.js tells a build from before BootClock by the first mark Main makes.
    assert 'performance.getEntriesByName("gf:ready_begin")' in smoke
    assert 'BootClock.mark("ready_begin")' in main


def test_smoke_checks_the_engine_ordering_the_veil_timeout_rests_on():
    # The page arms its 30 s veil timeout when startGame() resolves, which covers only the three veil
    # frames because Godot's web main() runs the first main-loop iteration inside callMain, so the
    # resolve comes after the game's first frame. No CI job can see that (it needs a web build and a
    # browser), so every full smoke run must compare the two marks, and the marks must exist.
    patched = patch_loader_html(SHELL_STUB)
    smoke = (ROOT / "deploy/web/smoke.js").read_text()
    clock = (ROOT / "scripts/ops/boot_clock.gd").read_text()
    assert 'first: at("gf:first_frame")' in smoke and 'resolved: at("gf:start_game_resolved")' in smoke
    check = smoke[smoke.index('check("startGame() resolved after the game\'s first frame'):]
    check = check[:check.index("));") + 3]
    assert "veil.resolved >= veil.first" in check
    assert "veil.first !== null && veil.resolved !== null" in check  # a missing mark fails, never passes
    assert "timelineMark('start_game_resolved')" in patched  # the page's mark
    assert 'mark("first_frame")' in clock  # the game's mark


@pytest.mark.parametrize("case", [str.lower, str.title, str.upper])
def test_measure_headers_are_case_insensitive(monkeypatch, case):
    from tools import web_measure

    headers = {
        "content-encoding": "br",
        "cache-control": "public, max-age=31536000, immutable",
        "cross-origin-opener-policy": "same-origin",
        "cross-origin-embedder-policy": "require-corp",
        "content-type": "application/wasm",
        "content-range": "bytes 0-0/6902599",
    }

    def fetch(url, request_headers):
        assert url == "https://example.org/index.wasm"
        assert request_headers == {"Accept-Encoding": "br", "Range": "bytes=0-0"}
        return 206, {case(name): value for name, value in headers.items()}, b"x"

    monkeypatch.setattr(web_measure, "fetch", fetch)
    assert web_measure.head("https://example.org/index.wasm", "br") == {
        "status": 206,
        "encoding": "br",
        "cache": headers["cache-control"],
        "coop": "same-origin",
        "coep": "require-corp",
        "type": "application/wasm",
        "content_range": "bytes 0-0/6902599",
        "probe_bytes": 1,
    }


def test_measure_headers_default_only_when_absent(monkeypatch):
    from tools import web_measure

    monkeypatch.setattr(web_measure, "fetch", lambda *_: (206, {}, b"x"))
    assert web_measure.head("https://example.org/index.pck", "identity") == {
        "status": 206, "encoding": "identity", "cache": "", "coop": "", "coep": "",
        "type": "", "content_range": "", "probe_bytes": 1,
    }


def test_measure_script_finds_the_assets_the_page_names():
    from tools.web_measure import asset_paths

    html = (
        '<script src="releases/abc/index.js"></script>'
        '<link rel="manifest" href="index.manifest.json">'
        '{"executable":"releases/abc/index","serviceWorker":"index.service.worker.js",'
        '"fileSizes":{"releases/abc/index.pck":100,"releases/abc/index.wasm":50}}'
        '<script src="https://example.com/analytics.js"></script>'
    )
    paths = asset_paths(html)
    # Exact set, in order: the page first, then only the assets the page names. The executable
    # value is a basename (the engine appends .pck/.wasm), so it is not a file, and the external
    # analytics URL is not probed.
    assert paths == [
        "",
        "releases/abc/index.js",
        "index.manifest.json",
        "releases/abc/index.pck",
        "releases/abc/index.wasm",
    ]


def test_pack_of_routes_every_tree():
    assert pack_of("env/sky.hdr") == "sky"
    assert pack_of("assets/posters/ad_bank.webp") == "posters"
    assert pack_of("models/real/zones/r1/house.glb") == "boot"
    assert pack_of("models/zones/c2/block.glb") == "boot"
    assert pack_of("models/real/props/bin.glb") == "props"
    assert pack_of("models/real/vehicles_v2/car.glb") == "traffic"
    assert pack_of("models/characters/bodies/Office_Male_01.glb") == "people"
    assert pack_of("models/real/animals/dog.glb") == "wildlife"
    assert pack_of("models/real/midlod/tower.res") == "midlod"
    assert pack_of("sounds/fp/footstep_grass_1.ogg") == "audio"
    # Boot keeps the city shell, the hero, and everything unmatched.
    assert pack_of("models/real/buildings/tower.glb") == "boot"
    assert pack_of("models/characters/anim/lib_m.tres") == "boot"
    assert pack_of("models/characters/bodies/Male_Adult_06.glb") == "boot"
    assert pack_of("models/characters/bodies/Female_Adult_04.glb") == "boot"
    assert pack_of("scripts/main.gd") == "boot"
    assert pack_of("textures/real/grass_albedo.jpg") == "boot"


def test_split_packs_groups_imports_with_their_asset(tmp_path):
    pack = tmp_path / "index.pck"
    imported = "res://.godot/imported/house.glb-abc.scn"
    sky_imported = "res://.godot/imported/sky.hdr-abc.ctex"

    def importer(dest: str) -> bytes:
        return f'[deps]\ndest_files=["{dest}"]\n'.encode()

    make_pack(pack, [
        ("models/real/zones/r1/house.glb", b"zone-glb"),
        ("models/real/zones/r1/house.glb.import", importer(imported)),
        (".godot/imported/house.glb-abc.scn", b"zone-scene"),
        ("scripts/main.gd", b"extends Node"),
        ("env/sky.hdr", b"hdri"),
        ("env/sky.hdr.import", importer(sky_imported)),
        (".godot/imported/sky.hdr-abc.ctex", b"sky-texture"),
        ("models/real/midlod/house.res", b"baked-twin"),
        ("models/zones/c2/block.glb", b"legacy-zone"),
    ])
    report = split_packs(pack, tmp_path)
    assert set(report["packs"]) == {"boot", "midlod", "sky"}
    # Option A keeps source buildings and their imports in boot; twins arrive later.
    boot = read_pack(pack)
    assert "scripts/main.gd" in boot
    assert boot["models/real/zones/r1/house.glb"][1] == b"zone-glb"
    assert boot[".godot/imported/house.glb-abc.scn"][1] == b"zone-scene"
    assert boot["models/zones/c2/block.glb"][1] == b"legacy-zone"
    assert "web_manifest.json" in boot
    assert ".godot/imported/sky.hdr-abc.ctex" not in boot
    sky = read_pack(tmp_path / report["manifest"]["packs"]["sky"]["file"])
    assert sky["env/sky.hdr"][1] == b"hdri"
    assert sky[".godot/imported/sky.hdr-abc.ctex"][1] == b"sky-texture"
    twins = read_pack(tmp_path / report["manifest"]["packs"]["midlod"]["file"])
    assert twins["models/real/midlod/house.res"][1] == b"baked-twin"
    # The manifest the runtime reads: rules plus a file per background pack.
    manifest = json.loads(boot["web_manifest.json"][1])
    assert manifest["boot"] == "boot"
    assert ["env/", "sky"] in manifest["rules"]
    assert manifest["packs"]["sky"]["file"].startswith("packs/sky-")
    assert manifest["packs"]["sky"]["bytes"] > 0
    assert len(manifest["packs"]["sky"]["sha256"]) == 64


def test_rewrite_manifest_prefixes_only_pack_paths(tmp_path):
    pack = tmp_path / "index.pck"
    make_pack(pack, [
        ("scripts/main.gd", b"extends Node"),
        ("web_manifest.json", b'{"boot":"boot","rules":[["env/","sky"]],'
                              b'"packs":{"sky":{"file":"packs/sky-abc.pck","bytes":4}}}'),
    ])
    rewrite_manifest(pack, "releases/1234/")
    boot = read_pack(pack)
    manifest = json.loads(boot["web_manifest.json"][1])
    assert manifest["packs"]["sky"]["file"] == "releases/1234/packs/sky-abc.pck"
    # Everything else is untouched, and rewriting twice does not double the prefix.
    assert boot["scripts/main.gd"][1] == b"extends Node"
    rewrite_manifest(pack, "releases/1234/")
    assert json.loads(read_pack(pack)["web_manifest.json"][1])["packs"]["sky"]["file"] == \
        "releases/1234/packs/sky-abc.pck"
