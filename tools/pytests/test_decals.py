"""The puddle decal textures keep a wet sheen without turning into sky mirrors.

Regression guard for the plaza-band report: a kerb chain of puddle decals at high wetness
mirrored the lilac dawn sky (ORM roughness 12/255, a perfect mirror) and read as a pale jagged
band on the ground. The generator (textures/real/decals/make_decals.py) now writes roughness
56/255 (~0.22): still wet, no longer a mirror.
"""
from pathlib import Path

from PIL import Image

DECALS = Path(__file__).parents[2] / "textures" / "real" / "decals"


def test_puddle_orm_roughness_is_sheen_not_mirror() -> None:
    im = Image.open(DECALS / "puddle_orm.png").convert("RGB")
    px = list(im.getdata())
    rough = sum(p[1] for p in px) / len(px)
    # 0.16..0.38: a wet sheen. Below ~0.1 the decal mirrors the sky (the band); near 1 it
    # would read as dry asphalt and the puddle would vanish.
    assert 40 <= rough <= 96, f"puddle_orm roughness channel {rough:.0f}/255"


def test_puddle_orm_has_full_ao_and_no_metal() -> None:
    im = Image.open(DECALS / "puddle_orm.png").convert("RGB")
    px = list(im.getdata())
    ao = sum(p[0] for p in px) / len(px)
    metal = sum(p[2] for p in px) / len(px)
    assert ao >= 250
    assert metal <= 8


def test_puddle_albedo_has_a_soft_alpha_edge() -> None:
    a = Image.open(DECALS / "puddle_0.png").convert("RGBA").getchannel("A")
    hist = a.histogram()
    total = sum(hist)
    soft = sum(hist[8:248])
    # The silhouette is a ~26 px gradient (mask slope 0.05 over 512 px): a soft edge, never
    # alpha-scissor. Scissor-sharp alpha (no mid values) would jag hard without MSAA.
    assert soft / total > 0.02, "puddle_0 alpha lost its soft edge"
    opaque = sum(hist[128:])
    assert 0.2 < opaque / total < 0.6, "puddle_0 blob footprint drifted"
