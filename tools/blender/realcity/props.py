"""Street props at real-world scale (1 unit = 20 m), origin at the base centre, front = Godot +Z.

Poly Haven CC0 models (decimated, 512 px textures) are used for the hydrant, trash can, park bench,
planter box, concrete barrier, utility box, picnic table, air-con unit and boulder; the rest is
procedural. Lamp glass objects are named Bulb / Bulb_<n> so the game can make them glow."""

import math

from mathutils import Matrix, Vector

import core
from core import import_polyhaven, rotz
from indkit import T, beam
from nature import tree, hedge
from services import part

Z0 = 0.0


def _bulb(name, loc, fn):
    return part(name, loc, fn)


# ----------------------------------------------------------------------------- lighting

def lamp_street(c, seed=0):
    """Modern 8 m street light, arm over local -y (front)."""
    mb = c.mb
    h = 0.4
    mb.cyl((0, 0, 0), 0.008, 0.012, "Concrete", n=10)
    mb.lathe([(0.0045, 0.0), (0.0026, h)], "Metal_Galv", n=10, c=(0, 0, 0.012))
    beam(mb, (0.0, 0.0, h + 0.004), (0.0, -0.075, h + 0.016), 0.0042, 0.0042, "Metal_Galv")
    mb.box((0.0, -0.085, h + 0.015), (0.018, 0.045, 0.007), "Metal_Dark")
    mb.box((0.0, 0.0, 0.06), (0.012, 0.004, 0.02), "Metal_Dark")
    _bulb("Bulb", (0.0, -0.085, h + 0.0112), lambda mb: mb.box((0, 0, 0), (0.014, 0.036, 0.0015), "Lamp_Glow"))


def lamp_classic(c, seed=0):
    """Cast-iron heritage lamp post with a lantern."""
    mb = c.mb
    mb.lathe([(0.009, 0.0), (0.009, 0.01), (0.006, 0.016), (0.0045, 0.03), (0.0035, 0.2), (0.005, 0.205),
              (0.005, 0.21)], "Metal_Dark", n=10)
    for k in range(4):
        a = k * math.pi / 2
        beam(mb, (0, 0, 0.17), (math.cos(a) * 0.012, math.sin(a) * 0.012, 0.205), 0.0015, 0.0015, "Metal_Dark")
    mb.lathe([(0.006, 0.0), (0.013, 0.004)], "Metal_Dark", n=8, c=(0, 0, 0.21), smooth=False)
    mb.lathe([(0.016, 0.0), (0.004, 0.012), (0.0, 0.016)], "Metal_Dark", n=8, c=(0, 0, 0.245), smooth=False)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        mb.box((math.cos(a) * 0.012, math.sin(a) * 0.012, 0.23), (0.0018, 0.0018, 0.03), "Metal_Dark", rz=a)
    _bulb("Bulb", (0, 0, 0.214), lambda mb: mb.lathe([(0.0115, 0.0), (0.014, 0.031)], "Lamp_Glow", n=8, smooth=False,
                                                     cap_top=True, cap_bottom=True))


def lamp_double(c, seed=0):
    """Twin-arm boulevard light."""
    mb = c.mb
    h = 0.45
    mb.cyl((0, 0, 0), 0.009, 0.012, "Concrete", n=10)
    mb.lathe([(0.005, 0.0), (0.003, h)], "Metal_Dark", n=10, c=(0, 0, 0.012))
    for i, s in enumerate((-1, 1)):
        beam(mb, (0.0, 0.0, h + 0.006), (s * 0.07, 0.0, h + 0.02), 0.004, 0.004, "Metal_Dark")
        mb.box((s * 0.08, 0.0, h + 0.019), (0.04, 0.016, 0.007), "Metal_Dark")
        _bulb("Bulb_%d" % i, (s * 0.08, 0.0, h + 0.0152), lambda mb: mb.box((0, 0, 0), (0.034, 0.012, 0.0015),
                                                                          "Lamp_Glow"))


# ----------------------------------------------------------------------------- furniture

def bench_park(c, seed=0):
    import_polyhaven("painted_wooden_bench", name="bench_park")


def bench_modern(c, seed=0):
    mb = c.mb
    for xx in (-0.035, 0.035):
        mb.box((xx, 0, 0.011), (0.012, 0.022, 0.022), "Concrete_Light", skip=("-z",))
    for k in range(5):
        mb.box((0, -0.009 + k * 0.0045, 0.0235), (0.1, 0.0036, 0.003), "Wood")


