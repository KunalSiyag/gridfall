"""Textures and props nothing loads stay out of the repo and the web pack (materials unit G2).

The export packs every resource, so an unreferenced file is pure download. tools/dead_assets.py
finds them (it understands name tables, format strings, name + suffix joins and the textures Godot
extracts from a GLB); these tests pin its rules on a throwaway tree, pin the repo to zero dead
files, and pin the list this unit removed so none comes back or is loaded again by accident.
"""
from __future__ import annotations

import json
import struct
from pathlib import Path

import pytest

from tools import dead_assets

REPO = Path(__file__).parents[2]

# Removed by the materials unit. The four roughness maps were close to flat: dirt 0.944 (std 0.010),
# asphalt 0.770 (0.008), sidewalk 0.862 (0.015), grass 0.685 (0.021, range 0.58 to 0.80). Every
# material now takes a constant (scripts/world/surface_materials.gd), so grass goes from about 0.69
# to the 0.9 the brief asks for: a look change, not a lossless swap. The props had no loader: no
# name table, format string or prefix pool reaches them.
REMOVED_ROUGHNESS = [f"textures/real/{name}_rough.jpg" for name in ("grass", "dirt", "asphalt", "sidewalk")]
REMOVED_PROPS = [
    "models/real/props/aircon_unit.glb",
    "models/real/props/barrier_concrete.glb",
    "models/real/props/picnic_table.glb",
]
# Loaded by prefix: CityView._props("lamp") / ("tree") keep every lamp*.glb / tree*.glb of the real
# folder (and of models/props when the real folder has none). They were removed once by mistake,
# which silently reshuffled every lot corner lamp and tree pick. They must stay.
POOLED_PROPS = [
    "models/real/props/lamp_classic.glb",
    "models/real/props/lamp_double.glb",
    "models/real/props/lamp_street.glb",
    "models/real/props/tree_hedge.glb",
    "models/props/lamp_classic.glb",
    "models/props/lamp_modern.glb",
    "models/props/tree_cone.glb",
    "models/props/tree_tall.glb",
]
# Files Godot extracted from the removed models (<model>_<image>), gone with them.
REMOVED_PREFIXES = [
    "models/real/props/aircon_unit_",
    "models/real/props/barrier_concrete_",
    "models/real/props/picnic_table_",
]
# The code that loads assets by name. A removed file's name here would mean something loads it.
RUNTIME_TREES = ("scripts", "shaders", "scenes", "data")


def _glb(images: list[dict]) -> bytes:
    body = json.dumps({"asset": {"version": "2.0"}, "images": images}).encode()
    body += b" " * (-len(body) % 4)
    return b"glTF" + struct.pack("<II", 2, 20 + len(body)) + struct.pack("<I", len(body)) + b"JSON" + body


def _tree(root: Path, files: dict) -> Path:
    for rel, content in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
    return root


def test_scanner_understands_every_way_a_name_is_built(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "scripts/a.gd": (
                'const P := "res://textures/real/by_path.png"\n'
                'var a := TEX + "by_name.jpg"\n'
                'var d := "crack_%d" % i\n'
                'var m := _pbr("floor", Color.RED)\n'
                'var f := TEX + name + "_albedo.jpg"\n'
                'var bare := "%s/%s"\n'
            ),
            "textures/real/by_path.png": b"x",
            "textures/real/by_name.jpg": b"x",
            "textures/real/crack_0.png": b"x",
            "textures/real/crack_9.png": b"x",
            "textures/real/crackle.png": b"x",
            "textures/real/floor_albedo.jpg": b"x",
            "textures/real/floor_normal.jpg": b"x",
            "textures/real/orphan.jpg": b"x",
            "models/real/props/box.glb": _glb([{"name": "wood_diff", "mimeType": "image/jpeg", "bufferView": 0}]),
            "models/real/props/box_wood_diff.jpg": b"x",
            "models/real/props/box_stray.jpg": b"x",
        },
    )
    result = dead_assets.scan(root, ("textures", "models/real/props"))
    used = result["used"]
    assert used["textures/real/by_path.png"] == "path"
    assert used["textures/real/by_name.jpg"] == "name"
    assert used["textures/real/crack_0.png"] == "format"
    assert used["textures/real/crack_9.png"] == "format"
    assert used["textures/real/floor_albedo.jpg"] == "parts"
    assert used["models/real/props/box_wood_diff.jpg"] == "glb"
    # Not built by anything: the format needs digits, "floor" has no _normal suffix literal, and a
    # bare "%s/%s" names nothing.
    assert sorted(result["dead"]) == [
        "models/real/props/box.glb",
        "models/real/props/box_stray.jpg",
        "textures/real/crackle.png",
        "textures/real/floor_normal.jpg",
        "textures/real/orphan.jpg",
    ]


