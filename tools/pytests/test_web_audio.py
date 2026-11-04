"""Web audio (unit A1): the web build must make a sound. Its root cause was a bus added at runtime
(AudioServer.add_bus) in web Sample playback mode, which left Master disconnected from the browser's
AudioContext destination, so the project ships a default bus layout. These tests read the layout and
project settings from the repository, the audio assets named by audio_bank.gd, and (when an export is
at hand) the .pck's directory. The live check is tools/web_audio_probe.js.

An export is found at GF_WEB_PACK, else build/web/**/index.pck; without one the pack tests skip.
"""
import json
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path

import pytest

from tools.web_export import _read_directory

ROOT = Path(__file__).resolve().parents[2]
LAYOUT = ROOT / "default_bus_layout.tres"
BANK = ROOT / "scripts/fp/audio/audio_bank.gd"
BUSES = ["Music", "SFX", "Ambience", "UI"]
needs_node = pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")


def layout_buses(text: str) -> dict:
    """{bus index: {key: value}} from a text AudioBusLayout."""
    out: dict = {}
    for m in re.finditer(r"^bus/(\d+)/(\w+) = (.+)$", text, re.M):
        out.setdefault(int(m.group(1)), {})[m.group(2)] = m.group(3).strip()
    return out


def bank_names(text: str) -> list:
    """The asset names audio_bank.gd's all_names() builds: loops, one-shots, footsteps and splashes."""

    def array(name: str) -> list:
        body = re.search(name + r": Array\[String\] = \[(.*?)\]", text, re.S).group(1)
        return re.findall(r'"([^"]+)"', body)

    names = array("LOOPS") + array("ONE_SHOTS")
    surfaces = array("SURFACES")
    steps = int(re.search(r"const STEP_VARIANTS := (\d+)", text).group(1))
    splashes = int(re.search(r"const SPLASH_VARIANTS := (\d+)", text).group(1))
    # water has no recordings of its own: its steps are the footstep_splash_<n> set (step_name)
    names += [f"footstep_{s}_{n}" for s in surfaces if s != "water" for n in range(1, steps + 1)]
    names += [f"footstep_splash_{n}" for n in range(1, splashes + 1)]
    return names


def pack_names(pack: Path) -> list:
    with open(pack, "rb") as f:
        _header, _base, entries = _read_directory(f)
    return [e["name"].decode("utf-8", "replace") for e in entries]


def pack_setting_blob(pack: Path) -> bytes:
    """The raw project.binary of a pack: the project settings as the engine reads them at boot."""
    with open(pack, "rb") as f:
        _header, _base, entries = _read_directory(f)
        for e in entries:
            if e["name"].decode("utf-8", "replace") == "project.binary":
                f.seek(e["offset"])
                return f.read(e["size"])
    return b""


def find_pack() -> Path | None:
    env = os.environ.get("GF_WEB_PACK")
    if env:
        return Path(env)
    packs = sorted((ROOT / "build/web").glob("**/index.pck"), key=lambda p: p.stat().st_mtime)
    return packs[-1] if packs else None


# ---------------------------------------------------------------- the layout, from the repository


def test_project_names_the_default_bus_layout():
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    section = re.search(r"^\[audio\]\n(.*?)(?=^\[|\Z)", project, re.S | re.M)
    assert section, "project.godot has no [audio] section"
    m = re.search(r'^buses/default_bus_layout="([^"]+)"', section.group(1), re.M)
    assert m, "project.godot [audio] does not set buses/default_bus_layout"
    assert m.group(1) == "res://default_bus_layout.tres"
    assert (ROOT / m.group(1).removeprefix("res://")).is_file()


def test_layout_has_the_four_buses_sending_to_master():
    buses = layout_buses(LAYOUT.read_text(encoding="utf-8"))
    names = [buses[i]["name"].removeprefix("&").strip('"') for i in sorted(buses)]
    assert names == BUSES
    for i in sorted(buses):
        assert buses[i]["send"] == '&"Master"', buses[i]