def bus_stop(c, seed=0):
    """Glass shelter, open side toward Godot +Z (Blender -y)."""
    mb = c.mb
    W, D, H = 0.24, 0.075, 0.13
    mb.box2(-W / 2 - 0.01, -D / 2 - 0.02, 0.0, W / 2 + 0.01, D / 2 + 0.005, 0.004, "Concrete_Light", skip=("-z",))
    for x in (-W / 2, W / 2):
        for y in (-D / 2 + 0.003, D / 2 - 0.003):
            mb.box((x, y, H / 2), (0.004, 0.004, H), "Metal_Galv", skip=("-z",))
    # back glazing and one glazed side, an advertising light box on the other
    for (a, b, out) in (((-W / 2, D / 2 - 0.003), (W / 2, D / 2 - 0.003), (0, 1, 0)),
                        ((W / 2, -D / 2 + 0.003), (W / 2, D / 2 - 0.003), (1, 0, 0))):
        for o in (out, (-out[0], -out[1], 0)):
            mb.polyo([(a[0], a[1], 0.012), (b[0], b[1], 0.012), (b[0], b[1], H - 0.01), (a[0], a[1], H - 0.01)],
                     "Glass_Curtain", o)
    mb.box2(-W / 2 - 0.003, -D / 2 + 0.006, 0.012, -W / 2 + 0.003, D / 2 - 0.006, H - 0.012, "Metal_Dark",
            mats={"-x": "Lamp_Glow", "+x": "Sign_Blue"})
    mb.box2(-W / 2 - 0.008, -D / 2 - 0.012, H, W / 2 + 0.008, D / 2 + 0.004, H + 0.006, "Metal_Galv",
            mats={"-z": "Metal_White"})
    mb.box2(-W / 2 - 0.008, -D / 2 - 0.0125, H + 0.001, W / 2 + 0.008, -D / 2 - 0.012, H + 0.005, "Sign_Blue")
    # bench inside
    mb.box2(-W * 0.35, D / 2 - 0.022, 0.022, W * 0.35, D / 2 - 0.006, 0.026, "Wood")
    for x in (-W * 0.3, W * 0.3):
        mb.box2(x - 0.002, D / 2 - 0.02, 0.004, x + 0.002, D / 2 - 0.008, 0.022, "Metal_Dark", skip=("-z",))
    # stop sign pole
    px = W / 2 + 0.03
    mb.cyl((px, -D / 2 - 0.005, 0.004), 0.0018, 0.15, "Metal_Galv", n=6)
    mb.cyl((px, -D / 2 - 0.005, 0.15), 0.014, 0.003, "Sign_Green", n=14, axis=Matrix.Rotation(math.pi / 2, 4, "X"))
    mb.box((px, -D / 2 - 0.0085, 0.15), (0.012, 0.0008, 0.008), "Paint_Yellow")
    mb.box((px, -D / 2 - 0.006, 0.11), (0.018, 0.003, 0.03), "Sign_White")


def hydrant(c, seed=0):
    import_polyhaven("fire_hydrant", decimate=0.04, name="hydrant", keep=lambda n: "aged" not in n and "chain" not in n)


def trash_bin(c, seed=0):
    import_polyhaven("metal_trash_can", decimate=0.25, name="trash_bin", keep=lambda n: "rust" not in n)


def trash_bin_wheelie(c, seed=0):
    mb = c.mb
    mb.box2(-0.017, -0.019, 0.004, 0.017, 0.019, 0.05, "Plastic_Green", skip=("-z",))
    mb.box2(-0.019, -0.023, 0.05, 0.019, 0.021, 0.054, "Plastic_Green")
    mb.box2(-0.015, 0.019, 0.044, 0.015, 0.025, 0.048, "Plastic_Black")
    for s in (-1, 1):
        mb.cyl((s * 0.017 - (0.004 if s > 0 else 0.0), 0.016, 0.006), 0.006, 0.004, "Rubber", n=10,
               axis=Matrix.Rotation(math.pi / 2, 4, "Y"))


def planter_box(c, seed=0):
    import_polyhaven("planter_box_01", decimate=0.12, name="planter_box")
    for k in range(4):
        tree(c.mb, c.fol, -0.017 + k * 0.0115, 0.0, h=0.022, kind="shrub", seed=seed + k, z0=0.018)


