"""Industrial kit: sheds, sawtooth roofs, dock doors, stacks, tanks, columns, pipes, galleries,
containers and trucks. Shared by industrial zones and utility service buildings."""

import math

from mathutils import Matrix, Vector

import core
from core import make_empty, rotz
from arch import SIDES, flat_roof, gable_roof

core.MATS.update({
    "Container_Blue": ("tex", "corrugated_iron", 1.2, (0.24, 0.38, 0.66)),
    "Container_Red": ("tex", "corrugated_iron", 1.2, (0.66, 0.17, 0.11)),
    "Container_Orange": ("tex", "corrugated_iron", 1.2, (0.88, 0.45, 0.14)),
    "Container_White": ("tex", "corrugated_iron", 1.2, (0.96, 0.96, 0.93)),
    "Container_Green": ("tex", "container_side", 2.5, (1, 1, 1)),
    "Container_Grey": ("tex", "corrugated_iron", 1.2, (0.55, 0.57, 0.58)),
    "Steel_White": ("flat", (0.72, 0.73, 0.72), 0.4, 0.35, {}),
    "Stack_Red": ("flat", (0.55, 0.07, 0.05), 0.5, 0.1, {}),
    "Stack_White": ("flat", (0.82, 0.82, 0.8), 0.5, 0.1, {}),
    "Soot": ("flat", (0.025, 0.024, 0.023), 0.95, 0.0, {}),
    "Grating": ("tex", "metal_plate", 1.0, (0.6, 0.6, 0.6)),
})
core.LITE.update({"Container_Green", "Grating"})


def T(x, y, z=0.0):
    return Matrix.Translation(Vector((x, y, z)))


def tube(mb, a, b, r, mat, n=8, smooth=True):
    a, b = Vector(a), Vector(b)
    d = b - a
    if d.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    mb.lathe([(r, 0.0), (r, d.length)], mat, n=n, c=tuple(a), axis=rot, smooth=smooth)


def pipe(mb, pts, r, mat, n=8):
    for a, b in zip(pts[:-1], pts[1:]):
        tube(mb, a, b, r, mat, n=n)
    for p in pts[1:-1]:
        mb.sphere(p, r * 1.05, mat, n=n, rings=4)


def beam(mb, a, b, w, h, mat):
    """Box from 3D point a to b with cross-section w x h."""
    a, b = Vector(a), Vector(b)
    d = b - a
    L = d.length
    yaw = math.atan2(d.y, d.x)
    pitch = math.atan2(d.z, math.hypot(d.x, d.y))
    mb.push(Matrix.Translation((a + b) / 2) @ rotz(yaw) @ Matrix.Rotation(-pitch, 4, "Y"))
    mb.box((0, 0, 0), (L, w, h), mat)
    mb.pop()


# ----------------------------------------------------------------------------- walls / sheds

def strip_window(c, u0, u1, za, zb, frame="Frame_Alu", pane=0.035, glass="Glass", lit=0.3, out=0.0022):
    mb = c.mb
    mb.box2(u0 - 0.002, -out, za - 0.002, u1 + 0.002, 0.0, zb + 0.002, frame, skip=("+y",))
    n = max(1, int(round((u1 - u0) / pane)))
    pw = (u1 - u0) / n
    g = c.glass(glass, lit)
    for i in range(n):
        if i % 3 == 0:
            g = c.glass(glass, lit)
        a, b = u0 + i * pw + 0.0009, u0 + (i + 1) * pw - 0.0009
        mb.poly([(a, -out - 0.0003, za), (b, -out - 0.0003, za), (b, -out - 0.0003, zb), (a, -out - 0.0003, zb)], g)


def dock_door(c, u, w, h, z0, shutter="Shutter", frame="Metal_Yellow", canopy=True, bollards=True):
    mb = c.mb
    mb.box2(u - w / 2, -0.0016, z0, u + w / 2, 0.0, z0 + h, shutter, skip=("+y",))
    for s in (-1, 1):
        mb.box2(u + s * w / 2 - 0.003, -0.003, z0, u + s * w / 2 + 0.003, 0.0, z0 + h + 0.004, frame, skip=("+y",))
    mb.box2(u - w / 2 - 0.003, -0.003, z0 + h, u + w / 2 + 0.003, 0.0, z0 + h + 0.006, frame, skip=("+y",))
    for s in (-1, 1):
        mb.box2(u + s * w * 0.35 - 0.004, -0.006, z0 + 0.03, u + s * w * 0.35 + 0.004, 0.0, z0 + 0.045, "Rubber",
                skip=("+y",))
    if canopy:
        mb.box2(u - w / 2 - 0.01, -0.035, z0 + h + 0.012, u + w / 2 + 0.01, 0.0, z0 + h + 0.018, "Metal_Galv")
    if bollards:
        for s in (-1, 1):
            mb.cyl((u + s * (w / 2 + 0.012), -0.014, z0), 0.004, 0.03, "Metal_Yellow", n=8)


