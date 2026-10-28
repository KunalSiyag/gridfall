"""Option A split-pack closure: boot never statically depends on a background pack.

The split web build ships boot assets in the engine PCK and the decorative packs
(models, sky, posters, audio, ...) as background downloads. A static reference from
boot-classified content to a background-pack asset would either break the boot or
silently poison the loader caches, so this file pins the closure:

- every source tree classifies to the pack the Phase B plan assigns it (Option A:
  zones, service geometry, hero and gameplay collision stay in boot);
- no .gd/.tscn/.tres references a resource of another pack (preloads, class-level
  loads and scene ext_resources included) — dynamic loads go through the
  WebPackStream request gate instead;
- the export PACK_RULES pack set matches the runtime WebPackStream.DEFAULT_ORDER,
  so no pack silently queues in the unknown-tail slot.
"""
import re
from pathlib import Path

from tools.web_export import BOOT_PATHS, PACK_RULES, pack_of

ROOT = Path(__file__).resolve().parent.parent.parent


def project_files(suffixes: tuple[str, ...]):
    return [
        p for p in ROOT.rglob("*")
        if p.suffix in suffixes and ".godot" not in p.parts and "build" not in p.parts
    ]


def test_option_a_classification():
    # Zones and the service geometry the first view needs ride in boot (Option A).
    for path in (
        "models/real/zones/r1/house.glb",
        "models/zones/c2/block.glb",
        "models/real/buildings/tower.glb",
        "models/real/street/sidewalk_concrete_diff.jpg",
        "textures/real/grass_albedo.jpg",
        "fonts/Inter.ttf",
        "sounds/ui/click.ogg",
        "scripts/main.gd",
        "data/feature_flags.json",
    ):
        assert pack_of(path) == "boot", path
    # The decorative packs land in the background.
    assert pack_of("env/sky.hdr") == "sky"
    assert pack_of("sounds/music/theme.ogg") == "audio"
    assert pack_of("sounds/fp/footstep.ogg") == "audio"
    assert pack_of("assets/posters/ad.webp") == "posters"
    assert pack_of("models/real/props/bin.glb") == "props"
    assert pack_of("models/real/vehicles/car.glb") == "traffic"
    assert pack_of("models/characters/bodies/Office_Male_01.glb") == "people"
    assert pack_of("models/real/animals/dog.glb") == "wildlife"
    assert pack_of("models/real/midlod/tower.res") == "midlod"
    # Boot paths win over any prefix rule (the hero bodies are inside people/).
    for path in BOOT_PATHS:
        assert pack_of(path) == "boot", path


def test_no_cross_pack_static_references():
    scene_ref = re.compile(r'path="(res://[^"]+)"')
    code_ref = re.compile(r'\b(?:preload|load)\(\s*"(res://[^"]+)"\s*\)')
    offenders = []
    for path in project_files((".gd", ".tscn", ".tres")):
        source_pack = pack_of(str(path.relative_to(ROOT)))
        text = path.read_text(encoding="utf-8", errors="replace")
        found = scene_ref.findall(text) if path.suffix != ".gd" else code_ref.findall(text)
        for ref in set(found):
            target = ref[len("res://"):]
            target_pack = pack_of(target)
            if target_pack != source_pack:
                offenders.append(f"{path.relative_to(ROOT)} ({source_pack}) -> {target} ({target_pack})")
    assert offenders == [], "static cross-pack references break the split build:\n" + "\n".join(offenders)


def test_pack_rules_match_coordinator_default_order():
    stream = (ROOT / "scripts/ops/web_pack_stream.gd").read_text(encoding="utf-8")
    match = re.search(r"DEFAULT_ORDER(?::\s*Array\[String\])?\s*=\s*\[([^\]]*)\]", stream)
    assert match, "WebPackStream.DEFAULT_ORDER not found"
    order = re.findall(r'"(\w+)"', match.group(1))
    rule_packs = {name for name, _ in PACK_RULES}
    assert rule_packs <= set(order), (
        f"packs {sorted(rule_packs - set(order))} would queue in the unknown tail"
    )
