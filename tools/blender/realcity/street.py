"""Street kit (models/real/street): signals, signs, poster carriers and kerb furniture at real size.

Authored in metres (scaled by S = core.M, 1 unit = 20 m); front faces Godot +Z (Blender -Y), base at
y = 0 (the ramp is modelled in the road tile's height frame: asphalt ZA to sidewalk ZS).

Node contracts (scripts/fp/asset_paths.gd, docs/fp/slices/H-assets.md §3):
  Poster_<n>     own object, one quad, material "Poster", UV 0..1, normal +Z in node space (slice D
                 overrides the material; the default is a baked poster)
  SignFace       sign faces (stop, yield, street-name blades, bus flag) with UV 0..1
  Signal_Red_<n>, Signal_Amber_<n>, Signal_Green_<n>   lens objects, one material each (slice E swaps
                 material_override per state); Walk_<n> / DontWalk_<n> on pedestrian heads
  SignText_A / SignText_B   name-blade anchors (A: blade along X facing +Z; B: blade along Z facing +X)
  Bulb_<n>       billboard luminaire glass (Lamp_Glow)
Small parts use the shared palette atlas (atlas.py, material Car_Atlas) so a prop has at most three
base materials plus the functional ones above."""

import math

from mathutils import Matrix, Vector
from mathutils.geometry import tessellate_polygon

import atlas
import core
import signtex
from core import MB, M, make_empty, rotz
from roads import ZA, ZS

S = M
AX_FRONT = Matrix.Rotation(math.pi / 2, 4, "X")   # lathe axis Z -> -Y (out of a front face)
AX_NEGX = Matrix.Rotation(-math.pi / 2, 4, "Y")   # lathe axis Z -> -X
AX_X = Matrix.Rotation(math.pi / 2, 4, "Y")       # lathe axis Z -> +X

core.MATS.update({
    # traffic-signal lenses: the default is red showing (E overrides every lens per state)
    "Signal_Red": ("flat", (0.32, 0.012, 0.01), 0.1, 0.0, {"emission": (1.0, 0.07, 0.03), "strength": 2.0}),
    "Signal_Amber": ("flat", (0.20, 0.08, 0.004), 0.1, 0.0, {}),
    "Signal_Green": ("flat", (0.006, 0.09, 0.055), 0.1, 0.0, {}),
    "DontWalk": ("flat", (0.55, 0.20, 0.03), 0.3, 0.0, {"emission": (1.0, 0.40, 0.07), "strength": 1.6}),
    "Walk": ("flat", (0.10, 0.11, 0.11), 0.3, 0.0, {}),
    "Pane_Clear": ("flat", (0.62, 0.68, 0.68), 0.03, 0.0, {"alpha": 0.16, "double": True}),
})


def V(x, y, z):
    return (x * S, y * S, z * S)


class Mm:
    """MB front end in metres."""

    def __init__(self, mb):
        self.mb = mb

    def push(self, loc=(0, 0, 0), rz=0.0, m=None):
        self.mb.push(Matrix.Translation(Vector(V(*loc))) @ rotz(rz) @ (m or Matrix.Identity(4)))

    def pop(self):
        self.mb.pop()

    def box(self, x0, y0, z0, x1, y1, z1, mat, skip=(), mats=None):
        self.mb.box2(x0 * S, y0 * S, z0 * S, x1 * S, y1 * S, z1 * S, mat, skip=skip, mats=mats)

    def boxc(self, c, s, mat, rz=0.0, skip=(), mats=None):
        self.mb.box(V(*c), V(*s), mat, rz=rz, skip=skip, mats=mats)

    def cyl(self, c, r, h, mat, n=12, r2=None, caps=(True, True), axis=None, smooth=True):
        self.mb.cyl(V(*c), r * S, h * S, mat, n=n, r2=None if r2 is None else r2 * S, caps=caps, axis=axis,
                    smooth=smooth)

    def lathe(self, prof, mat, n=12, c=(0, 0, 0), axis=None, smooth=True, a0=0.0, a1=2 * math.pi, mats=None,
              cap_top=False, cap_bottom=False):
        self.mb.lathe([(r * S, z * S) for r, z in prof], mat, n=n, c=V(*c), axis=axis, smooth=smooth, a0=a0, a1=a1,
                      mats=mats, cap_top=cap_top, cap_bottom=cap_bottom)

    def poly(self, pts, mat, uvs=None):
        return self.mb.poly([V(*p) for p in pts], mat, uvs=uvs)

    def polyo(self, pts, mat, out, uvs=None):
        return self.mb.polyo([V(*p) for p in pts], mat, out, uvs=uvs)

    def front_poly(self, pts2, y, mat, uvs=None, back=False):
        """Flat polygon in the XZ plane at depth y facing -Y (or +Y with back=True); pts2 = [(x, z)]."""
        pts = [(x, y, z) for x, z in pts2]
        out = (0, 1, 0) if back else (0, -1, 0)
        if len(pts2) > 4 and uvs is None:
            for t in tessellate_polygon([[(x, z, 0.0) for x, z in pts2]]):
                self.polyo([pts[i] for i in t], mat, out)
            return
        self.polyo(pts, mat, out, uvs=uvs)

    def sweep(self, pts, r, mat, n=8, side=(1, 0, 0)):
        """Round tube along a polyline lying in the plane normal to `side`, mitred at the joints."""
        P = [Vector(p) for p in pts]
        N = Vector(side).normalized()
        rings = []
        for k, p in enumerate(P):
            if k == 0:
                t = (P[1] - P[0]).normalized()
                sc = 1.0
            elif k == len(P) - 1:
                t = (P[-1] - P[-2]).normalized()
                sc = 1.0
            else:
                t0, t1 = (P[k] - P[k - 1]).normalized(), (P[k + 1] - P[k]).normalized()
                t = (t0 + t1).normalized()
                sc = 1.0 / max(0.3, t0.dot(t))
            B = t.cross(N).normalized()
            ring = []
            for i in range(n):
                a = 2 * math.pi * i / n
                q = p + (N * math.cos(a) + B * math.sin(a) * sc) * r
                ring.append(self.mb.vert(V(*q)))
            rings.append(ring)
        for k in range(len(rings) - 1):
            for i in range(n):
                j = (i + 1) % n
                f = [rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]]
                # orient outward: the face centre must move away from the path
                c = sum((self.mb.v[v] for v in f), Vector()) / 4
                mid = self.mb.xf @ Vector(V(*((P[k] + P[k + 1]) / 2)))
                e1, e2 = self.mb.v[f[1]] - self.mb.v[f[0]], self.mb.v[f[3]] - self.mb.v[f[0]]
                if e1.cross(e2).dot(c - mid) < 0:
                    f = list(reversed(f))
                self.mb.face(f, mat, True)