def man_door(c, u, z0, mat="Door_Blue", w=0.03, h=0.105, canopy=True):
    mb = c.mb
    mb.box2(u - w / 2, -0.0018, z0, u + w / 2, 0.0, z0 + h, mat, skip=("+y",))
    mb.box2(u - w / 2 - 0.002, -0.0012, z0, u + w / 2 + 0.002, 0.0, z0 + h + 0.002, "Metal_Dark", skip=("+y",))
    mb.box(((u - w * 0.3), -0.0026, z0 + h * 0.48), (0.003, 0.0015, 0.002), "Chrome")
    if canopy:
        mb.box2(u - w / 2 - 0.008, -0.022, z0 + h + 0.008, u + w / 2 + 0.008, 0.0, z0 + h + 0.012, "Metal_Galv")
    mb.box2(u - w / 2 - 0.01, -0.025, z0, u + w / 2 + 0.01, 0.0, z0 + 0.006, "Concrete")


def shed(c, x0, y0, x1, y1, z0, z1, wall, roof="Metal_Corrugated", rise=0.04, ridge="x", plinth="Concrete",
         plinth_h=0.02, flat=False, parapet=0.015, features=None, corner="Metal_White", gable_mat=None,
         roof_flat="Roof_Flat"):
    """Industrial hall: plinth, cladding, corner trims, a pitched (or flat) roof.
    features: {side: [callables(c, L)]} run in the facade's local frame (x along wall, -y outward)."""
    mb = c.mb
    for s in "SENW":
        o, ang, ln = SIDES[s]
        p = o(x0, y0, x1, y1)
        L = ln(x0, y0, x1, y1)
        mb.push(T(p[0], p[1]) @ rotz(ang))
        mb.poly([(0, 0, z0), (L, 0, z0), (L, 0, z0 + plinth_h), (0, 0, z0 + plinth_h)], plinth)
        mb.poly([(0, 0, z0 + plinth_h), (L, 0, z0 + plinth_h), (L, 0, z1), (0, 0, z1)], wall)
        if corner:
            mb.box2(-0.0025, -0.0025, z0 + plinth_h, 0.0025, 0.0, z1, corner, skip=("+y", "-z"))
        for fn in (features or {}).get(s, []):
            fn(c, L)
        mb.pop()
    if flat:
        flat_roof(c, x0, y0, x1, y1, z1, roof=roof_flat, parapet=parapet, pmat=wall, cap="Metal_Galv")
        return z1 + parapet
    return gable_roof(c, x0, y0, x1, y1, z1, rise, roof, gable_mat or wall, oh=0.008, ridge=ridge, t=0.003,
                      gutter="Metal_Galv", fascia="Metal_Galv")


def sawtooth_roof(c, x0, y0, x1, y1, z, n, rise, mat="Metal_Corrugated", end_mat="Brick_Old", glass="Glass",
                  frame="Frame_Dark"):
    """North-light sawtooth roof: sloped sheets facing -y, vertical glazing facing +y."""
    mb = c.mb
    d = (y1 - y0) / n
    for i in range(n):
        ya, yb = y0 + i * d, y0 + (i + 1) * d
        mb.polyo([(x0, ya, z), (x1, ya, z), (x1, yb, z + rise), (x0, yb, z + rise)], mat, (0, -rise, d))
        mb.polyo([(x0, yb, z + rise * 0.12), (x1, yb, z + rise * 0.12), (x1, yb, z + rise * 0.9),
                  (x0, yb, z + rise * 0.9)], c.glass(glass, 0.25), (0, 1, 0))
        mb.polyo([(x0, yb, z), (x1, yb, z), (x1, yb, z + rise * 0.12), (x0, yb, z + rise * 0.12)], mat, (0, 1, 0))
        mb.polyo([(x0, yb, z + rise * 0.9), (x1, yb, z + rise * 0.9), (x1, yb, z + rise), (x0, yb, z + rise)], mat,
                 (0, 1, 0))
        nm = max(2, int((x1 - x0) / 0.03))
        for k in range(nm + 1):
            xx = x0 + (x1 - x0) * k / nm
            mb.box2(xx - 0.0012, yb, z + rise * 0.1, xx + 0.0012, yb + 0.0015, z + rise * 0.92, frame, skip=("-y",))
        for xx, s in ((x0, -1), (x1, 1)):
            mb.polyo([(xx, ya, z), (xx, yb, z), (xx, yb, z + rise)], end_mat, (s, 0, 0))
        mb.box2(x0 - 0.004, yb - 0.004, z - 0.004, x1 + 0.004, yb + 0.004, z + 0.002, "Metal_Galv")
    return z + rise


