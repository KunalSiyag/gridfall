"""The wet-ground shaders sheen where water stands instead of mirroring the sky.

Regression guard for the plaza-band report: on the web GL build at grazing angles, the road
shader's pool mask (jagged fbm, wetness-gated) dropped ROUGHNESS to 0.03 with a 90%-flattened
normal, so each pool pixel sampled the sky — a pale jagged band winding along the carriageway
that flickered as the mask aliased. ground_detail had the same mirror in track ruts (0.05).
The pools must stay a sheen (>= 0.2): low enough to read as standing water against the
surrounding wet surface, never low enough to mirror.
"""
import re
from pathlib import Path

SHADERS = Path(__file__).parents[2] / "shaders"


def _pool_floor(source: str, pattern: str) -> float:
    m = re.search(pattern, source)
    assert m, "pool roughness line not found — the wet-pool feature moved; update this guard"
    return float(m.group(1))


def test_road_pools_sheen_not_mirror() -> None:
    src = (SHADERS / "road_fp.gdshader").read_text()
    floor = _pool_floor(src, r"mix\(ROUGHNESS, ([\d.]+), pool\)")
    assert 0.2 <= floor <= 0.4, f"road pool roughness floor {floor}"
    flatten = _pool_floor(src, r"pool \* ([\d.]+)\)")
    assert flatten <= 0.6, f"road pool normal flatten {flatten} kills the asphalt detail"


def test_ground_rut_puddles_sheen_not_mirror() -> None:
    src = (SHADERS / "ground_detail.gdshader").read_text()
    floor = _pool_floor(src, r"mix\(rough, ([\d.]+), puddle \* wetness")
    assert 0.18 <= floor <= 0.4, f"ground rut puddle roughness floor {floor}"
