"""Residential r2 (walk-ups, townhouses, mid-rise) and r3 (towers)."""

import math

from mathutils import Matrix, Vector

import arch
from arch import FH, Win, block, flat_roof, gable_roof, hip_roof, facade, lot, pad
from nature import tree


def _street_lot(c, trees=((-0.4, -0.42), (0.4, -0.42)), seed=0, mat="Sidewalk"):
    lot(c, mat)
    for i, (x, y) in enumerate(trees):
        arch.tree_pit(c, x, y, h=c.rnd.uniform(0.38, 0.5), kind=c.rnd.choice(["broad", "round"]), seed=seed + i)


def _ground_kinds(entry_bay, shop=False):
    def k(side, fi, bi):
        if fi == 0 and side == "S":
            if bi == entry_bay:
                return "door"
            return "shop" if shop else "win"
        return "win"
    return k


def cornice(c, x0, y0, x1, y1, z, mat="Trim_Stone", h=0.012, out=0.008):
    mb = c.mb
    mb.box2(x0 - out * 0.5, y0 - out * 0.5, z, x1 + out * 0.5, y1 + out * 0.5, z + h * 0.4, mat)
    mb.box2(x0 - out, y0 - out, z + h * 0.4, x1 + out, y1 + out, z + h, mat)


def balcony_band(c, x0, x1, y, z, depth=0.03, rail="Glass", side_sign=-1):
    """Continuous balcony slab + rail along a south-facing (y plane) facade."""
    mb = c.mb
    yf = y - depth
    mb.box2(x0, yf, z - 0.005, x1, y, z, "Concrete_Light")
    hgt = 0.05
    if rail == "Glass":
        mb.poly([(x0, yf, z), (x1, yf, z), (x1, yf, z + hgt), (x0, yf, z + hgt)], "Glass_Curtain")
        mb.poly([(x1, yf + 0.0005, z), (x0, yf + 0.0005, z), (x0, yf + 0.0005, z + hgt), (x1, yf + 0.0005, z + hgt)],
                "Glass_Curtain")
        mb.box2(x0, yf - 0.001, z + hgt, x1, yf + 0.0015, z + hgt + 0.002, "Frame_Alu")
    else:
        mb.box2(x0, yf, z, x1, yf + 0.004, z + hgt, rail)


