"""Commercial zones: c1 shops/cafes, c2 offices, c3 skyscrapers."""

import math

from mathutils import Matrix, Vector

import arch
from arch import FH, SIDES, Win, block, flat_roof, gable_roof, hip_roof, facade, lot, pad
from nature import tree
from zones_res2 import cornice, _street_lot

OFH = 0.17  # office storey (3.4 m)


def curtain(c, origin, angle, width, z0, z1, fh=OFH, panel=0.06, glass="Glass_Curtain", spandrel="Glass_Green",
            mullion="Frame_Alu", lit=0.35, fin=0.004, transom=True):
    """Glass curtain wall: vision glass + spandrel per floor, vertical mullions and floor transoms."""
    mb = c.mb
    mb.push(Matrix.Translation(Vector(origin)) @ arch.rotz(angle))
    n = max(1, int(round(width / panel)))
    pw = width / n
    nf = max(1, int(round((z1 - z0) / fh)))
    fh = (z1 - z0) / nf
    for f in range(nf):
        za = z0 + f * fh
        zs = za + fh * 0.22
        for i in range(n):
            xa, xb = i * pw, (i + 1) * pw
            mb.poly([(xa, 0, za), (xb, 0, za), (xb, 0, zs), (xa, 0, zs)], spandrel)
            mb.poly([(xa, 0, zs), (xb, 0, zs), (xb, 0, za + fh), (xa, 0, za + fh)], c.glass(glass, lit))
        if transom:
            mb.box2(0, -fin * 0.6, za - 0.0012, width, 0.0, za + 0.0012, mullion, skip=("+y",))
    for i in range(n + 1):
        x = i * pw
        mb.box2(x - 0.0012, -fin, z0, x + 0.0012, 0.0, z1, mullion, skip=("+y", "-z"))
    mb.pop()


def curtain_block(c, x0, y0, x1, y1, z0, z1, **kw):
    for s in "SENW":
        o, ang, ln = SIDES[s]
        p = o(x0, y0, x1, y1)
        curtain(c, (p[0], p[1], 0), ang, ln(x0, y0, x1, y1), z0, z1, **kw)


def shop_floor_kinds(entry, sides="S"):
    def k(s, fi, bi):
        if fi == 0 and s in sides:
            return "door" if bi == entry else "shop"
        return "win"
    return k


# ----------------------------------------------------------------------------- c1