def test_scanner_reads_prefix_pools_as_used(tmp_path: Path) -> None:
    """A folder listed by name prefix keeps every model that starts with it (the lot props)."""
    root = _tree(
        tmp_path,
        {
            "scripts/view.gd": (
                'const C_PROPS := ["lamp", "bench", "ab"]\n'
                'const I_PROPS: Array = ["hydrant"]\n'
                "func f():\n"
                '\tvar a := _props("tree")\n'
                '\tvar b := _list_glbs(R + "props/", "shrub")\n'
                '\tvar c := _list_glbs(R + "props/", "")\n'
            ),
            "models/props/lamp_one.glb": b"x",
            "models/props/lamp_two.glb": b"x",
            "models/props/hydrant_a.glb": b"x",
            "models/props/tree_oak.glb": b"x",
            "models/props/shrub_x.glb": b"x",
            "models/props/ab_short.glb": b"x",
            "models/props/barrel.glb": b"x",
            "models/props/lamppost.png": b"x",
        },
    )
    result = dead_assets.scan(root, ("models/props",))
    used = result["used"]
    for name in ("lamp_one", "lamp_two", "hydrant_a", "tree_oak", "shrub_x"):
        assert used[f"models/props/{name}.glb"] == "pool", name
    # Too short a prefix ("ab"), an empty prefix, a model nothing names and a non-model all stay dead.
    assert sorted(result["dead"]) == [
        "models/props/ab_short.glb",
        "models/props/barrel.glb",
        "models/props/lamppost.png",
    ]


def test_scanner_ignores_unreadable_models_and_huge_data(tmp_path: Path) -> None:
    big = "x" * (dead_assets.MAX_SOURCE_BYTES + 1) + " seen.png"
    root = _tree(
        tmp_path,
        {
            "data/recorded.json": big,
            "textures/seen.png": b"x",
            "models/props/broken.glb": b"not a glb",
        },
    )
    result = dead_assets.scan(root, ("textures", "models/props"))
    assert sorted(result["dead"]) == ["models/props/broken.glb", "textures/seen.png"]


def test_cli_reports_and_exits_nonzero_on_dead_files(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    root = _tree(tmp_path, {"textures/lost.png": b"abc", "scripts/a.gd": "var x := 1\n"})
    assert dead_assets.main(["--root", str(root), "--tree", "textures"]) == 1
    out = capsys.readouterr().out
    assert "textures/lost.png" in out and "1 dead" in out
    (root / "scripts" / "a.gd").write_text('var t := "lost.png"\n')
    assert dead_assets.main(["--root", str(root), "--tree", "textures"]) == 0


def test_repo_has_no_dead_textures_or_props() -> None:
    result = dead_assets.scan(REPO)
    assert result["dead"] == [], "unreferenced assets ship in the web pack: " + ", ".join(result["dead"])


@pytest.mark.parametrize("rel", POOLED_PROPS)
def test_pooled_props_stay(rel: str) -> None:
    assert (REPO / rel).is_file(), f"{rel} is picked by a prefix pool in CityView"


def test_repo_pools_include_the_lot_props() -> None:
    """The scanner sees the pools of the real CityView, so it can never call these models dead."""
    used = dead_assets.scan(REPO)["used"]
    for rel in POOLED_PROPS:
        assert used[rel] in ("pool", "name", "path"), rel


@pytest.mark.parametrize("rel", REMOVED_ROUGHNESS + REMOVED_PROPS)
def test_removed_files_stay_removed(rel: str) -> None:
    assert not (REPO / rel).exists(), f"{rel} came back"
    assert not (REPO / (rel + ".import")).exists(), f"{rel}.import came back"


@pytest.mark.parametrize("prefix", REMOVED_PREFIXES)
def test_removed_models_leave_no_extracted_textures(prefix: str) -> None:
    folder = REPO / Path(prefix).parent
    assert not [p.name for p in folder.glob(Path(prefix).name + "*")], f"{prefix}* came back"


def test_nothing_loads_a_removed_file() -> None:
    names = [Path(rel).name for rel in REMOVED_ROUGHNESS + REMOVED_PROPS]
    # A bare stem would also match prose; the file name (with its extension) is what a loader spells.
    hits: list[str] = []
    for tree in RUNTIME_TREES:
        for path in (REPO / tree).rglob("*"):
            if not path.is_file() or path.suffix not in dead_assets.SOURCE_EXT:
                continue
            if path.stat().st_size > dead_assets.MAX_SOURCE_BYTES:
                continue
            text = path.read_text(errors="ignore")
            hits += [f"{path.relative_to(REPO)}: {name}" for name in names if name in text]
    assert hits == []


def test_ground_materials_take_constant_roughness() -> None:
    """No code asks for a roughness map any more: the loaders for them were removed with the files."""
    for tree in ("scripts", "shaders"):
        for path in (REPO / tree).rglob("*"):
            if path.suffix in (".gd", ".gdshader"):
                assert '"_rough.jpg"' not in path.read_text(errors="ignore"), path
