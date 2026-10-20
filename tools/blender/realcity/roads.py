"""Road tiles (1 x 1, full tile). Orientation in Godot terms: N = -Z, E = +X, S = +Z, W = -X
(Blender: N = +Y, E = +X, S = -Y, W = -X).

    road_straight / road_straight_lights : N-S
    road_corner                          : S + W
    road_tee                             : E + S + W
    road_cross                           : N + E + S + W
    road_end                             : S only (cul-de-sac)
    road_bridge                          : N-S deck with piers below y = 0

Carriageway 12 m (|x| < 0.3), raised 4 m sidewalks with concrete curbs, white lane markings,
zebra crossings and stop lines at junctions. Street-lamp glass objects are named Bulb_<n>."""

import math

from mathutils import Matrix, Vector
from mathutils.geometry import tessellate_polygon

import core
from core import MB, rotz
from indkit import T, beam
from services import part

ZA = 0.003      # asphalt top
ZS = 0.009      # sidewalk top
ZM = ZA + 0.0003  # markings
HW = 0.3        # half carriageway width


def _arc(cx, cy, r, a0, a1, n=12):
    return [(cx + r * math.cos(a0 + (a1 - a0) * k / n), cy + r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]


def sidewalk(mb, pts, curb_edges):
    """Raised sidewalk polygon (CCW) with curb faces on the edges listed in curb_edges (index i = pts[i]->pts[i+1])."""
    tris = tessellate_polygon([[(p[0], p[1], 0.0) for p in pts]])
    for t in tris:
        a, b, c = (pts[i] for i in t)
        mb.polyo([(a[0], a[1], ZS), (b[0], b[1], ZS), (c[0], c[1], ZS)], "Sidewalk", (0, 0, 1))
    n = len(pts)
    for i in curb_edges:
        a, b = pts[i], pts[(i + 1) % n]
        # outward = right-hand normal of a CCW polygon edge
        dx, dy = b[0] - a[0], b[1] - a[1]
        mb.polyo([(a[0], a[1], ZA - 0.001), (b[0], b[1], ZA - 0.001), (b[0], b[1], ZS), (a[0], a[1], ZS)], "Curb",
                 (dy, -dx, 0))


def curb_run(pts_open):
    return list(range(len(pts_open) - 1))


def asphalt(mb, x0=-0.5, y0=-0.5, x1=0.5, y1=0.5):
    mb.poly([(x0, y0, ZA), (x1, y0, ZA), (x1, y1, ZA), (x0, y1, ZA)], "Asphalt")
    # skirt so the tile reads as a slab when seen edge-on
    for (a, b) in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        dx, dy = b[0] - a[0], b[1] - a[1]
        mb.polyo([(a[0], a[1], 0.0), (b[0], b[1], 0.0), (b[0], b[1], ZA), (a[0], a[1], ZA)], "Asphalt_Dark",
                 (dy, -dx, 0))


def mark_rect(mb, x0, y0, x1, y1, mat="Paint_White"):
    mb.poly([(x0, y0, ZM), (x1, y0, ZM), (x1, y1, ZM), (x0, y1, ZM)], mat)


def dashes_y(mb, x, y0, y1, w=0.005, dash=0.06, gap=0.065):
    y = y0 + gap / 2
    while y + dash <= y1 + 1e-6:
        mark_rect(mb, x - w / 2, y, x + w / 2, y + dash)
        y += dash + gap


def dashes_x(mb, y, x0, x1, w=0.005, dash=0.06, gap=0.065):
    x = x0 + gap / 2
    while x + dash <= x1 + 1e-6:
        mark_rect(mb, x, y - w / 2, x + dash, y + w / 2)
        x += dash + gap


def arc_marks(mb, cx, cy, r, a0, a1, w=0.005, dashed=True, n=24):
    for k in range(n):
        if dashed and k % 2:
            continue
        t0, t1 = a0 + (a1 - a0) * k / n, a0 + (a1 - a0) * (k + 1) / n
        p = [(cx + (r - w / 2) * math.cos(t0), cy + (r - w / 2) * math.sin(t0)),
             (cx + (r + w / 2) * math.cos(t0), cy + (r + w / 2) * math.sin(t0)),
             (cx + (r + w / 2) * math.cos(t1), cy + (r + w / 2) * math.sin(t1)),
             (cx + (r - w / 2) * math.cos(t1), cy + (r - w / 2) * math.sin(t1))]
        mb.polyo([(q[0], q[1], ZM) for q in p], "Paint_White", (0, 0, 1))


def zebra(mb, arm):
    """Zebra crossing on an arm ('N','E','S','W') between 0.37 and 0.47 from the centre."""
    n = 11
    w = (2 * HW - 0.04) / (2 * n - 1)
    for k in range(n):
        u0 = -HW + 0.02 + 2 * k * w
        u1 = u0 + w
        if arm == "S":
            mark_rect(mb, u0, -0.47, u1, -0.375)
        elif arm == "N":
            mark_rect(mb, u0, 0.375, u1, 0.47)
        elif arm == "E":
            mark_rect(mb, 0.375, u0, 0.47, u1)
        else:
            mark_rect(mb, -0.47, u0, -0.375, u1)
    # stop line on the inbound (right-hand) lane, on the approach side of the zebra (WS.STOP_LINE)
    s0, s1 = 0.475, 0.495
    if arm == "S":
        mark_rect(mb, 0.0, -s1, HW - 0.02, -s0)
    elif arm == "N":
        mark_rect(mb, -HW + 0.02, s0, 0.0, s1)
    elif arm == "E":
        mark_rect(mb, s0, 0.0, s1, HW - 0.02)
    else:
        mark_rect(mb, -s1, -HW + 0.02, -s0, 0.0)


def details(mb, drains=(), manholes=()):
    for (x, y, rz) in drains:
        mb.push(T(x, y) @ rotz(rz))
        mb.poly([(-0.012, -0.005, ZA + 0.0002), (0.012, -0.005, ZA + 0.0002), (0.012, 0.005, ZA + 0.0002),
                 (-0.012, 0.005, ZA + 0.0002)], "Metal_Dark")
        mb.pop()
    for (x, y) in manholes:
        mb.cyl((x, y, ZA), 0.015, 0.0003, "Metal_Dark", n=12, caps=(False, True), smooth=False)


def street_lamp(c, x, y, rz, idx, h=0.42):
    """Lamp on the sidewalk at (x, y); the arm reaches toward local -x (the road) for rz=0."""
    mb = c.mb
    mb.push(T(x, y, ZS) @ rotz(rz))
    mb.cyl((0, 0, 0), 0.008, 0.012, "Concrete", n=8)
    mb.lathe([(0.0042, 0.0), (0.0026, h)], "Metal_Galv", n=8, c=(0, 0, 0.012))
    beam(mb, (0.0, 0.0, h + 0.006), (-0.07, 0.0, h + 0.016), 0.004, 0.004, "Metal_Galv")
    mb.box((-0.08, 0.0, h + 0.015), (0.04, 0.016, 0.006), "Metal_Dark")
    mb.pop()
    ang = rz
    lx = x + math.cos(ang) * -0.08
    ly = y + math.sin(ang) * -0.08

    def bulb(mb):
        mb.push(rotz(ang))
        mb.box((0, 0, 0), (0.032, 0.012, 0.002), "Lamp_Glow")
        mb.pop()

    part("Bulb_%d" % idx, (lx, ly, ZS + h + 0.0115), bulb)


# ----------------------------------------------------------------------------- tiles

def _straight_sides(mb):
    sidewalk(mb, [(-0.5, -0.5), (-HW, -0.5), (-HW, 0.5), (-0.5, 0.5)], [1])
    sidewalk(mb, [(HW, -0.5), (0.5, -0.5), (0.5, 0.5), (HW, 0.5)], [3])


def road_straight(c, lights=False, seed=0):
    mb = c.mb
    asphalt(mb)
    _straight_sides(mb)
    dashes_y(mb, 0.0, -0.5, 0.5)
    for s in (-1, 1):
        mark_rect(mb, s * (HW - 0.025) - 0.002, -0.5, s * (HW - 0.025) + 0.002, 0.5)
    details(mb, drains=((-HW + 0.012, -0.2, math.pi / 2), (HW - 0.012, 0.25, math.pi / 2)),
            manholes=((0.12, -0.05),))
    if lights:
        street_lamp(c, -HW - 0.04, -0.25, 0.0 + math.pi, 0)
        street_lamp(c, HW + 0.04, 0.25, 0.0, 1)
        # in WS.CURB_FURNITURE, clear of the pedestrian band
        for (x, y) in ((-0.325, 0.2), (0.325, -0.2)):
            mb.cyl((x, y, ZS), 0.0035, 0.025, "Metal_Dark", n=6)


def road_corner(c, seed=0):
    """S + W: quarter-circle carriageway around the SW corner (centre (-0.5,-0.5), radii 0.2..0.8)."""
    mb = c.mb
    asphalt(mb)
    cx, cy = -0.5, -0.5
    inner = [(cx, cy)] + _arc(cx, cy, 0.5 - HW, 0.0, math.pi / 2, 10)
    sidewalk(mb, inner, list(range(1, len(inner) - 1)))
    outer_arc = _arc(cx, cy, 0.5 + HW, math.pi / 2, 0.0, 20)
    pts = outer_arc + [(0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
    sidewalk(mb, pts, list(range(0, len(outer_arc) - 1)))
    arc_marks(mb, cx, cy, 0.5, 0.0, math.pi / 2, n=16)
    for r in (0.5 - HW + 0.025, 0.5 + HW - 0.025):
        arc_marks(mb, cx, cy, r, 0.0, math.pi / 2, w=0.004, dashed=False, n=16)
    details(mb, manholes=((-0.05, -0.05),))


def _corner_fillet(mb, sx, sy, r=0.09):
    """Sidewalk block in the (sx, sy) quadrant corner with a rounded curb (junction tiles)."""
    ex, ey = sx * 0.5, sy * 0.5
    cx, cy = sx * (HW + r), sy * (HW + r)
    a_mid = math.atan2(-sy, -sx)
    arc = _arc(cx, cy, r, a_mid - math.pi / 4 * 1.0 - math.pi / 4, a_mid + math.pi / 2 - math.pi / 4 - math.pi / 4 + math.pi / 2,
               8)
    # arc runs from the point on x = sx*HW to the point on y = sy*HW (or reverse)
    p_x = (sx * HW, cy)
    p_y = (cx, sy * HW)
    a0 = math.atan2(p_x[1] - cy, p_x[0] - cx)
    a1 = math.atan2(p_y[1] - cy, p_y[0] - cx)
    if abs(a1 - a0) > math.pi:
        a1 += 2 * math.pi if a1 < a0 else -2 * math.pi
    arc = _arc(cx, cy, r, a0, a1, 8)
    pts = [(sx * HW, ey)] + arc + [(ex, sy * HW), (ex, ey)]
    curb = list(range(0, len(arc) + 1))
    # ensure CCW
    area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    if area < 0:
        pts = list(reversed(pts))
        n = len(pts)
        curb = [n - 2 - i for i in curb]
    sidewalk(mb, pts, curb)


def road_tee(c, seed=0):
    """E + S + W."""
    mb = c.mb
    asphalt(mb)
    sidewalk(mb, [(-0.5, HW), (0.5, HW), (0.5, 0.5), (-0.5, 0.5)], [0])
    _corner_fillet(mb, -1, -1)
    _corner_fillet(mb, 1, -1)
    for arm in "ESW":
        zebra(mb, arm)
    dashes_x(mb, 0.0, 0.5 - 0.125, 0.5)
    dashes_x(mb, 0.0, -0.5, -0.375)
    dashes_y(mb, 0.0, -0.5, -0.375)
    mark_rect(mb, -0.5, HW - 0.027, 0.5, HW - 0.023)
    details(mb, drains=((-0.2, HW - 0.012, 0.0), (0.2, HW - 0.012, 0.0)), manholes=((0.05, 0.1),))


def road_cross(c, seed=0):
    mb = c.mb
    asphalt(mb)
    for sx in (-1, 1):
        for sy in (-1, 1):
            _corner_fillet(mb, sx, sy)
    for arm in "NESW":
        zebra(mb, arm)
    details(mb, manholes=((0.0, 0.0),))


def road_end(c, seed=0):
    """S only: cul-de-sac with a turning circle."""
    mb = c.mb
    asphalt(mb)
    R = 0.38
    cy = 0.04
    yc = cy - math.sqrt(R * R - HW * HW)
    a0 = math.atan2(yc - cy, HW)
    arc = _arc(0.0, cy, R, a0, math.pi - a0, 28)
    pts = [(-HW, -0.5), (-0.5, -0.5), (-0.5, 0.5), (0.5, 0.5), (0.5, -0.5), (HW, -0.5)] + arc
    # polygon is clockwise as listed; reverse to CCW
    pts = list(reversed(pts))
    n = len(pts)
    # curb edges: along the arc and the two arm edges (everything except the tile border)
    curb = []
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        on_border = (abs(a[0]) > 0.499 and abs(b[0]) > 0.499) or (abs(a[1]) > 0.499 and abs(b[1]) > 0.499)
        if not on_border:
            curb.append(i)
    sidewalk(mb, pts, curb)
    dashes_y(mb, 0.0, -0.5, -0.16)
    mb.cyl((0.0, cy, ZA), 0.11, 0.004, "Curb", n=20)
    mb.cyl((0.0, cy, ZA + 0.004), 0.104, 0.002, "Grass", n=20, caps=(False, True))
    from nature import tree
    tree(mb, c.fol, 0.0, cy, h=0.3, kind="round", seed=seed, z0=ZA + 0.006)
    details(mb, drains=((-HW + 0.012, -0.3, math.pi / 2),))


def road_bridge(c, seed=0):
    """N-S bridge: deck at road level, girders and piers below y = 0 (into the water)."""
    mb = c.mb
    W = 0.44
    mb.poly([(-HW, -0.5, ZA), (HW, -0.5, ZA), (HW, 0.5, ZA), (-HW, 0.5, ZA)], "Asphalt")
    for s in (-1, 1):
        x0, x1 = sorted((s * HW, s * W))
        mb.box2(x0, -0.5, -0.04, x1, 0.5, ZS, "Concrete_Light", mats={"+z": "Sidewalk"}, skip=("-y", "+y"))
        # parapet with railing
        px = s * (W - 0.006)
        mb.box2(px - 0.006, -0.5, ZS, px + 0.006, 0.5, ZS + 0.014, "Concrete_Light", skip=("-y", "+y"))
        mb.box2(px - 0.002, -0.5, ZS + 0.05, px + 0.002, 0.5, ZS + 0.054, "Metal_Galv", skip=("-y", "+y"))
        for k in range(11):
            yy = -0.5 + 0.05 + k * 0.09
            mb.box2(px - 0.0015, yy - 0.0015, ZS + 0.014, px + 0.0015, yy + 0.0015, ZS + 0.05, "Metal_Galv",
                    skip=("-z",))
        mb.box2(s * HW - (0.002 if s > 0 else -0.002) - 0.002, -0.5, ZA, s * HW + 0.002, 0.5, ZS, "Curb",
                skip=("-y", "+y")) if False else None
    # deck slab + edge girders
    mb.box2(-W, -0.5, -0.06, W, 0.5, ZA, "Concrete", skip=("+z", "-y", "+y"))
    for s in (-1, 1):
        mb.box2(s * W - 0.012, -0.5, -0.13, s * W + 0.012 * (1 if s > 0 else -1) * 0 + (0.0 if s > 0 else 0.012) -
                (0.0 if s > 0 else 0.0), 0.5, -0.06, "Metal_Green", skip=("-y", "+y")) if False else None
    for xg in (-0.32, -0.11, 0.11, 0.32):
        mb.box2(xg - 0.015, -0.5, -0.13, xg + 0.015, 0.5, -0.06, "Concrete_Dark", skip=("-y", "+y"))
    # pier at mid-span
    mb.box2(-0.4, -0.04, -0.17, 0.4, 0.04, -0.13, "Concrete")
    for xp in (-0.22, 0.22):
        mb.lathe([(0.04, -0.6), (0.04, -0.17)], "Concrete", n=12, c=(xp, 0.0, 0.0))
    mb.box2(-0.04, -0.06, -0.6, 0.04, 0.06, -0.17, "Concrete") if False else None
    dashes_y(mb, 0.0, -0.5, 0.5)
    for s in (-1, 1):
        mark_rect(mb, s * (HW - 0.025) - 0.002, -0.5, s * (HW - 0.025) + 0.002, 0.5)
    street_lamp(c, -(HW + 0.06), 0.0, math.pi, 0, h=0.4)
    street_lamp(c, HW + 0.06, 0.0, 0.0, 1, h=0.4)


REGISTRY = {
    "roads/road_straight": (road_straight, {}),
    "roads/road_straight_lights": (road_straight, {"lights": True}),
    "roads/road_corner": (road_corner, {}),
    "roads/road_tee": (road_tee, {}),
    "roads/road_cross": (road_cross, {}),
    "roads/road_end": (road_end, {}),
    "roads/road_bridge": (road_bridge, {}),
}
