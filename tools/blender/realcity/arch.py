"""Architectural building blocks: lots, facades with real window openings, roofs, rooftop kit."""

import math
import random

from mathutils import Matrix, Vector

import core
from core import MB, rotz

FH = 0.15  # residential storey height (3 m)


class Ctx:
    """Per-model build context: the main builder, foliage builder and RNG."""

    def __init__(self, seed=0, lit_look="Glass"):
        from nature import FoliageMB
        self.mb = MB()
        self.fol = FoliageMB()
        self.rnd = random.Random(seed)
        self.lit_look = lit_look
        self.extra = []  # extra Blender objects (Poly Haven imports, animated parts)

    def glass(self, base="Glass", lit=0.4):
        return "WindowLit" if self.rnd.random() < lit else base


# ----------------------------------------------------------------------------- ground

def lot(c, mat="Grass", size=0.94, h=0.004, x0=None, y0=None, x1=None, y1=None):
    mb = c.mb
    s = size / 2
    x0 = -s if x0 is None else x0
    y0 = -s if y0 is None else y0
    x1 = s if x1 is None else x1
    y1 = s if y1 is None else y1
    mb.box2(x0, y0, 0.0, x1, y1, h, mat, skip=("-z",))


def pad(c, x0, y0, x1, y1, mat, z=0.004, h=0.0012):
    c.mb.box2(x0, y0, z, x1, y1, z + h, mat, skip=("-z",))


# ----------------------------------------------------------------------------- facades

class Win:
    def __init__(self, w=0.07, h=0.085, sill=0.045, depth=0.008, frame="Frame_White", fw=0.0045, mullion=True,
                 transom=False, sill_mat="Trim_Stone", lintel=None, shutters=None, glass="Glass", lit=0.4,
                 bay=0.14, balcony=None, rail="Metal_Dark", reveal=None, arch=False):
        self.__dict__.update(locals())
        del self.__dict__["self"]


def _opening(c, u0, u1, v0, v1, w: Win, glass_mat, reveal_mat, door=None):
    mb = c.mb
    d = w.depth
    # reveals
    mb.poly([(u0, 0, v0), (u0, d, v0), (u0, d, v1), (u0, 0, v1)], reveal_mat)
    mb.poly([(u1, d, v0), (u1, 0, v0), (u1, 0, v1), (u1, d, v1)], reveal_mat)
    mb.poly([(u0, 0, v0), (u1, 0, v0), (u1, d, v0), (u0, d, v0)], w.sill_mat if w.sill_mat else reveal_mat)
    mb.poly([(u0, d, v1), (u1, d, v1), (u1, 0, v1), (u0, 0, v1)], reveal_mat)
    fw = w.fw
    if door:
        # door leaf with a glazed top light
        split = v1 - min(0.022, (v1 - v0) * 0.2)
        mb.poly([(u0, d, v0), (u1, d, v0), (u1, d, split), (u0, d, split)], door)
        mb.poly([(u0, d, split), (u1, d, split), (u1, d, v1), (u0, d, v1)], glass_mat)
        fy = d - 0.0006
        mb.poly([(u0, fy, split - fw * 0.4), (u1, fy, split - fw * 0.4), (u1, fy, split + fw * 0.4),
                 (u0, fy, split + fw * 0.4)], w.frame)
        # door panels / handle hint
        mb.box(((u0 + u1) / 2 + (u1 - u0) * 0.32, d - 0.001, v0 + (split - v0) * 0.48), (0.003, 0.002, 0.004),
               "Chrome")
    else:
        mb.poly([(u0, d, v0), (u1, d, v0), (u1, d, v1), (u0, d, v1)], glass_mat)
    fy = d - 0.0006
    fm = w.frame
    # frame ring
    mb.poly([(u0, fy, v0), (u1, fy, v0), (u1, fy, v0 + fw), (u0, fy, v0 + fw)], fm)
    mb.poly([(u0, fy, v1 - fw), (u1, fy, v1 - fw), (u1, fy, v1), (u0, fy, v1)], fm)
    mb.poly([(u0, fy, v0 + fw), (u0 + fw, fy, v0 + fw), (u0 + fw, fy, v1 - fw), (u0, fy, v1 - fw)], fm)
    mb.poly([(u1 - fw, fy, v0 + fw), (u1, fy, v0 + fw), (u1, fy, v1 - fw), (u1 - fw, fy, v1 - fw)], fm)
    if not door:
        fy2 = d - 0.0009
        if w.mullion and (u1 - u0) > 0.045:
            um = (u0 + u1) / 2
            mb.poly([(um - fw * 0.4, fy2, v0), (um + fw * 0.4, fy2, v0), (um + fw * 0.4, fy2, v1),
                     (um - fw * 0.4, fy2, v1)], fm)
        if w.transom:
            vt = v0 + (v1 - v0) * 0.72
            mb.poly([(u0, fy2, vt - fw * 0.4), (u1, fy2, vt - fw * 0.4), (u1, fy2, vt + fw * 0.4),
                     (u0, fy2, vt + fw * 0.4)], fm)


