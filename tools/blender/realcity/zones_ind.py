"""Industrial zones: i1 warehouses/workshops, i2 factories with stacks, i3 heavy plants.
Smoke stacks carry empties StackTop_0 / StackTop_1 at their openings."""

import math

from mathutils import Matrix, Vector

import arch
from arch import FH, Win, block, flat_roof, lot, pad
from nature import tree
from indkit import (T, beam, car_park, column, container, cooling_tower, dock_door, fence_line, gallery,
                    hopper_silo, man_door, pallets, pipe, pipe_rack, sawtooth_roof, shed, silo, sphere_tank, stack,
                    strip_window, tank, truck, tube)
from zones_com import curtain

Z0 = 0.004


def _trees(c, pts, kind="broad", seed=0, h=(0.3, 0.42)):
    for i, (x, y) in enumerate(pts):
        tree(c.mb, c.fol, x, y, h=c.rnd.uniform(*h), kind=kind, seed=seed + i, z0=Z0)


def _roof_vents(c, pts, z):
    for (x, y) in pts:
        c.mb.cyl((x, y, z - 0.004), 0.004, 0.012, "Metal_Galv", n=8)
        c.mb.sphere((x, y, z + 0.012), 0.011, "Metal_Galv", n=10, rings=6, scale=(1, 1, 0.8))


def _office_annex(c, x0, y0, x1, y1, floors=2, wall="Concrete_Panel", entry=1, sides="SEW", glass="Glass"):
    fl = [(Z0 + k * FH, Z0 + (k + 1) * FH) for k in range(floors)]
    c.door_mat = "Glass_Shop"
    w = Win(w=0.075, h=0.075, sill=0.045, frame="Frame_Alu", bay=0.09, mullion=True, sill_mat="Metal_Galv",
            glass=glass, lit=0.45)
    block(c, x0, y0, x1, y1, fl, w, wall,
          lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == entry) else "win", sides=sides)
    top = Z0 + floors * FH
    flat_roof(c, x0, y0, x1, y1, top, roof="Roof_Gravel", parapet=0.012, pmat=wall, cap="Metal_Galv")
    return top + 0.012


# ----------------------------------------------------------------------------- i1

def warehouse_steel(c, wall="Metal_Corrugated_Light", seed=0):
    lot(c, "Concrete_Floor")
    pad(c, -0.47, -0.47, 0.47, -0.105, "Asphalt", h=0.0015)
    x0, y0, x1, y1 = -0.42, -0.1, 0.42, 0.42

    def front(c, L):
        for u in (0.42, 0.58, 0.74):
            dock_door(c, u, 0.12, 0.16, Z0)
        strip_window(c, 0.34, 0.82, 0.235, 0.262)

    def side(c, L):
        strip_window(c, 0.04, L - 0.04, 0.235, 0.262)
        man_door(c, L * 0.3, Z0)

    shed(c, x0, y0, x1, y1, Z0, 0.3, wall, roof="Metal_Corrugated", rise=0.05,
         features={"S": [front], "E": [side], "W": [side], "N": [lambda c, L: strip_window(c, 0.04, L - 0.04, 0.235, 0.262)]})
    _roof_vents(c, [(-0.25, 0.16), (0.0, 0.16), (0.25, 0.16)], 0.304 + 0.05)
    _office_annex(c, -0.42, -0.25, -0.12, -0.1, floors=2)
    arch.sign(c, -0.27, -0.252, 0.27, 0.16, 0.022, bg="Sign_Blue", depth=0.003)
    for u in (0.42, 0.58, 0.74):
        xx = x0 + u
        for s in (-1, 1):
            c.mb.box2(xx + s * 0.07 - 0.0012, -0.42, 0.0055, xx + s * 0.07 + 0.0012, -0.11, 0.0058, "Paint_Yellow",
                      skip=("-z",))
    truck(c, x0 + 0.58, -0.1 - 0.185, 0.0, box_mat="Container_White", cab_mat="Paint_blue", L=0.36)
    pallets(c, 0.3, -0.2, 2)
    fence_line(c, [(0.462, -0.1), (0.462, 0.462), (-0.462, 0.462), (-0.462, -0.1)])
    _trees(c, [(-0.42, -0.42), (-0.3, -0.43)], "round", seed)