def walkup_brick(c, wall="Brick_Red", floors_n=5, door="Door_Green", tank=True, seed=0):
    c.door_mat = door
    _street_lot(c, seed=seed)
    x0, x1, y0, y1 = -0.36, 0.36, -0.3, 0.3
    base = 0.01
    c.mb.box2(x0 - 0.004, y0 - 0.004, 0.0, x1 + 0.004, y1 + 0.004, base, "Stone_Facade", skip=("-z",))
    fl = [(base + i * FH, base + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.06, h=0.09, sill=0.04, frame="Frame_White", bay=0.12, transom=True, sill_mat="Trim_Stone",
            lintel="Trim_Stone")
    block(c, x0, y0, x1, y1, fl, w, wall, _ground_kinds(2))
    top = base + floors_n * FH
    arch.band(c, x0, y0, x1, y1, base + FH - 0.004, 0.008, "Trim_Stone", out=0.003)
    cornice(c, x0, y0, x1, y1, top, h=0.014, out=0.01)
    flat_roof(c, x0, y0, x1, y1, top + 0.014, roof="Roof_Flat", parapet=0.012, pmat=wall)
    # entrance canopy and stoop
    c.mb.box2(-0.05, y0 - 0.035, base + 0.118, 0.05, y0, base + 0.124, "Metal_Dark")
    c.mb.box2(-0.04, y0 - 0.03, 0.0, 0.04, y0, base, "Stone_Facade", skip=("-z",))
    arch.fire_escape(c, 0.12, 0.33, y0, fl)
    zr = top + 0.014
    if tank:
        arch.water_tank(c, -0.2, 0.12, zr, r=0.045, h=0.06)
    arch.bulkhead(c, 0.15, 0.15, zr, mat=wall)
    arch.hvac(c, -0.02, -0.15, zr, 0.06, 0.04, 0.03)
    arch.hvac(c, 0.22, -0.18, zr, 0.04, 0.04, 0.03)
    arch.antenna(c, 0.28, 0.24, zr, 0.08)


def townhouse_row(c, seed=0):
    _street_lot(c, trees=((-0.42, -0.43), (0.0, -0.43), (0.42, -0.43)), seed=seed)
    walls = ["Brick_Orange", "Plaster_Cream", "Brick_Dark", "Plaster_Blue"]
    doors = ["Door_Black", "Door_Red", "Door_Green", "Door_Blue"]
    y0, y1 = -0.26, 0.3
    base = 0.016
    for i in range(4):
        x0 = -0.44 + i * 0.22
        x1 = x0 + 0.22
        n = 4 if i % 2 == 0 else 5
        c.door_mat = doors[i]
        c.mb.box2(x0, y0 - 0.003, 0.0, x1, y1, base, "Stone_Facade", skip=("-z",))
        fl = [(base + k * FH, base + (k + 1) * FH) for k in range(n)]
        w = Win(w=0.055, h=0.095, sill=0.035, frame="Frame_White", bay=0.073, transom=True, sill_mat="Trim_Stone",
                lintel="Trim_Stone" if "Brick" in walls[i] else None)
        sides = "SN" + ("W" if i == 0 else "") + ("E" if i == 3 else "")
        block(c, x0, y0, x1, y1, fl, w, walls[i], lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 0) else "win",
              sides=sides)
        top = base + n * FH
        cornice(c, x0 + 0.004, y0, x1 - 0.004, y1, top, mat="Trim_White", h=0.012, out=0.008)
        # mansard roof with dormers
        mz = top + 0.012
        mh = 0.09
        ins = 0.035
        mb = c.mb
        mb.poly([(x0, y0, mz), (x1, y0, mz), (x1, y0 + ins, mz + mh), (x0, y0 + ins, mz + mh)], "Roof_Slate")
        mb.poly([(x1, y1, mz), (x0, y1, mz), (x0, y1 - ins, mz + mh), (x1, y1 - ins, mz + mh)], "Roof_Slate")
        mb.poly([(x0, y0 + ins, mz + mh), (x1, y0 + ins, mz + mh), (x1, y1 - ins, mz + mh), (x0, y1 - ins, mz + mh)],
                "Roof_Flat")
        for xx, s in ((x0, -1), (x1, 1)):
            mb.polyo([(xx, y0, mz), (xx, y1, mz), (xx, y1 - ins, mz + mh), (xx, y0 + ins, mz + mh)], walls[i], (s, 0, 0))
        dx = (x0 + x1) / 2
        mb.box2(dx - 0.03, y0 + 0.005, mz, dx + 0.03, y0 + 0.03, mz + 0.065, "Trim_White", skip=("-z",))
        facade(c, (dx - 0.03, y0 + 0.005, 0), 0.0, 0.06, [(mz, mz + 0.06)],
               Win(w=0.035, h=0.045, sill=0.008, frame="Frame_White", bay=0.06), "Trim_White", n_bays=1)
        arch.chimney(c, x0 + 0.02, y1 - 0.08, mz + mh, mz + mh + 0.05, mat="Brick_Old")
        # stoop with railings
        sx = x0 + 0.037
        for k in range(4):
            mb.box2(sx - 0.03, y0 - 0.06 + k * 0.012, 0.0, sx + 0.03, y0, base * (k + 1) / 4 + 0.002, "Stone_Facade",
                    skip=("-z",))
        for xx in (sx - 0.03, sx + 0.03):
            mb.box2(xx - 0.001, y0 - 0.06, base + 0.03, xx + 0.001, y0, base + 0.033, "Metal_Dark")
        # front area railing
        mb.box2(sx + 0.035, y0 - 0.05, 0.0, x1 - 0.005, y0 - 0.047, 0.03, "Metal_Dark", skip=("-z",))