def facade(c, origin, angle, width, floors, w: Win, wall_mat, kinds=None, n_bays=None, margin=None):
    """Wall from local x=0..width with window openings; local -Y is outward.
    floors: list of (z0, z1). kinds(floor_idx, bay_idx) -> 'win'|'door'|'shop'|'wall'|'balc'|'garage'|'tall'."""
    mb = c.mb
    mb.push(Matrix.Translation(Vector(origin)) @ rotz(angle))
    n = n_bays or max(1, int(round(width / w.bay)))
    bay = width / n
    reveal = w.reveal or wall_mat
    for fi, (z0, z1) in enumerate(floors):
        cols = []
        for bi in range(n):
            k = kinds(fi, bi) if kinds else "win"
            cu = (bi + 0.5) * bay
            if k == "wall":
                cols.append(None)
                continue
            if k == "shop":
                hw = bay * 0.5 - 0.006
                v0, v1 = z0 + 0.006, min(z1 - 0.02, z0 + 0.105)
            elif k == "door":
                hw = min(w.w * 0.5, 0.03)
                v0, v1 = z0 + 0.002, z0 + 0.112
            elif k == "garage":
                hw = min(bay * 0.42, 0.06)
                v0, v1 = z0 + 0.001, z0 + 0.1
            elif k == "balc":
                hw = w.w * 0.5
                v0, v1 = z0 + 0.008, z0 + 0.008 + max(w.h + w.sill - 0.012, 0.1)
            elif k == "tall":
                hw = w.w * 0.5
                v0, v1 = z0 + 0.02, z1 - 0.02
            elif k == "band":
                hw = bay * 0.5 - 0.002
                v0, v1 = z0 + w.sill, z0 + w.sill + w.h
            else:
                hw = w.w * 0.5
                v0, v1 = z0 + w.sill, z0 + w.sill + w.h
            v1 = min(v1, z1 - 0.004)
            cols.append((k, cu - hw, cu + hw, v0, v1))
        # wall cells
        edges = [0.0]
        for col in cols:
            if col:
                edges += [col[1], col[2]]
        edges.append(width)
        # piers
        x = 0.0
        for col in cols:
            if col is None:
                continue
            if col[1] > x + 1e-5:
                mb.poly([(x, 0, z0), (col[1], 0, z0), (col[1], 0, z1), (x, 0, z1)], wall_mat)
            if col[3] > z0 + 1e-5:
                mb.poly([(col[1], 0, z0), (col[2], 0, z0), (col[2], 0, col[3]), (col[1], 0, col[3])], wall_mat)
            if col[4] < z1 - 1e-5:
                mb.poly([(col[1], 0, col[4]), (col[2], 0, col[4]), (col[2], 0, z1), (col[1], 0, z1)], wall_mat)
            x = col[2]
        if width > x + 1e-5:
            mb.poly([(x, 0, z0), (width, 0, z0), (width, 0, z1), (x, 0, z1)], wall_mat)
        # openings
        for col in cols:
            if col is None:
                continue
            k, u0, u1, v0, v1 = col
            if k == "shop":
                ws = Win(**{**w.__dict__, "depth": 0.006, "frame": "Frame_Dark" if w.frame != "Frame_Alu" else "Frame_Alu",
                            "fw": 0.003, "mullion": True, "transom": True, "sill_mat": "Concrete_Dark"})
                _opening(c, u0, u1, v0, v1, ws, "Glass_Shop" if c.rnd.random() > 0.5 else "WindowLit", reveal)
                mb.poly([(u0, ws.depth - 0.0007, v0), (u1, ws.depth - 0.0007, v0), (u1, ws.depth - 0.0007, v0 + 0.012),
                         (u0, ws.depth - 0.0007, v0 + 0.012)], ws.frame)
            elif k == "door":
                _opening(c, u0, u1, v0, v1, Win(**{**w.__dict__, "sill_mat": "Concrete"}), "Glass",
                         reveal, door=c.door_mat if hasattr(c, "door_mat") else "Door_Red")
                mb.box(((u0 + u1) / 2, -0.008, z0 + 0.002), (u1 - u0 + 0.02, 0.018, 0.004), "Concrete", skip=("-z",))
            elif k == "garage":
                gw = Win(**{**w.__dict__, "sill_mat": "Concrete", "depth": 0.004})
                mb.poly([(u0, 0, v0), (u0, gw.depth, v0), (u0, gw.depth, v1), (u0, 0, v1)], reveal)
                mb.poly([(u1, gw.depth, v0), (u1, 0, v0), (u1, 0, v1), (u1, gw.depth, v1)], reveal)
                mb.poly([(u0, gw.depth, v1), (u1, gw.depth, v1), (u1, 0, v1), (u0, 0, v1)], reveal)
                mb.poly([(u0, gw.depth, v0), (u1, gw.depth, v0), (u1, gw.depth, v1), (u0, gw.depth, v1)],
                        getattr(c, "garage_mat", "Shutter"))
            else:
                _opening(c, u0, u1, v0, v1, w, c.glass(w.glass, w.lit), reveal,
                         door=None if k != "balc" else None)
                if w.sill_mat and k in ("win", "tall"):
                    mb.box(((u0 + u1) / 2, -0.002, v0 - 0.0015), (u1 - u0 + 0.008, 0.007, 0.003), w.sill_mat)
                if w.lintel and k in ("win", "tall", "balc"):
                    mb.box(((u0 + u1) / 2, -0.0012, v1 + 0.004), (u1 - u0 + 0.01, 0.0035, 0.008), w.lintel,
                           skip=("+y",))
                if w.shutters and k == "win":
                    sw = (u1 - u0) * 0.5
                    for sx in (u0 - sw * 0.5 - 0.002, u1 + sw * 0.5 + 0.002):
                        mb.box((sx, -0.0015, (v0 + v1) / 2), (sw, 0.002, v1 - v0), w.shutters, skip=("+y",))
                if k == "balc":
                    bd = w.balcony or 0.03
                    bx0, bx1 = u0 - 0.012, u1 + 0.012
                    mb.box2(bx0, -bd, z0 - 0.004, bx1, 0.0, z0 + 0.002, "Concrete_Light")
                    rail_h = 0.05
                    if w.rail == "Glass":
                        for (a, b) in (((bx0, -bd), (bx1, -bd)), ((bx0, 0), (bx0, -bd)), ((bx1, -bd), (bx1, 0))):
                            mb.poly([(a[0], a[1], z0 + 0.002), (b[0], b[1], z0 + 0.002), (b[0], b[1], z0 + rail_h),
                                     (a[0], a[1], z0 + rail_h)], "Glass_Curtain")
                            mb.poly([(b[0], b[1], z0 + 0.002), (a[0], a[1], z0 + 0.002), (a[0], a[1], z0 + rail_h),
                                     (b[0], b[1], z0 + rail_h)], "Glass_Curtain")
                        mb.box(((bx0 + bx1) / 2, -bd, z0 + rail_h), (bx1 - bx0, 0.002, 0.002), "Frame_Alu")
                    else:
                        mb.box(((bx0 + bx1) / 2, -bd + 0.001, z0 + rail_h), (bx1 - bx0, 0.0025, 0.0025), w.rail)
                        mb.box(((bx0 + bx1) / 2, -bd + 0.001, z0 + 0.012), (bx1 - bx0, 0.0015, 0.0015), w.rail)
                        for sx in (bx0, bx1):
                            mb.box((sx, -bd / 2, z0 + rail_h), (0.0025, bd, 0.0025), w.rail)
                        nb = max(2, int((bx1 - bx0) / 0.014))
                        for i in range(nb + 1):
                            bxx = bx0 + (bx1 - bx0) * i / nb
                            mb.box((bxx, -bd + 0.001, z0 + rail_h / 2 + 0.001), (0.0012, 0.0012, rail_h - 0.002),
                                   w.rail, skip=("+z", "-z"))
    mb.pop()