def planter_round(c, seed=0):
    mb = c.mb
    mb.lathe([(0.016, 0.0), (0.022, 0.024), (0.024, 0.026), (0.02, 0.026), (0.02, 0.022)], "Concrete_Light", n=16)
    mb.cyl((0, 0, 0.004), 0.02, 0.018, "Dirt", n=16, caps=(False, True))
    tree(mb, c.fol, 0.0, 0.0, h=0.04, kind="shrub", seed=seed, z0=0.02)


def picnic_table(c, seed=0):
    import_polyhaven("wooden_picnic_table", decimate=0.2, name="picnic_table")


def utility_box(c, seed=0):
    import_polyhaven("utility_box_01", decimate=0.3, name="utility_box")


def aircon_unit(c, seed=0):
    import_polyhaven("exterior_aircon_unit", decimate=0.15, name="aircon_unit", keep=lambda n: "rusted" not in n)


def barrier_concrete(c, seed=0):
    import_polyhaven("concrete_road_barrier", decimate=0.02, name="barrier_concrete")


def rock_boulder(c, seed=0):
    import_polyhaven("rock_07", decimate=0.08, target_height=0.03, name="rock_boulder")


def cone(c, seed=0):
    mb = c.mb
    mb.box((0, 0, 0.001), (0.018, 0.018, 0.002), "Plastic_Black")
    mb.lathe([(0.008, 0.002), (0.0055, 0.012), (0.004, 0.018), (0.0015, 0.0355), (0.0, 0.036)], "Plastic_Orange",
             n=12, mats=["Plastic_Orange", "Reflective_White", "Plastic_Orange", "Plastic_Orange"])


def bollard(c, seed=0):
    mb = c.mb
    mb.lathe([(0.006, 0.0), (0.006, 0.04), (0.0045, 0.046), (0.0, 0.047)], "Metal_Dark", n=12,
             mats=["Metal_Dark", "Metal_Dark", "Metal_Dark"])
    mb.lathe([(0.0062, 0.033), (0.0062, 0.037)], "Reflective_White", n=12)


def mailbox(c, seed=0):
    mb = c.mb
    mb.box((0, 0, 0.0005), (0.03, 0.028, 0.001), "Concrete")
    for (x, y) in ((-0.009, -0.008), (0.009, -0.008), (0.009, 0.008), (-0.009, 0.008)):
        mb.box((x, y, 0.008), (0.002, 0.002, 0.016), "Metal_Blue", skip=("-z",))
    mb.box((0, 0, 0.028), (0.024, 0.022, 0.024), "Metal_Blue")
    mb.lathe([(0.0, -0.011), (0.011, -0.011), (0.011, 0.011), (0.0, 0.011)], "Metal_Blue", n=10,
             c=(0, 0, 0.04), axis=Matrix.Rotation(math.pi / 2, 4, "X"), a0=0, a1=math.pi)
    mb.box((0, -0.0115, 0.036), (0.012, 0.001, 0.002), "Metal_Dark")