# ----------------------------------------------------------------------------- plant

def stack(c, idx, x, y, h, r0, r1, mat="Concrete", z0=0.0, bands=(), n=14, platform=0.82, rim="Metal_Dark",
          base=None):
    """Chimney stack; adds empty StackTop_<idx> at the opening (None idx = no marker)."""
    mb = c.mb
    if base:
        bw, bh, bm = base
        mb.box2(x - bw / 2, y - bw / 2, z0, x + bw / 2, y + bw / 2, z0 + bh, bm, skip=("-z",))
    mb.lathe([(r0, 0.0), (r1, h)], mat, n=n, c=(x, y, z0))
    rr = lambda f: r0 + (r1 - r0) * f
    for (f0, f1, bm) in bands:
        mb.lathe([(rr(f0) + 0.0008, h * f0), (rr(f1) + 0.0008, h * f1)], bm, n=n, c=(x, y, z0))
    mb.lathe([(r1, h), (r1 * 1.07, h), (r1 * 1.07, h + 0.008), (r1 * 0.86, h + 0.008), (r1 * 0.86, h - 0.012)],
             rim, n=n, c=(x, y, z0))
    mb.cyl((x, y, z0 + h - 0.012), r1 * 0.86, 0.0005, "Soot", n=n, caps=(False, True))
    if platform:
        zp = h * platform
        r = rr(platform)
        mb.lathe([(r, 0), (r + 0.014, 0), (r + 0.014, 0.003), (r, 0.003)], "Grating", n=n, c=(x, y, z0 + zp),
                 smooth=False)
        mb.lathe([(r + 0.014, 0.016), (r + 0.014, 0.019)], "Metal_Yellow", n=n, c=(x, y, z0 + zp))
        mb.box2(x - 0.003, y - rr(0.0) - 0.004, z0, x + 0.003, y - rr(0.0) + 0.001, z0 + zp, "Metal_Dark",
                skip=("-z",))
    if idx is not None:
        make_empty("StackTop_%d" % idx, (x, y, z0 + h + 0.01))
    return z0 + h


def tank(c, x, y, r, h, mat="Steel_White", z0=0.0, roof="cone", n=18, stairs=True, rings=2):
    mb = c.mb
    mb.cyl((x, y, z0), r + 0.006, 0.006, "Concrete", n=n, caps=(False, True), smooth=True)
    zb = z0 + 0.006
    if roof == "cone":
        prof = [(r, 0), (r, h), (r * 0.98, h + 0.003), (0.0, h + r * 0.18)]
    elif roof == "dome":
        prof = [(r, 0), (r, h)] + [(r * math.cos(t), h + r * 0.35 * math.sin(t)) for t in
                                   (0.3, 0.6, 0.9, 1.2, 1.5708)]
    else:  # floating roof: open top with dark deck inside a rim
        prof = [(r, 0), (r, h), (r * 0.97, h), (r * 0.97, h * 0.8), (0.0, h * 0.8)]
    mb.lathe(prof, mat, n=n, c=(x, y, zb))
    for k in range(rings):
        z = zb + h * (k + 1) / (rings + 1)
        mb.lathe([(r + 0.0012, 0), (r + 0.0012, 0.003)], "Metal_Galv", n=n, c=(x, y, z))
    if roof == "float":
        mb.cyl((x, y, zb + h * 0.8 + 0.0005), r * 0.9, 0.003, "Metal_Dark", n=n, caps=(False, True))
    mb.lathe([(r + 0.001, h - 0.001), (r + 0.006, h - 0.001), (r + 0.006, h + 0.009), (r + 0.0055, h + 0.009)],
             "Metal_Yellow", n=n, c=(x, y, zb), smooth=False)
    if stairs:
        steps = 14
        a0 = c.rnd.uniform(0, 2 * math.pi)
        for k in range(steps):
            a = a0 + k * 1.6 / steps
            zz = zb + h * (k + 0.5) / steps
            mb.box((x + math.cos(a) * (r + 0.006), y + math.sin(a) * (r + 0.006), zz), (0.01, 0.006, 0.0025),
                   "Grating", rz=a + math.pi / 2)
    return zb + h