SIDES = {
    # name: (origin_fn, angle, length_fn)
    "S": (lambda x0, y0, x1, y1: (x0, y0, 0), 0.0, lambda x0, y0, x1, y1: x1 - x0),
    "E": (lambda x0, y0, x1, y1: (x1, y0, 0), math.pi / 2, lambda x0, y0, x1, y1: y1 - y0),
    "N": (lambda x0, y0, x1, y1: (x1, y1, 0), math.pi, lambda x0, y0, x1, y1: x1 - x0),
    "W": (lambda x0, y0, x1, y1: (x0, y1, 0), -math.pi / 2, lambda x0, y0, x1, y1: y1 - y0),
}


def block(c, x0, y0, x1, y1, floors, w, wall_mat, kinds=None, sides="SENW", plain_mat=None):
    """Four facades around a rectangular block. kinds(side, floor, bay)."""
    for s in "SENW":
        o, ang, ln = SIDES[s]
        L = ln(x0, y0, x1, y1)
        if s in sides:
            k = (lambda fi, bi, s=s: kinds(s, fi, bi)) if kinds else None
            facade(c, o(x0, y0, x1, y1), ang, L, floors, w, wall_mat, kinds=k)
        else:
            facade(c, o(x0, y0, x1, y1), ang, L, floors, w, plain_mat or wall_mat, kinds=lambda fi, bi: "wall",
                   n_bays=1)


