"""Service buildings, part 1: utilities (coal, solar, wind, water, sewage) and civic services
(police, fire, hospital, school).

Scripted parts: StackTop_0/1 empties (coal smoke), Rotor_<n> objects with their origin at the hub
(spin about local Godot +Z = Blender -Y), and one object named exactly "Beacon" on police/fire."""

import math

from mathutils import Matrix, Vector

import arch
import core
from arch import FH, Win, block, flat_roof, gable_roof, lot, pad
from core import MB, make_empty, rotz
from nature import hedge, tree
from indkit import (T, beam, car_park, column, container, cooling_tower, dock_door, fence_line, gallery, man_door,
                    pipe, pipe_rack, shed, silo, stack, strip_window, tank, truck, tube)
from zones_res2 import cornice

core.MATS.update({
    "Coal": ("tex", "rocks_ground_02", 3.0, (0.16, 0.16, 0.17)),
    "Water_Sewage": ("flat", (0.10, 0.11, 0.07), 0.08, 0.1, {}),
    "Shutter_Red": ("tex", "painted_metal_shutter", 1.6, (0.85, 0.18, 0.14)),
    "Court_Green": ("tex", "concrete_floor_02", 4.0, (0.30, 0.52, 0.34)),
    "Court_Blue": ("tex", "concrete_floor_02", 4.0, (0.26, 0.38, 0.62)),
    "Track_Red": ("tex", "concrete_floor_02", 4.0, (0.70, 0.30, 0.22)),
})
core.MATS["Solar_Panel"] = ("tex", "solar_cells", 1.0, (1, 1, 1))

Z0 = 0.004


def part(name, loc, fn):
    """Separate object (for scripted animation) whose origin sits at loc; fn(mb) builds it around (0,0,0)."""
    mb = MB()
    fn(mb)
    ob = mb.build(name)
    ob.location = loc
    return ob


def flagpole(c, x, y, h=0.16, flag="Sign_Red"):
    mb = c.mb
    mb.cyl((x, y, Z0), 0.0018, h, "Metal_White", n=6)
    mb.sphere((x, y, Z0 + h + 0.002), 0.0028, "Chrome", n=6, rings=4)
    mb.box2(x + 0.002, y - 0.0006, Z0 + h - 0.03, x + 0.045, y + 0.0006, Z0 + h - 0.002, flag)


def light_bar(name, x, y, z, mats=("Siren_Blue", "Siren_Blue"), w=0.05):
    def fn(mb):
        mb.box2(-w / 2, -0.006, 0.0, w / 2, 0.006, 0.003, "Metal_Dark")
        mb.box2(-w / 2 + 0.002, -0.005, 0.003, -0.002, 0.005, 0.011, mats[0])
        mb.box2(0.002, -0.005, 0.003, w / 2 - 0.002, 0.005, 0.011, mats[1])
    return part(name, (x, y, z), fn)


def _trees(c, pts, kinds=("broad", "round"), seed=0, h=(0.32, 0.44)):
    for i, (x, y) in enumerate(pts):
        tree(c.mb, c.fol, x, y, h=c.rnd.uniform(*h), kind=kinds[i % len(kinds)], seed=seed + i, z0=Z0)


def _letters_sign(c, x, y, z, w, h, bg="Sign_Blue", fg="Sign_White", face="S"):
    arch.sign(c, x, y, z, w, h, bg=bg, fg=fg, depth=0.003, face=face)


# ----------------------------------------------------------------------------- utilities

