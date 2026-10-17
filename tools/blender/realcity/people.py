"""Pedestrians at real scale (1.75 m ~ 0.0875 units; the game draws them at 1.5x).

Each person uses the material names Shirt, Pants, Skin and Hair (plus Shoes and small extras), so
the game can recolour them; every file bakes its own palette into those materials. Front = -Y.
Mid-stride pose: left leg forward, right arm forward."""

import math

from mathutils import Matrix, Vector

import core
from core import M
from indkit import tube
from vehicles import finish

S = M


def _flat(col, rough=0.8):
    return ("flat", col, rough, 0.0, {})


def _lathe(mb, prof, mats, c=(0, 0, 0), sy=0.62, n=12):
    mb.push(Matrix.Translation(Vector((c[0] * S, c[1] * S, c[2] * S))) @ Matrix.Diagonal((1, sy, 1, 1)))
    mb.lathe([(r * S, z * S) for r, z in prof], mats[0], n=n, mats=mats, cap_top=False)
    mb.pop()


def person(c, shirt, pants, skin, hair, shoes=(0.05, 0.045, 0.04), sleeves="short", legs="trousers",
           hair_style="short", hat=None, pack=None, coat=False):
    core.material("Shirt", override=_flat(shirt))
    core.material("Pants", override=_flat(pants))
    core.material("Skin", override=_flat(skin, 0.55))
    core.material("Hair", override=_flat(hair, 0.6))
    core.material("Shoes", override=_flat(shoes, 0.5))
    mb = c.mb
    stride = 0.09
    # legs and shoes
    for sd, fwd in ((-1, -1), (1, 1)):
        x = sd * 0.095
        y = fwd * stride
        lower = "Skin" if legs in ("shorts", "skirt") else "Pants"
        upper = "Skin" if legs == "skirt" else "Pants"
        top = (x * 0.9, 0.0, 0.9)
        knee = (x, y * 0.55, 0.48)
        ankle = (x, y, 0.09)
        tube(mb, [v * S for v in ankle], [v * S for v in knee], 0.052 * S, lower, n=8)
        tube(mb, [v * S for v in knee], [v * S for v in top], 0.075 * S, upper, n=8)
        mb.sphere([v * S for v in knee], 0.058 * S, upper if legs != "shorts" else "Skin", n=8, rings=4)
        mb.box2((x - .05) * S, (y - .17) * S, 0, (x + .05) * S, (y + .08) * S, .085 * S, "Shoes")
    # hips and torso (shirt over the waist)
    if legs == "skirt" or coat:
        zb = 0.48 if legs == "skirt" else 0.62
        mat = "Pants" if legs == "skirt" else "Shirt"
        _lathe(mb, [(0.25, zb), (0.2, 0.92)], [mat])
    _lathe(mb, [(0.17, 0.82), (0.18, 0.95)], ["Pants"])
    _lathe(mb, [(0.18, 0.93), (0.17, 1.08), (0.18, 1.28), (0.2, 1.42), (0.13, 1.5), (0.06, 1.53)],
           ["Shirt"] * 5)
    # neck, head, face hint
    mb.cyl((0, 0, 1.48 * S), 0.05 * S, 0.12 * S, "Skin", n=8)
    mb.sphere((0, 0, 1.69 * S), 0.105 * S, "Skin", n=12, rings=8, scale=(0.9, 1.0, 1.12))
    mb.box((0, -0.1 * S, 1.67 * S), (0.03 * S, 0.03 * S, 0.05 * S), "Skin")
    # hair
    if hair_style != "none":
        mb.push(Matrix.Translation(Vector((0, 0.012 * S, 1.71 * S))))
        mb.sphere((0, 0, 0), 0.112 * S, "Hair", n=12, rings=8, scale=(0.93, 1.02, 1.05), hemi=True)
        mb.pop()
        if hair_style == "long":
            mb.box((0, 0.06 * S, 1.56 * S), (0.2 * S, 0.06 * S, 0.3 * S), "Hair")
        elif hair_style == "ponytail":
            tube(mb, (0, 0.11 * S, 1.72 * S), (0, 0.16 * S, 1.5 * S), 0.035 * S, "Hair", n=6)
    if hat == "cap":
        mb.cyl((0, 0.01 * S, 1.76 * S), 0.11 * S, 0.06 * S, "Hat", n=12)
        mb.box((0, -0.12 * S, 1.77 * S), (0.18 * S, 0.1 * S, 0.012 * S), "Hat")
    elif hat == "helmet":
        mb.sphere((0, 0.005 * S, 1.73 * S), 0.125 * S, "Hat", n=12, rings=8, scale=(0.95, 1.05, 0.95), hemi=True)
        mb.cyl((0, 0.005 * S, 1.725 * S), 0.135 * S, 0.012 * S, "Hat", n=12)
    elif hat == "fedora":
        mb.cyl((0, 0.01 * S, 1.76 * S), 0.17 * S, 0.012 * S, "Hat", n=12)
        mb.cyl((0, 0.01 * S, 1.77 * S), 0.1 * S, 0.09 * S, "Hat", n=12, r2=0.09 * S)
    if pack:
        mb.box((0, 0.16 * S, 1.22 * S), (0.26 * S, 0.12 * S, 0.34 * S), "Bag")
    # arms (swing opposite to the legs)
    for sd, fwd in ((-1, 1), (1, -1)):
        sh = (sd * 0.215, 0.0, 1.42)
        el = (sd * 0.245, fwd * 0.07, 1.14)
        wr = (sd * 0.25, fwd * 0.16, 0.9)
        tube(mb, [v * S for v in sh], [v * S for v in el], 0.048 * S, "Shirt", n=8)
        mb.sphere([v * S for v in sh], 0.055 * S, "Shirt", n=8, rings=4)
        fore = "Shirt" if sleeves == "long" else "Skin"
        tube(mb, [v * S for v in el], [v * S for v in wr], 0.04 * S, fore, n=8)
        mb.sphere([v * S for v in el], 0.044 * S, fore, n=8, rings=4)
        mb.sphere([v * S for v in (wr[0], wr[1], wr[2] - 0.05)], 0.05 * S, "Skin", n=8, rings=4,
                  scale=(0.7, 0.9, 1.2))
    finish(c, "person", angle=60)