def band(c, x0, y0, x1, y1, z, h, mat, out=0.004):
    """Horizontal string course / cornice ring around a block."""
    c.mb.box2(x0 - out, y0 - out, z, x1 + out, y1 + out, z + h, mat)


def flat_roof(c, x0, y0, x1, y1, z, roof="Roof_Flat", parapet=0.018, pmat=None, cap="Trim_Stone", t=0.006):
    mb = c.mb
    mb.poly([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], roof)
    if parapet > 0:
        pm = pmat or roof
        zt = z + parapet
        for (ax, ay, bx, by) in ((x0, y0, x1, y0 + t), (x1 - t, y0, x1, y1), (x0, y1 - t, x1, y1), (x0, y0, x0 + t, y1)):
            mb.box2(ax, ay, z, bx, by, zt, pm, skip=("-z", "+z"))
        if cap:
            mb.box2(x0 - 0.002, y0 - 0.002, zt, x1 + 0.002, y0 + t + 0.001, zt + 0.003, cap, skip=("-z",))
            mb.box2(x0 - 0.002, y1 - t - 0.001, zt, x1 + 0.002, y1 + 0.002, zt + 0.003, cap, skip=("-z",))
            mb.box2(x0 - 0.002, y0 + t + 0.001, zt, x0 + t + 0.001, y1 - t - 0.001, zt + 0.003, cap, skip=("-z",))
            mb.box2(x1 - t - 0.001, y0 + t + 0.001, zt, x1 + 0.002, y1 - t - 0.001, zt + 0.003, cap, skip=("-z",))