def workshop_sawtooth(c, wall="Brick_Old", seed=0):
    lot(c, "Concrete_Floor")
    x0, y0, x1, y1 = -0.4, -0.2, 0.4, 0.4
    z1 = 0.26

    def front(c, L):
        for i in range(5):
            u0 = 0.03 + i * 0.16
            c.mb.box2(u0 - 0.012, -0.005, Z0, u0 - 0.002, 0.0, z1, wall, skip=("+y", "-z"))
            if i == 2:
                dock_door(c, u0 + 0.065, 0.11, 0.17, Z0, shutter="Door_Green", frame="Metal_Dark", bollards=False)
                strip_window(c, u0 + 0.015, u0 + 0.115, 0.2, 0.235, frame="Frame_Dark", pane=0.02)
            else:
                strip_window(c, u0 + 0.01, u0 + 0.12, 0.055, 0.215, frame="Frame_Dark", pane=0.018, lit=0.2)
        c.mb.box2(L - 0.014, -0.005, Z0, L - 0.002, 0.0, z1, wall, skip=("+y", "-z"))
        c.mb.box2(0.0, -0.006, z1 - 0.018, L, 0.0, z1, "Trim_Stone", skip=("+y",))

    def side(c, L):
        for i in range(3):
            u0 = 0.04 + i * L / 3
            strip_window(c, u0, u0 + L / 3 - 0.08, 0.07, 0.2, frame="Frame_Dark", pane=0.018, lit=0.2)
        man_door(c, L - 0.05, Z0, mat="Door_Green")

    shed(c, x0, y0, x1, y1, Z0, z1, wall, plinth="Concrete_Dark", flat=True, parapet=0.0, corner=None,
         features={"S": [front], "E": [side], "W": [side]})
    sawtooth_roof(c, x0, y0, x1, y1, z1, 4, 0.075, end_mat=wall)
    arch.chimney(c, 0.3, 0.33, z1 + 0.05, 0.5, w=0.04, d=0.04, mat="Brick_Red")
    arch.sign(c, -0.1, y0 - 0.006, 0.232, 0.22, 0.02, bg="Sign_White", fg="Door_Black", depth=0.002)
    pallets(c, -0.38, -0.3, 3)
    pallets(c, 0.2, -0.36, 2, rz=0.3)
    c.mb.box2(0.3, -0.33, Z0, 0.42, -0.25, 0.05, "Metal_Green", skip=("-z",))
    arch.parked_car(c, -0.15, -0.36, rz=math.pi / 2, scale=1.15, color="Paint_white")
    _trees(c, [(0.43, -0.43), (-0.44, 0.0)], "broad", seed)


def storage_yard(c, seed=0):
    lot(c, "Concrete_Floor")
    pad(c, -0.46, -0.08, 0.46, 0.46, "Gravel", h=0.001)
    rnd = c.rnd
    mats = ["Container_Blue", "Container_Red", "Container_Orange", "Container_White", "Container_Green",
            "Container_Grey"]
    for row, yy in enumerate((0.0, 0.135, 0.27, 0.405)):
        for seg, (xc, L) in enumerate(((-0.12, 0.61), (0.3, 0.305))):
            tiers = rnd.choice([1, 2, 2, 3, 3]) if row < 3 else rnd.choice([1, 2])
            for t in range(tiers):
                container(c.mb, xc + rnd.uniform(-0.005, 0.005), yy, Z0 + 0.0015 + t * 0.131, 0.0, rnd.choice(mats),
                          L=L)
    # rail-mounted gantry crane spanning the rows
    mb = c.mb
    for xx in (-0.02, 0.1):
        for yy in (-0.07, 0.445):
            mb.box2(xx - 0.008, yy - 0.008, Z0, xx + 0.008, yy + 0.008, 0.5, "Metal_Yellow", skip=("-z",))
            mb.box2(xx - 0.015, yy - 0.02, Z0, xx + 0.015, yy + 0.02, Z0 + 0.025, "Metal_Yellow")
        mb.box2(xx - 0.01, -0.08, 0.5, xx + 0.01, 0.46, 0.53, "Metal_Yellow")
        beam(mb, (xx, -0.07, 0.3), (xx, 0.06, 0.5), 0.006, 0.006, "Metal_Yellow")
    for yy in (-0.07, 0.445):
        mb.box2(-0.03, yy - 0.01, 0.48, 0.11, yy + 0.01, 0.5, "Metal_Yellow")
    mb.box2(0.0, 0.12, 0.53, 0.08, 0.2, 0.56, "Metal_White")
    mb.box2(0.03, 0.155, 0.43, 0.05, 0.165, 0.53, "Metal_Dark")
    mb.box2(-0.11, 0.12, 0.42, 0.19, 0.2, 0.432, "Metal_Yellow")
    for yy in (-0.07, 0.445):
        mb.box2(-0.46, yy - 0.004, Z0, 0.46, yy + 0.004, Z0 + 0.004, "Metal_Dark", skip=("-z",))
    # site office: stacked portacabins
    for t in range(2):
        container(mb, -0.3, -0.3, Z0 + t * 0.131, 0.0, "Container_White", L=0.3)
        for xx in (-0.39, -0.3, -0.21):
            mb.box2(xx - 0.025, -0.3 - 0.0622, Z0 + t * 0.131 + 0.045, xx + 0.025, -0.3 - 0.061,
                    Z0 + t * 0.131 + 0.095, c.glass("Glass", 0.4))
    mb.box2(-0.16, -0.38, Z0 + 0.131, -0.14, -0.24, Z0 + 0.134, "Grating")
    beam(mb, (-0.15, -0.44, Z0), (-0.15, -0.31, Z0 + 0.131), 0.02, 0.003, "Grating")
    truck(c, 0.18, -0.3, math.pi / 2, box_mat="Container_Red", cab_mat="Paint_white", L=0.42)
    fence_line(c, [(-0.462, -0.462), (-0.06, -0.462)])
    fence_line(c, [(0.12, -0.462), (0.462, -0.462), (0.462, 0.462)])
    for yy in (-0.462,):
        mb.box2(-0.065, yy - 0.004, Z0, -0.055, yy + 0.004, 0.07, "Metal_Red", skip=("-z",))
        mb.box2(0.115, yy - 0.004, Z0, 0.125, yy + 0.004, 0.07, "Metal_Red", skip=("-z",))
    mb.cyl((0.44, -0.2, Z0), 0.004, 0.4, "Metal_Galv", n=8)
    mb.box2(0.425, -0.215, 0.4, 0.455, -0.185, 0.41, "Metal_Dark")


