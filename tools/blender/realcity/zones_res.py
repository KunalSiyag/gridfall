"""Residential zones: r1 detached houses, r2 walk-ups/townhouses, r3 towers."""

import math

from mathutils import Matrix, Vector

import arch
from arch import FH, Win, block, flat_roof, gable_roof, hip_roof, facade, lot, pad
from nature import tree, hedge


def _yard(c, drive_x=(0.18, 0.32), drive_to=-0.1, path_x=0.0, path_to=-0.12, mat_drive="Concrete_Floor"):
    lot(c, "Grass")
    if drive_x:
        pad(c, drive_x[0], -0.47, drive_x[1], drive_to, mat_drive)
    if path_x is not None:
        pad(c, path_x - 0.018, -0.47, path_x + 0.018, path_to, "Sidewalk", h=0.0010)


def _landscape(c, trees=(), shrubs=(), seed=0):
    for i, (x, y, h, k) in enumerate(trees):
        tree(c.mb, c.fol, x, y, h=h, kind=k, seed=seed + i)
    for i, (x, y, s) in enumerate(shrubs):
        tree(c.mb, c.fol, x, y, h=s, kind="shrub", seed=seed + 50 + i, z0=0.004)


def house_gable(c, wall="Siding_White", roof="Roof_Shingle", trim="Trim_White", door="Door_Red", shutters="Door_Black",
                garage=True, seed=0):
    c.door_mat = door
    _yard(c, drive_x=(0.17, 0.33) if garage else None, drive_to=-0.07, path_x=-0.08, path_to=-0.13)
    x0, x1, y0, y1 = -0.30, 0.12, -0.13, 0.17
    base = 0.008
    c.mb.box2(x0 - 0.003, y0 - 0.003, 0.0, x1 + 0.003, y1 + 0.003, base, "Concrete", skip=("-z",))
    floors = [(base, base + FH), (base + FH, base + 2 * FH)]
    w = Win(w=0.055, h=0.08, sill=0.045, frame="Frame_White", shutters=shutters, bay=0.105, sill_mat=trim)

    def kinds(side, fi, bi):
        if side == "S" and fi == 0 and bi == 1:
            return "door"
        if side in "EW" and bi == 1 and fi == 0:
            return "wall"
        return "win"
    block(c, x0, y0, x1, y1, floors, w, wall, kinds)
    zt = base + 2 * FH
    gable_roof(c, x0, y0, x1, y1, zt, 0.11, roof, wall, oh=0.014)
    arch.chimney(c, x0 + 0.03, y0 + 0.2, zt, zt + 0.14, mat="Brick_Red")
    # porch
    px0, px1 = -0.17, 0.01
    c.mb.box2(px0, y0 - 0.05, 0.0, px1, y0, base, "Concrete", skip=("-z",))
    for xx in (px0 + 0.004, px1 - 0.004):
        c.mb.box((xx, y0 - 0.046, base + 0.05), (0.005, 0.005, 0.1), trim, skip=("-z",))
    c.mb.poly([(px0 - 0.004, y0 - 0.054, base + 0.1), (px1 + 0.004, y0 - 0.054, base + 0.1),
               (px1 + 0.004, y0, base + 0.115), (px0 - 0.004, y0, base + 0.115)], roof)
    c.mb.poly([(px1 + 0.004, y0, base + 0.112), (px0 - 0.004, y0, base + 0.112),
               (px0 - 0.004, y0 - 0.054, base + 0.097), (px1 + 0.004, y0 - 0.054, base + 0.097)], trim)
    c.mb.box2(px0 - 0.004, y0 - 0.056, base + 0.096, px1 + 0.004, y0 - 0.052, base + 0.101, trim)
    if garage:
        gx0, gx1, gy0, gy1 = x1, x1 + 0.2, y0 + 0.03, y1
        c.garage_mat = "Shutter"
        gfl = [(base, base + FH * 0.95)]
        block(c, gx0, gy0, gx1, gy1, gfl, Win(w=0.05, h=0.06, sill=0.06, frame="Frame_White", bay=0.14),
              wall, lambda s, fi, bi: "garage" if s == "S" else ("wall" if s == "W" else "win"))
        gable_roof(c, gx0, gy0, gx1, gy1, base + FH * 0.95, 0.07, roof, wall, oh=0.012, ridge="y")
    arch.hvac(c, x0 - 0.04, y1 - 0.06, 0.0, 0.03, 0.03, 0.03)
    _landscape(c, trees=[(-0.36, -0.36, 0.42, "broad"), (0.36, 0.36, 0.5, "round"), (-0.38, 0.32, 0.36, "conifer")],
               shrubs=[(-0.26, -0.16, 0.035), (-0.21, -0.165, 0.03), (0.05, -0.16, 0.035), (0.09, -0.16, 0.03),
                       (-0.33, 0.0, 0.04)], seed=seed)
    arch.picket_fence(c, [(-0.465, -0.455), (-0.12, -0.455)])
    arch.picket_fence(c, [(-0.04, -0.455), (0.15, -0.455)])
    mailbox(c, -0.135, -0.43)