def sphere_tank(c, x, y, r, mat="Steel_White", z0=0.0):
    mb = c.mb
    zc = z0 + r * 1.55
    for k in range(6):
        a = 2 * math.pi * k / 6
        px, py = x + math.cos(a) * r * 0.8, y + math.sin(a) * r * 0.8
        mb.cyl((px, py, z0), 0.004, zc - z0, "Steel_White", n=6, caps=(False, False))
        mb.box((px, py, z0 + 0.004), (0.012, 0.012, 0.008), "Concrete")
    mb.sphere((x, y, zc), r, mat, n=18, rings=10)
    mb.lathe([(r * 0.995, 0), (r * 1.02, 0), (r * 1.02, 0.003), (r * 0.995, 0.003)], "Metal_Galv", n=18,
             c=(x, y, zc))
    mb.cyl((x, y, zc + r * 0.98), 0.012, 0.005, "Metal_Yellow", n=8)
    return zc + r


def column(c, x, y, r, h, mat="Steel_White", z0=0.0, platforms=4, n=14):
    mb = c.mb
    mb.cyl((x, y, z0), r * 1.5, 0.02, "Concrete", n=8, caps=(False, True), smooth=False)
    zb = z0 + 0.02
    mb.lathe([(r, 0), (r, h), (r * 0.7, h + r * 0.35), (0.0, h + r * 0.5)], mat, n=n, c=(x, y, zb))
    for k in range(platforms):
        z = zb + h * (k + 1) / (platforms + 1)
        a0 = k * 1.3
        mb.lathe([(r, 0), (r + 0.012, 0), (r + 0.012, 0.0025), (r, 0.0025)], "Grating", n=n, c=(x, y, z),
                 a0=a0, a1=a0 + math.pi * 1.2, smooth=False)
        mb.lathe([(r + 0.012, 0.014), (r + 0.012, 0.0165)], "Metal_Yellow", n=n, c=(x, y, z), a0=a0,
                 a1=a0 + math.pi * 1.2)
    mb.box2(x - 0.0025, y - r - 0.006, zb, x + 0.0025, y - r - 0.002, zb + h, "Metal_Yellow")
    return zb + h + r * 0.5


def pipe_rack(c, a, b, z, w=0.045, step=0.09, pipes=3, mats=("Metal_Galv", "Steel_White", "Metal_Red", "Metal_Dark")):
    mb = c.mb
    a, b = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
    d = b - a
    L = d.length
    ang = math.atan2(d.y, d.x)
    mb.push(T(a.x, a.y) @ rotz(ang))
    n = max(1, int(L / step))
    for i in range(n + 1):
        xx = L * i / n
        for s in (-1, 1):
            mb.box((xx, s * w / 2, z / 2), (0.004, 0.004, z), "Metal_Dark", skip=("-z",))
        mb.box((xx, 0, z), (0.005, w + 0.006, 0.004), "Metal_Dark")
    mb.box((L / 2, -w / 2, z + 0.003), (L, 0.003, 0.002), "Metal_Dark")
    mb.box((L / 2, w / 2, z + 0.003), (L, 0.003, 0.002), "Metal_Dark")
    for k in range(pipes):
        yy = -w / 2 + w * (k + 0.5) / pipes
        r = min(0.007, w / pipes * 0.38)
        tube(mb, (0, yy, z + 0.002 + r), (L, yy, z + 0.002 + r), r, mats[k % len(mats)], n=8)
    mb.pop()