def depot_cladded(c, seed=0):
    lot(c, "Concrete_Floor")
    pad(c, -0.47, -0.47, 0.47, -0.045, "Asphalt", h=0.0015)
    x0, y0, x1, y1 = -0.44, -0.04, 0.44, 0.44
    z1 = 0.38

    def front(c, L):
        c.mb.box2(0.0, -0.0012, 0.3, L, 0.0, 0.36, "Metal_Cladding_White", skip=("+y",))
        for u in (0.36, 0.5, 0.64, 0.78):
            dock_door(c, u, 0.11, 0.15, Z0, shutter="Shutter", frame="Metal_Dark")
        c.mb.push(T(0.02, -0.002))
        curtain(c, (0, 0, 0), 0.0, 0.22, Z0 + 0.012, 0.3, fh=0.145, panel=0.055, glass="Glass_Curtain",
                spandrel="Glass_Curtain", mullion="Frame_Alu", lit=0.35)
        c.mb.pop()
        man_door(c, 0.12, Z0, mat="Glass_Shop", w=0.05, canopy=True)

    def side(c, L):
        c.mb.box2(0.0, -0.0012, 0.3, L, 0.0, 0.36, "Metal_Cladding_White", skip=("+y",))
        man_door(c, 0.1, Z0)

    shed(c, x0, y0, x1, y1, Z0, z1, "Metal_Cladding_Blue", flat=True, parapet=0.012, plinth_h=0.025,
         features={"S": [front], "E": [side], "W": [side], "N": [side]})
    for xx in (-0.25, 0.0, 0.25):
        c.mb.box2(xx - 0.06, 0.05, z1, xx + 0.06, 0.35, z1 + 0.012, "Glass_Curtain", mats={"-z": "Metal_Galv"})
    arch.hvac(c, 0.36, 0.38, z1, 0.06, 0.05, 0.03)
    arch.sign(c, 0.12, y0 - 0.0035, 0.335, 0.3, 0.03, bg="Sign_White", fg="Sign_Blue", depth=0.002)
    truck(c, x0 + 0.5, y0 - 0.215, 0.0, box_mat="Container_Orange", cab_mat="Paint_white", L=0.42)
    truck(c, x0 + 0.78, y0 - 0.215, 0.0, box_mat="Container_White", cab_mat="Paint_red", L=0.42)
    car_park(c, -0.46, -0.46, -0.08, -0.25, 3, rz=0.0, fill=0.8)
    _trees(c, [(-0.44, -0.2)], "round", seed, h=(0.32, 0.36))


# ----------------------------------------------------------------------------- i2

def factory_brick(c, seed=0):
    lot(c, "Concrete_Floor")
    wall = "Brick_Red"
    x0, y0, x1, y1 = -0.44, -0.08, 0.16, 0.44
    z1 = 0.3

    def side(c, L):
        n = int(L / 0.12)
        for i in range(n):
            u0 = 0.02 + i * (L - 0.04) / n
            strip_window(c, u0 + 0.02, u0 + (L - 0.04) / n - 0.02, 0.06, 0.24, frame="Frame_Dark", pane=0.02,
                         lit=0.3)

    shed(c, x0, y0, x1, y1, Z0, z1, wall, plinth="Concrete_Dark", flat=True, parapet=0.0, corner=None,
         features={"E": [side], "W": [side], "N": [side]})
    sawtooth_roof(c, x0, y0, x1, y1, z1, 3, 0.09, end_mat=wall)
    # three-storey office block on the front
    ox0, ox1, oy0, oy1 = -0.4, 0.12, -0.3, -0.08
    fl = [(Z0, Z0 + 0.13), (Z0 + 0.13, Z0 + 0.25), (Z0 + 0.25, Z0 + 0.37)]
    c.door_mat = "Door_Green"
    w = Win(w=0.05, h=0.08, sill=0.025, frame="Frame_White", bay=0.085, transom=True, sill_mat="Trim_Stone",
            lintel="Trim_Stone", lit=0.45)
    block(c, ox0, oy0, ox1, oy1, fl, w, wall, lambda s, fi, bi: "door" if (s == "S" and fi == 0 and bi == 3) else "win",
          sides="SEW")
    from zones_res2 import cornice
    cornice(c, ox0, oy0, ox1, oy1, Z0 + 0.37, mat="Trim_Stone", h=0.014, out=0.008)
    flat_roof(c, ox0, oy0, ox1, oy1, Z0 + 0.384, roof="Roof_Flat", parapet=0.016, pmat=wall)
    arch.band(c, ox0, oy0, ox1, oy1, Z0 + 0.125, 0.008, "Trim_Stone", out=0.003)
    arch.sign(c, (ox0 + ox1) / 2, oy0 - 0.004, Z0 + 0.36, 0.3, 0.018, bg="Sign_White", fg="Door_Black", depth=0.002)
    # boiler house + chimney
    bx0, bx1, by0, by1 = 0.2, 0.44, 0.12, 0.44
    shed(c, bx0, by0, bx1, by1, Z0, 0.2, "Brick_Old", roof="Roof_Slate", rise=0.06, ridge="y", plinth="Concrete_Dark",
         corner=None, features={"S": [lambda c, L: dock_door(c, L / 2, 0.08, 0.12, Z0, shutter="Wood_Dark",
                                                              frame="Metal_Dark", bollards=False, canopy=False)]})
    stack(c, 0, 0.32, 0.0, 1.14, 0.052, 0.032, mat="Brick_Old", z0=Z0 + 0.08,
          bands=((0.55, 0.57, "Trim_Stone"), (0.92, 0.95, "Trim_Stone")), platform=None, rim="Concrete_Dark",
          base=(0.13, 0.08, "Brick_Red"))
    pipe(c.mb, [(0.2, 0.3, 0.12), (0.26, 0.3, 0.12), (0.26, 0.02, 0.12)], 0.009, "Metal_Rusty")
    tank(c, 0.36, -0.28, 0.06, 0.1, mat="Metal_Rusty", roof="cone", stairs=True)
    pallets(c, 0.2, -0.42, 3)
    arch.parked_car(c, -0.3, -0.4, rz=math.pi / 2, scale=1.15)
    arch.parked_car(c, -0.08, -0.4, rz=math.pi / 2, scale=1.15)
    _trees(c, [(-0.45, -0.44), (0.45, -0.1)], "broad", seed)


