"""Service buildings, part 2: park, city hall, stadium, train station, university, landfill, airport.

Scripted parts: Floodlight_<n> lamp heads on the stadium masts, and one object named "Beacon" on the
airport control tower."""

import math

from mathutils import Matrix, Vector

import arch
import core
from arch import FH, Win, block, flat_roof, gable_roof, hip_roof, lot, pad
from core import MB, rotz
from nature import hedge, tree
from indkit import T, beam, container, fence_line, man_door, pipe, shed, strip_window, truck, tube
from services import part, flagpole, light_bar, _letters_sign
from zones_com import bench, curtain
from zones_res2 import cornice

core.MATS.update({
    "Copper_Patina": ("flat", (0.24, 0.44, 0.37), 0.55, 0.3, {}),
    "Gold": ("flat", (0.85, 0.62, 0.22), 0.25, 1.0, {}),
    "Seat_Red": ("flat", (0.45, 0.05, 0.05), 0.5, 0.0, {}),
    "Seat_Blue": ("flat", (0.05, 0.12, 0.38), 0.5, 0.0, {}),
    "Seat_White": ("flat", (0.75, 0.75, 0.74), 0.5, 0.0, {}),
    "Turf": ("tex", "leafy_grass", 2.0, (0.72, 0.95, 0.62)),
    "Turf_Dark": ("tex", "leafy_grass", 2.0, (0.58, 0.8, 0.5)),
    "Train_White": ("flat", (0.82, 0.83, 0.82), 0.3, 0.2, {"coat": 0.6}),
    "Train_Red": ("flat", (0.6, 0.04, 0.04), 0.3, 0.2, {"coat": 0.6}),
    "Garbage": ("tex", "rocks_ground_02", 1.5, (0.7, 0.66, 0.6)),
})

Z0 = 0.004


def _trees(c, pts, kinds=("broad", "round"), seed=0, h=(0.32, 0.46)):
    for i, (x, y) in enumerate(pts):
        tree(c.mb, c.fol, x, y, h=c.rnd.uniform(*h), kind=kinds[i % len(kinds)], seed=seed + i, z0=Z0)


def lamp(c, x, y, h=0.09):
    mb = c.mb
    mb.cyl((x, y, Z0), 0.0018, h, "Metal_Dark", n=6)
    mb.cyl((x, y, Z0 + h), 0.006, 0.012, "Lamp_Glow", n=8, r2=0.004)
    mb.cyl((x, y, Z0 + h + 0.012), 0.007, 0.002, "Metal_Dark", n=8)


def fountain(c, x, y, r=0.07):
    mb = c.mb
    mb.lathe([(r, 0.0), (r, 0.018), (r - 0.008, 0.018), (r - 0.008, 0.01)], "Trim_Stone", n=24, c=(x, y, Z0),
             smooth=False)
    mb.cyl((x, y, Z0 + 0.012), r - 0.008, 0.0005, "Water", n=24, caps=(False, True))
    mb.lathe([(0.01, 0.0), (0.008, 0.04), (0.03, 0.045), (0.03, 0.05), (0.006, 0.052), (0.005, 0.07),
              (0.014, 0.072), (0.0, 0.08)], "Trim_Stone", n=12, c=(x, y, Z0 + 0.01))
    mb.cyl((x, y, Z0 + 0.054), 0.027, 0.0005, "Water", n=12, caps=(False, True))


def ring_path(c, x, y, r0, r1, mat="Gravel", n=32):
    c.mb.lathe([(r0, 0.0), (r1, 0.0), (r1, 0.0015), (r0, 0.0015)], mat, n=n, c=(x, y, Z0), smooth=False)


# ----------------------------------------------------------------------------- park