def gable_roof(c, x0, y0, x1, y1, z, rise, mat, gable_mat, oh=0.012, ridge="x", t=0.004, gutter="Metal_White",
               fascia="Trim_White"):
    """Pitched roof with overhangs, soffits, fascia, gable-end walls and gutters. ridge along x or y."""
    mb = c.mb
    if ridge == "y":
        mb.push(Matrix.Translation(Vector(((x0 + x1) / 2, (y0 + y1) / 2, 0))) @ rotz(math.pi / 2))
        hw, hd = (y1 - y0) / 2, (x1 - x0) / 2
    else:
        mb.push(Matrix.Translation(Vector(((x0 + x1) / 2, (y0 + y1) / 2, 0))))
        hw, hd = (x1 - x0) / 2, (y1 - y0) / 2
    slope = rise / hd
    ze = z - oh * slope
    zr = z + rise
    X0, X1 = -hw - oh, hw + oh
    for sgn in (-1, 1):
        ye = sgn * (hd + oh)
        # top surface
        if sgn < 0:
            mb.poly([(X0, ye, ze), (X1, ye, ze), (X1, 0, zr), (X0, 0, zr)], mat)
            mb.poly([(X0, 0, zr - t), (X1, 0, zr - t), (X1, ye, ze - t), (X0, ye, ze - t)], fascia)
            mb.poly([(X0, ye, ze - t), (X1, ye, ze - t), (X1, ye, ze), (X0, ye, ze)], fascia)
        else:
            mb.poly([(X1, ye, ze), (X0, ye, ze), (X0, 0, zr), (X1, 0, zr)], mat)
            mb.poly([(X1, 0, zr - t), (X0, 0, zr - t), (X0, ye, ze - t), (X1, ye, ze - t)], fascia)
            mb.poly([(X1, ye, ze - t), (X0, ye, ze - t), (X0, ye, ze), (X1, ye, ze)], fascia)
        # verge (gable-edge) boards
        for xx, s2 in ((X0, -1), (X1, 1)):
            mb.polyo([(xx, 0, zr - t), (xx, ye, ze - t), (xx, ye, ze), (xx, 0, zr)], fascia, (s2, 0, 0))
        if gutter:
            gy = ye + sgn * 0.0025
            mb.box((0, gy, ze - 0.003), (X1 - X0, 0.005, 0.005), gutter)
            for xx in (X0 + 0.006, X1 - 0.006):
                mb.box((xx, gy, (ze + 0.0) / 2), (0.003, 0.003, ze), gutter, skip=("-z",))
    # gable end walls (triangles) at x=-hw and x=+hw
    mb.poly([(-hw, hd, z), (-hw, -hd, z), (-hw, 0, zr - t)], gable_mat)
    mb.poly([(hw, -hd, z), (hw, hd, z), (hw, 0, zr - t)], gable_mat)
    mb.pop()
    return zr


def hip_roof(c, x0, y0, x1, y1, z, rise, mat, oh=0.012, t=0.004, gutter="Metal_White", fascia="Trim_White"):
    mb = c.mb
    X0, Y0, X1, Y1 = x0 - oh, y0 - oh, x1 + oh, y1 + oh
    w, d = X1 - X0, Y1 - Y0
    slope = rise / ((y1 - y0) / 2 if d <= w else (x1 - x0) / 2)
    ze = z - oh * slope
    zr = ze + slope * min(w, d) / 2
    cx, cy = (X0 + X1) / 2, (Y0 + Y1) / 2
    if w >= d:
        rx = (w - d) / 2
        r0, r1 = (cx - rx, cy, zr), (cx + rx, cy, zr)
    else:
        ry = (d - w) / 2
        r0, r1 = (cx, cy - ry, zr), (cx, cy + ry, zr)
    A, B, C, D = (X0, Y0, ze), (X1, Y0, ze), (X1, Y1, ze), (X0, Y1, ze)
    if w >= d:
        mb.poly([A, B, r1, r0], mat)
        mb.poly([C, D, r0, r1], mat)
        mb.poly([B, C, r1], mat)
        mb.poly([D, A, r0], mat)
    else:
        mb.poly([B, C, r1, r0], mat)
        mb.poly([D, A, r0, r1], mat)
        mb.poly([A, B, r0], mat)
        mb.poly([C, D, r1], mat)
    # soffit + fascia
    mb.poly([(X0, Y1, ze - t), (X1, Y1, ze - t), (X1, Y0, ze - t), (X0, Y0, ze - t)], fascia)
    for (p, q) in ((A, B), (B, C), (C, D), (D, A)):
        mb.poly([(p[0], p[1], ze - t), (q[0], q[1], ze - t), (q[0], q[1], ze), (p[0], p[1], ze)], fascia)
    if gutter:
        mb.box2(X0 - 0.003, Y0 - 0.003, ze - 0.005, X1 + 0.003, Y0 + 0.001, ze, gutter)
        mb.box2(X0 - 0.003, Y1 - 0.001, ze - 0.005, X1 + 0.003, Y1 + 0.003, ze, gutter)
        for (xx, yy) in ((X0 + 0.004, Y0 - 0.001), (X1 - 0.004, Y0 - 0.001)):
            mb.box((xx, yy, ze / 2), (0.003, 0.003, ze), gutter, skip=("-z",))
    return zr