def factory_steel(c, seed=0):
    lot(c, "Concrete_Floor")
    pad(c, -0.47, -0.47, 0.47, -0.135, "Asphalt", h=0.0015)
    xa0, ya0, xa1, ya1 = -0.44, -0.13, 0.08, 0.44

    def front(c, L):
        for u in (0.1, 0.26):
            dock_door(c, u, 0.12, 0.17, Z0)
        strip_window(c, 0.34, L - 0.03, 0.06, 0.16, frame="Frame_Alu", pane=0.03)
        man_door(c, 0.42, Z0)

    def side(c, L):
        strip_window(c, 0.03, L - 0.03, 0.25, 0.28, pane=0.04)

    shed(c, xa0, ya0, xa1, ya1, Z0, 0.32, "Metal_Cladding_Blue", roof="Metal_Corrugated", rise=0.05, ridge="y",
         features={"S": [front], "W": [side], "N": [side]})
    # taller furnace hall
    xb0, yb0, xb1, yb1 = 0.08, 0.05, 0.44, 0.44
    shed(c, xb0, yb0, xb1, yb1, Z0, 0.42, "Metal_Rusty", roof="Metal_Corrugated", rise=0.05, ridge="x",
         features={"S": [lambda c, L: dock_door(c, L * 0.4, 0.14, 0.2, Z0, frame="Metal_Dark")],
                   "E": [side]})
    # monitor roof (ventilation lantern)
    c.mb.box2(xb0 + 0.04, 0.23, 0.47, xb1 - 0.04, 0.27, 0.5, "Metal_Corrugated", skip=("-z",))
    stack(c, 0, 0.3, -0.06, 1.0, 0.03, 0.026, mat="Metal_Galv", z0=Z0,
          bands=((0.86, 0.9, "Stack_Red"), (0.94, 0.98, "Stack_White")), platform=0.78)
    stack(c, 1, 0.4, -0.2, 0.86, 0.026, 0.022, mat="Metal_Galv", z0=Z0,
          bands=((0.84, 0.89, "Stack_Red"), (0.94, 0.98, "Stack_White")), platform=0.7)
    pipe(c.mb, [(0.3, 0.05, 0.3), (0.3, -0.06, 0.3)], 0.014, "Metal_Galv")
    pipe(c.mb, [(0.4, 0.05, 0.22), (0.4, -0.2, 0.22)], 0.011, "Metal_Galv")
    hopper_silo(c, 0.17, -0.06, 0.04, 0.1, mat="Steel_White", z0=Z0)
    gallery(c, (0.17, -0.06, 0.32), (0.17, 0.05, 0.38), w=0.018, h=0.02)
    for i, yy in enumerate((-0.3, -0.42)):
        c.mb.box2(0.12, yy - 0.04, Z0, 0.44, yy + 0.04, Z0 + 0.06, "Metal_Rusty")
    truck(c, xa0 + 0.26, -0.13 - 0.185, 0.0, box_mat="Container_Grey", cab_mat="Paint_orange", L=0.36)
    _trees(c, [(-0.44, -0.44)], "round", seed)