def park(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    ring_path(c, 0.0, 0.0, 0.11, 0.15)
    for (a, b, cc, d) in ((-0.47, -0.02, -0.15, 0.02), (0.15, -0.02, 0.47, 0.02), (-0.02, -0.47, 0.02, -0.15),
                          (-0.02, 0.15, 0.02, 0.47)):
        pad(c, a, b, cc, d, "Gravel", h=0.0015)
    fountain(c, 0.0, 0.0, 0.08)
    # pond (irregular) in the north-east quarter
    pts = [(0.17 + 0.12 * math.cos(t) * (1 + 0.18 * math.sin(3 * t)), 0.27 + 0.1 * math.sin(t) * (1 + 0.12 * math.cos(2 * t)))
           for t in [2 * math.pi * k / 20 for k in range(20)]]
    edge = [(0.17 + (px - 0.17) * 1.08, 0.27 + (py - 0.27) * 1.1) for px, py in pts]
    mb.prism(edge, Z0, Z0 + 0.004, "Rock", caps=(False, True))
    mb.prism(pts, Z0, Z0 + 0.0045, "Water", caps=(False, True))
    # benches, lamps, trees, hedges
    for (x, y, rz) in ((-0.07, -0.19, 0.0), (0.07, -0.19, 0.0), (-0.19, 0.07, -math.pi / 2), (0.19, -0.07, math.pi / 2),
                       (-0.07, 0.19, math.pi)):
        bench(c, x, y, rz)
    for (x, y) in ((-0.04, -0.3), (0.04, 0.32), (-0.3, 0.04), (0.32, -0.04), (0.12, 0.12), (-0.12, -0.12)):
        lamp(c, x, y)
    _trees(c, [(-0.34, -0.34), (-0.22, -0.4), (-0.4, -0.18), (0.34, -0.34), (0.4, -0.2), (-0.34, 0.34),
               (-0.18, 0.4), (-0.4, 0.2), (0.42, 0.42)], kinds=("broad", "round", "birch", "fern", "conifer"), seed=seed,
           h=(0.3, 0.46))
    for (a, b, cc, d) in ((-0.46, -0.46, -0.05, -0.46), (0.05, -0.46, 0.46, -0.46)):
        hedge(mb, c.fol, a, b, cc, d, h=0.025, w=0.022, seed=seed, z0=Z0)
    for (x, y) in ((0.26, -0.26), (-0.26, 0.24), (0.06, 0.22)):
        tree(mb, c.fol, x, y, h=0.05, kind="shrub", seed=seed + int(x * 100), z0=Z0)
    # flower beds around the fountain ring
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        x, y = math.cos(a) * 0.24, math.sin(a) * 0.24
        if k == 0:
            continue
        mb.cyl((x, y, Z0), 0.04, 0.006, "Dirt", n=14)
        hedge(mb, c.fol, x - 0.03, y, x + 0.03, y, h=0.014, w=0.03, seed=seed + k, z0=Z0 + 0.004)


# ----------------------------------------------------------------------------- city hall

def city_hall(c, seed=0):
    lot(c, "Sidewalk")
    mb = c.mb
    pad(c, -0.46, -0.46, 0.46, -0.2, "Stone_Facade", h=0.0015)
    x0, y0, x1, y1 = -0.4, -0.08, 0.4, 0.34
    fh = 0.17
    c.door_mat = "Wood_Dark"
    w = Win(w=0.045, h=0.11, sill=0.035, frame="Frame_White", bay=0.08, transom=True, sill_mat="Stone_Light",
            lintel="Stone_Light", lit=0.4)
    # rusticated base + two piano-nobile floors
    block(c, x0, y0, x1, y1, [(Z0, Z0 + fh)], Win(**{**w.__dict__, "h": 0.08}), "Stone_Facade",
          lambda s, fi, bi: "door" if (s == "S" and bi == 5) else "win")
    arch.band(c, x0, y0, x1, y1, Z0 + fh, 0.01, "Stone_Light", out=0.005)
    block(c, x0, y0, x1, y1, [(Z0 + fh + 0.01, Z0 + 2 * fh + 0.01), (Z0 + 2 * fh + 0.01, Z0 + 3 * fh)], w,
          "Stone_Light", lambda s, fi, bi: "tall" if fi == 0 else "win")
    top = Z0 + 3 * fh
    cornice(c, x0, y0, x1, y1, top, mat="Stone_Light", h=0.02, out=0.012)
    # balustrade
    mb.box2(x0, y0, top + 0.02, x1, y1, top + 0.024, "Stone_Light")
    flat_roof(c, x0, y0, x1, y1, top + 0.02, roof="Roof_Slate", parapet=0.03, pmat="Stone_Light", cap="Stone_Light")
    # portico: steps, columns, entablature, pediment
    px0, px1, py0 = -0.16, 0.16, -0.2
    for k in range(4):
        mb.box2(px0 - 0.04 + k * 0.006, py0 - 0.05 + k * 0.012, Z0, px1 + 0.04 - k * 0.006, y0, Z0 + 0.008 * (k + 1),
                "Stone_Light", skip=("-z",))
    zc = Z0 + 0.032
    hcol = 2 * fh - 0.02
    for k in range(6):
        xx = px0 + 0.02 + k * (px1 - px0 - 0.04) / 5
        mb.cyl((xx, py0 + 0.012, zc), 0.0105, hcol, "Stone_Light", n=12, r2=0.009)
        mb.box((xx, py0 + 0.012, zc + 0.003), (0.026, 0.026, 0.006), "Stone_Light")
        mb.box((xx, py0 + 0.012, zc + hcol - 0.003), (0.026, 0.026, 0.006), "Stone_Light")
    ze = zc + hcol
    mb.box2(px0 - 0.005, py0 - 0.006, ze, px1 + 0.005, y0, ze + 0.035, "Stone_Light")
    # recessed portico wall in shade-toned stone so the colonnade reads against it
    core.MATS.setdefault("Stone_Shadow", ("tex", "rectangular_facade_tiles_02", 3.0, (0.58, 0.56, 0.53)))
    mb.box2(px0 + 0.01, py0 + 0.03, zc + 0.0, px1 - 0.01, y0 - 0.005, ze, "Stone_Shadow", skip=("-z",))
    mb.box2(-0.025, py0 + 0.027, zc, 0.025, py0 + 0.031, zc + 0.11, "Wood_Dark")
    mb.box2(-0.03, py0 + 0.026, zc + 0.11, 0.03, py0 + 0.031, zc + 0.12, "Stone_Light")
    for xx in (-0.09, 0.09):
        mb.box2(xx - 0.018, py0 + 0.027, zc + 0.04, xx + 0.018, py0 + 0.031, zc + 0.16, c.glass("Glass", 0.5))
        mb.box2(xx - 0.022, py0 + 0.026, zc + 0.16, xx + 0.022, py0 + 0.032, zc + 0.168, "Stone_Light")
    mb.prism([(px0 - 0.005, 0.0), (px1 + 0.005, 0.0), (0.0, 0.075)], -y0, -(py0 - 0.006), "Stone_Light",
             axis=Matrix.Translation(Vector((0, 0, ze + 0.035))) @ Matrix.Rotation(math.pi / 2, 4, "X"))
    mb.polyo([(px0 + 0.03, py0 - 0.0065, ze + 0.04), (px1 - 0.03, py0 - 0.0065, ze + 0.04),
              (0.0, py0 - 0.0065, ze + 0.095)], "Stone_Facade", (0, -1, 0))
    # drum + dome + lantern
    dx, dy = 0.0, 0.13
    zd = top + 0.05
    mb.cyl((dx, dy, top + 0.02), 0.14, 0.03, "Stone_Light", n=24)
    mb.cyl((dx, dy, zd), 0.12, 0.1, "Stone_Light", n=24)
    for k in range(12):
        a = 2 * math.pi * k / 12
        mb.box((dx + math.cos(a) * 0.121, dy + math.sin(a) * 0.121, zd + 0.05), (0.018, 0.004, 0.06),
               c.glass("Glass", 0.4), rz=a + math.pi / 2)
        mb.cyl((dx + math.cos(a + 0.26) * 0.126, dy + math.sin(a + 0.26) * 0.126, zd), 0.005, 0.1, "Stone_Light",
               n=8)
    mb.cyl((dx, dy, zd + 0.1), 0.13, 0.012, "Stone_Light", n=24)
    prof = [(0.122 * math.cos(t), 0.13 * math.sin(t)) for t in [k * math.pi / 2 / 8 for k in range(9)]]
    mb.lathe(prof, "Copper_Patina", n=24, c=(dx, dy, zd + 0.112))
    for k in range(8):
        a = 2 * math.pi * k / 8
        pts = [(dx + math.cos(a) * pr * 1.01, dy + math.sin(a) * pr * 1.01, zd + 0.112 + pz) for pr, pz in prof[:-1]]
        for p, q in zip(pts[:-1], pts[1:]):
            beam(mb, p, q, 0.004, 0.003, "Copper_Patina")
    zl = zd + 0.112 + 0.128
    mb.cyl((dx, dy, zl), 0.022, 0.04, "Stone_Light", n=12)
    mb.lathe([(0.026, 0.0), (0.0, 0.03)], "Copper_Patina", n=12, c=(dx, dy, zl + 0.04))
    mb.cyl((dx, dy, zl + 0.07), 0.002, 0.05, "Gold", n=6)
    mb.sphere((dx, dy, zl + 0.07), 0.006, "Gold", n=8, rings=6)
    # plaza: fountain, flags, trees
    fountain(c, 0.3, -0.34, 0.06)
    for xx, fl in ((-0.25, "Sign_Blue"), (-0.31, "Sign_Red"), (-0.37, "Sign_White")):
        flagpole(c, xx, -0.3, h=0.2, flag=fl)
    _trees(c, [(-0.43, -0.43), (0.43, -0.43), (-0.44, 0.0), (0.44, 0.0)], kinds=("round",), seed=seed,
           h=(0.34, 0.4))
    for (x, y, rz) in ((-0.1, -0.42, 0.0), (0.1, -0.42, 0.0)):
        bench(c, x, y, rz)


# ----------------------------------------------------------------------------- stadium

def stadium(c, seed=0):
    lot(c, "Concrete_Light")
    mb = c.mb
    sy = 0.78
    R_out = 0.44
    mb.push(Matrix.Diagonal((1.0, sy, 1.0, 1.0)))
    # pitch surround + running track
    mb.cyl((0, 0, Z0), 0.27, 0.002, "Track_Red" if "Track_Red" in core.MATS else "Asphalt", n=40,
           caps=(False, True))
    # stands: stepped seating rings
    tiers = 9
    prof = [(0.27, 0.002)]
    mats = []
    for k in range(tiers):
        r_in = 0.27 + k * 0.016
        z = 0.012 + k * 0.022
        prof += [(r_in, z), (r_in + 0.016, z)]
        mats += ["Concrete_Light", "Seat_Blue" if (k // 3) % 2 == 0 else "Seat_White"]
    prof += [(R_out - 0.02, 0.012 + tiers * 0.022 + 0.02), (R_out, 0.012 + tiers * 0.022 + 0.02)]
    mats += ["Concrete_Light", "Concrete"]
    mb.lathe([(p[0], p[1] + Z0) for p in prof], "Concrete_Light", n=40, mats=mats, smooth=False)
    zt = Z0 + 0.012 + tiers * 0.022 + 0.02
    # facade with vertical ribs and gates
    mb.lathe([(R_out, Z0), (R_out, zt)], "Concrete", n=40, smooth=True)
    for k in range(20):
        a = 2 * math.pi * k / 20
        mb.box((math.cos(a) * (R_out + 0.004), math.sin(a) * (R_out + 0.004), (Z0 + zt + 0.07) / 2),
               (0.012, 0.008, zt + 0.07 - Z0), "Metal_White", rz=a + math.pi / 2)
    mb.lathe([(R_out + 0.0015, Z0 + 0.03), (R_out + 0.0015, Z0 + 0.12)], "Glass", n=40)
    # roof canopy ring
    mb.lathe([(0.33, zt + 0.06), (R_out + 0.012, zt + 0.07), (R_out + 0.012, zt + 0.08), (0.33, zt + 0.07)],
             "Metal_White", n=40, smooth=False)
    mb.lathe([(0.33, zt + 0.07), (0.33, zt + 0.06)], "Metal_White", n=40)
    mb.pop()
    # pitch with mowing stripes and markings
    PX, PY = 0.2, 0.13
    for k in range(10):
        x0 = -PX + 2 * PX * k / 10
        mb.box2(x0, -PY, Z0 + 0.002, x0 + 2 * PX / 10, PY, Z0 + 0.003, "Turf" if k % 2 else "Turf_Dark",
                skip=("-z",))
    lw = 0.0018
    zz = Z0 + 0.0031
    for (a, b, cc, d) in ((-PX + 0.01, -PY + 0.01, PX - 0.01, -PY + 0.01 + lw), (-PX + 0.01, PY - 0.01 - lw, PX - 0.01, PY - 0.01),
                          (-PX + 0.01, -PY + 0.01, -PX + 0.01 + lw, PY - 0.01), (PX - 0.01 - lw, -PY + 0.01, PX - 0.01, PY - 0.01),
                          (-lw / 2, -PY + 0.01, lw / 2, PY - 0.01)):
        mb.box2(a, b, zz, cc, d, zz + 0.0003, "Paint_White", skip=("-z",))
    mb.lathe([(0.03, 0.0), (0.03 + lw, 0.0), (0.03 + lw, 0.0003), (0.03, 0.0003)], "Paint_White", n=24,
             c=(0, 0, zz), smooth=False)
    for s in (-1, 1):
        x = s * (PX - 0.01)
        mb.box2(min(x, x - s * 0.05), -0.06, zz, max(x, x - s * 0.05), -0.06 + lw, zz + 0.0003, "Paint_White",
                skip=("-z",))
        mb.box2(min(x, x - s * 0.05), 0.06 - lw, zz, max(x, x - s * 0.05), 0.06, zz + 0.0003, "Paint_White",
                skip=("-z",))
        mb.box2(x - s * 0.05 - lw / 2, -0.06, zz, x - s * 0.05 + lw / 2, 0.06, zz + 0.0003, "Paint_White",
                skip=("-z",))
        mb.box2(min(x, x + s * 0.006), -0.018, Z0, max(x, x + s * 0.006), 0.018, Z0 + 0.012, "Metal_White")
    # floodlight masts at the corners, heads aimed at the pitch
    for i, (sx, sy2) in enumerate(((-1, -1), (1, -1), (1, 1), (-1, 1))):
        mx, my = sx * 0.43, sy2 * 0.4
        mb.lathe([(0.009, 0.0), (0.005, 0.68)], "Metal_Galv", n=8, c=(mx, my, Z0))
        mb.box2(mx - 0.004, my - 0.004, Z0, mx + 0.004, my + 0.004, Z0 + 0.02, "Concrete")
        yaw = math.atan2(-my, -mx)

        def head(mb, yaw=yaw):
            mb.push(rotz(yaw - math.pi / 2) @ Matrix.Rotation(math.radians(-30), 4, "X"))
            mb.box((0, 0, 0), (0.07, 0.008, 0.045), "Metal_Dark", mats={"-y": "Flood_Glow"} if False else None)
            for r in range(3):
                for k in range(4):
                    mb.box((-0.0255 + k * 0.017, 0.0045, -0.015 + r * 0.015), (0.013, 0.0015, 0.011), "Flood_Glow")
            mb.pop()

        part("Floodlight_%d" % i, (mx, my, Z0 + 0.69), head)


# ----------------------------------------------------------------------------- train station

def _track(c, y, x0=-0.47, x1=0.47):
    mb = c.mb
    mb.box2(x0, y - 0.045, Z0, x1, y + 0.045, Z0 + 0.006, "Gravel", skip=("-z",))
    n = int((x1 - x0) / 0.03)
    for k in range(n):
        xx = x0 + (k + 0.5) * (x1 - x0) / n
        mb.box2(xx - 0.006, y - 0.032, Z0 + 0.006, xx + 0.006, y + 0.032, Z0 + 0.009, "Concrete_Dark", skip=("-z",))
    for s in (-1, 1):
        mb.box2(x0, y + s * 0.0215 - 0.0015, Z0 + 0.009, x1, y + s * 0.0215 + 0.0015, Z0 + 0.0125, "Metal_Galv",
                skip=("-z",))


def _carriage(c, x, y, L=0.42, W=0.13, H=0.17, cab=False, livery=("Train_White", "Train_Red")):
    mb = c.mb
    z0 = Z0 + 0.0125
    mb.box2(x - L / 2, y - W / 2 + 0.01, z0 + 0.01, x + L / 2, y + W / 2 - 0.01, z0 + 0.03, "Metal_Dark")
    zb = z0 + 0.03
    mb.box2(x - L / 2, y - W / 2, zb, x + L / 2, y + W / 2, zb + H * 0.82, livery[0])
    mb.lathe([(0.0, -L / 2), (W / 2, -L / 2), (W / 2, L / 2), (0.0, L / 2)], livery[0], n=12,
             c=(x, y, zb + H * 0.82 - W * 0.22), axis=Matrix.Rotation(math.pi / 2, 4, "Y") @
             Matrix.Diagonal((0.5, 1.0, 1.0, 1.0)), a0=0, a1=math.pi, smooth=True)
    for s in (-1, 1):
        yy = y + s * (W / 2 + 0.0006)
        mb.polyo([(x - L / 2 + 0.01, yy, zb + 0.07), (x + L / 2 - 0.01, yy, zb + 0.07),
                  (x + L / 2 - 0.01, yy, zb + 0.11), (x - L / 2 + 0.01, yy, zb + 0.11)], c.glass("Glass_Car", 0.5),
                 (0, s, 0))
        mb.polyo([(x - L / 2, yy + s * 0.0002, zb + 0.02), (x + L / 2, yy + s * 0.0002, zb + 0.02),
                  (x + L / 2, yy + s * 0.0002, zb + 0.035), (x - L / 2, yy + s * 0.0002, zb + 0.035)], livery[1],
                 (0, s, 0))
        for k in range(4):
            dx = x - L / 2 + 0.06 + k * (L - 0.12) / 3
            mb.polyo([(dx - 0.012, yy + s * 0.0004, zb + 0.005), (dx + 0.012, yy + s * 0.0004, zb + 0.005),
                      (dx + 0.012, yy + s * 0.0004, zb + 0.11), (dx - 0.012, yy + s * 0.0004, zb + 0.11)],
                     "Metal_Galv", (0, s, 0))
    for s in (-1, 1):
        for b in (-1, 1):
            mb.box2(x + b * L * 0.36 - 0.03, y - W / 2 + 0.02, z0, x + b * L * 0.36 + 0.03, y + W / 2 - 0.02, z0 + 0.012,
                    "Metal_Dark")


def train_station(c, seed=0):
    lot(c, "Sidewalk")
    mb = c.mb
    t1, t2 = 0.08, 0.32
    _track(c, t1)
    _track(c, t2)
    # island platform between the tracks, side platform at the station building
    for (pa, pb) in ((t1 + 0.055, t2 - 0.055), (-0.06, t1 - 0.055)):
        mb.box2(-0.44, pa, Z0, 0.44, pb, Z0 + 0.03, "Concrete_Light", mats={"+z": "Sidewalk"})
        for yy in (pa + 0.004, pb - 0.004):
            mb.box2(-0.44, yy - 0.002, Z0 + 0.03, 0.44, yy + 0.002, Z0 + 0.0303, "Paint_Yellow", skip=("-z",))
    # canopies
    for (yc, w) in (((t1 + t2) / 2, 0.1), (-0.035, 0.05)):
        for k in range(7):
            xx = -0.36 + k * 0.12
            mb.box2(xx - 0.003, yc - 0.003, Z0 + 0.03, xx + 0.003, yc + 0.003, Z0 + 0.15, "Metal_Green", skip=("-z",))
        mb.box2(-0.4, yc - w / 2 - 0.02, Z0 + 0.15, 0.4, yc + w / 2 + 0.02, Z0 + 0.158, "Metal_Corrugated",
                mats={"-z": "Metal_Green"})
        mb.box2(-0.4, yc - 0.012, Z0 + 0.158, 0.4, yc + 0.012, Z0 + 0.168, "Glass_Curtain")
    for k in range(3):
        bench(c, -0.3 + k * 0.3, (t1 + t2) / 2 + 0.02, 0.0)
        lamp(c, -0.24 + k * 0.3, (t1 + t2) / 2 - 0.03, h=0.1) if False else None
    _carriage(c, -0.2, t2, L=0.44)
    _carriage(c, 0.255, t2, L=0.44)
    _carriage(c, 0.12, t1, L=0.44, livery=("Train_White", "Sign_Blue"))
    # station building on the south side
    x0, y0, x1, y1 = -0.34, -0.42, 0.3, -0.1
    c.door_mat = "Wood_Dark"
    w = Win(w=0.06, h=0.13, sill=0.02, frame="Frame_Dark", bay=0.1, transom=True, sill_mat="Trim_Stone",
            lintel="Trim_Stone", lit=0.45)
    block(c, x0, y0, x1, y1, [(Z0, Z0 + 0.2)], w, "Brick_Red",
          lambda s, fi, bi: ("door" if bi in (2, 3, 4) else "tall") if s == "S" else "tall")
    cornice(c, x0, y0, x1, y1, Z0 + 0.2, mat="Trim_Stone", h=0.012, out=0.006)
    gable_roof(c, x0, y0, x1, y1, Z0 + 0.212, 0.07, "Roof_Slate", "Brick_Red", ridge="x", gutter="Metal_Dark",
               fascia="Trim_Stone")
    # clock tower
    cx0, cx1, cy0, cy1 = 0.3, 0.42, -0.36, -0.24
    tw = Win(w=0.03, h=0.1, sill=0.04, frame="Frame_Dark", bay=0.06, sill_mat="Trim_Stone", lit=0.2)
    block(c, cx0, cy0, cx1, cy1, [(Z0, Z0 + 0.2), (Z0 + 0.2, Z0 + 0.4)], tw, "Brick_Red")
    cornice(c, cx0, cy0, cx1, cy1, Z0 + 0.4, mat="Trim_Stone", h=0.01, out=0.006)
    block(c, cx0, cy0, cx1, cy1, [(Z0 + 0.41, Z0 + 0.5)], tw, "Brick_Red", lambda s, fi, bi: "wall")
    for (px, py, rz) in (((cx0 + cx1) / 2, cy0 - 0.001, 0.0), (cx1 + 0.001, (cy0 + cy1) / 2, math.pi / 2)):
        mb.push(T(px, py, Z0 + 0.455) @ rotz(rz))
        mb.cyl((0, 0, 0), 0.035, 0.002, "Sign_White", n=20, axis=Matrix.Rotation(math.pi / 2, 4, "X"))
        mb.cyl((0, 0, 0), 0.037, 0.0015, "Gold", n=20, axis=Matrix.Rotation(math.pi / 2, 4, "X"), caps=(False, False))
        mb.box((0, -0.003, 0.01), (0.003, 0.001, 0.022), "Door_Black")
        mb.box((0.008, -0.003, 0.0), (0.017, 0.001, 0.003), "Door_Black")
        mb.pop()
    hip_roof(c, cx0, cy0, cx1, cy1, Z0 + 0.5, 0.09, "Roof_Slate", oh=0.008, gutter=None, fascia="Trim_Stone")
    _letters_sign(c, -0.02, y0 - 0.004, Z0 + 0.185, 0.3, 0.018, bg="Sign_Blue")
    _trees(c, [(-0.42, -0.42), (-0.42, -0.18)], kinds=("round",), seed=seed, h=(0.3, 0.36))
    for k in range(3):
        mb.box2(-0.2 + k * 0.17, -0.47, Z0, -0.12 + k * 0.17, -0.462, Z0 + 0.003, "Paint_White", skip=("-z",))


# ----------------------------------------------------------------------------- university

def university(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    # quad paths
    pad(c, -0.03, -0.47, 0.03, 0.1, "Sidewalk", h=0.0015)
    pad(c, -0.3, -0.08, 0.3, -0.03, "Sidewalk", h=0.0015)
    ring_path(c, 0.0, -0.22, 0.06, 0.09, mat="Sidewalk")
    # main hall with a clock tower (north side of the quad)
    x0, y0, x1, y1 = -0.4, 0.12, 0.4, 0.4
    c.door_mat = "Wood_Dark"
    w = Win(w=0.045, h=0.1, sill=0.03, frame="Frame_White", bay=0.08, transom=True, sill_mat="Stone_Light",
            lintel="Stone_Light", lit=0.45)
    fl = [(Z0, Z0 + 0.16), (Z0 + 0.16, Z0 + 0.32), (Z0 + 0.32, Z0 + 0.46)]
    block(c, x0, y0, x1, y1, fl, w, "Brick_Red", lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 5) else "win")
    arch.band(c, x0, y0, x1, y1, Z0 + 0.16, 0.008, "Stone_Light", out=0.003)
    cornice(c, x0, y0, x1, y1, Z0 + 0.46, mat="Stone_Light", h=0.012, out=0.006)
    gable_roof(c, x0, y0, x1, y1, Z0 + 0.472, 0.08, "Roof_Slate", "Brick_Red", ridge="x", gutter="Metal_Dark",
               fascia="Stone_Light")
    tx0, tx1, ty0, ty1 = -0.06, 0.06, 0.06, 0.18
    tw = Win(w=0.035, h=0.11, sill=0.04, frame="Frame_White", bay=0.06, sill_mat="Stone_Light", lit=0.35)
    block(c, tx0, ty0, tx1, ty1, [(Z0, Z0 + 0.16), (Z0 + 0.16, Z0 + 0.32), (Z0 + 0.32, Z0 + 0.48),
                                  (Z0 + 0.48, Z0 + 0.62)], tw, "Stone_Light",
          lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 1) else "win")
    cornice(c, tx0, ty0, tx1, ty1, Z0 + 0.62, mat="Stone_Light", h=0.012, out=0.006)
    for (px, py, rz) in ((0.0, ty0 - 0.002, 0.0),):
        mb.push(T(px, py, Z0 + 0.58) @ rotz(rz))
        mb.cyl((0, 0, 0), 0.03, 0.002, "Sign_White", n=20, axis=Matrix.Rotation(math.pi / 2, 4, "X"))
        mb.box((0, -0.003, 0.008), (0.003, 0.001, 0.018), "Door_Black")
        mb.box((0.006, -0.003, 0.0), (0.014, 0.001, 0.003), "Door_Black")
        mb.pop()
    mb.prism([(tx0 - 0.004, ty0 - 0.004), (tx1 + 0.004, ty0 - 0.004), (tx1 + 0.004, ty1 + 0.004),
              (tx0 - 0.004, ty1 + 0.004)], Z0 + 0.632, Z0 + 0.64, "Stone_Light")
    mb.lathe([(0.055, 0.0), (0.0, 0.16)], "Roof_Slate", n=4, c=(0, (ty0 + ty1) / 2, Z0 + 0.64), smooth=False,
             a0=math.pi / 4, a1=math.pi / 4 + 2 * math.pi)
    mb.cyl((0, (ty0 + ty1) / 2, Z0 + 0.8), 0.0015, 0.04, "Gold", n=6)
    # side wings framing the quad
    ww = Win(w=0.05, h=0.08, sill=0.035, frame="Frame_White", bay=0.085, sill_mat="Stone_Light", lit=0.45)
    for (a, b) in ((-0.44, -0.3), (0.3, 0.44)):
        block(c, a, -0.4, b, 0.06, [(Z0, Z0 + 0.15), (Z0 + 0.15, Z0 + 0.3)], ww, "Stone_Light",
              lambda s, fi, bi: "door" if (fi == 0 and s in "EW" and bi == 2) else "win")
        gable_roof(c, a, -0.4, b, 0.06, Z0 + 0.3, 0.06, "Roof_Slate", "Stone_Light", ridge="y", gutter="Metal_Dark",
                   fascia="Stone_Light")
    # statue + trees + benches
    mb.box2(-0.015, -0.237, Z0, 0.015, -0.203, Z0 + 0.04, "Stone_Light")
    mb.cyl((0, -0.22, Z0 + 0.04), 0.006, 0.03, "Copper_Patina", n=8)
    mb.sphere((0, -0.22, Z0 + 0.076), 0.006, "Copper_Patina", n=8, rings=6)
    _trees(c, [(-0.18, -0.3), (0.18, -0.3), (-0.18, -0.15), (0.18, -0.15), (-0.2, 0.0), (0.2, 0.0)],
           kinds=("broad", "round"), seed=seed, h=(0.28, 0.36))
    for (x, y, rz) in ((-0.1, -0.12, 0.0), (0.1, -0.12, 0.0), (-0.1, -0.33, math.pi), (0.1, -0.33, math.pi)):
        bench(c, x, y, rz)


# ----------------------------------------------------------------------------- landfill

def landfill(c, seed=0):
    lot(c, "Dirt")
    mb = c.mb
    rnd = c.rnd
    # capped (grassed) terraces and the active tipping face
    mb.push(T(0.04, 0.12) @ Matrix.Diagonal((1.0, 0.8, 1.0, 1.0)))
    prof = [(0.4, 0.0), (0.33, 0.06), (0.3, 0.065), (0.24, 0.13), (0.21, 0.135), (0.14, 0.19), (0.0, 0.2)]
    mb.lathe([(r, z + Z0) for r, z in prof], "Grass", n=24, mats=["Grass", "Dirt", "Grass", "Dirt", "Garbage", "Garbage"],
             smooth=True)
    mb.pop()
    for k in range(60):
        a = rnd.uniform(0, 2 * math.pi)
        r = rnd.uniform(0.0, 0.17)
        x, y = 0.04 + math.cos(a) * r, 0.12 + math.sin(a) * r * 0.8
        t = r / 0.21
        z = Z0 + 0.2 - 0.065 * max(0.0, (r - 0.14) / 0.07) - 0.01 * t
        m = rnd.choice(["Plastic_Blue", "Fabric_Cream", "Plastic_Black", "Metal_Rusty", "Plastic_Orange", "Wood",
                        "Fabric_Red", "Plastic_Green", "Sign_White"])
        s = rnd.uniform(0.006, 0.016)
        mb.box((x, y, z), (s, s * rnd.uniform(0.5, 1.2), s * 0.5), m, rz=rnd.uniform(0, 3))
    # haul road up the mound
    beam(mb, (-0.4, -0.3, Z0 + 0.002), (-0.12, 0.0, Z0 + 0.13), 0.05, 0.004, "Gravel")
    # bulldozer and compactor on top
    for (x, y, rz, col) in ((0.06, 0.16, 0.6, "Metal_Yellow"), (-0.04, 0.06, -0.4, "Metal_Yellow")):
        mb.push(T(x, y, Z0 + 0.2) @ rotz(rz))
        mb.box2(-0.03, -0.035, 0.0, 0.03, 0.035, 0.016, "Rubber")
        mb.box2(-0.022, -0.03, 0.016, 0.022, 0.025, 0.04, col)
        mb.box2(-0.018, 0.0, 0.04, 0.018, 0.025, 0.065, "Glass_Car", mats={"+z": col})
        mb.box2(-0.04, -0.05, 0.0, 0.04, -0.044, 0.025, "Metal_Dark")
        mb.pop()
    # weighbridge, office, fence, garbage truck
    pad(c, -0.46, -0.46, 0.46, -0.3, "Asphalt", h=0.0012)
    mb.box2(-0.1, -0.42, Z0, 0.18, -0.34, Z0 + 0.006, "Metal_Plate")
    container(mb, 0.32, -0.38, Z0, 0.0, "Container_White", L=0.24, W=0.1, H=0.11)
    for xx in (0.25, 0.32, 0.39):
        mb.box2(xx - 0.02, -0.4305, Z0 + 0.04, xx + 0.02, -0.4295, Z0 + 0.085, c.glass("Glass", 0.3))
    truck(c, 0.04, -0.38, math.pi / 2, box_mat="Metal_Green", cab_mat="Paint_white", L=0.38)
    for k in range(4):
        container(mb, -0.4 + k * 0.0, -0.2 + k * 0.0, Z0, 0.0, "Container_Green", L=0.0, W=0.0, H=0.0) if False else None
    for (x, y, m) in ((-0.38, -0.22, "Metal_Green"), (-0.38, -0.12, "Metal_Blue"), (0.4, -0.2, "Metal_Rusty")):
        mb.box2(x - 0.05, y - 0.03, Z0, x + 0.05, y + 0.03, Z0 + 0.05, m, skip=("-z",))
        mb.box2(x - 0.045, y - 0.025, Z0 + 0.04, x + 0.045, y + 0.025, Z0 + 0.055, "Garbage", skip=("-z",))
    fence_line(c, [(-0.462, -0.29), (-0.462, 0.462), (0.462, 0.462), (0.462, -0.29)], h=0.05, mat="Metal_Galv")
    _trees(c, [(-0.43, 0.43), (-0.3, 0.44), (0.43, 0.43), (0.44, 0.3), (0.44, 0.15)], kinds=("conifer", "poplar"),
           seed=seed, h=(0.3, 0.42))


# ----------------------------------------------------------------------------- airport

def _airliner(c, x, y, rz=0.0, s=1.0, livery="Train_White", tail="Sign_Blue"):
    mb = c.mb
    mb.push(T(x, y, Z0) @ rotz(rz) @ Matrix.Scale(s, 4))
    L, R = 0.5, 0.026
    zc = 0.045
    prof = [(0.0, 0.0), (0.012, 0.004), (0.022, 0.018), (R, 0.045), (R, 0.38), (0.018, 0.45), (0.008, 0.49), (0.0, 0.5)]
    mb.lathe([(r, z - L / 2) for r, z in prof], livery, n=14, c=(0, 0, zc), axis=Matrix.Rotation(math.pi / 2, 4, "X"))
    for sgn in (-1, 1):
        mb.polyo([(sgn * (R + 0.0003), -0.226, zc + 0.008), (sgn * (R + 0.0003), -0.218, zc + 0.008),
                  (sgn * (R + 0.0003), -0.218, zc + 0.016), (sgn * (R + 0.0003), -0.226, zc + 0.016)], "Glass_Car",
                 (sgn, 0, 0))
        mb.polyo([(sgn * (R + 0.0002), -0.19, zc + 0.006), (sgn * (R + 0.0002), 0.15, zc + 0.006),
                  (sgn * (R + 0.0002), 0.15, zc + 0.011), (sgn * (R + 0.0002), -0.19, zc + 0.011)], "Glass_Car",
                 (sgn, 0, 0))
        wing = [(sgn * R * 0.6, -0.06), (sgn * 0.23, 0.04), (sgn * 0.23, 0.07), (sgn * R * 0.6, 0.06)]
        mb.prism(wing if sgn > 0 else list(reversed(wing)), zc - 0.012, zc - 0.007, livery)
        stab = [(sgn * 0.006, 0.18), (sgn * 0.085, 0.235), (sgn * 0.085, 0.25), (sgn * 0.006, 0.235)]
        mb.prism(stab if sgn > 0 else list(reversed(stab)), zc + 0.008, zc + 0.011, livery)
        mb.cyl((sgn * 0.085, -0.03, zc - 0.03), 0.011, 0.055, "Metal_Galv", n=10,
               axis=Matrix.Rotation(-math.pi / 2, 4, "X"), r2=0.01)
        mb.box((sgn * 0.022, 0.02, 0.009), (0.004, 0.012, 0.018), "Rubber")
    fin = [(0.17, 0.0), (0.245, 0.0), (0.25, 0.09), (0.225, 0.09)]
    mb.prism(fin, -0.002, 0.002, tail, axis=T(0, 0, zc + 0.015) @ Matrix.Rotation(math.pi / 2, 4, "Y") @
             Matrix.Rotation(math.pi / 2, 4, "Z") @ Matrix.Diagonal((1.0, 1.0, 1.0, 1.0)))
    mb.box((0, -0.2, 0.01), (0.003, 0.006, 0.02), "Rubber")
    mb.pop()


def airport(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    # runway (east-west) with markings
    ry0, ry1 = 0.16, 0.34
    mb.box2(-0.47, ry0, Z0, 0.47, ry1, Z0 + 0.0015, "Asphalt_Dark", skip=("-z",))
    zz = Z0 + 0.0016
    yc = (ry0 + ry1) / 2
    for k in range(9):
        xx = -0.4 + k * 0.1
        mb.box2(xx, yc - 0.002, zz, xx + 0.05, yc + 0.002, zz + 0.0003, "Paint_White", skip=("-z",))
    for s in (-1, 1):
        for k in range(6):
            yy = ry0 + 0.02 + k * (ry1 - ry0 - 0.04) / 5
            mb.box2(s * 0.45 - 0.012, yy - 0.004, zz, s * 0.45 + 0.012, yy + 0.004, zz + 0.0003, "Paint_White",
                    skip=("-z",))
    for yy in (ry0 + 0.006, ry1 - 0.006):
        mb.box2(-0.47, yy - 0.0012, zz, 0.47, yy + 0.0012, zz + 0.0003, "Paint_White", skip=("-z",))
    # taxiway and apron
    mb.box2(-0.44, -0.12, Z0, 0.3, 0.1, Z0 + 0.0012, "Asphalt", skip=("-z",))
    mb.box2(-0.05, 0.1, Z0, 0.0, ry0, Z0 + 0.0012, "Asphalt", skip=("-z",))
    mb.box2(-0.03, -0.1, Z0 + 0.0013, -0.026, ry0, Z0 + 0.0016, "Paint_Yellow", skip=("-z",))
    _airliner(c, -0.18, -0.01, rz=math.pi / 2 + 0.25, s=0.9)
    # terminal
    x0, y0, x1, y1 = -0.44, -0.44, 0.24, -0.16
    curtain_mod = __import__("zones_com")
    curtain_mod.curtain_block(c, x0, y0, x1, y1, Z0, Z0 + 0.16, fh=0.08, panel=0.05, glass="Glass_Curtain",
                              spandrel="Metal_White", mullion="Frame_Alu", lit=0.45)
    mb.push(T((x0 + x1) / 2, (y0 + y1) / 2, Z0 + 0.16))
    w2, d2 = (x1 - x0) / 2 + 0.02, (y1 - y0) / 2 + 0.02
    mb.lathe([(0.0, -w2), (d2, -w2), (d2, w2), (0.0, w2)], "Metal_White", n=10,
             axis=Matrix.Rotation(math.pi / 2, 4, "Y") @ Matrix.Diagonal((0.18, 1.0, 1.0, 1.0)), a0=0, a1=math.pi,
             smooth=True)
    mb.pop()
    mb.box2(x0 - 0.02, y0 - 0.02, Z0 + 0.157, x1 + 0.02, y1 + 0.02, Z0 + 0.163, "Metal_White")
    # jet bridge to the plane
    beam(mb, (-0.18, y1, Z0 + 0.06), (-0.16, -0.08, Z0 + 0.055), 0.022, 0.024, "Metal_Galv")
    _letters_sign(c, -0.1, y0 - 0.004, Z0 + 0.14, 0.3, 0.018, bg="Sign_Blue")
    # control tower with the beacon
    tx, ty = 0.36, -0.3
    mb.lathe([(0.04, 0.0), (0.028, 0.06), (0.024, 0.66)], "Concrete_Light", n=16, c=(tx, ty, Z0))
    zc = Z0 + 0.66
    mb.lathe([(0.024, 0.0), (0.06, 0.03), (0.062, 0.035)], "Concrete_Light", n=8, c=(tx, ty, zc), smooth=False)
    mb.lathe([(0.062, 0.035), (0.07, 0.09)], c.glass("Glass_Curtain", 0.6), n=8, c=(tx, ty, zc), smooth=False)
    mb.lathe([(0.07, 0.09), (0.074, 0.1), (0.05, 0.11), (0.0, 0.112)], "Metal_White", n=8, c=(tx, ty, zc),
             smooth=False)
    mb.cyl((tx, ty, zc + 0.112), 0.003, 0.08, "Metal_Galv", n=6)
    mb.box2(tx - 0.03, ty - 0.003, zc + 0.15, tx + 0.03, ty + 0.003, zc + 0.155, "Metal_Galv")
    light_bar_obj = part("Beacon", (tx, ty, zc + 0.19), lambda mb: (
        mb.cyl((0, 0, 0), 0.006, 0.008, "Beacon_Red", n=8), mb.sphere((0, 0, 0.008), 0.006, "Beacon_Red", n=8, rings=4,
                                                                       hemi=True)))
    # hangar
    hx0, hx1, hy0, hy1 = 0.3, 0.46, -0.12, 0.12
    mb.push(T((hx0 + hx1) / 2, (hy0 + hy1) / 2, Z0))
    mb.lathe([(0.0, -(hx1 - hx0) / 2), ((hy1 - hy0) / 2, -(hx1 - hx0) / 2), ((hy1 - hy0) / 2, (hx1 - hx0) / 2),
              (0.0, (hx1 - hx0) / 2)], "Metal_Corrugated", n=12,
             axis=Matrix.Rotation(math.pi / 2, 4, "Y"), a0=math.pi / 2, a1=1.5 * math.pi,
             smooth=True)
    mb.pop()
    mb.polyo([(hx0, hy0 + 0.02, Z0), (hx0, hy1 - 0.02, Z0), (hx0, hy1 - 0.02, Z0 + 0.09), (hx0, hy0 + 0.02, Z0 + 0.09)],
             "Shutter", (-1, 0, 0))
    # windsock, lights
    mb.cyl((0.0, 0.4, Z0), 0.0015, 0.06, "Metal_White", n=6)
    mb.cyl((0.0, 0.4, Z0 + 0.055), 0.006, 0.03, "Plastic_Orange", n=8, r2=0.003,
           axis=Matrix.Rotation(math.pi / 2, 4, "Y"))
    for k in range(10):
        xx = -0.45 + k * 0.1
        for yy in (ry0 - 0.006, ry1 + 0.006):
            mb.cyl((xx, yy, Z0), 0.002, 0.006, "Lamp_Glow", n=6)
    car_park_mod = __import__("indkit")
    car_park_mod.car_park(c, -0.44, -0.47 + 0.0, 0.0, -0.45, 1, fill=0.0) if False else None


REGISTRY = {
    "buildings/park": (park, {}),
    "buildings/city_hall": (city_hall, {}),
    "buildings/stadium": (stadium, {}),
    "buildings/train_station": (train_station, {}),
    "buildings/university": (university, {}),
    "buildings/landfill": (landfill, {}),
    "buildings/airport": (airport, {"_lit": "Glass_Curtain"}),
}
