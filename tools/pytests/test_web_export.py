"""Web staging and PCK aliasing never alter desktop source assets."""
import hashlib
import json
import struct
from pathlib import Path

import pytest

from tools.web_export import (
    cap_import,
    cap_limit,
    deduplicate_pack,
    is_uncapped,
    ogg_import,
    pack_of,
    patch_loader_html,
    prune_releases,
    rewrite_manifest,
    split_packs,
    stage_project,
    version_site,
)


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
    wav = root / "sounds/music/track.wav"
    wav.parent.mkdir(parents=True)
    wav.write_bytes(b"wav sample")
    Path(str(wav) + ".import").write_text("edit/loop_mode=0\n")

    def encode(command, check):
        assert check
        Path(command[-1]).write_bytes(b"OggS")

    monkeypatch.setattr("tools.web_export.subprocess.run", encode)
    report = stage_project(root, stage)
    assert report["capped_imports"] == 2
    assert report["kept_full_size"] == 1
    assert report["converted_wav"] == 1
    assert "size_limit=0" in body.read_text()
    assert wav.read_bytes() == b"wav sample"
    assert "size_limit=256" in (stage / body.relative_to(root)).read_text()
    # The tiling ground material keeps its own, larger cap.
    assert "size_limit=1024" in (stage / ground.relative_to(root)).read_text()
    assert (stage / poster.relative_to(root)).read_text() == poster.read_text()
    assert not (stage / wav.relative_to(root)).exists()
    assert "loop=true" in (stage / "sounds/music/track.ogg.import").read_text()


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
        '<style></style>'
        '<progress id="status-progress"></progress>'
        "<script>\n\tconst statusNotice = document.getElementById('status-notice');\n"
        "\t\t\t\t\tstatusProgress.max = total;\n</script>"
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
    html = (
        "<style></style>"
        '<progress id="status-progress"></progress>'
        "<script>\n\tconst statusNotice = document.getElementById('status-notice');\n"
        "\t\t\t\t\tstatusProgress.max = total;\n</script>"
    )
    patched = patch_loader_html(html)
    assert 'id="gf-fill"' in patched and 'id="gf-label"' in patched
    assert "function setProgress(ratio)" in patched
    assert "setProgress(current / total);" in patched
    assert patched.count("<progress id=\"status-progress\"></progress>") == 1
    # A changed shell must fail loudly rather than ship an unpatched page.
    with pytest.raises(ValueError, match="HTML shell changed"):
        patch_loader_html("<style></style>")


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
