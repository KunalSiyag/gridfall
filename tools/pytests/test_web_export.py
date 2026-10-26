"""Web staging and PCK aliasing never alter desktop source assets."""
import hashlib
import json
import struct
from pathlib import Path

import pytest

from tools.web_export import (
    cap_import,
    deduplicate_pack,
    is_uncapped,
    ogg_import,
    prune_releases,
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
    assert report["capped_imports"] == 1
    assert report["kept_full_size"] == 1
    assert report["converted_wav"] == 1
    assert "size_limit=0" in body.read_text()
    assert wav.read_bytes() == b"wav sample"
    assert "size_limit=256" in (stage / body.relative_to(root)).read_text()
    assert (stage / ground.relative_to(root)).read_text() == ground.read_text()
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