def plant_food(c, seed=0):
    lot(c, "Concrete_Floor")
    pad(c, -0.47, -0.47, 0.47, -0.2, "Asphalt", h=0.0015)
    # processing building
    x0, y0, x1, y1 = -0.44, -0.18, 0.02, 0.4

    def front(c, L):
        for u in (0.08, 0.22):
            dock_door(c, u, 0.11, 0.15, Z0, frame="Metal_Dark")
        strip_window(c, 0.3, L - 0.03, 0.2, 0.25, pane=0.035)
        man_door(c, 0.36, Z0, mat="Door_Blue")

    shed(c, x0, y0, x1, y1, Z0, 0.3, "Metal_Cladding_White", flat=True, parapet=0.014,
         features={"S": [front], "W": [lambda c, L: strip_window(c, 0.03, L - 0.03, 0.2, 0.25, pane=0.035)]})
    arch.hvac(c, -0.3, 0.2, 0.3, 0.07, 0.05, 0.03)
    arch.hvac(c, -0.15, 0.25, 0.3, 0.05, 0.04, 0.03)
    arch.sign(c, -0.21, y0 - 0.0035, 0.27, 0.26, 0.026, bg="Sign_Green", fg="Sign_White", depth=0.002)
    # silo battery
    r = 0.055
    for i, sx in enumerate((0.12, 0.235, 0.35)):
        for sy in (0.1, 0.215, 0.33):
            silo(c, sx, sy, r, 0.62, mat="Concrete_Light", z0=Z0, roof="Concrete")
    c.mb.box2(0.12, 0.1, Z0 + 0.62, 0.35, 0.33, Z0 + 0.64, "Concrete")
    hx0, hx1, hy0, hy1 = 0.2, 0.3, 0.17, 0.27
    shed(c, hx0, hy0, hx1, hy1, Z0 + 0.64, Z0 + 0.78, "Metal_Corrugated_Light", flat=True, parapet=0.006,
         features={"S": [lambda c, L: strip_window(c, 0.02, L - 0.02, 0.73, 0.76, pane=0.03)]})
    gallery(c, (-0.02, 0.15, 0.3), (0.2, 0.22, 0.72), w=0.022, h=0.024)
    # intake pit and tanker
    c.mb.box2(0.08, -0.12, Z0, 0.4, -0.02, Z0 + 0.012, "Concrete_Dark")
    c.mb.box2(0.12, -0.08, Z0 + 0.012, 0.36, -0.06, Z0 + 0.014, "Grating")
    stack(c, 0, 0.44, 0.0, 0.94, 0.022, 0.018, mat="Steel_White", z0=Z0,
          bands=((0.92, 0.97, "Stack_Red"),), platform=0.75)
    pipe(c.mb, [(0.02, 0.0, 0.22), (0.44, 0.0, 0.22)], 0.008, "Metal_Galv")
    truck(c, 0.25, -0.33, math.pi / 2, box_mat="Chrome", cab_mat="Paint_green", L=0.42, tanker=True)
    car_park(c, -0.46, -0.46, -0.1, -0.24, 3, fill=0.7)


def factory_modern(c, seed=0):
    lot(c, "Grass")
    pad(c, -0.47, -0.47, 0.47, 0.47, "Concrete_Floor", z=0.004, h=0.0005)
    x0, y0, x1, y1 = -0.3, -0.12, 0.44, 0.44
    z1 = 0.28

    def front(c, L):
        c.mb.box2(0.0, -0.0012, 0.235, L, 0.0, 0.265, "Metal_Blue", skip=("+y",))
        strip_window(c, 0.04, L - 0.24, 0.1, 0.2, pane=0.05, glass="Glass_Curtain")
        for u in (L - 0.17, L - 0.06):
            dock_door(c, u, 0.09, 0.15, Z0, shutter="Metal_White", frame="Metal_Blue")

    def side(c, L):
        c.mb.box2(0.0, -0.0012, 0.235, L, 0.0, 0.265, "Metal_Blue", skip=("+y",))
        strip_window(c, 0.04, L - 0.04, 0.12, 0.18, pane=0.05, glass="Glass_Curtain")

    shed(c, x0, y0, x1, y1, Z0, z1, "Metal_Cladding_White", flat=True, parapet=0.012,
         features={"S": [front], "E": [side], "N": [side]})
    # glazed office cube on the west end
    ox0, ox1, oy0, oy1 = -0.44, -0.3, -0.18, 0.12
    from zones_com import curtain_block
    curtain_block(c, ox0, oy0, ox1, oy1, Z0, Z0 + 0.32, fh=0.16, panel=0.05, glass="Glass_Curtain",
                  spandrel="Metal_White", mullion="Frame_Alu", lit=0.45)
    flat_roof(c, ox0, oy0, ox1, oy1, Z0 + 0.32, roof="Roof_Flat", parapet=0.008, pmat="Metal_White", cap="Metal_White")
    for (x, y) in ((-0.1, 0.1), (0.1, 0.25), (0.28, 0.08)):
        arch.hvac(c, x, y, z1, 0.07, 0.05, 0.03)
    pipe(c.mb, [(-0.1, 0.1, z1 + 0.05), (0.3, 0.1, z1 + 0.05), (0.3, 0.3, z1 + 0.05)], 0.012, "Metal_Galv")
    stack(c, 0, 0.3, 0.3, 0.8, 0.02, 0.018, mat="Metal_Galv", z0=z1, platform=None,
          bands=((0.9, 0.96, "Stack_Red"),))
    tank(c, 0.4, -0.3, 0.035, 0.18, mat="Steel_White", roof="dome", stairs=False)
    tank(c, 0.31, -0.3, 0.035, 0.18, mat="Steel_White", roof="dome", stairs=False)
    car_park(c, -0.2, -0.46, 0.2, -0.24, 3, fill=0.8)
    for i, xx in enumerate((-0.42, -0.25)):
        tree(c.mb, c.fol, xx, -0.4, h=0.34, kind="birch", seed=seed + i, z0=Z0)
    tree(c.mb, c.fol, -0.42, 0.35, h=0.4, kind="conifer", seed=seed + 5, z0=Z0)


# ----------------------------------------------------------------------------- i3