def chimney(c, x, y, z0, z1, w=0.026, d=0.02, mat="Brick_Red"):
    mb = c.mb
    mb.box2(x - w / 2, y - d / 2, z0, x + w / 2, y + d / 2, z1, mat, skip=("-z",))
    mb.box2(x - w / 2 - 0.002, y - d / 2 - 0.002, z1, x + w / 2 + 0.002, y + d / 2 + 0.002, z1 + 0.004, "Concrete")
    for dx in (-w / 4, w / 4):
        mb.cyl((x + dx, y, z1 + 0.004), 0.003, 0.008, "Clay_Pot" if "Clay_Pot" in core.MATS else "Brick_Orange", n=6)


def hvac(c, x, y, z, sx=0.05, sy=0.035, sz=0.025, rz=0.0):
    mb = c.mb
    mb.push(Matrix.Translation(Vector((x, y, z))) @ rotz(rz))
    mb.box((0, 0, sz / 2 + 0.002), (sx, sy, sz), "Metal_Galv")
    mb.box((0, 0, 0.001), (sx * 0.9, sy * 0.9, 0.002), "Metal_Dark")
    nf = 2 if sx > sy * 1.3 else 1
    for i in range(nf):
        fx = (i - (nf - 1) / 2) * sx / nf
        r = min(sx / nf, sy) * 0.36
        mb.cyl((fx, 0, sz + 0.002), r, 0.002, "Metal_Dark", n=12)
        mb.cyl((fx, 0, sz + 0.0035), r * 0.25, 0.001, "Metal_Galv", n=8)
    # louvres on the long face
    for k in range(3):
        mb.box((0, -sy / 2 - 0.0004, 0.006 + k * sz * 0.25), (sx * 0.8, 0.0008, 0.0016), "Metal_Dark")
    mb.pop()


def water_tank(c, x, y, z, r=0.035, h=0.05):
    mb = c.mb
    leg = 0.03
    for (dx, dy) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        mb.box((x + dx * r * 0.62, y + dy * r * 0.62, z + leg / 2), (0.004, 0.004, leg), "Metal_Dark")
    mb.box((x, y, z + leg - 0.002), (r * 1.6, r * 1.6, 0.003), "Metal_Dark")
    mb.lathe([(r, 0), (r, h)], "Wood_Weathered", n=14, c=(x, y, z + leg))
    for k in range(3):
        mb.lathe([(r + 0.0012, 0), (r + 0.0012, 0.0018)], "Metal_Dark", n=14, c=(x, y, z + leg + 0.008 + k * h * 0.38))
    mb.lathe([(r + 0.003, 0), (0.003, h * 0.4), (0.0, h * 0.42)], "Roof_Shingle", n=14, c=(x, y, z + leg + h))


def bulkhead(c, x, y, z, sx=0.07, sy=0.05, h=0.05, mat="Brick_Red"):
    mb = c.mb
    mb.box2(x - sx / 2, y - sy / 2, z, x + sx / 2, y + sy / 2, z + h, mat, skip=("-z", "+z"))
    flat_roof(c, x - sx / 2, y - sy / 2, x + sx / 2, y + sy / 2, z + h, roof="Roof_Flat", parapet=0.0)
    mb.box2(x - sx / 2 - 0.002, y - sy / 2 - 0.002, z + h - 0.001, x + sx / 2 + 0.002, y + sy / 2 + 0.002, z + h + 0.003,
            "Trim_Stone", skip=("+z",))
    mb.poly([(x - 0.012, y - sy / 2 - 0.0005, z), (x + 0.012, y - sy / 2 - 0.0005, z),
             (x + 0.012, y - sy / 2 - 0.0005, z + 0.042), (x - 0.012, y - sy / 2 - 0.0005, z + 0.042)], "Metal_Dark")


def antenna(c, x, y, z, h=0.12):
    mb = c.mb
    mb.cyl((x, y, z), 0.0025, h, "Metal_Galv", n=6)
    for k in range(3):
        mb.box((x, y, z + h * (0.5 + 0.2 * k)), (0.03 - k * 0.006, 0.0015, 0.0015), "Metal_Galv")
    mb.cyl((x, y, z + h), 0.003, 0.004, "Beacon_Red", n=6)


def dish(c, x, y, z, r=0.012, rz=0.0):
    mb = c.mb
    mb.cyl((x, y, z), 0.002, 0.012, "Metal_Galv", n=6)
    ax = Matrix.Rotation(math.radians(55), 4, "X") @ rotz(rz)
    mb.lathe([(0.0, 0.0), (r * 0.6, 0.002), (r, 0.006)], "Metal_White", n=12, c=(x, y, z + 0.012),
             axis=rotz(rz) @ Matrix.Rotation(math.radians(-55), 4, "X"))