def part(name, loc, fn, rz=0.0):
    """Own object (kept out of the <name>_body merge) built by fn(Mm) around its origin at loc (metres)."""
    mb = MB()
    fn(Mm(mb))
    atlas.resolve(mb)
    ob = mb.build(name, uv_offset=(0.0, 0.0))
    ob.location = V(*loc)
    ob.rotation_euler = (0.0, 0.0, rz)
    return ob


def empty(name, loc, rz=0.0, scale=None):
    e = make_empty(name, V(*loc))
    e.rotation_euler = (0.0, 0.0, rz)
    if scale is not None:
        e.scale = scale
    return e


def poster(name, c, w, h, rz=0.0):
    """Poster_<n>: one w x h quad (metres) centred at c, facing local -Y (Godot +Z), UV 0..1."""
    def fn(m):
        m.poly([(-w / 2, 0, -h / 2), (w / 2, 0, -h / 2), (w / 2, 0, h / 2), (-w / 2, 0, h / 2)], "Poster",
               uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
    return part(name, c, fn, rz)


def finish(c):
    atlas.resolve(c.mb)


def pole_base(m, plate=0.42, found=0.28):
    """Concrete foundation, base plate, anchor bolts with nuts."""
    m.cyl((0, 0, 0), found, 0.08, "Concrete", n=14, caps=(False, True))
    m.box(-plate / 2, -plate / 2, 0.08, plate / 2, plate / 2, 0.105, "@Metal_Galv", skip=("-z",))
    for sx in (-1, 1):
        for sy in (-1, 1):
            m.cyl((sx * plate * 0.38, sy * plate * 0.38, 0.105), 0.022, 0.045, "@Metal_Dark", n=6, caps=(False, True),
                  smooth=False)


# ----------------------------------------------------------------------------- signal heads

def signal_head(m, n, loc, scale=1.0, backplate=True):
    """US 3-section head facing -Y centred at loc; lens objects Signal_<Col>_<n>."""
    x, y, z = loc
    k = scale
    hw, hh, hd = 0.18 * k, 0.53 * k, 0.13 * k
    m.box(x - hw, y - hd, z - hh, x + hw, y + hd, z + hh, "@frame_black")
    if backplate:
        bw, bh = 0.31 * k, 0.65 * k
        yb = y + hd
        m.box(x - bw, yb, z - bh, x + bw, yb + 0.025, z + bh, "@frame_black")
        e = 0.05 * k
        for x0, z0, x1, z1 in ((x - bw, z + bh - e, x + bw, z + bh), (x - bw, z - bh, x + bw, z - bh + e),
                               (x - bw, z - bh + e, x - bw + e, z + bh - e), (x + bw - e, z - bh + e, x + bw, z + bh - e)):
            m.front_poly([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], yb - 0.002, "@reflective_yellow")
    yf = y - hd
    for j, col in enumerate(("Red", "Amber", "Green")):
        zc = z + (0.35 - 0.35 * j) * k
        r = 0.15 * k
        # lens door ring and a visor open at the bottom (two-sided)
        m.lathe([(r + 0.025 * k, 0.0), (r + 0.025 * k, 0.012 * k), (r, 0.012 * k)], "@frame_black", n=14,
                c=(x, yf, zc), axis=AX_FRONT, smooth=False)
        L = 0.24 * k
        m.lathe([(r + 0.018 * k, 0.0), (r + 0.018 * k, L)], "@frame_black", n=8, c=(x, yf, zc), axis=AX_FRONT,
                a0=math.radians(-15), a1=math.radians(195), smooth=False)
        m.lathe([(r + 0.012 * k, L), (r + 0.012 * k, 0.0)], "@frame_black", n=8, c=(x, yf, zc), axis=AX_FRONT,
                a0=math.radians(-15), a1=math.radians(195), smooth=False)

        def lens(mm, r=r, k=k):
            mm.lathe([(r, 0.0), (r * 0.75, 0.016 * k), (r * 0.35, 0.026 * k), (0.0, 0.029 * k)], "Signal_" + col,
                     n=16, axis=AX_FRONT, smooth=True)
        part("Signal_%s_%d" % (col, n), (x, yf - 0.002, zc), lens)


def _hand(mm, s):
    """Raised-hand icon in the XZ plane facing -Y, about s x s metres."""
    u = s / 10.0
    mm.front_poly([(-2.2 * u, -4.2 * u), (2.0 * u, -4.2 * u), (2.4 * u, -0.4 * u), (2.2 * u, 0.6 * u),
                   (-2.4 * u, 0.6 * u), (-2.6 * u, -1.8 * u)], 0.0, "DontWalk")
    for fx, top in ((-1.9, 3.6), (-0.65, 4.4), (0.6, 4.2), (1.75, 3.2)):
        mm.front_poly([(fx * u - 0.5 * u, 0.5 * u), (fx * u + 0.5 * u, 0.5 * u), (fx * u + 0.5 * u, top * u),
                       (fx * u - 0.5 * u, top * u)], 0.0, "DontWalk")
    mm.front_poly([(2.2 * u, -1.6 * u), (3.0 * u, -0.6 * u), (4.0 * u, 1.0 * u), (3.4 * u, 1.5 * u), (2.3 * u, 0.4 * u)],
                  0.0, "DontWalk")


def _walker(mm, s):
    """Walking-person icon in the XZ plane facing -Y."""
    u = s / 10.0
    mm.front_poly([(0.3 * u + 0.9 * u * math.cos(a), 3.6 * u + 0.9 * u * math.sin(a))
                   for a in [2 * math.pi * k / 10 for k in range(10)]], 0.0, "Walk")
    mm.front_poly([(-0.6 * u, 2.4 * u), (0.9 * u, 2.4 * u), (1.0 * u, -0.6 * u), (-0.5 * u, -0.6 * u)], 0.0, "Walk")
    for a, b in (((-0.4, -0.4), (-2.2, -4.6)), ((0.7, -0.4), (2.0, -4.6)), ((-0.4, 2.2), (-2.0, 0.0)),
                 ((0.8, 2.2), (2.2, 0.4))):
        dx, dz = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dz)
        nx, nz = -dz / ln * 0.45, dx / ln * 0.45
        mm.front_poly([((a[0] - nx) * u, (a[1] - nz) * u), ((b[0] - nx) * u, (b[1] - nz) * u),
                       ((b[0] + nx) * u, (b[1] + nz) * u), ((a[0] + nx) * u, (a[1] + nz) * u)], 0.0, "Walk")