def euro_apartment(c, wall="Plaster_Ochre", roof="Roof_Clay", floors_n=6, seed=0):
    c.door_mat = "Door_Wood" if False else "Door_Black"
    _street_lot(c, seed=seed)
    x0, x1, y0, y1 = -0.4, 0.4, -0.28, 0.28
    base = 0.01
    c.mb.box2(x0 - 0.004, y0 - 0.004, 0.0, x1 + 0.004, y1 + 0.004, base + FH * 0.0 + 0.004, "Stone_Facade", skip=("-z",))
    fl = [(base + i * FH, base + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.055, h=0.1, sill=0.03, frame="Frame_White", bay=0.115, transom=True, shutters="Frame_Wood",
            sill_mat="Trim_White", balcony=0.026, rail="Metal_Dark")

    def kinds(s, fi, bi):
        if fi == 0:
            return "door" if (s == "S" and bi == 3) else ("shop" if s == "S" and bi in (0, 6) else "win")
        if s in "SN" and bi in (1, 5) and fi < floors_n:
            return "balc"
        return "win"
    block(c, x0, y0, x1, y1, fl, w, wall, kinds)
    # rusticated ground floor band
    c.mb.box2(x0 - 0.003, y0 - 0.003, base, x1 + 0.003, y0, base + 0.004, "Stone_Facade")
    arch.band(c, x0, y0, x1, y1, base + FH - 0.004, 0.008, "Trim_White", out=0.004)
    top = base + floors_n * FH
    cornice(c, x0, y0, x1, y1, top, mat="Trim_White", h=0.012, out=0.009)
    zr = hip_roof(c, x0, y0, x1, y1, top + 0.012, 0.16, roof, oh=0.012, gutter="Metal_Galv", fascia="Trim_White")
    for xx in (-0.25, 0.05, 0.28):
        arch.chimney(c, xx, 0.08, top + 0.012, top + 0.16, mat=wall)
    arch.awning(c, -0.4 + 0.012, -0.4 + 0.1, y0, base + 0.112, mat="Fabric_Green")
    arch.awning(c, 0.4 - 0.1, 0.4 - 0.012, y0, base + 0.112, mat="Fabric_Green")


def modern_midrise(c, floors_n=7, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    pad(c, -0.46, 0.2, 0.46, 0.46, "Grass")
    for i, x in enumerate((-0.38, -0.1, 0.2, 0.4)):
        tree(c.mb, c.fol, x, 0.37, h=0.4 + 0.05 * (i % 2), kind="fern" if i % 2 else "broad", seed=seed + i, z0=0.005)
    x0, x1, y0, y1 = -0.42, 0.42, -0.24, 0.16
    base = 0.006
    fl = [(base + i * FH, base + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.08, h=0.11, sill=0.012, depth=0.006, frame="Frame_Dark", fw=0.003, bay=0.105, sill_mat=None,
            mullion=True)

    def kinds(s, fi, bi):
        if fi == 0 and s == "S":
            return "door" if bi == 4 else "shop"
        if s == "S":
            return "tall"
        if s == "N":
            return "win" if bi % 2 else "tall"
        return "win" if bi % 2 == 0 else "wall"
    block(c, x0, y0, x1, y1, fl, w, "Plaster_White", kinds)
    # timber-clad end bays
    for xx0, xx1 in ((x0 - 0.0015, x0 + 0.105), (x1 - 0.105, x1 + 0.0015)):
        c.mb.box2(xx0, y0 - 0.0015, base + FH, xx1, y0 + 0.001, base + floors_n * FH, "Wood", skip=("+y",))
    for k in range(1, floors_n):
        balcony_band(c, x0 + 0.105, x1 - 0.105, y0, base + k * FH + 0.003, depth=0.035)
    top = base + floors_n * FH
    flat_roof(c, x0, y0, x1, y1, top, roof="Roof_Gravel", parapet=0.012, pmat="Plaster_White", cap="Metal_Galv")
    arch.solar_array(c, x0 + 0.05, y0 + 0.04, x0 + 0.4, y1 - 0.04, top, rows=3, tilt=15)
    arch.bulkhead(c, 0.18, 0.0, top, 0.09, 0.08, 0.05, mat="Plaster_White")
    arch.hvac(c, 0.33, -0.12, top, 0.05, 0.04, 0.03)
    arch.hvac(c, 0.33, 0.07, top, 0.05, 0.04, 0.03)
    # entrance canopy
    c.mb.box2(x0 + 0.38, y0 - 0.05, base + 0.11, x0 + 0.52, y0, base + 0.116, "Metal_Dark")


# ----------------------------------------------------------------------------- r3 towers

def _podium(c, x0, y0, x1, y1, n, wall, shopfront=True, entry=2):
    base = 0.006
    fl = [(base + i * FH * 1.1, base + (i + 1) * FH * 1.1) for i in range(n)]
    w = Win(w=0.09, h=0.11, sill=0.02, depth=0.007, frame="Frame_Dark", fw=0.003, bay=0.12, sill_mat=None)
    block(c, x0, y0, x1, y1, fl, w, wall,
          lambda s, fi, bi: ("door" if bi == entry else "shop") if (fi == 0 and s in "SE" and shopfront) else "win")
    top = base + n * FH * 1.1
    return top


def tower_slab(c, floors_n=13, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    pad(c, -0.46, 0.25, 0.46, 0.46, "Grass")
    for i, x in enumerate((-0.35, 0.0, 0.35)):
        tree(c.mb, c.fol, x, 0.36, h=0.45, kind="round", seed=seed + i, z0=0.005)
    x0, x1, y0, y1 = -0.4, 0.4, -0.2, 0.14
    z = _podium(c, -0.44, -0.3, 0.44, 0.2, 1, "Concrete_Dark", entry=3)
    flat_roof(c, -0.44, -0.3, 0.44, 0.2, z, roof="Roof_Gravel", parapet=0.01, pmat="Concrete_Dark", cap="Metal_Galv")
    fl = [(z + i * FH, z + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.075, h=0.1, sill=0.012, depth=0.009, frame="Frame_Alu", fw=0.003, bay=0.1, sill_mat=None,
            mullion=True, glass="Glass")
    block(c, x0, y0, x1, y1, fl, w, "Concrete_Panel", lambda s, fi, bi: "tall" if s in "SN" else ("win" if bi % 2 == 0 else "wall"))
    for k in range(1, floors_n):
        balcony_band(c, x0 + 0.01, x1 - 0.01, y0, z + k * FH + 0.003, depth=0.032, rail="Concrete_Light")
        c.mb.box2(x0 + 0.01, y1, z + k * FH - 0.002, x1 - 0.01, y1 + 0.02, z + k * FH + 0.003, "Concrete_Light")
    # vertical fins between loggias
    for xx in (-0.2, 0.0, 0.2):
        c.mb.box2(xx - 0.004, y0 - 0.034, z, xx + 0.004, y0, z + floors_n * FH, "Concrete_Light", skip=("-z",))
    top = z + floors_n * FH
    flat_roof(c, x0, y0, x1, y1, top, roof="Roof_Flat", parapet=0.016, pmat="Concrete_Panel")
    arch.bulkhead(c, 0.1, -0.03, top, 0.16, 0.12, 0.07, mat="Concrete_Panel")
    arch.hvac(c, -0.25, -0.05, top, 0.07, 0.05, 0.035)
    arch.hvac(c, -0.12, 0.05, top, 0.05, 0.04, 0.03)
    arch.antenna(c, 0.32, 0.06, top, 0.14)
    arch.dish(c, -0.32, 0.08, top)


def tower_brick_point(c, floors_n=15, seed=0):
    c.door_mat = "Door_Black"
    _street_lot(c, trees=((-0.42, -0.42), (0.42, -0.42), (-0.42, 0.42), (0.42, 0.42)), seed=seed)
    z = _podium(c, -0.4, -0.4, 0.4, 0.4, 2, "Stone_Facade", entry=3)
    cornice(c, -0.4, -0.4, 0.4, 0.4, z, mat="Trim_Stone", h=0.01, out=0.006)
    flat_roof(c, -0.4, -0.4, 0.4, 0.4, z + 0.01, roof="Roof_Gravel", parapet=0.012, pmat="Stone_Facade")
    x0, x1, y0, y1 = -0.3, 0.3, -0.3, 0.3
    z += 0.01
    fl = [(z + i * FH, z + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.06, h=0.095, sill=0.03, frame="Frame_White", fw=0.0035, bay=0.1, sill_mat="Trim_Stone",
            lintel=None, transom=False)
    block(c, x0, y0, x1, y1, fl, w, "Brick_Orange")
    for k in (4, 8, 12):
        arch.band(c, x0, y0, x1, y1, z + k * FH - 0.004, 0.008, "Trim_Stone", out=0.003)
    # corner quoins
    for (xx, yy) in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        c.mb.box2(xx - 0.006, yy - 0.006, z, xx + 0.006, yy + 0.006, z + floors_n * FH, "Trim_Stone", skip=("-z",))
    top = z + floors_n * FH
    cornice(c, x0, y0, x1, y1, top, mat="Trim_Stone", h=0.016, out=0.012)
    # setback crown
    cz = top + 0.016
    block(c, -0.2, -0.2, 0.2, 0.2, [(cz, cz + FH)], Win(w=0.05, h=0.1, sill=0.02, frame="Frame_White", bay=0.1,
                                                       sill_mat=None), "Brick_Orange")
    flat_roof(c, x0, y0, x1, y1, cz, roof="Roof_Flat", parapet=0.02, pmat="Brick_Orange")
    flat_roof(c, -0.2, -0.2, 0.2, 0.2, cz + FH, roof="Roof_Flat", parapet=0.01, pmat="Brick_Orange")
    arch.water_tank(c, 0.0, 0.0, cz + FH, r=0.05, h=0.07)
    arch.hvac(c, 0.22, -0.22, cz, 0.05, 0.04, 0.03)
    arch.hvac(c, -0.22, 0.22, cz, 0.05, 0.04, 0.03)


def tower_glass_balcony(c, floors_n=16, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    pad(c, -0.46, -0.46, -0.2, 0.46, "Grass")
    for i, y in enumerate((-0.35, 0.0, 0.35)):
        tree(c.mb, c.fol, -0.36, y, h=0.48, kind="birch" if i % 2 else "fern", seed=seed + i, z0=0.005)
    x0, x1, y0, y1 = -0.16, 0.36, -0.28, 0.28
    z = _podium(c, -0.18, -0.32, 0.42, 0.32, 1, "Stone_Light", entry=2)
    flat_roof(c, -0.18, -0.32, 0.42, 0.32, z, roof="Roof_Gravel", parapet=0.012, pmat="Stone_Light", cap="Metal_Galv")
    fl = [(z + i * FH, z + (i + 1) * FH) for i in range(floors_n)]
    w = Win(w=0.11, h=0.12, sill=0.008, depth=0.006, frame="Frame_Dark", fw=0.0025, bay=0.13, sill_mat=None,
            mullion=True, glass="Glass_Curtain")
    block(c, x0, y0, x1, y1, fl, w, "Plaster_White", lambda s, fi, bi: "tall")
    mb = c.mb
    for k in range(1, floors_n + 1):
        zz = z + k * FH
        d = 0.03
        # wraparound slab with rounded-feel corner via chamfer
        mb.box2(x0 - d, y0 - d, zz - 0.006, x1 + d, y1 + d, zz, "Plaster_White")
        if k == floors_n:
            continue
        for (ax, ay, bx, by, o) in ((x0 - d, y0 - d, x1 + d, y0 - d, (0, -1, 0)), (x1 + d, y0 - d, x1 + d, y1 + d, (1, 0, 0)),
                                    (x1 + d, y1 + d, x0 - d, y1 + d, (0, 1, 0)), (x0 - d, y1 + d, x0 - d, y0 - d, (-1, 0, 0))):
            mb.polyo([(ax, ay, zz), (bx, by, zz), (bx, by, zz + 0.045), (ax, ay, zz + 0.045)], "Glass_Curtain", o)
            mb.polyo([(ax, ay, zz), (bx, by, zz), (bx, by, zz + 0.045), (ax, ay, zz + 0.045)], "Glass_Curtain",
                     (-o[0], -o[1], 0))
    top = z + floors_n * FH
    flat_roof(c, x0 - 0.03, y0 - 0.03, x1 + 0.03, y1 + 0.03, top, roof="Roof_Gravel", parapet=0.0)
    arch.bulkhead(c, 0.1, 0.0, top, 0.18, 0.14, 0.08, mat="Plaster_White")
    arch.hvac(c, 0.26, -0.18, top, 0.06, 0.05, 0.03)
    arch.hvac(c, -0.08, 0.18, top, 0.06, 0.05, 0.03)
    # roof terrace planting
    for i, (xx, yy) in enumerate(((-0.1, -0.2), (0.3, 0.2))):
        tree(c.mb, c.fol, xx, yy, h=0.06, kind="shrub", seed=seed + 20 + i, z0=top)


def tower_twin(c, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    z = _podium(c, -0.44, -0.44, 0.44, 0.44, 2, "Brick_Yellow", entry=3)
    flat_roof(c, -0.44, -0.44, 0.44, 0.44, z, roof="Roof_Flat", parapet=0.012, pmat="Brick_Yellow", cap="Trim_Stone")
    c.mb.poly([(-0.42, -0.42, z + 0.001), (0.42, -0.42, z + 0.001), (0.42, 0.42, z + 0.001), (-0.42, 0.42, z + 0.001)],
              "Grass")
    for i, (xx, yy, n, wall) in enumerate(((-0.2, 0.18, 14, "Plaster_Beige"), (0.2, -0.17, 11, "Plaster_Grey"))):
        x0, x1, y0, y1 = xx - 0.17, xx + 0.17, yy - 0.17, yy + 0.17
        fl = [(z + k * FH, z + (k + 1) * FH) for k in range(n)]
        w = Win(w=0.065, h=0.1, sill=0.025, depth=0.008, frame="Frame_Alu", fw=0.003, bay=0.085, sill_mat="Trim_White",
                balcony=0.028, rail="Glass")
        block(c, x0, y0, x1, y1, fl, w, wall, lambda s, fi, bi: "balc" if (s in "SE" and bi == 1 and fi % 1 == 0) else "win")
        top = z + n * FH
        cornice(c, x0, y0, x1, y1, top, mat="Trim_White", h=0.01, out=0.006)
        flat_roof(c, x0, y0, x1, y1, top + 0.01, roof="Roof_Flat", parapet=0.012, pmat=wall)
        arch.bulkhead(c, xx, yy, top + 0.01, 0.1, 0.08, 0.06, mat=wall)
        arch.hvac(c, xx + 0.1, yy - 0.1, top + 0.01, 0.04, 0.04, 0.03)
    for i, (xx, yy) in enumerate(((0.25, 0.28), (-0.28, -0.25), (0.05, 0.05))):
        tree(c.mb, c.fol, xx, yy, h=0.3, kind="round", seed=seed + i, z0=z)


REGISTRY = {
    "zones/r2/walkup_brick": (walkup_brick, {}),
    "zones/r2/walkup_yellow": (walkup_brick, {"wall": "Brick_Yellow", "floors_n": 6, "door": "Door_Red", "seed": 3}),
    "zones/r2/townhouse_row": (townhouse_row, {}),
    "zones/r2/euro_apartment": (euro_apartment, {}),
    "zones/r2/modern_midrise": (modern_midrise, {}),
    "zones/r3/tower_slab": (tower_slab, {}),
    "zones/r3/tower_brick_point": (tower_brick_point, {}),
    "zones/r3/tower_glass_balcony": (tower_glass_balcony, {"_lit": "Glass_Curtain"}),
    "zones/r3/tower_twin": (tower_twin, {}),
}