def corner_store(c, wall="Brick_Red", awn=("Fabric_Green", "Fabric_Cream"), sign_bg="Sign_Green", seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    x0, x1, y0, y1 = -0.36, 0.3, -0.3, 0.3
    base = 0.006
    fl = [(base, base + FH * 1.15), (base + FH * 1.15, base + FH * 2.15)]
    w = Win(w=0.06, h=0.09, sill=0.04, frame="Frame_White", bay=0.13, transom=True, sill_mat="Trim_Stone",
            lintel="Trim_Stone")
    block(c, x0, y0, x1, y1, fl, w, wall, shop_floor_kinds(2, "SE"))
    top = base + FH * 2.15
    arch.band(c, x0, y0, x1, y1, base + FH * 1.15 - 0.022, 0.022, "Metal_Dark", out=0.003)
    sign = arch.sign
    sign(c, (x0 + x1) / 2, y0 - 0.004, base + FH * 1.15 - 0.011, 0.4, 0.018, bg=sign_bg, depth=0.003)
    sign(c, x1 + 0.004, 0.0, base + FH * 1.15 - 0.011, 0.36, 0.018, bg=sign_bg, depth=0.003, face="E")
    arch.awning(c, x0 + 0.02, x1 - 0.02, y0 - 0.0035, base + FH * 1.15 - 0.03, depth=0.045, stripes=list(awn))
    cornice(c, x0, y0, x1, y1, top, mat="Trim_Stone", h=0.012, out=0.008)
    flat_roof(c, x0, y0, x1, y1, top + 0.012, roof="Roof_Flat", parapet=0.012, pmat=wall)
    arch.hvac(c, -0.15, 0.12, top + 0.012, 0.07, 0.05, 0.035)
    arch.hvac(c, 0.1, 0.15, top + 0.012, 0.04, 0.04, 0.03)
    # sidewalk dressing: produce crates, bench, planters
    for i, xx in enumerate((-0.28, -0.2)):
        c.mb.box2(xx - 0.03, y0 - 0.07, 0.004, xx + 0.03, y0 - 0.045, 0.024, "Wood", skip=("-z",))
        tree(c.mb, c.fol, xx, y0 - 0.058, h=0.012, kind="shrub", seed=seed + i, z0=0.022)
    arch.tree_pit(c, -0.4, -0.42, 0.44, "round", seed=seed)
    arch.tree_pit(c, 0.38, -0.42, 0.4, "broad", seed=seed + 3)


def cafe(c, wall="Plaster_Cream", roof="Roof_Clay", seed=0):
    c.door_mat = "Door_Green"
    lot(c, "Sidewalk")
    pad(c, -0.44, -0.46, 0.44, -0.18, "Wood", h=0.002)
    x0, x1, y0, y1 = -0.34, 0.34, -0.14, 0.32
    base = 0.006
    fl = [(base, base + FH * 1.2), (base + FH * 1.2, base + FH * 2.2)]
    w = Win(w=0.055, h=0.09, sill=0.035, frame="Frame_White", bay=0.115, transom=True, shutters="Frame_Wood",
            sill_mat="Trim_White", balcony=0.02, rail="Metal_Dark")
    block(c, x0, y0, x1, y1, fl, w, wall,
          lambda s, fi, bi: ("door" if bi == 3 else "shop") if (fi == 0 and s == "S") else ("balc" if (s == "S" and bi in (1, 4)) else "win"))
    top = base + FH * 2.2
    arch.sign(c, 0.0, y0 - 0.003, base + FH * 1.2 - 0.016, 0.3, 0.02, bg="Sign_Red", depth=0.003)
    arch.awning(c, x0 + 0.02, x1 - 0.02, y0 - 0.003, base + FH * 1.2 - 0.035, depth=0.06, mat="Fabric_Red")
    hip_roof(c, x0, y0, x1, y1, top, 0.13, roof, oh=0.012)
    arch.chimney(c, 0.2, 0.15, top, top + 0.12, mat=wall)
    # terrace: tables, chairs, parasols
    for i, xx in enumerate((-0.33, -0.17, 0.0, 0.17, 0.33)):
        yy = -0.33 if i % 2 else -0.27
        mb = c.mb
        mb.cyl((xx, yy, 0.006), 0.0025, 0.03, "Metal_Dark", n=6)
        mb.cyl((xx, yy, 0.036), 0.016, 0.002, "Metal_White", n=12)
        for a in (0, math.pi):
            cx, cy = xx + math.cos(a) * 0.024, yy + math.sin(a) * 0.024
            mb.box((cx, cy, 0.022), (0.012, 0.012, 0.002), "Wood_Dark")
            mb.box((cx + math.cos(a) * 0.006, cy, 0.03), (0.002, 0.012, 0.016), "Wood_Dark")
            for (dx, dy) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                mb.box((cx + dx * 0.005, cy + dy * 0.005, 0.014), (0.0015, 0.0015, 0.016), "Metal_Dark", skip=("-z",))
        mb.cyl((xx, yy, 0.038), 0.0015, 0.06, "Wood", n=5)
        mb.lathe([(0.05, 0.0), (0.012, 0.016), (0.0, 0.018)], "Fabric_Cream" if i % 2 else "Fabric_Green", n=8,
                 c=(xx, yy, 0.085), smooth=False)
        mb.lathe([(0.0, 0.0), (0.012, 0.0158), (0.05, -0.0002)][::-1], "Fabric_Cream", n=8, c=(xx, yy, 0.0848),
                 smooth=False)
    for i, xx in enumerate((-0.43, 0.43)):
        c.mb.box2(xx - 0.02, -0.46, 0.006, xx + 0.02, -0.18, 0.03, "Concrete_Light", skip=("-z",))
        tree(c.mb, c.fol, xx, -0.32, h=0.03, kind="shrub", seed=seed + i, z0=0.03)


def shop_row(c, seed=0):
    lot(c, "Sidewalk")
    specs = [(-0.45, -0.15, "Plaster_Terracotta", 2, ("Fabric_Navy", "Fabric_Cream"), "Sign_Blue"),
             (-0.15, 0.15, "Brick_Orange", 2, ("Fabric_Red", "Fabric_Cream"), "Sign_Red"),
             (0.15, 0.45, "Plaster_Grey", 1, ("Fabric_Green", "Fabric_Green"), "Sign_Green")]
    y0, y1 = -0.22, 0.3
    base = 0.006
    for i, (x0, x1, wall, n, awn, sg) in enumerate(specs):
        c.door_mat = ["Door_Blue", "Door_Black", "Door_Green"][i]
        fl = [(base, base + FH * 1.2)] + [(base + FH * (1.2 + k), base + FH * (2.2 + k)) for k in range(n - 1)]
        w = Win(w=0.055, h=0.09, sill=0.035, frame="Frame_White", bay=0.1, transom=True, sill_mat="Trim_Stone")
        sides = "SN" + ("W" if i == 0 else "") + ("E" if i == 2 else "")
        block(c, x0, y0, x1, y1, fl, w, wall, shop_floor_kinds(0 if i != 1 else 1), sides=sides)
        top = fl[-1][1]
        arch.sign(c, (x0 + x1) / 2, y0 - 0.003, base + FH * 1.2 - 0.013, x1 - x0 - 0.06, 0.018, bg=sg, depth=0.003)
        arch.awning(c, x0 + 0.015, x1 - 0.015, y0 - 0.003, base + FH * 1.2 - 0.03, depth=0.045, stripes=list(awn))
        cornice(c, x0 + 0.003, y0, x1 - 0.003, y1, top, mat="Trim_White" if i != 1 else "Trim_Stone", h=0.01,
                out=0.006)
        flat_roof(c, x0, y0, x1, y1, top + 0.01, roof="Roof_Flat", parapet=0.01 + 0.006 * i, pmat=wall)
        arch.hvac(c, (x0 + x1) / 2, 0.1, top + 0.01, 0.05, 0.04, 0.03)
    for i, xx in enumerate((-0.3, 0.3)):
        arch.tree_pit(c, xx, -0.4, 0.42, "round" if i else "broad", seed=seed + i)
    bench(c, 0.0, -0.4)


def bench(c, x, y, rz=0.0):
    mb = c.mb
    mb.push(Matrix.Translation(Vector((x, y, 0.004))) @ arch.rotz(rz))
    for xx in (-0.025, 0.025):
        mb.box((xx, 0, 0.006), (0.003, 0.016, 0.012), "Metal_Dark", skip=("-z",))
    mb.box((0, 0, 0.0125), (0.065, 0.016, 0.002), "Wood")
    mb.box((0, 0.008, 0.02), (0.065, 0.002, 0.012), "Wood")
    mb.pop()


def mini_mart(c, seed=0):
    """Convenience store with fuel canopy, pumps and price pylon."""
    c.door_mat = "Door_Black"
    lot(c, "Asphalt")
    mb = c.mb
    pad(c, -0.46, 0.06, 0.46, 0.46, "Concrete_Floor")
    x0, x1, y0, y1 = -0.3, 0.3, 0.14, 0.42
    block(c, x0, y0, x1, y1, [(0.006, 0.006 + FH * 1.25)], Win(w=0.06, h=0.08, sill=0.04, frame="Frame_Alu", bay=0.1),
          "Concrete_Panel", shop_floor_kinds(3))
    top = 0.006 + FH * 1.25
    mb.box2(x0 - 0.004, y0 - 0.004, top - 0.035, x1 + 0.004, y1 + 0.004, top + 0.012, "Metal_White")
    mb.box2(x0 - 0.0045, y0 - 0.0045, top - 0.03, x1 + 0.0045, y0 - 0.004, top - 0.022, "Sign_Red")
    arch.sign(c, 0.0, y0 - 0.005, top - 0.012, 0.3, 0.016, bg="Sign_White", fg="Sign_Red", depth=0.002)
    flat_roof(c, x0, y0, x1, y1, top + 0.012, parapet=0.0)
    arch.hvac(c, 0.15, 0.3, top + 0.012, 0.06, 0.04, 0.03)
    # canopy over pumps
    cz = 0.12
    for xx in (-0.25, 0.25):
        for yy in (-0.22, -0.02):
            mb.box((xx, yy, cz / 2), (0.012, 0.012, cz), "Metal_White", skip=("-z",))
        mb.box2(xx - 0.008, -0.27, 0.004, xx + 0.008, 0.03, 0.01, "Concrete_Light", skip=("-z",))
        for yy in (-0.2, -0.04):
            mb.box2(xx - 0.007, yy - 0.012, 0.01, xx + 0.007, yy + 0.012, 0.055, "Metal_White", skip=("-z",))
            mb.box2(xx - 0.0075, yy - 0.012, 0.035, xx + 0.0075, yy + 0.012, 0.05, "Sign_Red", skip=("-z",))
    mb.box2(-0.36, -0.3, cz, 0.36, 0.06, cz + 0.022, "Metal_White")
    mb.box2(-0.3605, -0.3005, cz + 0.004, 0.3605, 0.0605, cz + 0.014, "Sign_Red", skip=("+z", "-z"))
    mb.poly([(-0.34, 0.04, cz - 0.0002), (0.34, 0.04, cz - 0.0002), (0.34, -0.28, cz - 0.0002), (-0.34, -0.28, cz - 0.0002)],
            "Lamp_Glow")
    # price pylon
    mb.box2(0.37, -0.43, 0.004, 0.43, -0.41, 0.2, "Metal_White", skip=("-z",))
    mb.box2(0.365, -0.435, 0.2, 0.435, -0.405, 0.28, "Sign_Red")
    for k in range(3):
        mb.box2(0.372, -0.4355, 0.08 + k * 0.035, 0.428, -0.434, 0.105 + k * 0.035, "Sign_White")
    # parking stripes
    for k in range(5):
        xx = -0.42 + k * 0.08
        pad(c, xx, 0.07, xx + 0.004, 0.13, "Paint_White", z=0.0041, h=0.0004)
    arch.parked_car(c, -0.34, 0.1, rz=math.pi / 2, scale=1.0)
    arch.parked_car(c, 0.25, -0.12, rz=0.0, scale=1.0, color="Paint_blue")
    tree(c.mb, c.fol, 0.42, 0.4, h=0.45, kind="broad", seed=seed)


def bank(c, seed=0):
    """Two-storey classical stone bank/pharmacy with columns and pediment."""
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    x0, x1, y0, y1 = -0.34, 0.34, -0.22, 0.32
    base = 0.02
    mb = c.mb
    for k in range(3):
        mb.box2(-0.2 - k * 0.006, y0 - 0.06 + k * 0.016, 0.0, 0.2 + k * 0.006, y0, base * (k + 1) / 3, "Stone_Light",
                skip=("-z",))
    mb.box2(x0, y0, 0.0, x1, y1, base, "Stone_Light", skip=("-z",))
    fl = [(base, base + FH * 1.3), (base + FH * 1.3, base + FH * 2.3)]
    w = Win(w=0.06, h=0.12, sill=0.03, frame="Frame_Dark", bay=0.11, transom=True, sill_mat="Trim_Stone", lintel="Trim_Stone")
    block(c, x0, y0, x1, y1, fl, w, "Stone_Light", lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 3) else "tall")
    top = base + FH * 2.3
    # portico
    for k in range(6):
        xx = -0.15 + k * 0.06
        mb.cyl((xx, y0 - 0.04, base), 0.009, top - base - 0.03, "Stone_Light", n=10)
        mb.box((xx, y0 - 0.04, top - 0.027), (0.024, 0.024, 0.006), "Stone_Light")
    mb.box2(-0.19, y0 - 0.06, top - 0.024, 0.19, y0, top, "Stone_Light")
    arch.gable_roof(c, -0.19, y0 - 0.06, 0.19, y0, top, 0.05, "Stone_Light", "Stone_Light", oh=0.004, ridge="y",
                    gutter=None, fascia="Stone_Light")
    cornice(c, x0, y0, x1, y1, top, mat="Stone_Light", h=0.014, out=0.01)
    flat_roof(c, x0, y0, x1, y1, top + 0.014, roof="Roof_Flat", parapet=0.02, pmat="Stone_Light")
    arch.sign(c, 0.0, y0 - 0.0605, top - 0.012, 0.22, 0.012, bg="Stone_Light", fg="Metal_Dark", depth=0.001)
    arch.hvac(c, 0.15, 0.15, top + 0.014, 0.06, 0.05, 0.03)
    for i, xx in enumerate((-0.42, 0.42)):
        arch.tree_pit(c, xx, -0.42, 0.42, "round", seed=seed + i)