def solar_array(c, x0, y0, x1, y1, z, tilt=25, rows=2):
    mb = c.mb
    d = (y1 - y0) / rows
    for r in range(rows):
        yy = y0 + d * (r + 0.5)
        h = d * 0.7 * math.sin(math.radians(tilt))
        ln = d * 0.7
        pz = z + 0.004 + h / 2
        m = Matrix.Translation(Vector(((x0 + x1) / 2, yy, pz))) @ Matrix.Rotation(math.radians(tilt), 4, "X")
        mb.push(m)
        mb.box((0, 0, 0), (x1 - x0, ln, 0.002), "Metal_Galv", mats={"+z": "Solar_Panel"})
        mb.pop()
        mb.box((x0 + 0.004, yy + ln * 0.35, z + h * 0.5), (0.003, 0.003, h + 0.004), "Metal_Galv", skip=("-z",))
        mb.box((x1 - 0.004, yy + ln * 0.35, z + h * 0.5), (0.003, 0.003, h + 0.004), "Metal_Galv", skip=("-z",))


def fire_escape(c, x0, x1, y, floors, rail="Metal_Dark"):
    """Iron fire escape on a south-facing wall (y is the wall plane, extends to y-depth)."""
    mb = c.mb
    dep = 0.028
    for (z0, z1) in floors[1:]:
        zz = z0 + 0.004
        mb.box2(x0, y - dep, zz - 0.002, x1, y, zz, rail)
        mb.box2(x0, y - dep, zz + 0.04, x1, y - dep + 0.0016, zz + 0.0416, rail)
        for xx in (x0, x1):
            mb.box2(xx - 0.001, y - dep, zz, xx + 0.001, y - dep + 0.0016, zz + 0.04, rail)
        n = int((x1 - x0) / 0.012)
        for i in range(1, n):
            xx = x0 + (x1 - x0) * i / n
            mb.box2(xx - 0.0006, y - dep, zz, xx + 0.0006, y - dep + 0.0012, zz + 0.04, rail, skip=("+z", "-z"))
        # stair to the floor above (diagonal)
        L = z1 - z0
        run = (x1 - x0) * 0.6
        ang = math.atan2(L, run)
        mb.push(Matrix.Translation(Vector((x0 + (x1 - x0) * 0.5, y - dep * 0.5, zz + L / 2))) @
                Matrix.Rotation(-ang, 4, "Y"))
        mb.box((0, 0, 0), (math.hypot(L, run), dep * 0.45, 0.002), rail)
        mb.pop()


def awning(c, x0, x1, y, z, depth=0.035, drop=0.014, mat="Fabric_Red", stripes=None):
    """Sloped shop awning on a south-facing wall at plane y."""
    mb = c.mb
    yt, yf = y, y - depth
    zt, zf = z, z - drop
    if stripes:
        n = max(3, int((x1 - x0) / 0.012))
        for i in range(n):
            a = x0 + (x1 - x0) * i / n
            b = x0 + (x1 - x0) * (i + 1) / n
            m = stripes[i % 2]
            mb.poly([(a, yf, zf), (b, yf, zf), (b, yt, zt), (a, yt, zt)], m)
            mb.poly([(a, yf, zf - 0.008), (b, yf, zf - 0.008), (b, yf, zf), (a, yf, zf)], m)
            mb.poly([(b, yt, zt - 0.0005), (a, yt, zt - 0.0005), (a, yf, zf - 0.0005), (b, yf, zf - 0.0005)], m)
    else:
        mb.poly([(x0, yf, zf), (x1, yf, zf), (x1, yt, zt), (x0, yt, zt)], mat)
        mb.poly([(x0, yf, zf - 0.008), (x1, yf, zf - 0.008), (x1, yf, zf), (x0, yf, zf)], mat)
        mb.poly([(x1, yt, zt - 0.0005), (x0, yt, zt - 0.0005), (x0, yf, zf - 0.0005), (x1, yf, zf - 0.0005)], mat)
    for xx, s in ((x0, -1), (x1, 1)):
        mb.polyo([(xx, yt, zt), (xx, yf, zf), (xx, yf, zf - 0.008)], mat if not stripes else stripes[0], (s, 0, 0))