def ped_head(m, n, loc, rz=0.0):
    """Two-section pedestrian head (hand over walker) facing local -Y, centred at loc, turned rz."""
    m.push(loc, rz)
    m.box(-0.17, -0.1, -0.33, 0.17, 0.1, 0.33, "@frame_black")
    for zc in (0.16, -0.16):
        m.front_poly([(-0.14, zc - 0.14), (0.14, zc - 0.14), (0.14, zc + 0.14), (-0.14, zc + 0.14)], -0.101,
                     "@glass_dark")
        m.box(-0.16, -0.25, zc + 0.14, 0.16, -0.1, zc + 0.155, "@frame_black")
        for sx in (-1, 1):
            m.box(sx * 0.16 - 0.006, -0.25, zc - 0.06, sx * 0.16 + 0.006, -0.1, zc + 0.155, "@frame_black")
    m.pop()
    fx = Matrix.Translation(Vector(V(*loc))) @ rotz(rz)
    for name, zc, fn in (("DontWalk_%d" % n, 0.16, _hand), ("Walk_%d" % n, -0.16, _walker)):
        p = fx @ Vector(V(0, -0.104, zc))
        part(name, (p.x / S, p.y / S, p.z / S), lambda mm, fn=fn: fn(mm, 0.22), rz)


# ----------------------------------------------------------------------------- 1. traffic light

def traffic_light(c):
    """Mast-arm signal pole: 6.4 m pole, 5.5 m arm along -X at 6.0 m, a backplated head over the lane at the
    arm's end and a pole-mounted secondary head (both facing +Z), a pedestrian head facing -X (across the
    crossing), a push button, and the SignText_A / SignText_B anchors E and G1 use for the name blades."""
    m = Mm(c.mb)
    pole_base(m)
    m.lathe([(0.13, 0.105), (0.1, 6.4)], "@Metal_Galv", n=14, smooth=True)
    m.lathe([(0.1, 6.4), (0.06, 6.47), (0.0, 6.49)], "@Metal_Galv", n=14, smooth=True)
    # mast arm with its flange plate and a slight rise toward the tip
    za = 6.0
    m.box(-0.16, -0.16, za - 0.22, -0.1, 0.16, za + 0.22, "@Metal_Galv")
    m.lathe([(0.105, 0.0), (0.06, 5.5)], "@Metal_Galv", n=10, c=(-0.13, 0, za), axis=AX_NEGX, smooth=True)
    m.cyl((-5.63, 0, za), 0.06, 0.004, "@Metal_Galv", n=10, axis=AX_NEGX, caps=(False, True))
    # main head hanging from the arm over the lane
    xh = -5.2
    m.box(xh - 0.05, -0.05, za - 0.19, xh + 0.05, 0.05, za + 0.065, "@frame_black")
    signal_head(m, 0, (xh, -0.02, za - 0.19 - 0.53))
    # secondary head on the pole, on a bracket toward the traffic
    m.box(-0.05, -0.32, 3.35, 0.05, -0.09, 3.45, "@frame_black")
    signal_head(m, 1, (0.0, -0.32 - 0.11, 3.4), scale=0.8, backplate=False)
    # pedestrian head and push button facing -X (people waiting at the far corner)
    m.box(-0.2, -0.04, 2.66, -0.08, 0.04, 2.74, "@frame_black")
    ped_head(m, 0, (-0.3, 0.0, 2.7), rz=-math.pi / 2)
    m.box(-0.19, -0.06, 0.98, -0.1, 0.06, 1.16, "@housing_yellow")
    m.cyl((-0.19, 0, 1.06), 0.03, 0.012, "@Metal_Galv", n=10, axis=AX_NEGX, smooth=False)
    m.box(-0.2, -0.07, 1.18, -0.115, 0.07, 1.36, "@Sign_White")
    # name-blade anchors (same frame as E's procedural pole: A along X facing +Z, B along Z facing +X)
    empty("SignText_A", (-0.05, 0.0, 4.6))
    empty("SignText_B", (-0.05, 0.0, 4.35), rz=math.pi / 2)
    finish(c)


# ----------------------------------------------------------------------------- 2. pedestrian signal

def ped_signal(c):
    """2.6 m post, two-section head (DontWalk_0 over Walk_0) facing +Z, push button with its plate."""
    m = Mm(c.mb)
    m.cyl((0, 0, 0), 0.12, 0.05, "Concrete", n=12, caps=(False, True))
    m.lathe([(0.055, 0.05), (0.045, 2.6)], "@Metal_Galv", n=12, smooth=True)
    m.lathe([(0.045, 2.6), (0.03, 2.63), (0.0, 2.64)], "@Metal_Galv", n=12, smooth=True)
    for zz in (2.08, 2.42):
        m.box(-0.06, -0.12, zz - 0.03, 0.06, 0.0, zz + 0.03, "@frame_black")
    ped_head(m, 0, (0.0, -0.22, 2.25))
    m.box(-0.05, -0.1, 0.98, 0.05, -0.04, 1.16, "@housing_yellow")
    m.cyl((0, -0.1, 1.06), 0.028, 0.012, "@Metal_Galv", n=10, axis=AX_FRONT, smooth=False)
    m.box(-0.07, -0.06, 1.18, 0.07, -0.045, 1.38, "@Sign_White")
    m.front_poly([(-0.035, 1.27), (0.02, 1.27), (0.02, 1.25), (0.045, 1.28), (0.02, 1.31), (0.02, 1.29),
                  (-0.035, 1.29)], -0.0605, "@trim_black")
    finish(c)


# ----------------------------------------------------------------------------- 3. street-name sign