def gallery(c, a, b, w=0.024, h=0.026, mat="Metal_Corrugated_Light", supports=True):
    """Enclosed conveyor gallery from 3D point a to b with trestle supports."""
    mb = c.mb
    beam(mb, a, b, w, h, mat)
    if supports:
        a, b = Vector(a), Vector(b)
        L = (b - a).length
        n = max(1, int(L / 0.18))
        for i in range(1, n + 1):
            p = a + (b - a) * (i / (n + 1))
            if p.z > 0.04:
                for s in (-1, 1):
                    mb.box((p.x, p.y + s * w * 0.4, (p.z - h / 2) / 2), (0.004, 0.004, p.z - h / 2), "Metal_Dark",
                           skip=("-z",))


def silo(c, x, y, r, h, mat="Concrete", z0=0.0, n=16, roof="Concrete_Dark"):
    mb = c.mb
    mb.lathe([(r, 0), (r, h)], mat, n=n, c=(x, y, z0))
    mb.lathe([(r, h), (r * 1.02, h), (r * 0.15, h + r * 0.35), (0.0, h + r * 0.36)], roof, n=n, c=(x, y, z0))
    return z0 + h + r * 0.36


def hopper_silo(c, x, y, r, h, mat="Metal_Galv", z0=0.0, legs=0.12, n=14):
    """Steel silo on legs with a conical hopper bottom."""
    mb = c.mb
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        mb.box((x + math.cos(a) * r * 0.85, y + math.sin(a) * r * 0.85, z0 + (legs + r * 0.6) / 2),
               (0.005, 0.005, legs + r * 0.6), "Metal_Dark", skip=("-z",))
    zb = z0 + legs
    mb.lathe([(0.008, 0), (r, r * 0.8), (r, r * 0.8 + h), (r * 0.2, r * 1.3 + h), (0, r * 1.32 + h)], mat, n=n,
             c=(x, y, zb))
    return zb + r * 1.32 + h


def cooling_tower(c, x, y, r0, h, mat="Concrete", z0=0.0, n=24):
    mb = c.mb
    prof = []
    for k in range(9):
        t = k / 8
        prof.append((r0 * (1.0 - 0.42 * math.sin(t * math.pi * 0.62) + 0.06 * t), h * t))
    mb.lathe(prof, mat, n=n, c=(x, y, z0))
    rt = prof[-1][0]
    mb.lathe([(rt, h), (rt * 0.97, h), (rt * 0.97, h * 0.75)], "Concrete_Dark", n=n, c=(x, y, z0))
    mb.cyl((x, y, z0 + h * 0.3), rt * 0.97, 0.0005, "Water", n=n, caps=(False, True))
    # leg ring at the base (open air intake)
    mb.lathe([(r0 * 1.003, 0.0), (r0 * 1.003, h * 0.06)], "Concrete_Dark", n=n, c=(x, y, z0))
    return z0 + h


def container(mb, x, y, z, rz=0.0, mat="Container_Blue", L=0.305, W=0.122, H=0.13):
    mb.push(T(x, y, z) @ rotz(rz))
    mb.box((0, 0, H / 2), (L, W, H), mat, mats={"+x": "Metal_Dark" if "Green" not in mat else mat})
    for s in (-1, 1):
        mb.box((s * (L / 2 - 0.004), 0, H / 2), (0.008, W + 0.002, H + 0.002), mat, skip=("-z",))
    for k in (-1, 0, 1):
        mb.box((L / 2 + 0.0008, k * W * 0.2, H / 2), (0.0016, 0.002, H * 0.9), "Metal_Galv")
    mb.pop()