def _p(**kw):
    def fn(c):
        extra = {"Hat": kw.pop("hat_col", (0.1, 0.1, 0.12)), "Bag": kw.pop("bag_col", (0.08, 0.1, 0.14))}
        for k, v in extra.items():
            core.material(k, override=_flat(v, 0.6))
        person(c, **kw)
    return (fn, {})


SKINS = [(0.86, 0.66, 0.53), (0.62, 0.42, 0.30), (0.36, 0.23, 0.15), (0.78, 0.56, 0.42), (0.92, 0.74, 0.62)]

REGISTRY = {
    "people/person_a": _p(shirt=(0.12, 0.25, 0.55), pants=(0.08, 0.10, 0.16), skin=SKINS[0], hair=(0.18, 0.11, 0.06)),
    "people/person_b": _p(shirt=(0.62, 0.08, 0.10), pants=(0.05, 0.07, 0.16), skin=SKINS[3], hair=(0.04, 0.03, 0.025),
                          legs="skirt", hair_style="long"),
    "people/person_c": _p(shirt=(0.28, 0.30, 0.32), pants=(0.45, 0.38, 0.25), skin=SKINS[2], hair=(0.02, 0.02, 0.02),
                          sleeves="long"),
    "people/person_d": _p(shirt=(0.10, 0.40, 0.25), pants=(0.12, 0.17, 0.32), skin=SKINS[1], hair=(0.75, 0.6, 0.32),
                          sleeves="long", hair_style="ponytail"),
    "people/person_e": _p(shirt=(0.70, 0.62, 0.48), pants=(0.25, 0.18, 0.12), skin=SKINS[4], hair=(0.55, 0.55, 0.55),
                          sleeves="long", hat="fedora", hat_col=(0.15, 0.12, 0.1), coat=True),
    "people/person_f": _p(shirt=(0.88, 0.88, 0.86), pants=(0.22, 0.28, 0.20), skin=SKINS[1], hair=(0.03, 0.025, 0.02),
                          legs="shorts", pack=True, bag_col=(0.6, 0.15, 0.08)),
    "people/person_g": _p(shirt=(0.85, 0.62, 0.12), pants=(0.03, 0.03, 0.04), skin=SKINS[0], hair=(0.45, 0.14, 0.05),
                          sleeves="long", coat=True, hair_style="long"),
    "people/person_h": _p(shirt=(0.95, 0.42, 0.04), pants=(0.10, 0.11, 0.14), skin=SKINS[3], hair=(0.1, 0.07, 0.04),
                          hat="helmet", hat_col=(0.92, 0.75, 0.05), hair_style="none"),
}