def sign(c, x, y, z, w, h, bg="Sign_Red", fg="Sign_White", depth=0.004, letters=True, face="S", proj=False):
    """Fascia sign with blocky letters (reads as lettering at miniature scale)."""
    mb = c.mb
    ang = {"S": 0, "E": math.pi / 2, "N": math.pi, "W": -math.pi / 2}[face]
    mb.push(Matrix.Translation(Vector((x, y, z))) @ rotz(ang))
    mb.box((0, -depth / 2, 0), (w, depth, h), bg)
    if letters:
        rnd = c.rnd
        n = max(3, int(w / (h * 0.62)))
        lw = w * 0.82 / n
        xs = -w * 0.41
        for i in range(n):
            if rnd.random() < 0.12 and 0 < i < n - 1:
                continue
            ww = lw * rnd.uniform(0.55, 0.8)
            mb.poly([(xs + i * lw, -depth - 0.0005, -h * 0.28), (xs + i * lw + ww, -depth - 0.0005, -h * 0.28),
                     (xs + i * lw + ww, -depth - 0.0005, h * 0.28), (xs + i * lw, -depth - 0.0005, h * 0.28)], fg)
    mb.pop()


def tree_pit(c, x, y, h=0.4, kind="broad", seed=0):
    from nature import tree
    c.mb.box2(x - 0.018, y - 0.018, 0.004, x + 0.018, y + 0.018, 0.0055, "Dirt", skip=("-z",))
    tree(c.mb, c.fol, x, y, h=h, kind=kind, seed=seed, z0=0.005)


def fence(c, pts, h=0.03, mat="Wood", post=0.004, closed=False):
    mb = c.mb
    seq = list(pts) + ([pts[0]] if closed else [])
    for (a, b) in zip(seq[:-1], seq[1:]):
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        mb.push(Matrix.Translation(Vector(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, 0))) @ rotz(ang))
        mb.box((0, 0, h * 0.8), (L, 0.0018, 0.004), mat)
        mb.box((0, 0, h * 0.35), (L, 0.0018, 0.004), mat)
        n = max(1, int(L / 0.03))
        for i in range(n + 1):
            mb.box((-L / 2 + L * i / n, 0, h / 2), (post, post, h), mat, skip=("-z",))
        mb.pop()


def picket_fence(c, pts, h=0.022, mat="Trim_White"):
    mb = c.mb
    for (a, b) in zip(pts[:-1], pts[1:]):
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        mb.push(Matrix.Translation(Vector(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, 0))) @ rotz(ang))
        mb.box((0, 0, h * 0.7), (L, 0.0016, 0.003), mat)
        n = max(2, int(L / 0.007))
        for i in range(n + 1):
            mb.box((-L / 2 + L * i / n, 0, h / 2), (0.0028, 0.0012, h), mat, skip=("-z",))
        mb.pop()


# Real-size body shapes for parked cars (vehicles2.SHAPES2) with their length in units.
PARKED_SHAPES = (("hatchback", 0.205), ("coupe", 0.225), ("sedan", 0.235), ("suv", 0.24))


def parked_car(c, x, y, rz=0.0, color=None, scale=0.5, max_len=None, z=0.004):
    """Parked car merged into the model: a real-size (1.0x) body from the vehicles_v2 generator, opaque
    glass, merged wheels; its length runs along local Y before rz. The shape is drawn from those that fit
    max_len (default: room for the old placeholder of this `scale` plus 20%, at least a hatchback)."""
    import vehicles2
    rnd = c.rnd
    color = color or rnd.choice(["Paint_white", "Paint_black", "Paint_silver", "Paint_red", "Paint_blue", "Paint_grey"])
    if max_len is None:
        max_len = 0.09 * scale / 0.5 * 1.2
    # a private RNG seeded by the spot, so the zone's own random sequence is unchanged
    pr = random.Random(int(abs(x) * 1e4) * 7919 + int(abs(y) * 1e4) * 104729 + int(abs(rz) * 100))
    fits = [s for s, ln in PARKED_SHAPES if ln <= max_len] or [PARKED_SHAPES[0][0]]
    shape = pr.choice(fits)
    saved = c.rnd
    c.rnd = pr
    try:
        vehicles2.baked_car(c, x, y, rz=rz, paint=color, shape=shape, z=z,
                            rims="alloy" if pr.random() < 0.6 else "steel")
    finally:
        c.rnd = saved