def coal_plant(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    # turbine hall + boiler house
    shed(c, -0.44, 0.04, -0.12, 0.38, Z0, 0.34, "Metal_Cladding_Blue", roof="Metal_Corrugated", rise=0.04, ridge="y",
         features={"S": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.26, 0.3, pane=0.04),
                         lambda c, L: dock_door(c, L * 0.5, 0.12, 0.16, Z0, frame="Metal_Dark")],
                   "W": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.26, 0.3, pane=0.04)]})
    shed(c, -0.12, 0.0, 0.18, 0.38, Z0, 0.66, "Metal_Corrugated_Light", flat=True, parapet=0.01,
         features={"S": [lambda c, L: [strip_window(c, 0.02, L - 0.02, z, z + 0.035, pane=0.04)
                                       for z in (0.18, 0.34, 0.5)]],
                   "E": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.5, 0.535, pane=0.04)]})
    arch.hvac(c, -0.02, 0.2, 0.66, 0.08, 0.06, 0.04)
    # electrostatic precipitator + flue ducts
    mb.box2(0.2, 0.04, Z0, 0.3, 0.34, 0.36, "Metal_Galv")
    for k in range(4):
        mb.box2(0.205 + k * 0.024, 0.035, 0.36, 0.22 + k * 0.024, 0.345, 0.4, "Metal_Galv", mats={"+z": "Metal_Dark"})
    beam(mb, (0.18, 0.2, 0.55), (0.25, 0.2, 0.4), 0.05, 0.04, "Metal_Galv")
    stack(c, 0, 0.385, 0.32, 1.95, 0.062, 0.042, mat="Concrete_Light", z0=Z0,
          bands=((0.86, 0.9, "Stack_Red"), (0.9, 0.94, "Stack_White"), (0.94, 0.98, "Stack_Red")), platform=0.85, n=16)
    stack(c, 1, 0.385, 0.1, 1.7, 0.055, 0.038, mat="Concrete_Light", z0=Z0,
          bands=((0.86, 0.9, "Stack_Red"), (0.9, 0.94, "Stack_White"), (0.94, 0.98, "Stack_Red")), platform=0.85, n=16)
    pipe(mb, [(0.3, 0.26, 0.2), (0.385, 0.26, 0.2), (0.385, 0.3, 0.2)], 0.02, "Metal_Galv")
    pipe(mb, [(0.3, 0.12, 0.2), (0.385, 0.12, 0.2)], 0.02, "Metal_Galv")
    # cooling tower and coal yard
    cooling_tower(c, -0.27, -0.25, 0.18, 0.62, z0=Z0, n=28)
    for (x, y, r) in ((0.12, -0.28, 0.15), (0.34, -0.36, 0.09)):
        mb.lathe([(r, 0.0), (r * 0.65, r * 0.32), (r * 0.2, r * 0.48), (0.0, r * 0.5)], "Coal", n=16, c=(x, y, Z0))
    gallery(c, (0.18, -0.15, Z0 + 0.03), (0.05, 0.0, 0.55), w=0.024, h=0.026)
    mb.box2(0.1, -0.2, Z0, 0.24, -0.12, 0.08, "Metal_Corrugated", skip=("-z",))
    # switchyard
    for i in range(3):
        mb.box2(-0.1 + i * 0.07, -0.08, Z0, -0.06 + i * 0.07, -0.03, 0.06, "Metal_Green")
        for k in range(3):
            mb.cyl((-0.09 + i * 0.07 + k * 0.012, -0.055, 0.06), 0.003, 0.03, "Clay_Pot", n=6)
    fence_line(c, [(-0.462, -0.462), (0.462, -0.462)])


def solar_farm(c, seed=0):
    lot(c, "Grass")
    pad(c, -0.45, -0.45, 0.45, 0.45, "Gravel", h=0.0008)
    mb = c.mb
    rows = 7
    for r in range(rows):
        y0 = -0.36 + r * 0.115
        arch.solar_array(c, -0.42, y0, 0.3, y0 + 0.095, Z0, tilt=28, rows=1)
        arch.solar_array(c, 0.33, y0, 0.44, y0 + 0.095, Z0, tilt=28, rows=1)
    # service track, inverters, control hut
    pad(c, -0.45, -0.46, 0.45, -0.39, "Gravel", h=0.0015)
    for x in (-0.25, 0.05):
        container(mb, x, -0.425, Z0, 0.0, "Container_White", L=0.1, W=0.05, H=0.05)
    mb.box2(0.3, -0.46, Z0, 0.44, -0.4, 0.07, "Concrete_Panel")
    flat_roof(c, 0.3, -0.46, 0.44, -0.4, 0.07, roof="Roof_Flat", parapet=0.005, pmat="Concrete_Panel")
    fence_line(c, [(-0.465, -0.465), (-0.465, 0.465), (0.465, 0.465), (0.465, -0.465)], h=0.035)