def mailbox(c, x, y):
    c.mb.box((x, y, 0.016), (0.003, 0.003, 0.03), "Wood", skip=("-z",))
    c.mb.lathe([(0.0045, 0.0), (0.0045, 0.016)], "Metal_Dark", n=8, c=(x, y - 0.008, 0.035),
               axis=Matrix.Rotation(-math.pi / 2, 4, "X"))
    c.mb.box((x, y, 0.032), (0.009, 0.016, 0.004), "Metal_Dark")


def house_hip(c, wall="Brick_Orange", roof="Roof_Grey", door="Door_Green", seed=1):
    c.door_mat = door
    _yard(c, drive_x=(-0.36, -0.22), drive_to=0.17, path_x=0.06, path_to=-0.13)
    x0, x1, y0, y1 = -0.2, 0.3, -0.13, 0.19
    base = 0.008
    c.mb.box2(x0 - 0.003, y0 - 0.003, 0.0, x1 + 0.003, y1 + 0.003, base, "Concrete", skip=("-z",))
    floors = [(base, base + FH), (base + FH, base + 2 * FH)]
    w = Win(w=0.06, h=0.08, sill=0.045, frame="Frame_White", bay=0.1, sill_mat="Trim_Stone", lintel="Trim_Stone",
            transom=True)
    block(c, x0, y0, x1, y1, floors, w, wall, lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 2) else "win")
    band(c, x0, y0, x1, y1, base + FH - 0.003, 0.006, "Trim_Stone")
    zt = base + 2 * FH
    hip_roof(c, x0, y0, x1, y1, zt, 0.1, roof, oh=0.016)
    arch.chimney(c, x1 - 0.08, y1 - 0.06, zt, zt + 0.12, mat=wall)
    # carport
    cx0, cx1, cy0, cy1 = -0.37, -0.21, -0.07, 0.17
    for (xx, yy) in ((cx0 + 0.005, cy0 + 0.005), (cx0 + 0.005, cy1 - 0.005)):
        c.mb.box((xx, yy, 0.055), (0.006, 0.006, 0.11), "Trim_White", skip=("-z",))
    c.mb.box2(cx0, cy0, 0.11, cx1, cy1, 0.118, "Trim_White")
    c.mb.poly([(cx0, cy0, 0.118), (cx1, cy0, 0.118), (cx1, cy1, 0.118), (cx0, cy1, 0.118)], "Roof_Flat")
    arch.parked_car(c, -0.29, 0.03, rz=0.0, scale=0.9)
    c.mb.box2(0.0, y0 - 0.045, 0.0, 0.12, y0, base, "Concrete", skip=("-z",))
    _landscape(c, trees=[(0.38, -0.36, 0.48, "round"), (0.35, 0.37, 0.44, "broad"), (-0.12, 0.36, 0.5, "fern")],
               shrubs=[(-0.15, -0.16, 0.03), (-0.08, -0.16, 0.035), (0.18, -0.16, 0.035), (0.25, -0.16, 0.03)],
               seed=seed)
    hedge(c.mb, c.fol, -0.2, -0.45, 0.46, -0.45, seed=seed)
    c.mb.box2(-0.2, -0.455, 0.004, 0.46, -0.445, 0.026, "Hedge_Core", skip=("-z",))


def band(c, x0, y0, x1, y1, z, h, mat):
    arch.band(c, x0, y0, x1, y1, z, h, mat, out=0.003)