# ----------------------------------------------------------------------------- c2

def _office_lobby(c, x0, y0, x1, y1, z0, z1, wall):
    w = Win(w=0.1, h=0.12, sill=0.008, depth=0.012, frame="Frame_Alu", fw=0.0025, bay=0.12, sill_mat=None)
    block(c, x0, y0, x1, y1, [(z0, z1)], w, wall, lambda s, fi, bi: "door" if (s == "S" and bi == 2) else "shop")


def office_ribbon(c, floors_n=6, seed=0):
    c.door_mat = "Glass_Shop"
    lot(c, "Sidewalk")
    x0, x1, y0, y1 = -0.4, 0.4, -0.3, 0.3
    base = 0.006
    _office_lobby(c, x0 + 0.03, y0 + 0.03, x1 - 0.03, y1 - 0.03, base, base + OFH * 1.2, "Concrete_Dark")
    z = base + OFH * 1.2
    c.mb.box2(x0, y0, z - 0.008, x1, y1, z, "Concrete_Light")
    for xx in (x0 + 0.01, -0.13, 0.13, x1 - 0.01):
        for yy in (y0 + 0.01, y1 - 0.01):
            c.mb.box((xx, yy, (base + z) / 2), (0.016, 0.016, z - base), "Concrete_Light", skip=("-z",))
    fl = [(z + k * OFH, z + (k + 1) * OFH) for k in range(floors_n)]
    w = Win(w=0.1, h=0.095, sill=0.045, depth=0.008, frame="Frame_Dark", fw=0.0025, bay=0.1, sill_mat=None,
            mullion=False, glass="Glass_Curtain")
    block(c, x0, y0, x1, y1, fl, w, "Concrete_Light", lambda s, fi, bi: "band")
    top = z + floors_n * OFH
    flat_roof(c, x0, y0, x1, y1, top, roof="Roof_Gravel", parapet=0.018, pmat="Concrete_Light", cap="Metal_Galv")
    # rooftop plant screen
    c.mb.box2(-0.2, -0.1, top, 0.2, 0.16, top + 0.06, "Metal_Corrugated", skip=("-z",))
    for i in range(3):
        arch.hvac(c, -0.3 + i * 0.12, 0.22, top, 0.06, 0.05, 0.03)
    arch.tree_pit(c, -0.42, -0.42, 0.44, "round", seed=seed)
    arch.tree_pit(c, 0.42, -0.42, 0.44, "round", seed=seed + 1)