def wind_farm(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    pad(c, -0.03, -0.46, 0.03, 0.46, "Gravel", h=0.0012)
    sites = ((-0.22, 0.22, 0.9, 0.0), (0.22, 0.22, 0.82, 0.7), (0.0, -0.2, 0.95, 1.4))
    for i, (x, y, h, ph) in enumerate(sites):
        mb.box2(x - 0.04, y - 0.04, Z0, x + 0.04, y + 0.04, Z0 + 0.006, "Concrete")
        mb.lathe([(0.017, 0.0), (0.0085, h)], "Steel_White", n=14, c=(x, y, Z0 + 0.006))
        mb.box2(x - 0.0175, y - 0.0005, Z0 + 0.03, x - 0.0172 + 0.0003, y + 0.006, Z0 + 0.06, "Metal_Dark")
        zt = Z0 + 0.006 + h
        # nacelle (rounded box) facing -y
        mb.lathe([(0.0, -0.02), (0.012, -0.018), (0.014, 0.01), (0.012, 0.055), (0.0, 0.058)], "Steel_White", n=12,
                 c=(x, y, zt + 0.012), axis=Matrix.Rotation(math.pi / 2, 4, "X"))
        mb.box2(x - 0.008, y + 0.0, zt + 0.024, x + 0.008, y + 0.04, zt + 0.027, "Steel_White")

        def rotor(mb, ph=ph):
            # spinner along -y
            mb.lathe([(0.0, 0.0), (0.012, 0.002), (0.011, 0.012), (0.006, 0.02), (0.0, 0.024)], "Steel_White", n=12,
                     axis=Matrix.Rotation(math.pi / 2, 4, "X"))
            L = 0.24
            for k in range(3):
                a = ph + 2 * math.pi * k / 3
                outline = [(-0.006, 0.008), (0.011, 0.01), (0.014, 0.05), (0.008, L * 0.7), (0.004, L),
                           (-0.002, L), (-0.006, L * 0.6), (-0.008, 0.05)]
                mb.push(Matrix.Rotation(-a, 4, "Y") @ Matrix.Rotation(math.pi / 2, 4, "X") @
                        Matrix.Rotation(0.12, 4, "Y"))
                mb.prism(outline, 0.008, 0.0115, "Steel_White")
                mb.pop()

        part("Rotor_%d" % i, (x, y - 0.02, zt + 0.012), rotor)
        mb.box2(x - 0.03, y - 0.03, Z0, x - 0.016, y - 0.016, Z0 + 0.03, "Metal_Green")
    # substation
    mb.box2(0.22, -0.44, Z0, 0.44, -0.24, Z0 + 0.003, "Gravel")
    for i in range(2):
        mb.box2(0.25 + i * 0.09, -0.4, Z0, 0.31 + i * 0.09, -0.34, Z0 + 0.06, "Metal_Green")
        for k in range(3):
            mb.cyl((0.26 + i * 0.09 + k * 0.02, -0.37, Z0 + 0.06), 0.003, 0.03, "Clay_Pot", n=6)
    for xx in (0.24, 0.42):
        mb.box2(xx - 0.003, -0.3, Z0, xx + 0.003, -0.294, Z0 + 0.12, "Metal_Galv", skip=("-z",))
    mb.box2(0.24, -0.3, Z0 + 0.115, 0.42, -0.294, Z0 + 0.12, "Metal_Galv")
    fence_line(c, [(0.21, -0.45), (0.21, -0.23), (0.45, -0.23)], h=0.03)
    hedge(mb, c.fol, -0.46, -0.46, -0.1, -0.46, h=0.03, w=0.025, seed=seed, z0=Z0)
    _trees(c, [(-0.42, -0.4), (-0.4, 0.42)], ("conifer", "broad"), seed)


def water_pump(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    pad(c, -0.45, -0.46, 0.45, -0.3, "Asphalt", h=0.0012)
    # elevated steel water tower
    tx, ty = 0.15, 0.12
    h_leg = 0.5
    for k in range(6):
        a = 2 * math.pi * k / 6
        px, py = tx + math.cos(a) * 0.11, ty + math.sin(a) * 0.11
        beam(mb, (px, py, Z0), (tx + math.cos(a) * 0.09, ty + math.sin(a) * 0.09, Z0 + h_leg + 0.02), 0.009, 0.009,
             "Steel_White")
        mb.box((px, py, Z0 + 0.008), (0.022, 0.022, 0.016), "Concrete")
        a2 = 2 * math.pi * (k + 1) / 6
        for zf in (0.18, 0.36):
            rr = 0.11 - 0.02 * zf / 0.5
            beam(mb, (tx + math.cos(a) * rr, ty + math.sin(a) * rr, Z0 + zf),
                 (tx + math.cos(a2) * rr, ty + math.sin(a2) * rr, Z0 + zf), 0.004, 0.004, "Steel_White")
            beam(mb, (tx + math.cos(a) * rr, ty + math.sin(a) * rr, Z0 + zf),
                 (tx + math.cos(a2) * (rr - 0.008), ty + math.sin(a2) * (rr - 0.008), Z0 + zf + 0.18), 0.002, 0.002,
                 "Metal_Galv")
    mb.cyl((tx, ty, Z0), 0.022, h_leg + 0.05, "Steel_White", n=12)
    zt = Z0 + h_leg
    prof = [(0.0, 0.0), (0.06, 0.004), (0.12, 0.04), (0.14, 0.08), (0.14, 0.16), (0.12, 0.19), (0.05, 0.215),
            (0.0, 0.22)]
    mb.lathe(prof, "Steel_White", n=24, c=(tx, ty, zt))
    mb.lathe([(0.141, 0.0), (0.16, 0.0), (0.16, 0.003), (0.141, 0.003)], "Grating", n=24, c=(tx, ty, zt + 0.08),
             smooth=False)
    mb.lathe([(0.16, 0.018), (0.16, 0.02)], "Metal_Galv", n=24, c=(tx, ty, zt + 0.08))
    mb.box2(tx - 0.005, ty - 0.15, zt + 0.085, tx + 0.005, ty - 0.149, zt + 0.14, "Sign_Blue")
    arch.sign(c, tx, ty - 0.1415, zt + 0.12, 0.12, 0.03, bg="Sign_Blue", fg="Sign_White", depth=0.001)
    mb.cyl((tx, ty, zt + 0.22), 0.004, 0.012, "Beacon_Red", n=6)
    # pump house
    c.door_mat = "Door_Blue"
    w = Win(w=0.05, h=0.07, sill=0.04, frame="Frame_White", bay=0.09, sill_mat="Trim_Stone", lit=0.3)
    block(c, -0.42, -0.24, -0.12, -0.04, [(Z0, Z0 + 0.17)], w, "Brick_Red",
          lambda s, fi, bi: "door" if (s == "S" and bi == 1) else "win")
    gable_roof(c, -0.42, -0.24, -0.12, -0.04, Z0 + 0.17, 0.06, "Roof_Slate", "Brick_Red", ridge="x")
    pipe(mb, [(-0.12, -0.12, 0.04), (tx, -0.12, 0.04), (tx, ty - 0.02, 0.04)], 0.012, "Metal_Blue")
    # reservoir
    rx0, ry0, rx1, ry1 = -0.44, 0.06, -0.08, 0.44
    mb.box2(rx0, ry0, Z0, rx1, ry1, Z0 + 0.03, "Concrete", skip=("-z",))
    mb.box2(rx0 + 0.01, ry0 + 0.01, Z0 + 0.024, rx1 - 0.01, ry1 - 0.01, Z0 + 0.0305, "Water", skip=("-z",))
    fence_line(c, [(-0.462, -0.29), (-0.462, 0.462), (0.462, 0.462), (0.462, -0.29)], h=0.035)
    _trees(c, [(0.4, -0.2), (-0.03, 0.42)], ("conifer", "round"), seed)
    arch.parked_car(c, 0.3, -0.38, rz=math.pi / 2, scale=1.15, color="Paint_white")


def sewage_plant(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    pad(c, -0.46, -0.46, 0.46, 0.46, "Concrete_Floor", h=0.0006)
    # circular clarifiers with rotating bridges
    for (x, y, r) in ((-0.26, 0.24, 0.17), (0.2, 0.26, 0.15)):
        mb.lathe([(r, 0.0), (r, 0.04), (r - 0.01, 0.04), (r - 0.01, 0.03)], "Concrete", n=32, c=(x, y, Z0),
                 smooth=False)
        mb.cyl((x, y, Z0 + 0.03), r - 0.01, 0.0005, "Water_Sewage", n=32, caps=(False, True))
        mb.cyl((x, y, Z0 + 0.03), r * 0.18, 0.012, "Concrete", n=12)
        mb.box2(x - 0.006, y - r, Z0 + 0.045, x + 0.006, y, Z0 + 0.05, "Grating")
        mb.box2(x - 0.006, y - r, Z0 + 0.06, x - 0.005, y, Z0 + 0.061, "Metal_Yellow")
        mb.box2(x + 0.005, y - r, Z0 + 0.06, x + 0.006, y, Z0 + 0.061, "Metal_Yellow")
        mb.lathe([(r * 0.9, 0.0), (r * 0.9, 0.006)], "Concrete_Dark", n=32, c=(x, y, Z0 + 0.03))
    # aeration basins
    bx0, by0, bx1, by1 = -0.44, -0.2, 0.06, 0.02
    mb.box2(bx0, by0, Z0, bx1, by1, Z0 + 0.035, "Concrete", skip=("-z",))
    for k in range(3):
        y0 = by0 + 0.008 + k * (by1 - by0 - 0.008) / 3
        y1 = y0 + (by1 - by0 - 0.008) / 3 - 0.008
        mb.box2(bx0 + 0.008, y0, Z0 + 0.03, bx1 - 0.008, y1, Z0 + 0.0355, "Water_Sewage", skip=("-z",))
    mb.box2(bx0, by1 - 0.002, Z0 + 0.04, bx1, by1 + 0.008, Z0 + 0.044, "Grating")
    # egg-shaped digesters
    for (x, y) in ((0.26, -0.08), (0.4, -0.08)):
        prof = [(0.0, 0.0), (0.035, 0.01), (0.055, 0.06), (0.06, 0.13), (0.052, 0.2), (0.03, 0.26), (0.012, 0.28),
                (0.0, 0.282)]
        mb.lathe(prof, "Metal_Galv", n=18, c=(x, y, Z0))
        mb.cyl((x, y, Z0 + 0.28), 0.012, 0.02, "Metal_Dark", n=8)
    mb.box2(0.24, -0.09, 0.27, 0.42, -0.07, 0.276, "Grating")
    stack(c, None, 0.46 - 0.02, 0.06, 0.38, 0.008, 0.007, mat="Metal_Galv", z0=Z0, platform=None, n=8)
    pipe(mb, [(0.06, -0.09, 0.03), (0.26, -0.09, 0.03)], 0.008, "Metal_Dark")
    pipe(mb, [(-0.26, 0.07, 0.03), (-0.26, 0.02, 0.03)], 0.01, "Metal_Dark")
    # control building
    c.door_mat = "Door_Green"
    w = Win(w=0.06, h=0.06, sill=0.05, frame="Frame_Alu", bay=0.08, lit=0.35)
    block(c, -0.1, -0.44, 0.24, -0.28, [(Z0, Z0 + 0.15)], w, "Concrete_Panel",
          lambda s, fi, bi: "door" if (s == "S" and bi == 2) else "win")
    flat_roof(c, -0.1, -0.44, 0.24, -0.28, Z0 + 0.15, roof="Roof_Flat", parapet=0.01, pmat="Concrete_Panel")
    _letters_sign(c, 0.07, -0.443, Z0 + 0.13, 0.2, 0.018, bg="Sign_Green")
    truck(c, 0.36, -0.36, 0.0, box_mat="Steel_White", cab_mat="Paint_white", L=0.3, tanker=True)
    _trees(c, [(-0.4, -0.4), (-0.3, -0.42)], ("broad", "round"), seed)


# ----------------------------------------------------------------------------- civic

def police_station(c, seed=0):
    lot(c, "Sidewalk")
    mb = c.mb
    x0, y0, x1, y1 = -0.4, -0.14, 0.3, 0.3
    c.door_mat = "Glass_Shop"
    w0 = Win(w=0.075, h=0.09, sill=0.03, frame="Frame_Alu", bay=0.1, lit=0.5, sill_mat="Metal_Galv")
    block(c, x0, y0, x1, y1, [(Z0, Z0 + 0.16)], w0, "Stone_Light",
          lambda s, fi, bi: ("door" if bi == 3 else "shop") if s == "S" else "win")
    arch.band(c, x0, y0, x1, y1, Z0 + 0.16, 0.014, "Metal_Blue", out=0.004)
    w1 = Win(w=0.06, h=0.085, sill=0.04, frame="Frame_White", bay=0.1, lit=0.45, sill_mat="Trim_Stone")
    fl = [(Z0 + 0.174, Z0 + 0.324), (Z0 + 0.324, Z0 + 0.474)]
    block(c, x0, y0, x1, y1, fl, w1, "Brick_Red")
    top = Z0 + 0.474
    cornice(c, x0, y0, x1, y1, top, mat="Trim_Stone", h=0.012, out=0.006)
    flat_roof(c, x0, y0, x1, y1, top + 0.012, roof="Roof_Flat", parapet=0.014, pmat="Brick_Red")
    zr = top + 0.012
    # entrance canopy + sign
    ex = x0 + 3.5 * (x1 - x0) / 7
    mb.box2(ex - 0.09, y0 - 0.07, Z0 + 0.13, ex + 0.09, y0, Z0 + 0.142, "Metal_Blue")
    for sx in (-1, 1):
        mb.cyl((ex + sx * 0.08, y0 - 0.06, Z0), 0.004, 0.13, "Metal_Galv", n=8)
    _letters_sign(c, ex, y0 - 0.0705, Z0 + 0.136, 0.16, 0.011, bg="Sign_Blue")
    _letters_sign(c, ex, y0 - 0.005, top - 0.03, 0.26, 0.03, bg="Sign_Blue")
    arch.hvac(c, -0.25, 0.15, zr, 0.07, 0.05, 0.03)
    arch.antenna(c, 0.2, 0.2, zr, h=0.2)
    light_bar("Beacon", ex, y0 + 0.02, zr + 0.014, mats=("Siren_Blue", "Siren_Blue"), w=0.06)
    flagpole(c, x0 + 0.03, y0 - 0.1, h=0.2, flag="Sign_Blue")
    # yard with patrol cars
    pad(c, 0.32, -0.46, 0.46, 0.46, "Asphalt", h=0.0012)
    for i, yy in enumerate((-0.33, -0.1, 0.13)):
        arch.parked_car(c, 0.39, yy, rz=0.0, scale=1.15, color="Paint_white" if i % 2 == 0 else "Paint_navy")
        mb.box2(0.384, yy - 0.004, 0.058, 0.396, yy + 0.004, 0.064, "Siren_Blue")
    _trees(c, [(-0.42, -0.42), (0.2, -0.42)], seed=seed)
    hedge(mb, c.fol, -0.32, -0.3, -0.1, -0.3, h=0.025, w=0.02, seed=seed, z0=Z0)


def fire_station(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    x0, y0, x1, y1 = -0.44, -0.08, 0.2, 0.34
    wall = "Brick_Red"

    def front(c, L):
        for u in (0.11, 0.32, 0.53):
            dock_door(c, u, 0.15, 0.17, Z0, shutter="Shutter_Red", frame="Trim_White", canopy=False, bollards=False)
        c.mb.box2(0.0, -0.004, 0.2, L, 0.0, 0.215, "Trim_Stone", skip=("+y",))

    shed(c, x0, y0, x1, y1, Z0, 0.22, wall, flat=True, parapet=0.0, corner=None, plinth="Concrete_Dark",
         features={"S": [front], "E": [lambda c, L: man_door(c, 0.1, Z0, mat="Door_Red")]})
    w = Win(w=0.055, h=0.08, sill=0.035, frame="Frame_White", bay=0.09, sill_mat="Trim_Stone", lit=0.45)
    block(c, x0, y0, x1, y1, [(0.22, 0.36)], w, wall)
    cornice(c, x0, y0, x1, y1, 0.36, mat="Trim_Stone", h=0.012, out=0.006)
    flat_roof(c, x0, y0, x1, y1, 0.372, roof="Roof_Flat", parapet=0.014, pmat=wall)
    _letters_sign(c, (x0 + x1) / 2, y0 - 0.004, 0.335, 0.3, 0.03, bg="Sign_Red")
    light_bar("Beacon", (x0 + x1) / 2, y0 + 0.02, 0.386, mats=("Siren_Red", "Siren_Red"), w=0.07)
    # hose-drying / training tower
    tx0, ty0, tx1, ty1 = 0.24, 0.12, 0.38, 0.3
    tw = Win(w=0.04, h=0.07, sill=0.04, frame="Frame_Dark", bay=0.07, sill_mat="Trim_Stone", lit=0.2)
    block(c, tx0, ty0, tx1, ty1, [(Z0 + k * 0.13, Z0 + (k + 1) * 0.13) for k in range(5)], tw, wall)
    flat_roof(c, tx0, ty0, tx1, ty1, Z0 + 0.65, roof="Roof_Flat", parapet=0.016, pmat=wall)
    mb.cyl((0.31, 0.21, Z0 + 0.65), 0.003, 0.08, "Metal_Galv", n=6)
    # apron with markings, engine and hydrant
    pad(c, x0, -0.46, x1, -0.085, "Concrete_Light", h=0.001)
    for u in (0.11, 0.32, 0.53):
        xx = x0 + u
        mb.box2(xx - 0.08, -0.12, 0.0055, xx + 0.08, -0.105, 0.0058, "Paint_Yellow", skip=("-z",))
    truck(c, x0 + 0.32, -0.27, 0.0, box_mat="Metal_Red", cab_mat="Paint_red", L=0.4)
    mb.box2(x0 + 0.29, -0.3, 0.2, x0 + 0.35, -0.08, 0.212, "Metal_Galv")
    mb.cyl((0.3, -0.4, Z0), 0.008, 0.03, "Metal_Red", n=10)
    mb.sphere((0.3, -0.4, Z0 + 0.03), 0.008, "Metal_Red", n=10, rings=4, hemi=True)
    flagpole(c, 0.42, -0.42, h=0.2)
    _trees(c, [(0.42, 0.42), (-0.44, 0.44)], seed=seed)


def hospital(c, seed=0):
    lot(c, "Sidewalk")
    mb = c.mb
    pad(c, -0.46, 0.2, -0.2, 0.46, "Grass", h=0.0015)
    # podium
    px0, py0, px1, py1 = -0.44, -0.2, 0.44, 0.18
    c.door_mat = "Glass_Shop"
    w0 = Win(w=0.08, h=0.085, sill=0.03, frame="Frame_Alu", bay=0.1, lit=0.5, sill_mat="Metal_Galv")
    block(c, px0, py0, px1, py1, [(Z0, Z0 + 0.16), (Z0 + 0.16, Z0 + 0.32)], w0, "Plaster_White",
          lambda s, fi, bi: ("door" if bi in (2, 6) else "shop") if (s == "S" and fi == 0) else "band")
    flat_roof(c, px0, py0, px1, py1, Z0 + 0.32, roof="Roof_Gravel", parapet=0.012, pmat="Plaster_White",
              cap="Metal_Galv")
    # ward tower
    tx0, ty0, tx1, ty1 = -0.16, -0.12, 0.36, 0.12
    wt = Win(w=0.06, h=0.07, sill=0.04, frame="Frame_Alu", bay=0.075, lit=0.5, sill_mat=None)
    fl = [(Z0 + 0.32 + k * 0.15, Z0 + 0.32 + (k + 1) * 0.15) for k in range(5)]
    block(c, tx0, ty0, tx1, ty1, fl, wt, "Plaster_White", lambda s, fi, bi: "band")
    for k in range(len(fl) + 1):
        arch.band(c, tx0, ty0, tx1, ty1, Z0 + 0.32 + k * 0.15 - 0.004, 0.008, "Metal_White", out=0.003)
    top = Z0 + 0.32 + 0.75
    flat_roof(c, tx0, ty0, tx1, ty1, top, roof="Roof_Flat", parapet=0.012, pmat="Plaster_White", cap="Metal_Galv")
    # helipad
    hx, hy = 0.1, 0.0
    mb.cyl((hx, hy, top), 0.105, 0.012, "Metal_Dark", n=24)
    mb.cyl((hx, hy, top + 0.012), 0.1, 0.001, "Asphalt_Dark", n=24, caps=(False, True))
    mb.lathe([(0.088, 0.0), (0.094, 0.0), (0.094, 0.0005), (0.088, 0.0005)], "Paint_Yellow", n=24,
             c=(hx, hy, top + 0.0128), smooth=False)
    for (a, b, cc, d) in ((-0.03, -0.04, -0.018, 0.04), (0.018, -0.04, 0.03, 0.04), (-0.018, -0.006, 0.018, 0.006)):
        mb.box2(hx + a, hy + b, top + 0.013, hx + cc, hy + d, top + 0.0136, "Paint_White", skip=("-z",))
    # red cross signs
    for (sx, sy, face) in (((tx0 + 0.06), ty0 - 0.004, "S"),):
        mb.box2(sx - 0.035, sy - 0.003, top - 0.075, sx + 0.035, sy, top - 0.005, "Sign_White")
        mb.box2(sx - 0.007, sy - 0.0045, top - 0.068, sx + 0.007, sy, top - 0.012, "Sign_Red")
        mb.box2(sx - 0.028, sy - 0.0045, top - 0.047, sx + 0.028, sy, top - 0.033, "Sign_Red")
    _letters_sign(c, 0.1, py0 - 0.004, Z0 + 0.29, 0.34, 0.03, bg="Sign_White", fg="Sign_Red")
    # emergency canopy and ambulance bay
    mb.box2(0.22, py0 - 0.12, Z0 + 0.135, 0.42, py0, Z0 + 0.15, "Metal_White")
    for xx in (0.23, 0.41):
        mb.cyl((xx, py0 - 0.11, Z0), 0.005, 0.135, "Metal_Galv", n=8)
    mb.box2(0.22, py0 - 0.124, Z0 + 0.137, 0.42, py0 - 0.12, Z0 + 0.148, "Sign_Red")
    truck(c, 0.32, -0.38, 0.0, box_mat="Metal_White", cab_mat="Paint_white", L=0.3)
    mb.box2(0.26, -0.33, 0.12, 0.38, -0.329, 0.14, "Sign_Red")
    arch.hvac(c, -0.35, 0.05, Z0 + 0.32, 0.07, 0.05, 0.03)
    arch.hvac(c, 0.25, 0.08, top, 0.06, 0.04, 0.03)
    _trees(c, [(-0.42, -0.42), (-0.1, -0.42), (-0.4, 0.3), (-0.28, 0.4)], seed=seed)


def school(c, seed=0):
    lot(c, "Grass")
    mb = c.mb
    # classroom wing
    wall = "Brick_Orange"
    c.door_mat = "Door_Blue"
    w = Win(w=0.1, h=0.075, sill=0.04, frame="Frame_White", bay=0.12, lit=0.45, sill_mat="Trim_Stone",
            transom=True)
    x0, y0, x1, y1 = -0.44, 0.06, 0.1, 0.3
    block(c, x0, y0, x1, y1, [(Z0, Z0 + 0.16), (Z0 + 0.16, Z0 + 0.32)], w, wall,
          lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 2) else "win")
    arch.band(c, x0, y0, x1, y1, Z0 + 0.16, 0.008, "Trim_Stone", out=0.003)
    flat_roof(c, x0, y0, x1, y1, Z0 + 0.32, roof="Roof_Flat", parapet=0.014, pmat=wall)
    arch.solar_array(c, x0 + 0.04, y0 + 0.03, x1 - 0.04, y1 - 0.03, Z0 + 0.32, tilt=20, rows=2)
    # entrance canopy and sign
    ex = x0 + 2.5 * (x1 - x0) / 4
    mb.box2(ex - 0.07, y0 - 0.06, Z0 + 0.13, ex + 0.07, y0, Z0 + 0.14, "Metal_White")
    for sx in (-1, 1):
        mb.cyl((ex + sx * 0.06, y0 - 0.05, Z0), 0.004, 0.13, "Metal_White", n=8)
    _letters_sign(c, ex, y0 - 0.0605, Z0 + 0.135, 0.12, 0.009, bg="Sign_Green")
    # gymnasium
    gx0, gy0, gx1, gy1 = 0.12, 0.02, 0.44, 0.44
    shed(c, gx0, gy0, gx1, gy1, Z0, 0.26, wall, flat=False, roof="Roof_Grey", rise=0.04, ridge="y", corner=None,
         plinth="Concrete_Dark",
         features={"S": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.18, 0.235, frame="Frame_White", pane=0.04),
                         lambda c, L: man_door(c, L / 2, Z0, mat="Door_Blue", w=0.05)],
                   "W": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.18, 0.235, frame="Frame_White", pane=0.04)]})
    # playground + court
    pad(c, -0.44, -0.44, 0.44, -0.04, "Asphalt", h=0.0012)
    cx0, cy0, cx1, cy1 = 0.06, -0.42, 0.42, -0.08
    mb.box2(cx0, cy0, Z0 + 0.0012, cx1, cy1, Z0 + 0.0018, "Court_Blue", skip=("-z",))
    lw = 0.0018
    zz = Z0 + 0.0019
    for (a, b, cc, d) in ((cx0, cy0, cx1, cy0 + lw), (cx0, cy1 - lw, cx1, cy1), (cx0, cy0, cx0 + lw, cy1),
                          (cx1 - lw, cy0, cx1, cy1), ((cx0 + cx1) / 2 - lw / 2, cy0, (cx0 + cx1) / 2 + lw / 2, cy1)):
        mb.box2(a, b, zz, cc, d, zz + 0.0003, "Paint_White", skip=("-z",))
    for xx, s in ((cx0 + 0.015, 1), (cx1 - 0.015, -1)):
        yy = (cy0 + cy1) / 2
        mb.cyl((xx, yy, Z0), 0.0025, 0.07, "Metal_Galv", n=6)
        mb.box2(xx - 0.001, yy - 0.012, Z0 + 0.06, xx + 0.001, yy + 0.012, Z0 + 0.08, "Sign_White")
    # play equipment
    mb.box2(-0.36, -0.3, Z0, -0.3, -0.24, Z0 + 0.04, "Metal_Red", skip=("-z",))
    mb.box2(-0.37, -0.31, Z0 + 0.04, -0.29, -0.23, Z0 + 0.046, "Wood")
    beam(mb, (-0.3, -0.27, Z0 + 0.04), (-0.22, -0.27, Z0 + 0.002), 0.02, 0.003, "Metal_Yellow")
    for xx in (-0.16, -0.06):
        beam(mb, (xx, -0.36, Z0), (xx, -0.32, Z0 + 0.05), 0.003, 0.003, "Metal_Blue")
        beam(mb, (xx, -0.28, Z0), (xx, -0.32, Z0 + 0.05), 0.003, 0.003, "Metal_Blue")
    beam(mb, (-0.16, -0.32, Z0 + 0.05), (-0.06, -0.32, Z0 + 0.05), 0.003, 0.003, "Metal_Blue")
    fence_line(c, [(-0.462, -0.462), (0.462, -0.462), (0.462, 0.462), (-0.462, 0.462), (-0.462, -0.462)], h=0.03,
               mat="Metal_Green")
    flagpole(c, -0.4, 0.0, h=0.18)
    _trees(c, [(-0.42, 0.4), (-0.2, 0.42), (-0.02, -0.0)], seed=seed)


REGISTRY = {
    "buildings/coal_plant": (coal_plant, {}),
    "buildings/solar_farm": (solar_farm, {}),
    "buildings/wind_farm": (wind_farm, {}),
    "buildings/water_pump": (water_pump, {}),
    "buildings/sewage_plant": (sewage_plant, {}),
    "buildings/police_station": (police_station, {}),
    "buildings/fire_station": (fire_station, {}),
    "buildings/hospital": (hospital, {"_lit": "Glass"}),
    "buildings/school": (school, {}),
}