def house_cottage(c, wall="Plaster_Cream", roof="Roof_Clay", door="Door_Blue", seed=2):
    """Gable-fronted 1.5-storey house with dormers and a bay window."""
    c.door_mat = door
    _yard(c, drive_x=(0.2, 0.33), drive_to=0.1, path_x=-0.05, path_to=-0.16)
    x0, x1, y0, y1 = -0.2, 0.12, -0.16, 0.24
    base = 0.008
    c.mb.box2(x0 - 0.003, y0 - 0.003, 0.0, x1 + 0.003, y1 + 0.003, base, "Stone_Facade", skip=("-z",))
    floors = [(base, base + FH)]
    w = Win(w=0.05, h=0.08, sill=0.04, frame="Frame_White", bay=0.1, transom=True, shutters=None)
    block(c, x0, y0, x1, y1, floors, w, wall, lambda s, fi, bi: "door" if (s == "S" and bi == 1) else "win")
    zt = base + FH
    # steep gable facing the street (ridge along y) with an upper window in the gable
    gable_roof(c, x0, y0, x1, y1, zt, 0.2, roof, wall, oh=0.014, ridge="y")
    facade(c, (-0.06, y0, 0), 0.0, 0.06, [(zt, zt + 0.12)], Win(w=0.04, h=0.07, sill=0.02, frame="Frame_White",
                                                              bay=0.06, mullion=True), wall, n_bays=1)
    # the gable-window block above sits inside the triangle; cover its sides
    # dormers on the east slope
    for yy in (-0.02, 0.12):
        dz = zt + 0.03
        dx0 = x1 - 0.07
        c.mb.box2(dx0, yy - 0.03, zt, x1 - 0.01, yy + 0.03, dz + 0.07, wall, skip=("-z", "+z", "-x"))
        facade(c, (x1 - 0.01, yy - 0.03, 0), math.pi / 2, 0.06, [(dz, dz + 0.07)],
               Win(w=0.036, h=0.05, sill=0.01, frame="Frame_White", bay=0.06), wall, n_bays=1)
        gable_roof(c, dx0 - 0.005, yy - 0.03, x1 - 0.005, yy + 0.03, dz + 0.07, 0.03, roof, wall, oh=0.006,
                   ridge="x", gutter=None)
    arch.chimney(c, x0 + 0.05, y1 - 0.05, zt, zt + 0.25, mat="Brick_Old")
    # small detached garage
    gx0, gx1, gy0, gy1 = 0.18, 0.36, 0.12, 0.34
    c.garage_mat = "Wood"
    block(c, gx0, gy0, gx1, gy1, [(0.004, 0.004 + FH * 0.85)], Win(bay=0.2), "Siding_White",
          lambda s, fi, bi: "garage" if s == "S" else "wall")
    gable_roof(c, gx0, gy0, gx1, gy1, 0.004 + FH * 0.85, 0.06, roof, "Siding_White", oh=0.01, ridge="y")
    _landscape(c, trees=[(-0.36, -0.34, 0.5, "broad"), (0.36, -0.3, 0.38, "birch"), (-0.36, 0.34, 0.55, "round"),
                         (0.04, 0.39, 0.4, "conifer")],
               shrubs=[(-0.17, -0.19, 0.035), (0.07, -0.19, 0.035), (-0.25, 0.05, 0.04), (0.16, -0.05, 0.03)],
               seed=seed)
    arch.fence(c, [(-0.465, -0.46), (-0.07, -0.46)], h=0.025, mat="Wood_Weathered")
    arch.fence(c, [(-0.03, -0.46), (0.19, -0.46)], h=0.025, mat="Wood_Weathered")
    mailbox(c, -0.085, -0.44)


def house_modern(c, seed=3):
    """Two offset flat-roofed volumes, white render + timber cladding, big glazing."""
    c.door_mat = "Door_Black"
    _yard(c, drive_x=(0.16, 0.34), drive_to=0.2, path_x=-0.02, path_to=-0.1, mat_drive="Concrete_Floor")
    base = 0.006
    # lower volume (living), full-height glazing
    x0, x1, y0, y1 = -0.32, 0.12, -0.08, 0.2
    c.mb.box2(x0 - 0.003, y0 - 0.003, 0.0, x1 + 0.003, y1 + 0.003, base, "Concrete_Light", skip=("-z",))
    big = Win(w=0.09, h=0.11, sill=0.008, depth=0.006, frame="Frame_Dark", fw=0.003, bay=0.11, sill_mat=None)
    block(c, x0, y0, x1, y1, [(base, base + FH)], big, "Plaster_White",
          lambda s, fi, bi: ("door" if bi == 2 else "tall") if s == "S" else ("tall" if s == "N" else "win"))
    flat_roof(c, x0, y0, x1, y1, base + FH, roof="Roof_Gravel", parapet=0.008, pmat="Plaster_White", cap="Metal_Galv")
    # upper volume cantilevered, timber clad
    ux0, ux1, uy0, uy1 = -0.22, 0.2, -0.04, 0.22
    z1 = base + FH
    ribbon = Win(w=0.1, h=0.06, sill=0.05, depth=0.005, frame="Frame_Dark", fw=0.003, bay=0.14, sill_mat=None)
    c.mb.box2(ux0, uy0, z1, ux1, uy1, z1 + 0.006, "Concrete_Light")
    block(c, ux0, uy0, ux1, uy1, [(z1 + 0.006, z1 + 0.006 + FH)], ribbon, "Wood",
          lambda s, fi, bi: "wall" if (s in "EW" and bi == 1) else "win")
    flat_roof(c, ux0, uy0, ux1, uy1, z1 + 0.006 + FH, roof="Roof_Gravel", parapet=0.008, pmat="Wood", cap="Metal_Galv")
    c.mb.poly([(ux1, uy0, z1), (x1, uy0, z1), (x1, uy1, z1), (ux1, uy1, z1)][::-1], "Concrete_Light")
    arch.solar_array(c, ux0 + 0.03, uy0 + 0.04, ux1 - 0.05, uy1 - 0.03, z1 + 0.006 + FH, rows=2, tilt=12)
    # carport roof on posts over the drive
    for yy in (-0.06, 0.16):
        c.mb.box((0.33, yy, 0.06), (0.006, 0.006, 0.12), "Metal_Dark", skip=("-z",))
    c.mb.box2(0.2, -0.07, 0.12, 0.345, 0.2, 0.128, "Metal_Dark")
    arch.parked_car(c, 0.27, 0.05, scale=0.95, color="Paint_black")
    # pool
    c.mb.box2(-0.38, 0.27, 0.0, -0.06, 0.43, 0.006, "Concrete_Light", skip=("-z",))
    c.mb.poly([(-0.37, 0.28, 0.0062), (-0.07, 0.28, 0.0062), (-0.07, 0.42, 0.0062), (-0.37, 0.42, 0.0062)], "Water")
    _landscape(c, trees=[(0.38, 0.36, 0.52, "poplar"), (0.38, -0.36, 0.44, "fern"), (-0.42, -0.38, 0.4, "birch")],
               shrubs=[(-0.3, -0.12, 0.03), (-0.24, -0.12, 0.028), (-0.1, -0.12, 0.03)], seed=seed)
    c.mb.box2(-0.46, -0.465, 0.0, -0.05, -0.452, 0.03, "Concrete_Light", skip=("-z",))