def office_stone(c, floors_n=6, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    x0, x1, y0, y1 = -0.42, 0.42, -0.34, 0.34
    base = 0.01
    c.mb.box2(x0 - 0.004, y0 - 0.004, 0.0, x1 + 0.004, y1 + 0.004, base, "Stone_Facade", skip=("-z",))
    fl = [(base + k * OFH, base + (k + 1) * OFH) for k in range(floors_n)]
    w = Win(w=0.055, h=0.12, sill=0.025, depth=0.01, frame="Frame_Dark", fw=0.003, bay=0.093, sill_mat="Trim_Stone",
            transom=True)
    block(c, x0, y0, x1, y1, fl, w, "Stone_Facade",
          lambda s, fi, bi: ("door" if bi == 4 else "shop") if (fi == 0 and s in "S") else "tall")
    arch.band(c, x0, y0, x1, y1, base + OFH - 0.004, 0.008, "Trim_Stone", out=0.004)
    arch.band(c, x0, y0, x1, y1, base + (floors_n - 1) * OFH - 0.004, 0.008, "Trim_Stone", out=0.004)
    top = base + floors_n * OFH
    cornice(c, x0, y0, x1, y1, top, mat="Trim_Stone", h=0.02, out=0.014)
    flat_roof(c, x0, y0, x1, y1, top + 0.02, roof="Roof_Flat", parapet=0.02, pmat="Stone_Facade")
    # entrance surround
    c.mb.box2(-0.075, y0 - 0.012, base, 0.075, y0, base + OFH * 0.95, "Trim_Stone", skip=("-z",))
    arch.sign(c, 0.0, y0 - 0.0125, base + OFH * 0.8, 0.12, 0.012, bg="Metal_Dark", fg="Chrome", depth=0.0005)
    arch.bulkhead(c, 0.15, 0.1, top + 0.02, 0.14, 0.1, 0.07, mat="Stone_Facade")
    arch.hvac(c, -0.2, 0.15, top + 0.02, 0.07, 0.05, 0.035)
    arch.hvac(c, -0.2, -0.1, top + 0.02, 0.07, 0.05, 0.035)
    arch.antenna(c, 0.3, -0.25, top + 0.02, 0.1)
    for i, xx in enumerate((-0.25, 0.25)):
        arch.tree_pit(c, xx, -0.42, 0.4, "broad", seed=seed + i)


def office_glass(c, floors_n=6, seed=0):
    c.door_mat = "Glass_Shop"
    lot(c, "Sidewalk")
    pad(c, -0.46, 0.24, 0.46, 0.46, "Grass")
    base = 0.006
    _office_lobby(c, -0.42, -0.36, 0.42, 0.2, base, base + OFH * 1.3, "Stone_Facade")
    z = base + OFH * 1.3
    flat_roof(c, -0.42, -0.36, 0.42, 0.2, z, roof="Roof_Gravel", parapet=0.008, pmat="Stone_Facade", cap="Metal_Galv")
    x0, x1, y0, y1 = -0.36, 0.36, -0.3, 0.16
    curtain_block(c, x0, y0, x1, y1, z, z + floors_n * OFH, panel=0.06)
    top = z + floors_n * OFH
    flat_roof(c, x0, y0, x1, y1, top, roof="Roof_Flat", parapet=0.02, pmat="Metal_Galv", cap="Frame_Alu")
    c.mb.box2(-0.15, -0.12, top, 0.18, 0.08, top + 0.07, "Metal_Corrugated_Light", skip=("-z",))
    flat_roof(c, -0.15, -0.12, 0.18, 0.08, top + 0.07, parapet=0.0)
    for i, x in enumerate((-0.32, 0.0, 0.32)):
        tree(c.mb, c.fol, x, 0.35, h=0.42, kind="fern", seed=seed + i, z0=0.005)


def office_loft(c, floors_n=5, seed=0):
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    x0, x1, y0, y1 = -0.42, 0.42, -0.32, 0.32
    base = 0.008
    fl = [(base + k * OFH, base + (k + 1) * OFH) for k in range(floors_n)]
    w = Win(w=0.075, h=0.12, sill=0.025, depth=0.012, frame="Frame_Dark", fw=0.003, bay=0.12, sill_mat="Concrete",
            transom=True, lintel="Trim_Stone")
    block(c, x0, y0, x1, y1, fl, w, "Brick_Old", lambda s, fi, bi: ("door" if bi == 3 else "shop") if (fi == 0 and s == "S") else "win")
    for xx in [x0 + k * 0.12 for k in range(8)]:
        c.mb.box2(xx - 0.006, y0 - 0.006, base, xx + 0.006, y0, base + floors_n * OFH, "Brick_Old", skip=("-z", "+y"))
    top = base + floors_n * OFH
    cornice(c, x0, y0, x1, y1, top, mat="Brick_Old", h=0.016, out=0.008)
    flat_roof(c, x0, y0, x1, y1, top + 0.016, roof="Roof_Flat", parapet=0.012, pmat="Brick_Old")
    # glass rooftop extension
    zz = top + 0.016
    curtain_block(c, -0.25, -0.1, 0.3, 0.22, zz, zz + OFH, panel=0.05, glass="Glass", spandrel="Metal_Dark",
                  mullion="Metal_Dark")
    flat_roof(c, -0.27, -0.12, 0.32, 0.24, zz + OFH, parapet=0.0)
    arch.water_tank(c, -0.32, 0.2, zz, r=0.04, h=0.055)
    c.mb.box2(-0.4, -0.3, zz, -0.28, -0.18, zz + 0.002, "Wood")
    arch.sign(c, x1 + 0.004, -0.2, base + OFH * 3.5, 0.025, 0.25, bg="Sign_Red", depth=0.006, face="E", letters=False)
    for i, xx in enumerate((-0.42, 0.42)):
        arch.tree_pit(c, xx, -0.42, 0.42, "broad", seed=seed + i)


# ----------------------------------------------------------------------------- c3

def sky_glass(c, seed=0):
    c.door_mat = "Glass_Shop"
    lot(c, "Sidewalk")
    pad(c, -0.46, -0.46, 0.46, -0.36, "Stone_Facade")
    base = 0.006
    _office_lobby(c, -0.4, -0.32, 0.4, 0.38, base, base + OFH * 1.5, "Stone_Facade")
    z = base + OFH * 1.5
    flat_roof(c, -0.4, -0.32, 0.4, 0.38, z, roof="Roof_Gravel", parapet=0.01, pmat="Stone_Facade", cap="Metal_Galv")
    z1 = z + 11 * OFH
    curtain_block(c, -0.34, -0.26, 0.34, 0.32, z, z1, panel=0.057)
    flat_roof(c, -0.34, -0.26, 0.34, 0.32, z1, roof="Roof_Flat", parapet=0.012, pmat="Frame_Alu", cap=None)
    z2 = z1 + 6 * OFH
    curtain_block(c, -0.24, -0.18, 0.24, 0.24, z1, z2, panel=0.06)
    # crown: glass fins extending above the roof
    top = z2 + 0.08
    curtain(c, (-0.24, -0.18, 0), 0.0, 0.48, z2, top, fh=0.08, glass="Glass_Curtain", spandrel="Glass_Curtain", lit=0.0)
    curtain(c, (0.24, 0.24, 0), math.pi, 0.48, z2, top, fh=0.08, glass="Glass_Curtain", spandrel="Glass_Curtain", lit=0.0)
    for s in (-1, 1):
        c.mb.box2(-0.24, -0.18, z2, 0.24, 0.24, z2 + 0.002, "Roof_Flat")
    c.mb.box2(-0.1, -0.05, z2, 0.1, 0.12, z2 + 0.06, "Metal_Galv", skip=("-z",))
    c.mb.cyl((0.0, 0.03, z2 + 0.06), 0.006, 0.28, "Metal_Galv", n=8, r2=0.002)
    c.mb.cyl((0.0, 0.03, z2 + 0.34), 0.004, 0.006, "Beacon_Red", n=6)
    for i, xx in enumerate((-0.42, 0.42)):
        arch.tree_pit(c, xx, -0.41, 0.4, "round", seed=seed + i)


def sky_grid(c, floors_n=15, seed=0):
    """Concrete exoskeleton grid over dark glass."""
    c.door_mat = "Glass_Shop"
    lot(c, "Sidewalk")
    base = 0.006
    x0, x1, y0, y1 = -0.34, 0.34, -0.34, 0.34
    _office_lobby(c, x0 + 0.03, y0 + 0.03, x1 - 0.03, y1 - 0.03, base, base + OFH * 2, "Concrete_Dark")
    z = base + OFH * 2
    curtain_block(c, x0 + 0.006, y0 + 0.006, x1 - 0.006, y1 - 0.006, z, z + floors_n * OFH, panel=0.045,
                  glass="Glass", spandrel="Metal_Dark", mullion="Metal_Dark", transom=False)
    mb = c.mb
    n = 6
    for s in "SENW":
        o, ang, ln = SIDES[s]
        p = o(x0, y0, x1, y1)
        L = ln(x0, y0, x1, y1)
        mb.push(Matrix.Translation(Vector((p[0], p[1], 0))) @ arch.rotz(ang))
        for i in range(n + 1):
            xx = L * i / n
            mb.box2(xx - 0.009, -0.006, base, xx + 0.009, 0.007, z + floors_n * OFH, "Concrete_Light",
                    skip=("-z", "+y"))
        for k in range(floors_n + 1):
            zz = z + k * OFH
            mb.box2(0, -0.0055, zz - 0.007, L, 0.007, zz + 0.007, "Concrete_Light", skip=("+y",))
        mb.pop()
    top = z + floors_n * OFH
    flat_roof(c, x0, y0, x1, y1, top + 0.007, roof="Roof_Flat", parapet=0.03, pmat="Concrete_Light")
    mb.box2(-0.18, -0.15, top, 0.18, 0.15, top + 0.1, "Concrete_Light", skip=("-z",))
    flat_roof(c, -0.18, -0.15, 0.18, 0.15, top + 0.1, parapet=0.0)
    arch.hvac(c, 0.25, 0.22, top + 0.007, 0.06, 0.05, 0.035)
    arch.hvac(c, -0.25, 0.22, top + 0.007, 0.06, 0.05, 0.035)
    for k in range(2):
        arch.antenna(c, -0.1 + k * 0.2, 0.0, top + 0.1, 0.12 + k * 0.05)
    for i, (xx, yy) in enumerate(((-0.42, -0.42), (0.42, -0.42), (0.42, 0.42), (-0.42, 0.42))):
        arch.tree_pit(c, xx, yy, 0.4, "fern", seed=seed + i)


def sky_deco(c, seed=0):
    """Stepped art-deco stone tower with vertical piers and a spire."""
    c.door_mat = "Door_Black"
    lot(c, "Sidewalk")
    base = 0.008
    tiers = [(-0.42, -0.4, 0.42, 0.4, 5), (-0.33, -0.31, 0.33, 0.31, 6), (-0.24, -0.22, 0.24, 0.22, 5),
             (-0.15, -0.14, 0.15, 0.14, 2)]
    z = base
    w = Win(w=0.045, h=0.13, sill=0.02, depth=0.01, frame="Frame_Dark", fw=0.0025, bay=0.07, sill_mat=None,
            mullion=False, transom=True)
    for ti, (x0, y0, x1, y1, n) in enumerate(tiers):
        fl = [(z + k * OFH, z + (k + 1) * OFH) for k in range(n)]
        block(c, x0, y0, x1, y1, fl, w, "Stone_Light",
              lambda s, fi, bi, ti=ti: ("door" if bi == 6 else "shop") if (ti == 0 and fi == 0 and s == "S") else "tall")
        # piers
        for s in "SENW":
            o, ang, ln = SIDES[s]
            p = o(x0, y0, x1, y1)
            L = ln(x0, y0, x1, y1)
            nb = max(1, int(round(L / 0.07)))
            c.mb.push(Matrix.Translation(Vector((p[0], p[1], 0))) @ arch.rotz(ang))
            for i in range(nb + 1):
                xx = L * i / nb
                c.mb.box2(xx - 0.005, -0.006, z + (OFH if ti == 0 else 0), xx + 0.005, 0.0, z + n * OFH + 0.02,
                          "Stone_Light", skip=("+y", "-z"))
            c.mb.pop()
        z += n * OFH
        cornice(c, x0, y0, x1, y1, z, mat="Stone_Light", h=0.02, out=0.008)
        flat_roof(c, x0, y0, x1, y1, z + 0.02, roof="Roof_Flat", parapet=0.012, pmat="Stone_Light")
        z += 0.02
    # crown + spire
    c.mb.lathe([(0.1, 0.0), (0.085, 0.06), (0.05, 0.12), (0.02, 0.2), (0.006, 0.32), (0.0, 0.36)], "Metal_Galv", n=8,
               c=(0, 0, z), smooth=False)
    c.mb.cyl((0, 0, z + 0.36), 0.003, 0.006, "Beacon_Red", n=6)
    for i, xx in enumerate((-0.44, 0.44)):
        arch.tree_pit(c, xx, -0.44, 0.4, "round", seed=seed + i)


def sky_octagon(c, floors_n=18, seed=0):
    """Chamfered (octagonal plan) green-glass tower with banded floors on a stone base."""
    c.door_mat = "Glass_Shop"
    lot(c, "Sidewalk")
    pad(c, -0.46, -0.46, 0.46, -0.3, "Stone_Facade")
    base = 0.006
    _office_lobby(c, -0.38, -0.3, 0.38, 0.38, base, base + OFH * 1.2, "Concrete_Dark")
    z = base + OFH * 1.2
    flat_roof(c, -0.38, -0.3, 0.38, 0.38, z, roof="Roof_Gravel", parapet=0.008, pmat="Concrete_Dark")
    r, ch = 0.3, 0.1
    cy = 0.04
    pts = [(-r + ch, -r), (r - ch, -r), (r, -r + ch), (r, r - ch), (r - ch, r), (-r + ch, r), (-r, r - ch), (-r, -r + ch)]
    pts = [(x, y + cy) for x, y in pts]
    z1 = z + floors_n * OFH
    for i in range(8):
        a, b = pts[i], pts[(i + 1) % 8]
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        curtain(c, (a[0], a[1], 0), ang, L, z, z1, panel=0.055, glass="Glass_Green", spandrel="Metal_White",
                mullion="Metal_White")
    c.mb.prism(pts, z1, z1 + 0.004, "Roof_Flat", caps=(False, True))
    # tapered glass crown
    inner = [(x * 0.6, (y - cy) * 0.6 + cy) for x, y in pts]
    for i in range(8):
        a, b = pts[i], pts[(i + 1) % 8]
        a2, b2 = inner[i], inner[(i + 1) % 8]
        c.mb.poly([(a[0], a[1], z1 + 0.004), (b[0], b[1], z1 + 0.004), (b2[0], b2[1], z1 + 0.16), (a2[0], a2[1], z1 + 0.16)],
                  "Glass_Green")
    c.mb.poly([(x, y, z1 + 0.16) for x, y in inner], "Metal_White")
    c.mb.cyl((0, cy, z1 + 0.16), 0.004, 0.2, "Metal_Galv", n=6, r2=0.0015)
    for i, xx in enumerate((-0.42, 0.42)):
        arch.tree_pit(c, xx, 0.42, 0.42, "broad", seed=seed + i)


REGISTRY = {
    "zones/c1/corner_store": (corner_store, {}),
    "zones/c1/cafe": (cafe, {}),
    "zones/c1/shop_row": (shop_row, {}),
    "zones/c1/mini_mart": (mini_mart, {}),
    "zones/c1/bank": (bank, {}),
    "zones/c2/office_ribbon": (office_ribbon, {"_lit": "Glass_Curtain"}),
    "zones/c2/office_stone": (office_stone, {}),
    "zones/c2/office_glass": (office_glass, {"_lit": "Glass_Curtain"}),
    "zones/c2/office_loft": (office_loft, {}),
    "zones/c3/sky_glass": (sky_glass, {"_lit": "Glass_Curtain"}),
    "zones/c3/sky_grid": (sky_grid, {}),
    "zones/c3/sky_deco": (sky_deco, {}),
    "zones/c3/sky_octagon": (sky_octagon, {"_lit": "Glass_Green"}),
}