def test_layout_carries_the_effects_the_feature_adopts():
    """audio_feature._make_buses() adopts a low-pass on Music and a reverb and limiter on SFX: shipped in
    the layout, none is added at runtime."""
    text = LAYOUT.read_text(encoding="utf-8")
    kinds = dict(re.findall(r'\[sub_resource type="(\w+)" id="(\w+)"', text))
    assert set(kinds) >= {"AudioEffectLowPassFilter", "AudioEffectReverb", "AudioEffectHardLimiter"}
    assert re.search(r"^bus/1/effect/0/effect = SubResource", text, re.M)
    assert re.search(r"^bus/2/effect/0/effect = SubResource", text, re.M)
    assert re.search(r"^bus/2/effect/1/effect = SubResource", text, re.M)


def test_layout_matches_the_banks_bus_names():
    bank = BANK.read_text(encoding="utf-8")
    found = re.findall(r'const BUS_\w+ := &"(\w+)"', bank)
    assert sorted(found) == sorted(BUSES)
    feature = (ROOT / "scripts/fp/audio/audio_feature.gd").read_text(encoding="utf-8")
    assert "BANK.BUS_MUSIC, BANK.BUS_SFX, BANK.BUS_AMBIENCE, BANK.BUS_UI" in feature


def test_no_runtime_bus_creation_outside_the_missing_bus_fallback():
    """The one add_bus call is the guarded fallback in _make_buses (it warns on the web)."""
    hits = []
    for p in (ROOT / "scripts").rglob("*.gd"):
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if "AudioServer.add_bus(" in line:
                hits.append(f"{p.relative_to(ROOT)}:{n}")
    assert hits == ["scripts/fp/audio/audio_feature.gd:" + hits[0].split(":")[1]], hits
    text = (ROOT / "scripts/fp/audio/audio_feature.gd").read_text(encoding="utf-8")
    assert "WebSupport.is_web()" in text.split("AudioServer.add_bus()")[0].split("func _make_buses")[1]


def test_every_banks_sound_has_a_source_in_the_repository():
    for name in bank_names(BANK.read_text(encoding="utf-8")):
        stem = ROOT / "sounds/fp" / name
        assert stem.with_suffix(".wav").is_file() or stem.with_suffix(".ogg").is_file(), name


def test_bank_names_parser_finds_every_group():
    names = bank_names(BANK.read_text(encoding="utf-8"))
    assert "engine_run" in names and "horn_short" in names
    assert "footstep_asphalt_1" in names and "footstep_splash_4" in names
    assert len(names) == len(set(names)) >= 90


# ---------------------------------------------------------------- the pack: parser on a synthetic pck


def write_pck(path: Path, files: dict) -> None:
    """A minimal Godot 4 pack (format 4, relative offsets, unencrypted) holding files {name: bytes}."""
    base = 112
    body = b""
    entries = []
    for name, data in files.items():
        raw = name.encode() + b"\0"
        raw += b"\0" * ((4 - len(raw) % 4) % 4)
        entries.append((raw, len(body), len(data)))
        body += data
    directory = struct.pack("<I", len(entries))
    for raw, off, size in entries:
        directory += struct.pack("<I", len(raw)) + raw + struct.pack("<QQ", off, size) + b"\0" * 16 + struct.pack("<I", 0)
    dir_offset = base + len(body)
    header = b"GDPC" + struct.pack("<IIIII", 4, 4, 7, 0, 2) + struct.pack("<QQ", base, dir_offset)
    header += b"\0" * (base - len(header))
    path.write_bytes(header + body + directory)


def test_pack_readers_on_a_synthetic_pack(tmp_path):
    pack = tmp_path / "t.pck"
    write_pck(pack, {"project.binary": b"ECFG...buses/default_bus_layout...res://default_bus_layout.tres", "a/b.ogg.import": b"x"})
    assert pack_names(pack) == ["project.binary", "a/b.ogg.import"]
    assert b"res://default_bus_layout.tres" in pack_setting_blob(pack)


# ---------------------------------------------------------------- the export, when there is one


@pytest.fixture(scope="module")
def pack() -> Path:
    p = find_pack()
    if p is None or not p.is_file():
        pytest.skip("no web export (set GF_WEB_PACK or run tools/export.sh web)")
    return p