def refinery(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    # bunded tank farm (back left)
    pad(c, -0.46, 0.0, -0.02, 0.46, "Gravel", h=0.001)
    for (a, b) in (((-0.46, 0.0), (-0.02, 0.0)), ((-0.02, 0.0), (-0.02, 0.46))):
        mb.box2(min(a[0], b[0]) - 0.004, min(a[1], b[1]) - 0.004, Z0, max(a[0], b[0]) + 0.004,
                max(a[1], b[1]) + 0.004, Z0 + 0.02, "Concrete")
    for (x, y, r, h, rf) in ((-0.34, 0.12, 0.095, 0.13, "float"), (-0.13, 0.12, 0.085, 0.13, "float"),
                             (-0.34, 0.35, 0.085, 0.16, "cone"), (-0.13, 0.35, 0.08, 0.16, "cone")):
        tank(c, x, y, r, h, mat="Steel_White", roof=rf)
    # process unit: columns, furnace, racks
    column(c, 0.16, 0.3, 0.032, 1.28, z0=Z0, platforms=6)
    column(c, 0.27, 0.3, 0.036, 0.98, z0=Z0, platforms=5)
    column(c, 0.37, 0.32, 0.024, 0.78, z0=Z0, platforms=4)
    column(c, 0.25, 0.42, 0.018, 0.5, z0=Z0, platforms=2)
    mb.box2(0.1, 0.05, Z0, 0.36, 0.16, Z0 + 0.22, "Metal_Rusty", mats={"+z": "Metal_Dark"})
    for k in range(4):
        mb.box2(0.1 + k * 0.065 + 0.005, 0.048, Z0 + 0.03, 0.1 + k * 0.065 + 0.06, 0.05, Z0 + 0.2, "Metal_Dark")
    stack(c, 0, 0.23, 0.1, 1.46, 0.032, 0.026, mat="Steel_White", z0=Z0 + 0.22,
          bands=((0.9, 0.94, "Stack_Red"), (0.95, 0.99, "Stack_White")), platform=0.8)
    pipe_rack(c, (0.0, 0.21), (0.46, 0.21), 0.12, w=0.05, pipes=4)
    pipe_rack(c, (0.04, -0.3), (0.04, 0.21), 0.12, w=0.05, pipes=3)
    pipe_rack(c, (-0.46, -0.05), (0.04, -0.05), 0.08, w=0.04, pipes=3)
    for x in (0.16, 0.27):
        pipe(mb, [(x, 0.3, 0.6), (x, 0.21, 0.6), (x, 0.21, 0.14)], 0.007, "Metal_Galv")
    sphere_tank(c, 0.25, -0.2, 0.065)
    sphere_tank(c, 0.4, -0.2, 0.055)
    # flare stack
    fx, fy = -0.38, -0.32
    for k in range(3):
        a = k * 2 * math.pi / 3
        beam(mb, (fx + math.cos(a) * 0.05, fy + math.sin(a) * 0.05, Z0), (fx, fy, 1.6), 0.006, 0.006, "Metal_Red")
    stack(c, 1, fx, fy, 2.0, 0.012, 0.012, mat="Metal_Galv", z0=Z0, platform=0.78, n=8, rim="Soot")
    for k in range(5):
        z = Z0 + 0.3 * (k + 1)
        a = 0.05 * (1 - z / 1.6)
        for i in range(3):
            a0, a1 = i * 2 * math.pi / 3, (i + 1) * 2 * math.pi / 3
            beam(mb, (fx + math.cos(a0) * a, fy + math.sin(a0) * a, z), (fx + math.cos(a1) * a, fy + math.sin(a1) * a, z),
                 0.003, 0.003, "Metal_Red")
    # control room
    mb.box2(-0.2, -0.44, Z0, 0.02, -0.3, 0.1, "Concrete_Panel")
    flat_roof(c, -0.2, -0.44, 0.02, -0.3, 0.1, roof="Roof_Flat", parapet=0.008, pmat="Concrete_Panel")
    strip_window_mb(c, -0.19, 0.01, -0.44, 0.05, 0.08)


def strip_window_mb(c, xa, xb, y, za, zb):
    c.mb.push(T(xa, y))
    strip_window(c, 0.0, xb - xa, za, zb, pane=0.03)
    c.mb.pop()


def steel_mill(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    # melt shop hall
    x0, y0, x1, y1 = -0.46, 0.02, -0.02, 0.46

    def side(c, L):
        strip_window(c, 0.03, L - 0.03, 0.4, 0.44, pane=0.04, lit=0.5)

    shed(c, x0, y0, x1, y1, Z0, 0.48, "Metal_Rusty", roof="Metal_Corrugated", rise=0.06, ridge="y",
         features={"S": [side, lambda c, L: dock_door(c, L / 2, 0.16, 0.22, Z0, frame="Metal_Dark")], "E": [side]})
    mb.box2(-0.3, 0.06, 0.54, -0.18, 0.42, 0.57, "Metal_Corrugated", skip=("-z",))
    # blast furnace
    bx, by = 0.2, 0.25
    prof = [(0.07, 0.0), (0.075, 0.14), (0.09, 0.2), (0.07, 0.5), (0.05, 0.62), (0.03, 0.66), (0.03, 0.72)]
    mb.lathe(prof, "Metal_Rusty", n=18, c=(bx, by, Z0 + 0.05), smooth=False)
    mb.cyl((bx, by, Z0), 0.11, 0.05, "Concrete", n=16, caps=(False, True))
    for k, z in enumerate((0.2, 0.42, 0.62)):
        mb.box2(bx - 0.12, by - 0.12, Z0 + z, bx + 0.12, by + 0.12, Z0 + z + 0.006, "Grating")
    for (dx, dy) in ((-0.12, -0.12), (0.12, -0.12), (0.12, 0.12), (-0.12, 0.12)):
        mb.box2(bx + dx - 0.006, by + dy - 0.006, Z0, bx + dx + 0.006, by + dy + 0.006, Z0 + 0.95, "Metal_Dark",
                skip=("-z",))
    mb.box2(bx - 0.125, by - 0.125, Z0 + 0.95, bx + 0.125, by + 0.125, Z0 + 0.96, "Metal_Dark")
    for (dx, dy) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        pipe(mb, [(bx + dx * 0.028, by + dy * 0.028, Z0 + 0.77), (bx + dx * 0.06, by + dy * 0.06, Z0 + 1.0),
                  (bx, by, Z0 + 1.12)], 0.011, "Metal_Rusty")
    pipe(mb, [(bx, by, Z0 + 1.12), (bx, by, Z0 + 1.2), (0.42, by, Z0 + 1.0), (0.42, by, Z0 + 0.2)], 0.018,
         "Metal_Rusty")
    mb.cyl((0.42, by, Z0), 0.04, 0.2, "Metal_Rusty", n=12)
    # hot blast stoves
    for i, sx in enumerate((0.06, 0.18, 0.3)):
        tank(c, sx, -0.08, 0.045, 0.62, mat="Metal_Galv", roof="dome", stairs=False, rings=4)
    pipe(mb, [(0.06, -0.08, 0.3), (0.3, -0.08, 0.3), (bx, by - 0.08, 0.3)], 0.012, "Metal_Rusty")
    gallery(c, (-0.02, -0.3, Z0 + 0.02), (bx - 0.05, by - 0.05, Z0 + 0.9), w=0.024, h=0.026)
    # ore piles
    for (x, y, r) in ((-0.3, -0.3, 0.12), (-0.08, -0.36, 0.08)):
        mb.lathe([(r, 0.0), (r * 0.6, r * 0.35), (r * 0.15, r * 0.5), (0.0, r * 0.52)], "Rock", n=14, c=(x, y, Z0))
    stack(c, 0, 0.4, -0.36, 2.2, 0.06, 0.04, mat="Concrete_Light", z0=Z0,
          bands=((0.86, 0.9, "Stack_Red"), (0.9, 0.94, "Stack_White"), (0.94, 0.98, "Stack_Red")), platform=0.84,
          n=16)
    stack(c, 1, 0.14, -0.3, 1.5, 0.035, 0.028, mat="Metal_Galv", z0=Z0,
          bands=((0.92, 0.97, "Stack_Red"),), platform=0.7)


def chemical_plant(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    for i, (x, y, r) in enumerate(((-0.36, 0.34, 0.075), (-0.18, 0.34, 0.075), (-0.36, 0.16, 0.065))):
        sphere_tank(c, x, y, r)
    column(c, 0.12, 0.34, 0.03, 1.15, z0=Z0, platforms=5)
    column(c, 0.22, 0.38, 0.026, 0.9, z0=Z0, platforms=4)
    for (x, y) in ((0.05, 0.14), (0.15, 0.14), (0.25, 0.14)):
        hopper_silo(c, x, y, 0.035, 0.12, mat="Steel_White", z0=Z0, legs=0.1)
    # steel process structure
    sx0, sy0, sx1, sy1 = 0.0, 0.05, 0.3, 0.24
    for lv, z in enumerate((0.14, 0.28, 0.42)):
        mb.box2(sx0, sy0, Z0 + z, sx1, sy1, Z0 + z + 0.005, "Grating")
        mb.box2(sx0, sy0 - 0.001, Z0 + z + 0.016, sx1, sy0 + 0.001, Z0 + z + 0.019, "Metal_Yellow")
    for (x, y) in ((sx0, sy0), (sx1, sy0), (sx1, sy1), (sx0, sy1), ((sx0 + sx1) / 2, sy0), ((sx0 + sx1) / 2, sy1)):
        mb.box2(x - 0.005, y - 0.005, Z0, x + 0.005, y + 0.005, Z0 + 0.43, "Metal_Dark", skip=("-z",))
    cooling_tower(c, 0.36, -0.22, 0.1, 0.42, z0=Z0)
    pipe_rack(c, (-0.46, 0.0), (0.46, 0.0), 0.1, w=0.05, pipes=4)
    pipe_rack(c, (-0.1, -0.44), (-0.1, 0.0), 0.1, w=0.04, pipes=3)
    stack(c, 0, 0.4, 0.32, 1.8, 0.04, 0.03, mat="Concrete_Light", z0=Z0,
          bands=((0.9, 0.95, "Stack_Red"),), platform=0.8)
    stack(c, 1, 0.33, 0.42, 1.45, 0.025, 0.02, mat="Metal_Galv", z0=Z0,
          bands=((0.9, 0.95, "Stack_Red"),), platform=0.7)
    pipe(mb, [(0.3, 0.2, 0.3), (0.4, 0.2, 0.3), (0.4, 0.28, 0.3)], 0.012, "Metal_Galv")
    for (x, y) in ((-0.36, -0.16), (-0.24, -0.16)):
        tank(c, x, y, 0.05, 0.16, mat="Metal_Galv", roof="dome", stairs=False)
    mb.box2(-0.46, -0.46, Z0, -0.18, -0.3, 0.12, "Concrete_Panel")
    flat_roof(c, -0.46, -0.46, -0.18, -0.3, 0.12, roof="Roof_Flat", parapet=0.01, pmat="Concrete_Panel")
    strip_window_mb(c, -0.45, -0.19, -0.46, 0.06, 0.1)
    truck(c, 0.05, -0.33, math.pi / 2, box_mat="Steel_White", cab_mat="Paint_yellow", L=0.42, tanker=True)


def cement_works(c, seed=0):
    lot(c, "Concrete_Floor")
    mb = c.mb
    # preheater tower
    tx0, ty0, tx1, ty1 = 0.1, 0.12, 0.32, 0.36
    levels = (0.25, 0.5, 0.75, 1.0, 1.25)
    for (x, y) in ((tx0, ty0), (tx1, ty0), (tx1, ty1), (tx0, ty1)):
        mb.box2(x - 0.012, y - 0.012, Z0, x + 0.012, y + 0.012, Z0 + 1.3, "Concrete", skip=("-z",))
    for z in levels:
        mb.box2(tx0 - 0.01, ty0 - 0.01, Z0 + z, tx1 + 0.01, ty1 + 0.01, Z0 + z + 0.02, "Concrete")
    shed(c, tx0, ty0, tx1, ty1, Z0 + 1.27, Z0 + 1.38, "Metal_Corrugated_Light", flat=True, parapet=0.006, corner=None,
         plinth_h=0.004)
    for k, z in enumerate((0.27, 0.52, 0.77, 1.02)):
        for (x, y) in ((tx0 + 0.06, ty0 + 0.08), (tx1 - 0.06, ty1 - 0.08)):
            mb.lathe([(0.0, 0.0), (0.012, 0.0), (0.045, 0.1), (0.045, 0.2)], "Steel_White", n=12, c=(x, y, Z0 + z))
            mb.cyl((x, y, Z0 + z + 0.2), 0.012, 0.03, "Steel_White", n=8)
    # rotary kiln
    kx0, kx1, ky = -0.44, 0.1, 0.06
    a = math.atan2(0.05, kx1 - kx0)
    mb.push(T(kx0, ky, Z0 + 0.08) @ Matrix.Rotation(math.pi / 2 - a, 4, "Y"))
    L = math.hypot(kx1 - kx0, 0.05)
    mb.lathe([(0.042, 0.0), (0.042, L)], "Metal_Rusty", n=16)
    for k in range(4):
        mb.lathe([(0.05, L * (0.15 + 0.23 * k)), (0.05, L * (0.15 + 0.23 * k) + 0.012)], "Metal_Dark", n=16)
    mb.pop()
    for k in range(4):
        x = kx0 + 0.07 + (kx1 - kx0 - 0.1) * k / 3
        z = Z0 + 0.08 + 0.05 * (x - kx0) / (kx1 - kx0)
        mb.box2(x - 0.015, ky - 0.04, Z0, x + 0.015, ky + 0.04, z - 0.036, "Concrete", skip=("-z",))
    mb.box2(-0.46, ky - 0.06, Z0, -0.4, ky + 0.06, 0.18, "Concrete_Dark", skip=("-z",))
    # clinker / cement silos
    for i, (x, y) in enumerate(((-0.38, 0.33), (-0.22, 0.33), (-0.06, 0.33))):
        silo(c, x, y, 0.07, 0.72, mat="Concrete_Light", z0=Z0, roof="Concrete")
    mb.box2(-0.4, 0.31, Z0 + 0.72, -0.04, 0.35, Z0 + 0.76, "Metal_Corrugated_Light")
    gallery(c, (0.1, 0.3, 0.9), (-0.04, 0.33, 0.74), w=0.02, h=0.024, supports=False)
    gallery(c, (-0.25, -0.32, Z0 + 0.02), (0.1, 0.18, 0.5), w=0.022, h=0.024)
    for (x, y, r) in ((-0.33, -0.3, 0.12),):
        mb.lathe([(r, 0.0), (r * 0.6, r * 0.35), (r * 0.15, r * 0.5), (0.0, r * 0.52)], "Rock", n=14, c=(x, y, Z0))
    stack(c, 0, 0.4, -0.3, 1.9, 0.05, 0.035, mat="Concrete_Light", z0=Z0,
          bands=((0.88, 0.93, "Stack_Red"), (0.93, 0.98, "Stack_White")), platform=0.82, n=16)
    pipe(mb, [(0.32, 0.2, 0.9), (0.4, 0.2, 0.9), (0.4, -0.25, 0.9)], 0.02, "Metal_Galv")
    stack(c, 1, 0.21, 0.24, 1.62, 0.02, 0.018, mat="Metal_Galv", z0=Z0 + 1.38, platform=None)
    truck(c, -0.02, -0.33, math.pi / 2, box_mat="Steel_White", cab_mat="Paint_grey", L=0.42, tanker=True)


REGISTRY = {
    "zones/i1/warehouse_steel": (warehouse_steel, {}),
    "zones/i1/workshop_sawtooth": (workshop_sawtooth, {}),
    "zones/i1/storage_yard": (storage_yard, {}),
    "zones/i1/depot_cladded": (depot_cladded, {"_lit": "Glass_Curtain"}),
    "zones/i2/factory_brick": (factory_brick, {}),
    "zones/i2/factory_steel": (factory_steel, {}),
    "zones/i2/plant_food": (plant_food, {}),
    "zones/i2/factory_modern": (factory_modern, {"_lit": "Glass_Curtain"}),
    "zones/i3/refinery": (refinery, {}),
    "zones/i3/steel_mill": (steel_mill, {}),
    "zones/i3/chemical_plant": (chemical_plant, {}),
    "zones/i3/cement_works": (cement_works, {}),
}