def truck(c, x, y, rz=0.0, box_mat="Container_White", cab_mat="Paint_white", L=0.42, tanker=False):
    """Rigid truck, front facing local -y."""
    mb = c.mb
    W = 0.125
    # keep the whole truck (incl. bumper and mirrors) inside the 0.94 lot
    hx = abs(math.cos(rz)) * (W / 2 + 0.01) + abs(math.sin(rz)) * (L / 2 + 0.01)
    hy = abs(math.sin(rz)) * (W / 2 + 0.01) + abs(math.cos(rz)) * (L / 2 + 0.01)
    x = max(-0.468 + hx, min(0.468 - hx, x))
    y = max(-0.468 + hy, min(0.468 - hy, y))
    mb.push(T(x, y) @ rotz(rz))
    ys = -L / 2
    cab = 0.105
    mb.box2(-W * 0.38, ys + 0.01, 0.022, W * 0.38, L / 2 - 0.005, 0.04, "Metal_Dark")
    mb.box2(-W / 2, ys, 0.03, W / 2, ys + cab, 0.1, cab_mat)
    mb.box2(-W / 2, ys + 0.006, 0.1, W / 2, ys + cab, 0.16, cab_mat, mats={"-y": "Glass_Car"})
    for s in (-1, 1):
        mb.polyo([(s * (W / 2 + 0.0006), ys + 0.012, 0.105), (s * (W / 2 + 0.0006), ys + 0.06, 0.105),
                  (s * (W / 2 + 0.0006), ys + 0.06, 0.15), (s * (W / 2 + 0.0006), ys + 0.012, 0.15)],
                 "Glass_Car", (s, 0, 0))
        mb.box((s * W * 0.36, ys - 0.0008, 0.05), (0.018, 0.0016, 0.008), "Light_Head")
        mb.box((s * W * 0.38, L / 2 + 0.0008, 0.05), (0.012, 0.0016, 0.008), "Light_Tail")
    mb.box((0, ys - 0.0008, 0.07), (W * 0.6, 0.0016, 0.025), "Metal_Dark")
    if tanker:
        mb.lathe([(0.0, 0.0), (0.05, 0.004), (0.055, 0.02), (0.055, L - cab - 0.03), (0.05, L - cab - 0.014),
                  (0.0, L - cab - 0.01)], box_mat, n=14, c=(0, ys + cab + 0.006, 0.105),
                 axis=Matrix.Rotation(-math.pi / 2, 4, "X"))
    else:
        mb.box2(-W / 2, ys + cab + 0.006, 0.042, W / 2, L / 2, 0.2, box_mat)
    wheels = (ys + 0.055, L / 2 - 0.07, L / 2 - 0.12)
    for yy in wheels:
        for s in (-1, 1):
            mb.cyl((s * (W / 2 - 0.006) - 0.007, yy, 0.0225), 0.0225, 0.014, "Rubber", n=12,
                   axis=Matrix.Rotation(math.pi / 2, 4, "Y"))
    mb.pop()


def car_park(c, x0, y0, x1, y1, n, rz=0.0, fill=0.7, along="x"):
    """Asphalt bay row with painted lines and parked cars."""
    from arch import pad, parked_car
    pad(c, x0, y0, x1, y1, "Asphalt", h=0.0015)
    mb = c.mb
    if along == "x":
        bw = (x1 - x0) / n
        for i in range(n + 1):
            xx = x0 + i * bw
            mb.box2(xx - 0.0012, y0 + 0.004, 0.0055, xx + 0.0012, y1 - 0.004, 0.0058, "Paint_White", skip=("-z",))
        for i in range(n):
            if c.rnd.random() < fill:
                parked_car(c, x0 + (i + 0.5) * bw, (y0 + y1) / 2, rz=rz, max_len=y1 - y0 - 0.01, z=0.0055)
    else:
        bw = (y1 - y0) / n
        for i in range(n + 1):
            yy = y0 + i * bw
            mb.box2(x0 + 0.004, yy - 0.0012, 0.0055, x1 - 0.004, yy + 0.0012, 0.0058, "Paint_White", skip=("-z",))
        for i in range(n):
            if c.rnd.random() < fill:
                parked_car(c, (x0 + x1) / 2, y0 + (i + 0.5) * bw, rz=rz, max_len=x1 - x0 - 0.01, z=0.0055)


def fence_line(c, pts, h=0.04, mat="Metal_Galv"):
    mb = c.mb
    for a, b in zip(pts[:-1], pts[1:]):
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        mb.push(T((a[0] + b[0]) / 2, (a[1] + b[1]) / 2) @ rotz(ang))
        mb.box((0, 0, h), (L, 0.002, 0.002), mat)
        mb.box((0, 0, 0.006), (L, 0.002, 0.002), mat)
        n = max(1, int(L / 0.05))
        for i in range(n + 1):
            mb.box((-L / 2 + L * i / n, 0, h / 2 + 0.002), (0.0025, 0.0025, h), mat, skip=("-z",))
        mb.pop()


def pallets(c, x, y, n=3, rz=0.0):
    mb = c.mb
    mb.push(T(x, y, 0.004) @ rotz(rz))
    for i in range(n):
        h = 0.006 + 0.01 * (i % 2)
        mb.box((i * 0.06, 0, 0.003), (0.05, 0.06, 0.006), "Wood_Weathered")
        mb.box((i * 0.06, 0, 0.006 + h / 2), (0.046, 0.056, h), "Fabric_Cream" if i % 2 else "Wood")
    mb.pop()