def _blade(name, loc, rz):
    """0.9 x 0.2 m extruded blade: SignFace on both faces (UV 0..1, the back mirrored), rolled edges."""
    L, H, T = 0.9, 0.2, 0.022

    def fn(mm):
        x0, x1, z0, z1 = -L / 2, L / 2, -H / 2, H / 2
        mm.front_poly([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], -T / 2, "SignFace",
                      uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
        mm.polyo([(x1, T / 2, z0), (x0, T / 2, z0), (x0, T / 2, z1), (x1, T / 2, z1)], "SignFace", (0, 1, 0),
                 uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
        mm.box(x0 - 0.004, -T / 2 - 0.001, z1 - 0.0, x1 + 0.004, T / 2 + 0.001, z1 + 0.008, "@Metal_Galv")
        mm.box(x0 - 0.004, -T / 2 - 0.001, z0 - 0.008, x1 + 0.004, T / 2 + 0.001, z0, "@Metal_Galv")
        mm.box(x0 - 0.004, -T / 2, z0, x0, T / 2, z1, "@Metal_Galv", skip=("+z", "-z"))
        mm.box(x1, -T / 2, z0, x1 + 0.004, T / 2, z1, "@Metal_Galv", skip=("+z", "-z"))
    return part(name, loc, fn, rz)


def street_sign(c):
    """3.2 m post, Blade_B (along Z) on the cap bracket and Blade_A (along X) above it, SignText_* at the
    blade centres (A facing +Z, B facing +X)."""
    m = Mm(c.mb)
    signtex.tex_material("SignFace", signtex.blade_face(), rough=0.35)
    m.cyl((0, 0, 0), 0.07, 0.04, "@concrete_light", n=10, caps=(False, True))
    m.lathe([(0.032, 0.04), (0.032, 2.9)], "@Metal_Galv", n=10, smooth=True)
    zb, za = 3.02, 3.25
    # cap bracket: a sleeve on the post, saddles under each blade and a stem between them
    m.cyl((0, 0, 2.86), 0.042, 0.05, "@Metal_Galv", n=10)
    m.box(-0.03, -0.12, 2.91, 0.03, 0.12, zb - 0.1, "@Metal_Galv")
    m.cyl((0, 0, zb + 0.108), 0.022, za - zb - 0.21, "@Metal_Galv", n=8, caps=(False, False))
    m.box(-0.12, -0.03, za - 0.118, 0.12, 0.03, za - 0.108, "@Metal_Galv")
    _blade("Blade_A", (0, 0, za), 0.0)
    _blade("Blade_B", (0, 0, zb), math.pi / 2)
    empty("SignText_A", (0, 0, za))
    empty("SignText_B", (0, 0, zb), rz=math.pi / 2)
    finish(c)


# ----------------------------------------------------------------------------- 4. stop and yield

def _sign_post(m, top=2.4):
    m.cyl((0, 0, 0), 0.06, 0.03, "@concrete_light", n=10, caps=(False, True))
    m.box(-0.026, -0.026, 0.0, 0.026, 0.026, top, "@Metal_Galv", skip=("-z",))
    # the post is punched (telespar): a dotted line of holes on the front face
    for k in range(int((top - 0.3) / 0.075)):
        zz = 0.2 + k * 0.075
        m.front_poly([(-0.007, zz), (0.007, zz), (0.007, zz + 0.014), (-0.007, zz + 0.014)], -0.0262, "@trim_black")


def _plate(m, pts_uv, size, zc, y=-0.03, T=0.004):
    """Sign plate in front of the post: SignFace front (UV from the bounding square), aluminium back and
    edge, two clamp brackets."""
    pts = [((u - 0.5) * size, zc + (v - 0.5) * size) for u, v in pts_uv]
    yf = y - T / 2
    for t in tessellate_polygon([[(x, z, 0.0) for x, z in pts]]):
        m.polyo([(pts[i][0], yf, pts[i][1]) for i in t], "SignFace", (0, -1, 0), uvs=[pts_uv[i] for i in t])
    m.front_poly(pts, y + T / 2, "@Metal_Galv", back=True)
    n = len(pts)
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        # outward normal of a CCW edge in the (x, z) plane
        m.polyo([(a[0], yf, a[1]), (b[0], yf, b[1]), (b[0], y + T / 2, b[1]), (a[0], y + T / 2, a[1])], "@Metal_Galv",
                (b[1] - a[1], 0, -(b[0] - a[0])))
    for dz in (-0.2, 0.2):
        m.box(-0.045, y + T / 2, zc + dz - 0.02, 0.045, 0.03, zc + dz + 0.02, "@Metal_Galv")


def stop_sign(c):
    """2.4 m punched post, 0.75 m octagon (flat top) centred 2.15 m up, SignFace with STOP."""
    m = Mm(c.mb)
    signtex.tex_material("SignFace", signtex.stop_face(), rough=0.35)
    _sign_post(m)
    size = 0.75
    pts = []
    rc = 0.5 / math.cos(math.pi / 8)
    for k in range(8):
        a = math.pi / 8 + k * math.pi / 4
        pts.append((0.5 + rc * math.cos(a), 0.5 + rc * math.sin(a)))
    _plate(m, pts, size, 2.15)
    finish(c)


def yield_sign(c):
    """2.4 m punched post, 0.9 m point-down triangle centred 2.15 m up, SignFace with YIELD."""
    m = Mm(c.mb)
    signtex.tex_material("SignFace", signtex.yield_face(), rough=0.35)
    _sign_post(m)
    top, bot = 22 / 256.0, 243 / 256.0
    hw = (bot - top) / math.sqrt(3)
    # the texture's triangle (signtex.yield_face) in UV, counter-clockwise from the bottom point
    pts = [(0.5, 1 - bot), (0.5 + hw, 1 - top), (0.5 - hw, 1 - top)]
    _plate(m, pts, 0.9 * 256 / 255.2, 2.15)
    finish(c)


# ----------------------------------------------------------------------------- 5. bus shelter

def bus_shelter(c):
    """4.0 x 1.5 x 2.5 m glass shelter open to +Z: cantilevered roof with a downlight and a bus flag, glass
    back and +X side with a manifestation band, a double-sided lightbox at -X (Poster_0 facing -X toward
    people walking up, Poster_1 facing into the shelter), a slatted bench."""
    m = Mm(c.mb)
    signtex.tex_material("Poster", signtex.poster_portrait("poster_shelter", (0.95, 0.55, 0.10)), rough=0.3)
    signtex.tex_material("SignFace", signtex.bus_flag(), rough=0.35)
    W, D, H = 3.96, 1.5, 2.5
    yb = D / 2          # back wall plane (Blender +Y)
    m.box(-W / 2, -D / 2, 0.0, W / 2, D / 2, 0.03, "Concrete", skip=("-z",))
    # back posts and roof
    for x in (-W / 2 + 0.2, 0.0, W / 2 - 0.05):
        m.box(x - 0.04, yb - 0.1, 0.03, x + 0.04, yb - 0.02, H - 0.14, "@Metal_Dark", skip=("-z",))
    m.box(-W / 2, -D / 2, H - 0.14, W / 2, D / 2, H - 0.02, "@Metal_Dark",
          mats={"-z": "@Metal_White", "-y": "@Metal_Dark"})
    m.box(-W / 2 - 0.0, -D / 2 - 0.0, H - 0.02, W / 2, D / 2, H, "@Metal_Galv", skip=("-z",))
    m.polyo([(-1.2, -0.1, H - 0.141), (1.2, -0.1, H - 0.141), (1.2, 0.02, H - 0.141), (-1.2, 0.02, H - 0.141)],
            "Lamp_Glow", (0, 0, -1))
    # bus-stop flag hanging under the roof at the +X front corner, across the sidewalk (both faces)
    fx, fy0, fy1, fz0, fz1 = 1.62, -0.7, -0.2, 2.06, 2.31
    m.polyo([(fx - 0.006, fy1, fz0), (fx - 0.006, fy0, fz0), (fx - 0.006, fy0, fz1), (fx - 0.006, fy1, fz1)],
            "SignFace", (-1, 0, 0), uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
    m.polyo([(fx + 0.006, fy0, fz0), (fx + 0.006, fy1, fz0), (fx + 0.006, fy1, fz1), (fx + 0.006, fy0, fz1)],
            "SignFace", (1, 0, 0), uvs=[(0, 0), (1, 0), (1, 1), (0, 1)])
    m.box(fx - 0.006, fy0 - 0.01, fz0 - 0.01, fx + 0.006, fy1 + 0.01, fz0, "@Metal_Galv")
    m.box(fx - 0.006, fy0 - 0.01, fz1, fx + 0.006, fy1 + 0.01, fz1 + 0.01, "@Metal_Galv")
    for yy in (fy0 + 0.05, fy1 - 0.05):
        m.box(fx - 0.01, yy - 0.01, fz1 + 0.01, fx + 0.01, yy + 0.01, H - 0.14, "@Metal_Galv")
    # glass: back wall (three bays) and the +X side, framed, with a frosted manifestation band
    gz0, gz1 = 0.18, H - 0.16
    bays = [(-W / 2 + 0.24, -0.04), (0.04, W / 2 - 0.09)]
    for x0, x1 in bays:
        m.polyo([(x0, yb - 0.06, gz0), (x1, yb - 0.06, gz0), (x1, yb - 0.06, gz1), (x0, yb - 0.06, gz1)], "Pane_Clear",
                (0, 1, 0))
        m.box(x0, yb - 0.08, gz0 - 0.04, x1, yb - 0.04, gz0, "@Metal_Dark")
        m.box(x0, yb - 0.065, 1.38, x1, yb - 0.055, 1.46, "@Sign_White")
        m.box(x0, yb - 0.065, 0.92, x1, yb - 0.055, 0.95, "@Sign_White")
    xs = W / 2 - 0.05
    m.polyo([(xs, -D / 2 + 0.15, gz0), (xs, yb - 0.1, gz0), (xs, yb - 0.1, gz1), (xs, -D / 2 + 0.15, gz1)],
            "Pane_Clear", (1, 0, 0))
    m.box(xs - 0.04, -D / 2 + 0.1, 0.03, xs + 0.04, -D / 2 + 0.18, H - 0.14, "@Metal_Dark", skip=("-z",))
    m.box(xs - 0.005, -D / 2 + 0.18, 1.38, xs + 0.005, yb - 0.1, 1.46, "@Sign_White")
    # lightbox at -X: frame, glowing reveal and two poster faces (1.26 x 2.12 m portrait)
    lx0, lx1 = -W / 2, -W / 2 + 0.18
    ly0, ly1 = -D / 2 + 0.06, yb - 0.04
    m.box(lx0, ly0, 0.03, lx1, ly1, H - 0.14, "@Metal_Dark", skip=("-z", "+z"),
          mats={"-x": "@Metal_Dark", "+x": "@Metal_Dark"})
    pw, ph = 1.26, 2.12
    pyc, pzc = (ly0 + ly1) / 2, 0.2 + ph / 2
    for sx in (-1, 1):
        xf = (lx0 - 0.001) if sx < 0 else (lx1 + 0.001)
        m.polyo([(xf, pyc - pw / 2 - 0.02, pzc - ph / 2 - 0.02), (xf, pyc + pw / 2 + 0.02, pzc - ph / 2 - 0.02),
                 (xf, pyc + pw / 2 + 0.02, pzc + ph / 2 + 0.02), (xf, pyc - pw / 2 - 0.02, pzc + ph / 2 + 0.02)],
                "Lamp_Glow", (sx, 0, 0))
        # frame lips round the glowing reveal
        xl = xf + sx * 0.012
        for y0, z0, y1, z1 in ((ly0, pzc + ph / 2 + 0.02, ly1, pzc + ph / 2 + 0.09),
                               (ly0, 0.06, ly1, pzc - ph / 2 - 0.02),
                               (ly0, pzc - ph / 2 - 0.02, pyc - pw / 2 - 0.02, pzc + ph / 2 + 0.02),
                               (pyc + pw / 2 + 0.02, pzc - ph / 2 - 0.02, ly1, pzc + ph / 2 + 0.02)):
            m.box(min(xf, xl), y0, z0, max(xf, xl), y1, z1, "@Metal_Dark")
    poster("Poster_0", (lx0 - 0.004, pyc, pzc), pw, ph, rz=-math.pi / 2)
    poster("Poster_1", (lx1 + 0.004, pyc, pzc), pw, ph, rz=math.pi / 2)
    # bench: slats on two cantilever brackets off the back posts
    bx0, bx1 = -1.2, 1.3
    for x in (-0.95, 1.05):
        m.box(x - 0.03, yb - 0.4, 0.05, x + 0.03, yb - 0.3, 0.42, "@Metal_Dark", skip=("-z",))
        m.box(x - 0.08, yb - 0.5, 0.03, x + 0.08, yb - 0.2, 0.05, "@Metal_Dark", skip=("-z",))
        m.box(x - 0.025, yb - 0.5, 0.385, x + 0.025, yb - 0.1, 0.42, "@Metal_Dark")
    for k in range(4):
        y0 = yb - 0.5 + k * 0.105
        m.box(bx0, y0, 0.42, bx1, y0 + 0.085, 0.455, "@wood_slat")
    # timetable case on the inner face of the middle post
    m.box(-0.3, yb - 0.12, 1.1, 0.3, yb - 0.1, 1.75, "@Metal_Dark")
    m.front_poly([(-0.27, 1.13), (0.27, 1.13), (0.27, 1.72), (-0.27, 1.72)], yb - 0.121, "@Sign_White")
    finish(c)


# ----------------------------------------------------------------------------- 6. billboard

def billboard(c):
    """props/billboard's silhouette: two I-beam legs at x = +-2 m on footings, braced; a 6.8 x 3.0 m
    Poster_0 on the +Z face centred 5.5 m up in a frame with a ribbed back; a catwalk with a rail; two
    downlights Bulb_0 / Bulb_1 on arms above the face."""
    m = Mm(c.mb)
    signtex.tex_material("Poster", signtex.poster_billboard(), rough=0.8)
    W, Hp, z0 = 6.8, 3.0, 4.0
    ly = 0.3            # leg centre line, behind the frame
    for x in (-2.0, 2.0):
        m.box(x - 0.36, ly - 0.36, 0.0, x + 0.36, ly + 0.36, 0.3, "Concrete", skip=("-z",))
        # I-beam: two flanges and a web, up to the top of the frame
        for dy in (-0.14, 0.14):
            m.box(x - 0.12, ly + dy - 0.012, 0.3, x + 0.12, ly + dy + 0.012, z0 + Hp + 0.12, "@Metal_Galv",
                  skip=("-z",))
        m.box(x - 0.008, ly - 0.128, 0.3, x + 0.008, ly + 0.128, z0 + Hp + 0.12, "@Metal_Galv", skip=("-z",))
        m.box(x - 0.2, ly - 0.2, 0.3, x + 0.2, ly + 0.2, 0.33, "@Metal_Galv", skip=("-z",))
    # X-brace between the legs, in the web plane
    for a, b in (((-1.9, 0.6), (1.9, 3.5)), ((1.9, 0.6), (-1.9, 3.5))):
        dx, dz = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dz)
        m.push(((a[0] + b[0]) / 2, ly, (a[1] + b[1]) / 2), 0.0, Matrix.Rotation(math.atan2(-dz, dx), 4, "Y"))
        m.box(-ln / 2, -0.02, -0.04, ln / 2, 0.02, 0.04, "@Metal_Galv")
        m.pop()
    m.box(-2.0, ly - 0.04, 3.5, 2.0, ly + 0.04, 3.6, "@Metal_Galv")
    # frame and ribbed back (the back is what the far side sees)
    fy0, fy1 = -0.12, 0.1
    zb, zt = z0 - 0.12, z0 + Hp + 0.12
    m.box(-W / 2 - 0.12, fy0, zt - 0.12, W / 2 + 0.12, fy1, zt, "@Metal_Dark")
    m.box(-W / 2 - 0.12, fy0, zb, W / 2 + 0.12, fy1, zb + 0.12, "@Metal_Dark")
    m.box(-W / 2 - 0.12, fy0, zb + 0.12, -W / 2, fy1, zt - 0.12, "@Metal_Dark")
    m.box(W / 2, fy0, zb + 0.12, W / 2 + 0.12, fy1, zt - 0.12, "@Metal_Dark")
    m.polyo([(-W / 2, fy1 - 0.02, zb + 0.12), (W / 2, fy1 - 0.02, zb + 0.12), (W / 2, fy1 - 0.02, zt - 0.12),
             (-W / 2, fy1 - 0.02, zt - 0.12)], "@Metal_Dark", (0, 1, 0))
    for zz in (z0 + 0.6, z0 + 1.5, z0 + 2.4):
        m.box(-W / 2, fy1 - 0.02, zz - 0.05, W / 2, fy1 + 0.08, zz + 0.05, "@Metal_Galv")
    for xx in (-2.0, 2.0):
        m.box(xx - 0.06, fy1 - 0.02, zb + 0.12, xx + 0.06, fy1 + 0.1, zt - 0.12, "@Metal_Galv")
    # face recess behind the poster
    m.polyo([(-W / 2, fy0 + 0.04, z0), (W / 2, fy0 + 0.04, z0), (W / 2, fy0 + 0.04, z0 + Hp),
             (-W / 2, fy0 + 0.04, z0 + Hp)], "@Metal_Dark", (0, -1, 0))
    poster("Poster_0", (0.0, fy0 + 0.03, z0 + Hp / 2), W, Hp)
    # catwalk: grating, toe board, a rail on posts
    cy0, cy1 = -0.75, fy0
    zc = zb - 0.06
    m.box(-W / 2, cy0, zc - 0.05, W / 2, cy1, zc, "Grating")
    for x in (-2.0, 2.0):
        m.box(x - 0.04, cy0, zc - 0.17, x + 0.04, ly - 0.14, zc - 0.05, "@Metal_Galv")
    m.box(-W / 2, cy0 - 0.005, zc, W / 2, cy0 + 0.005, zc + 0.1, "@Metal_Galv")
    for k in range(5):
        x = -W / 2 + 0.05 + k * (W - 0.1) / 4
        m.cyl((x, cy0 + 0.02, zc), 0.02, 1.05, "@Metal_Galv", n=6, caps=(False, True), smooth=False)
    m.lathe([(0.022, 0.0), (0.022, W)], "@Metal_Galv", n=6, c=(-W / 2, cy0 + 0.02, zc + 1.05), axis=AX_X,
            smooth=True)
    m.lathe([(0.016, 0.0), (0.016, W)], "@Metal_Galv", n=6, c=(-W / 2, cy0 + 0.02, zc + 0.55), axis=AX_X,
            smooth=True)
    # ladder on the right leg
    for sx in (-0.2, 0.2):
        m.box(2.0 + sx - 0.02, -0.5, 0.33, 2.0 + sx + 0.02, -0.46, zc, "@Metal_Galv")
    for k in range(int((zc - 0.6) / 0.3)):
        zz = 0.6 + k * 0.3
        m.cyl((1.8, -0.48, zz), 0.014, 0.4, "@Metal_Galv", n=5, axis=AX_X, caps=(False, False), smooth=False)
    for zz in (1.2, 3.0):
        for sx in (-0.2, 0.2):
            m.box(2.0 + sx - 0.015, -0.46, zz, 2.0 + sx + 0.015, ly - 0.14, zz + 0.04, "@Metal_Galv")
    # downlights on arms over the face
    for i, x in enumerate((-1.8, 1.8)):
        m.box(x - 0.04, fy0, zt - 0.04, x + 0.04, fy0 + 0.08, zt + 0.25, "@Metal_Dark")
        m.push((x, 0, zt + 0.21))
        m.box(-0.03, -1.0, -0.03, 0.03, fy0, 0.03, "@Metal_Dark")
        m.pop()
        m.box(x - 0.3, -1.12, zt + 0.12, x + 0.3, -0.88, zt + 0.24, "@Metal_Dark")

        def glass(mm):
            mm.box(-0.26, -0.1, -0.012, 0.26, 0.1, 0.0, "Lamp_Glow")
        part("Bulb_%d" % i, (x, -1.0, zt + 0.12), glass)
    finish(c)


# ----------------------------------------------------------------------------- 7. poster frame

def poster_frame(c):
    """Wall-mounted snap frame, 4 cm deep, back plane at Godot z = 0, bottom at y = 0; Poster_0 1.2 x 1.8 m."""
    m = Mm(c.mb)
    signtex.tex_material("Poster", signtex.poster_portrait(), rough=0.35)
    pw, ph, f = 1.2, 1.8, 0.035
    w, h = pw + 2 * f, ph + 2 * f
    m.box(-w / 2, -0.012, 0.0, w / 2, 0.0, h, "@Metal_Dark", skip=("+y",))
    for x0, z0, x1, z1 in ((-w / 2, h - f, w / 2, h), (-w / 2, 0.0, w / 2, f), (-w / 2, f, -w / 2 + f, h - f),
                           (w / 2 - f, f, w / 2, h - f)):
        m.box(x0, -0.04, z0, x1, -0.012, z1, "@Metal_Galv", skip=("+y",))
        m.box(x0 + 0.006, -0.0405, z0 + 0.006, x1 - 0.006, -0.04, z1 - 0.006, "@Chrome", skip=("+y",))
    poster("Poster_0", (0.0, -0.03, h / 2), pw, ph)
    finish(c)


# ----------------------------------------------------------------------------- 8. hoarding

def hoarding(c):
    """6.0 x 2.4 m painted plywood hoarding with Poster_0 and Poster_1 (2.9 x 2.2 m) on the +Z face, a timber
    frame, raking braces and concrete ballast feet behind."""
    m = Mm(c.mb)
    signtex.tex_material("Poster", signtex.poster_hoarding(), rough=0.8)
    W, H, T = 6.0, 2.4, 0.02
    m.box(-W / 2, 0.0, 0.0, W / 2, T, H, "@hoarding_paint", mats={"+y": "@plywood"}, skip=("-z",))
    m.box(-W / 2 - 0.01, -0.01, H, W / 2 + 0.01, T + 0.01, H + 0.04, "@Sign_White")
    for k in range(4):
        x = -W / 2 + 0.05 + k * (W - 0.1) / 3
        m.box(x - 0.05, T, 0.0, x + 0.05, T + 0.1, H - 0.05, "@timber", skip=("-z",))
        # raking brace to a ballast block
        m.push((x, 0, 0))
        a, b = Vector((0.0, T + 0.1, 1.8)), Vector((0.0, 1.05, 0.25))
        d = b - a
        ln = d.length
        m.push(((a + b) / 2), 0.0, Matrix.Rotation(math.atan2(-d.y, d.z), 4, "X"))
        m.box(-0.035, -0.045, -ln / 2, 0.035, 0.045, ln / 2, "@timber")
        m.pop()
        m.box(-0.3, 0.75, 0.0, 0.3, 1.25, 0.22, "Concrete", skip=("-z",))
        m.pop()
    for zz in (0.35, H - 0.4):
        m.box(-W / 2, T + 0.1, zz - 0.045, W / 2, T + 0.17, zz + 0.045, "@timber")
    # hazard skirting along the foot of the face
    for k in range(20):
        x = -W / 2 + k * W / 20
        m.front_poly([(x, 0.0), (x + W / 20, 0.0), (x + W / 20, 0.08), (x, 0.08)], -0.003,
                     "@stripe_red" if k % 2 else "@stripe_white")
    pw, ph = 2.9, 2.2
    for i, x in enumerate((-W / 4 + 0.01, W / 4 - 0.01)):
        poster("Poster_%d" % i, (x, -0.004, 0.1 + ph / 2), pw, ph)
    finish(c)


# ----------------------------------------------------------------------------- 9. curb ramp

def curb_ramp(c):
    """Kerb ramp in the gutter at a zebra (local +Z away from the road, origin on the curb line at road
    level): a 1.9 m wide ramp (the zebra's 0.375-0.47 band) rising from the asphalt (ZA) 1.2 m out in the
    road to the sidewalk top (ZS) at the curb, flared sides, a tactile warning pad on its lower half."""
    m = Mm(c.mb)
    path = _tactile_tex()
    signtex.tex_material("Tactile", path, rough=0.7)
    _tactile_repeat()
    za, zs = ZA / S, ZS / S        # metres
    L, w, fl = 1.2, 1.9 / 2, 0.45
    y0, y1 = 0.0, L                # Blender +Y is Godot -Z: the road side
    lift = 0.003

    def zr(y):                     # ramp surface height at distance y from the curb line
        return zs + (za - zs) * (y / L) + lift * (1 - y / L)
    ym = L * 0.5
    # surface: upper half concrete, lower half tactile pad (tiled 0.3 m)
    m.polyo([(-w, y0, zr(y0)), (w, y0, zr(y0)), (w, ym, zr(ym)), (-w, ym, zr(ym))], "Sidewalk", (0, 0, 1))
    uv = lambda x, y: ((x + w) / 0.3, y / 0.3)  # noqa: E731
    pts = [(-w + 0.05, ym, zr(ym) + 0.002), (w - 0.05, ym, zr(ym) + 0.002), (w - 0.05, y1 - 0.03, zr(y1 - 0.03) + 0.002),
           (-w + 0.05, y1 - 0.03, zr(y1 - 0.03) + 0.002)]
    m.polyo(pts, "Tactile", (0, 0, 1), uvs=[uv(p[0], p[1]) for p in pts])
    m.polyo([(-w, ym, zr(ym)), (w, ym, zr(ym)), (w, y1, zr(y1)), (-w, y1, zr(y1))], "Sidewalk", (0, 0, 1))
    for sx in (-1, 1):
        # flared side: a sloped triangle from the curb top to the gutter
        m.polyo([(sx * w, y0, zr(y0)), (sx * (w + fl), y0, zs + lift), (sx * w, y1, zr(y1))], "Curb", (0, 0, 1))
        m.polyo([(sx * (w + fl), y0, za), (sx * (w + fl), y0, zs + lift), (sx * w, y1, za)], "Curb", (sx, 1, 0))
    finish(c)


def _tactile_tex():
    """Truncated-dome warning tile (one 0.3 m repeat, 5 x 5 domes) in safety yellow."""
    cv = signtex.Canvas(96, 96, (0.62, 0.42, 0.03))
    for i in range(5):
        for j in range(5):
            cx, cy = 9.6 + i * 19.2, 9.6 + j * 19.2
            cv.circle(cx + 1.2, cy + 1.6, 6.4, (0.32, 0.2, 0.01), n=18)
            cv.circle(cx, cy, 6.0, (0.78, 0.56, 0.06), n=18)
            cv.circle(cx - 1.4, cy - 1.6, 2.4, (0.92, 0.74, 0.22), n=12)
    return cv.save("tactile_tile")


def _tactile_repeat():
    m = core._mat_cache.get("Tactile")
    if m is None:
        return
    for nd in m.node_tree.nodes:
        if nd.type == "TEX_IMAGE":
            nd.extension = "REPEAT"


# ----------------------------------------------------------------------------- 10. bike rack, meter

def bike_rack(c):
    """Three galvanised Sheffield hoops (0.85 m tall, 0.75 m wide, across Z), 0.9 m apart along X."""
    m = Mm(c.mb)
    hw, top, rr = 0.375, 0.85, 0.15
    path = [(0, -hw, 0.0), (0, -hw, top - rr)]
    for k in range(1, 4):
        a = math.pi - k * math.pi / 2 / 4
        path.append((0, -hw + rr + rr * math.cos(a), top - rr + rr * math.sin(a)))
    path.append((0, -hw + rr, top))
    path.append((0, hw - rr, top))
    for k in range(1, 4):
        a = math.pi / 2 - k * math.pi / 2 / 4
        path.append((0, hw - rr + rr * math.cos(a), top - rr + rr * math.sin(a)))
    path += [(0, hw, top - rr), (0, hw, 0.0)]
    for x in (-0.9, 0.0, 0.9):
        m.sweep([(x + p[0], p[1], p[2]) for p in path], 0.025, "@Metal_Galv", n=8)
        for sy in (-1, 1):
            m.cyl((x, sy * hw, 0.0), 0.06, 0.012, "@Metal_Galv", n=8, smooth=False, caps=(False, True))
    finish(c)


def parking_meter(c):
    """Single-space smart meter: tapered post, dark housing with a rounded steel top, lit display, keypad,
    coin and card slots, a blue P plate (SignFace)."""
    m = Mm(c.mb)
    signtex.tex_material("SignFace", _meter_face(), rough=0.35)
    m.cyl((0, 0, 0), 0.09, 0.03, "@concrete_light", n=10, caps=(False, True))
    m.lathe([(0.045, 0.03), (0.038, 1.02)], "@Metal_Dark", n=10, smooth=True)
    m.cyl((0, 0, 1.0), 0.06, 0.05, "@Metal_Dark", n=10)
    hw, hd, z0, z1 = 0.115, 0.085, 1.05, 1.38
    m.box(-hw, -hd, z0, hw, hd, z1, "@frame_black")
    # rounded top: the upper half of a cylinder along X (lathe angles 90..270 deg are z >= 0 after AX_X)
    m.lathe([(hd, 0.0), (hd, 2 * hw)], "@Metal_Galv", n=10, c=(-hw, 0, z1), axis=AX_X, a0=math.pi / 2,
            a1=3 * math.pi / 2, smooth=True)
    m.polyo([(-hw, -hd, z1)] + [(-hw, -hd * math.cos(a), z1 + hd * math.sin(a)) for a in
                                [math.pi * k / 10 for k in range(1, 10)]] + [(-hw, hd, z1)], "@Metal_Galv", (-1, 0, 0))
    m.polyo([(hw, -hd, z1)] + [(hw, -hd * math.cos(a), z1 + hd * math.sin(a)) for a in
                               [math.pi * k / 10 for k in range(1, 10)]] + [(hw, hd, z1)], "@Metal_Galv", (1, 0, 0))
    yf = -hd - 0.001
    m.front_poly([(-0.085, 1.27), (0.085, 1.27), (0.085, 1.355), (-0.085, 1.355)], yf, "@meter_screen")
    m.box(-0.09, yf - 0.012, 1.26, 0.09, yf, 1.265, "@trim_black")
    for i in range(3):
        for j in range(2):
            x, z = -0.045 + i * 0.045, 1.2 - j * 0.04
            m.box(x - 0.015, yf - 0.01, z - 0.012, x + 0.015, yf, z + 0.012, "@Metal_Galv")
    m.box(0.055, yf - 0.008, 1.115, 0.095, yf, 1.13, "@trim_black")
    m.box(-0.095, yf - 0.008, 1.115, -0.035, yf, 1.125, "@trim_black")
    m.polyo([(-0.05, hd + 0.001, 1.15), (0.05, hd + 0.001, 1.15), (0.05, hd + 0.001, 1.25), (-0.05, hd + 0.001, 1.25)],
            "SignFace", (0, 1, 0), uvs=[(1, 0), (0, 0), (0, 1), (1, 1)])
    finish(c)


def _meter_face():
    cv = signtex.Canvas(128, 128, signtex.BLUE)
    cv.rect(5, 5, 123, 123, signtex.WHITE, r=10)
    cv.rect(10, 10, 118, 118, signtex.BLUE, r=8)
    cv.text("P", 64, 66, 70, signtex.WHITE, bold=0.06)
    return cv.save("meter_face")


# ----------------------------------------------------------------------------- 11. lease sign

def lease_sign(c):
    """1.8 x 1.2 m board (Poster_0 on the +Z face, default FOR LEASE) bolted to two 4 x 4 posts."""
    m = Mm(c.mb)
    signtex.tex_material("Poster", signtex.poster_lease(), rough=0.5)
    bw, bh, zb = 1.8, 1.2, 1.0
    for x in (-0.65, 0.65):
        m.box(x - 0.045, 0.012, 0.0, x + 0.045, 0.102, zb + bh + 0.1, "@timber", skip=("-z",))
        m.box(x - 0.045, 0.012, zb + bh + 0.1, x + 0.045, 0.102, zb + bh + 0.11, "@timber")
    m.box(-bw / 2, -0.008, zb, bw / 2, 0.012, zb + bh, "@Sign_White", skip=("-y",))
    m.front_poly([(-bw / 2, zb), (bw / 2, zb), (bw / 2, zb + bh), (-bw / 2, zb + bh)], -0.008, "@Sign_White")
    for x in (-0.65, 0.65):
        for z in (zb + 0.15, zb + bh - 0.15):
            m.cyl((x, -0.009, z), 0.012, 0.004, "@Metal_Galv", n=6, axis=AX_FRONT, caps=(False, True), smooth=False)
    poster("Poster_0", (0.0, -0.0095, zb + bh / 2), bw - 0.02, bh - 0.02)
    finish(c)


REGISTRY = {
    "street/traffic_light": (traffic_light, {}),
    "street/ped_signal": (ped_signal, {}),
    "street/street_sign": (street_sign, {}),
    "street/stop_sign": (stop_sign, {}),
    "street/yield_sign": (yield_sign, {}),
    "street/bus_shelter": (bus_shelter, {}),
    "street/billboard": (billboard, {}),
    "street/poster_frame": (poster_frame, {}),
    "street/hoarding": (hoarding, {}),
    "street/curb_ramp": (curb_ramp, {}),
    "street/bike_rack": (bike_rack, {}),
    "street/parking_meter": (parking_meter, {}),
    "street/lease_sign": (lease_sign, {}),
}