def house_bungalow(c, wall="Siding_Blue", roof="Roof_Shingle_Brown", seed=4):
    """Single-storey bungalow with wrap porch and a cross gable."""
    c.door_mat = "Door_Red"
    _yard(c, drive_x=(-0.4, -0.27), drive_to=0.2, path_x=0.05, path_to=-0.16)
    base = 0.012
    x0, x1, y0, y1 = -0.22, 0.32, -0.1, 0.22
    c.mb.box2(x0 - 0.003, y0 - 0.003, 0.0, x1 + 0.003, y1 + 0.003, base, "Brick_Red", skip=("-z",))
    w = Win(w=0.055, h=0.08, sill=0.04, frame="Frame_White", bay=0.1, transom=False, shutters="Door_Black")
    block(c, x0, y0, x1, y1, [(base, base + FH)], w, wall, lambda s, fi, bi: "door" if (s == "S" and bi == 2) else "win")
    zt = base + FH
    gable_roof(c, x0, y0, x1, y1, zt, 0.12, roof, wall, oh=0.016)
    # cross gable over the porch
    gable_roof(c, -0.06, y0 - 0.07, 0.16, y0 + 0.06, zt, 0.09, roof, wall, oh=0.008, ridge="y")
    c.mb.box2(-0.08, y0 - 0.075, 0.0, 0.18, y0, base, "Wood", skip=("-z",))
    for xx in (-0.05, 0.15):
        c.mb.box((xx, y0 - 0.068, base + FH / 2), (0.008, 0.008, FH), "Trim_White", skip=("-z",))
    arch.picket_fence(c, [(-0.08, y0 - 0.075), (0.02, y0 - 0.075)], h=0.016)
    arch.picket_fence(c, [(0.09, y0 - 0.075), (0.18, y0 - 0.075)], h=0.016)
    arch.chimney(c, x1 - 0.06, y0 + 0.2, zt, zt + 0.15, mat="Brick_Red")
    arch.parked_car(c, -0.335, 0.05, rz=0.0, scale=0.9, color="Paint_red")
    _landscape(c, trees=[(0.4, -0.37, 0.56, "broad"), (-0.12, 0.38, 0.45, "round"), (0.37, 0.36, 0.4, "conifer")],
               shrubs=[(-0.18, -0.13, 0.035), (0.24, -0.13, 0.04), (0.29, -0.13, 0.03), (-0.13, -0.13, 0.03)],
               seed=seed)
    hedge(c.mb, c.fol, 0.1, -0.45, 0.46, -0.45, seed=seed)
    c.mb.box2(0.1, -0.455, 0.004, 0.46, -0.445, 0.024, "Hedge_Core", skip=("-z",))
    mailbox(c, 0.0, -0.44)


R1 = {
    "zones/r1/house_gable_white": (house_gable, {}),
    "zones/r1/house_gable_yellow": (house_gable, {"wall": "Siding_Yellow", "roof": "Roof_Slate", "door": "Door_Blue",
                                                  "shutters": "Door_Green", "seed": 7}),
    "zones/r1/house_hip_brick": (house_hip, {}),
    "zones/r1/house_cottage": (house_cottage, {}),
    "zones/r1/house_modern": (house_modern, {}),
    "zones/r1/house_bungalow": (house_bungalow, {}),
}