def test_pack_ships_the_audio(pack):
    names = pack_names(pack)
    streams = [n for n in names if n.endswith(".oggvorbisstr")]
    assert len(streams) >= 120, len(streams)
    imports = {n for n in names if n.startswith("sounds/") and n.endswith(".ogg.import")}
    missing = [n for n in bank_names(BANK.read_text(encoding="utf-8")) if f"sounds/fp/{n}.ogg.import" not in imports]
    assert not missing, missing
    for stem in ("gridfall_nominal", "gridfall_blackout_crisis"):
        assert f"sounds/music/{stem}.ogg.import" in imports, stem


def test_pack_ships_the_default_bus_layout(pack):
    names = pack_names(pack)
    assert any("default_bus_layout" in n for n in names), "the layout is not in the pack"
    # The setting's default value is this very path, so project.binary does not list it: the file in
    # the pack is what makes the buses exist (tools/web_export.py stage_project copies it).
    blob = pack_setting_blob(pack)
    assert b"audio/buses/default_bus_layout" not in blob or b"res://default_bus_layout.tres" in blob


# ---------------------------------------------------------------- the probe's own tests


@needs_node
def test_probe_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", "--test-reporter=tap", "tools/tests/web_audio_probe.test.js"],
        cwd=ROOT, capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stdout[-3000:] + result.stderr[-1000:]
    assert re.search(r"^# fail 0$", result.stdout, re.M)
    assert not re.search(r"^# pass 0$", result.stdout, re.M)


@needs_node
def test_probe_script_parses():
    result = subprocess.run(["node", "--check", str(ROOT / "tools/web_audio_probe.js")], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr


def test_the_loader_shows_the_sound_banner():
    """tools/web_export.py patches the loader: a banner while the AudioContext is not running."""
    from tools.web_export import LOADER_AUDIO, LOADER_AUDIO_TEXT, LOADER_CSS

    assert LOADER_AUDIO_TEXT == "Sound is off - click or press any key"
    assert "#gf-sound" in LOADER_CSS and ".gf-on" in LOADER_CSS
    assert "state !== 'running'" in LOADER_AUDIO
    assert "AUDIO_GRACE_MS = 3000" in LOADER_AUDIO
    assert "resume()" in LOADER_AUDIO
    assert "window.gfAudioState" in LOADER_AUDIO
    json.dumps(LOADER_AUDIO)  # plain text


def test_the_export_stage_carries_the_layout(tmp_path):
    """The export stages named trees plus a few root files: the layout is one of them (it sits at the
    project root, where Godot's default for audio/buses/default_bus_layout looks)."""
    from tools.web_export import BUS_LAYOUT, stage_project

    root = tmp_path / "root"
    stage = tmp_path / "stage"
    (root / "sounds").mkdir(parents=True)
    stage.mkdir()
    (root / "project.godot").write_text("[application]\n")
    (root / "export_presets.cfg").write_text("[preset.2.options]\n")
    (root / BUS_LAYOUT).write_text(LAYOUT.read_text(encoding="utf-8"))
    stage_project(root, stage, ffmpeg="unused")
    assert (stage / BUS_LAYOUT).is_file()
    assert BUS_LAYOUT == "default_bus_layout.tres" == LAYOUT.name


def test_the_patched_loader_page_carries_the_sound_watch():
    """The watch ships in the page: after the Godot shell is patched, its AudioContext subclass is defined
    before the engine starts and the banner text is in the page once."""
    from tools.pytests.test_web_export import SHELL_STUB
    from tools.web_export import LOADER_AUDIO_TEXT, patch_loader_html

    page = patch_loader_html(SHELL_STUB)
    assert page.count(LOADER_AUDIO_TEXT) == 1
    # The script's top level runs before the start sequence at its tail (the stub's .then(engineStarted)).
    assert page.index("window.AudioContext = class") < page.index("engineStarted();\n\t\t}, displayFailureNotice")
    assert page.index("const AUDIO_GRACE_MS") > page.index("let veilReleased"), "the watch reads veilReleased"
    assert "NativeAudioContext" in page and "'pointerdown', 'keydown', 'touchstart'" in page