def billboard(c, seed=0):
    """Roadside billboard facing Godot +Z; spotlight glass objects Bulb_0 / Bulb_1."""
    mb = c.mb
    W, Hb, z0 = 0.34, 0.15, 0.2
    for x in (-0.1, 0.1):
        mb.box2(x - 0.006, -0.006, 0.0, x + 0.006, 0.006, z0 + 0.02, "Metal_Galv", skip=("-z",))
        mb.box2(x - 0.012, -0.012, 0.0, x + 0.012, 0.012, 0.012, "Concrete")
    mb.box2(-W / 2 - 0.006, -0.004, z0 - 0.006, W / 2 + 0.006, 0.008, z0 + Hb + 0.006, "Metal_Dark")
    # poster: sky-blue field, product block and lettering
    yy = -0.0045
    mb.poly([(-W / 2, yy, z0), (W / 2, yy, z0), (W / 2, yy, z0 + Hb), (-W / 2, yy, z0 + Hb)], "Sign_Blue")
    mb.poly([(0.04, yy - 0.0004, z0 + 0.015), (0.15, yy - 0.0004, z0 + 0.015), (0.15, yy - 0.0004, z0 + 0.13),
             (0.04, yy - 0.0004, z0 + 0.13)], "Sign_Red")
    mb.poly([(0.065, yy - 0.0008, z0 + 0.035), (0.125, yy - 0.0008, z0 + 0.035), (0.125, yy - 0.0008, z0 + 0.11),
             (0.065, yy - 0.0008, z0 + 0.11)], "Sign_White")
    rnd = c.rnd
    for row, (zz, hh) in enumerate(((z0 + 0.1, 0.022), (z0 + 0.06, 0.012), (z0 + 0.035, 0.012))):
        x = -W / 2 + 0.02
        while x < 0.0:
            w = rnd.uniform(0.008, 0.016)
            mb.poly([(x, yy - 0.0006, zz), (x + w, yy - 0.0006, zz), (x + w, yy - 0.0006, zz + hh),
                     (x, yy - 0.0006, zz + hh)], "Sign_White" if row else "Paint_Yellow")
            x += w + 0.004
    # catwalk and lamp arms
    mb.box2(-W / 2, -0.03, z0 - 0.012, W / 2, 0.0, z0 - 0.008, "Grating")
    for i, x in enumerate((-0.09, 0.09)):
        beam(mb, (x, 0.006, z0 + Hb + 0.006), (x, -0.045, z0 + Hb + 0.03), 0.003, 0.003, "Metal_Dark")
        mb.box((x, -0.05, z0 + Hb + 0.03), (0.03, 0.012, 0.008), "Metal_Dark")
        _bulb("Bulb_%d" % i, (x, -0.05, z0 + Hb + 0.0258), lambda mb: mb.box((0, 0, 0), (0.026, 0.009, 0.0015),
                                                                          "Lamp_Glow"))


def fountain(c, seed=0):
    from services2 import fountain as ftn
    import services2
    services2.Z0 = 0.0
    ftn(c, 0.0, 0.0, 0.11)
    mb = c.mb
    mb.lathe([(0.115, 0.0), (0.125, 0.0), (0.125, 0.003), (0.115, 0.003)], "Stone_Facade", n=24, smooth=False)


# ----------------------------------------------------------------------------- vegetation

def _tree_prop(kind, h):
    def fn(c, seed=0):
        tree(c.mb, c.fol, 0.0, 0.0, h=h, kind=kind, seed=seed)
    return fn


def tree_bush(c, seed=0):
    for i, (x, y, h) in enumerate(((0.0, 0.0, 0.05), (0.03, 0.02, 0.035), (-0.028, 0.015, 0.03))):
        tree(c.mb, c.fol, x, y, h=h, kind="shrub", seed=seed + i)


def tree_hedge(c, seed=0):
    hedge(c.mb, c.fol, -0.08, 0.0, 0.08, 0.0, h=0.03, w=0.025, seed=seed)


REGISTRY = {
    "props/lamp_street": (lamp_street, {}),
    "props/lamp_classic": (lamp_classic, {}),
    "props/lamp_double": (lamp_double, {}),
    "props/bench_park": (bench_park, {}),
    "props/bench_modern": (bench_modern, {}),
    "props/bus_stop": (bus_stop, {}),
    "props/hydrant": (hydrant, {}),
    "props/trash_bin": (trash_bin, {}),
    "props/trash_bin_wheelie": (trash_bin_wheelie, {}),
    "props/planter_box": (planter_box, {}),
    "props/planter_round": (planter_round, {}),
    "props/picnic_table": (picnic_table, {}),
    "props/utility_box": (utility_box, {}),
    "props/aircon_unit": (aircon_unit, {}),
    "props/barrier_concrete": (barrier_concrete, {}),
    "props/rock_boulder": (rock_boulder, {}),
    "props/cone": (cone, {}),
    "props/bollard": (bollard, {}),
    "props/mailbox": (mailbox, {}),
    "props/billboard": (billboard, {}),
    "props/fountain": (fountain, {}),
    "props/tree_oak": (_tree_prop("broad", 0.42), {}),
    "props/tree_round": (_tree_prop("round", 0.4), {}),
    "props/tree_birch": (_tree_prop("birch", 0.4), {}),
    "props/tree_conifer": (_tree_prop("conifer", 0.44), {}),
    "props/tree_poplar": (_tree_prop("poplar", 0.46), {}),
    "props/tree_fern": (_tree_prop("fern", 0.36), {}),
    "props/tree_small": (_tree_prop("round", 0.24), {}),
    "props/tree_bush": (tree_bush, {}),
    "props/tree_hedge": (tree_hedge, {}),
}
