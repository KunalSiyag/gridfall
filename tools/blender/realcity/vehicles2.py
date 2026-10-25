"""Vehicle library v2: road vehicles at real size (1.0x) for street-level play.

Everything is authored in metres and scaled by S = core.M (1 unit = 20 m): a 4.7 m sedan is 0.235
units long, a 12 m bus 0.6. The legacy 1.2x library (vehicles.py, VS = 1.2 * M) is untouched; this
module only reads its CAR_SHAPES cross-sections. Front faces Godot +Z (Blender -Y), wheels touch y = 0,
and the driver's side (right-hand traffic) is Godot +X.

Node contracts (scripts/fp/asset_paths.gd):
  Wheel_FL, Wheel_FR, Wheel_RL, Wheel_RR   own objects, origin at the hub, spin about local X
                                           (the bicycle: Wheel_F, Wheel_R)
  Seat_Driver                              empty at the driver's hip point, facing +Z
  Pedal_L, Pedal_R                         ankle targets on the footwell floor, driver's left on +X
  Wheel_L, Wheel_R                         grips on the steering rim at ten and two
  Cab_Roof                                 the headliner above the seat (drive_feature.gd sinks the
                                           hips until the hero's head clears it)
  Crank                                    the bicycle's cranks and pedals, origin at the bottom
                                           bracket, spin about local X (left pedal up at rest)
  Siren_0, Siren_1 (+ Siren_2, Siren_3)    light-bar lenses on the police car, ambulance and fire truck
Materials (at most 8 per file): Paint_<colour> (clear coat), Glass_Car (tinted, alpha 0.55, two-sided),
Light_Head, Light_Tail, Light_Brake, Light_Indicator_L, Light_Indicator_R and Car_Atlas (atlas.py:
tyres, trim, interior, plates, secondary paint). Glass is see-through, so every vehicle has a cabin.

<name>_lod1.glb (key vehicles_v2/<name>_lod1): the same silhouette with a few flat, untextured materials
(atlas.build_lod: colour groups, emissive Light_Head / Light_Tail lenses), opaque glass, wheels merged and
static, at most 1,500 triangles.

baked_car() puts a mid-detail car (Paint + Car_Atlas, opaque glass, merged wheels) into another
model's builder; arch.parked_car uses it for the cars on house drives and parking lots."""

import math

from mathutils import Matrix, Vector

import atlas
import core
from core import MB, M, make_empty, rotz

S = M
RX = lambda a: Matrix.Rotation(a, 4, "X")  # noqa: E731
RY90 = Matrix.Rotation(math.pi / 2, 4, "Y")  # local Z -> +X

GLASS_V2 = ("flat", (0.018, 0.022, 0.026), 0.03, 0.0, {"alpha": 0.55, "double": True})
LIGHT_SPECS = {
    "Light_Head": ("flat", (0.90, 0.90, 0.88), 0.05, 0.0, {"emission": (1.0, 0.96, 0.88), "strength": 0.6}),
    "Light_Tail": ("flat", (0.40, 0.012, 0.01), 0.1, 0.0, {"emission": (0.55, 0.015, 0.01), "strength": 0.5}),
    "Light_Brake": ("flat", (0.36, 0.012, 0.01), 0.1, 0.0, {}),
    "Light_Indicator_L": ("flat", (0.80, 0.36, 0.015), 0.12, 0.0, {}),
    "Light_Indicator_R": ("flat", (0.80, 0.36, 0.015), 0.12, 0.0, {}),
}


# ----------------------------------------------------------------------------- look / materials

class Look:
    """Material per role for one of three detail modes:
    full  - the vehicles_v2 GLB (8 materials, transparent glass, cabin, lights as own materials)
    lod   - the _lod1 GLB (everything as palette swatches, merged into one mesh of flat colour groups)
    baked - a parked car merged into a zone model (Paint + Car_Atlas, opaque glass)"""

    def __init__(self, mode, paint, rnd=None):
        self.mode = mode
        self.paint = paint
        self.full = mode == "full"
        self.lod = mode == "lod"
        self.rnd = rnd

    def __call__(self, role):
        if role.startswith("@"):
            return role
        if role == "paint":
            return "@" + self.paint if self.lod else self.paint
        if role.startswith("paint:"):
            p = role[6:]
            if p == self.paint:
                return self("paint")
            return "@" + p
        if self.full:
            return {"glass": "Glass_Car", "head": "Light_Head", "tail": "Light_Tail", "brake": "Light_Brake",
                    "ind_l": "Light_Indicator_L", "ind_r": "Light_Indicator_R"}[role]
        return {"glass": "@glass_dark", "head": "@lens_head", "tail": "@lens_tail", "brake": "@lens_tail",
                "ind_l": "@lens_amber", "ind_r": "@lens_amber"}[role]


def setup_materials(look):
    """Per-build material overrides for the names the v2 contract redefines."""
    if look.full:
        core.material("Glass_Car", override=GLASS_V2)
        for n, spec in LIGHT_SPECS.items():
            core.material(n, override=spec)


def bx(mb, x0, y0, z0, x1, y1, z1, mat, **kw):
    """Box between two corners given in metres."""
    mb.box2(x0 * S, y0 * S, z0 * S, x1 * S, y1 * S, z1 * S, mat, **kw)


def bc(mb, c, s, mat, rz=0.0, **kw):
    """Box centred at c (metres) with size s (metres), turned rz about Z."""
    mb.box((c[0] * S, c[1] * S, c[2] * S), (s[0] * S, s[1] * S, s[2] * S), mat, rz=rz, **kw)


def quad(mb, pts, mat, out=None):
    P = [(p[0] * S, p[1] * S, p[2] * S) for p in pts]
    if out is not None:
        return mb.polyo(P, mat, out)
    return mb.poly(P, mat)


# ----------------------------------------------------------------------------- loft with wheel arches

class Arch:
    def __init__(self, y, r, gap=0.06):
        self.y, self.zc, self.R = y, r, r + gap

    def z(self, y):
        dy = y - self.y
        if abs(dy) > self.R:
            return None
        return self.zc + math.sqrt(max(0.0, self.R * self.R - dy * dy))


def arch_bottom(y, arches, sill):
    z = sill
    for a in arches:
        h = a.z(y)
        if h is not None:
            z = max(z, h)
    return z


def loft_ys(base, arches, steps, y0, y1):
    ys = list(base)
    for a in arches:
        ys += [a.y - a.R - 0.004, a.y + a.R + 0.004]
        for k in range(steps + 1):
            ys.append(a.y - a.R * math.cos(math.pi * k / steps))
    ys = sorted(y for y in ys if y0 - 1e-6 <= y <= y1 + 1e-6)
    out = []
    for y in ys:
        if out and abs(y - out[-1]) < 0.0015:
            continue
        out.append(y)
    return out


def loft(mb, ys, ring_fn, mat_fn, caps=(None, None), inward=False, inset=0.0, crease=None, end_crease=0.0):
    """Loft rings ring_fn(y) -> [(x, z)] (closed, up the left side, over the top, down the right,
    bottom edge last) through stations ys (front -> rear). mat_fn(y_mid, i) -> material or None (skip).
    caps: materials for the first / last ring polygon (None: open). inward flips every face.
    inset > 0 closes each end with a ring shrunk by that fraction toward its centre (same plane) before
    the polygon, so a subdivided body gets a flat end face with rounded edges. crease: edge crease for
    every edge of this loft when the cage is subdivided (cage_object); end_crease for the edges of the first
    and last ring loops (tightens the rounding where the body meets its end faces)."""
    rings = []
    local = []
    first = len(mb.v)
    for y in ys:
        pts = ring_fn(y)
        local.append(pts)
        rings.append([mb.vert((x * S, y * S, z * S)) for x, z in pts])
    n = len(rings[0])
    for k in range(len(rings) - 1):
        ym = (ys[k] + ys[k + 1]) / 2
        for i in range(n):
            m = mat_fn(ym, i)
            if m is None:
                continue
            j = (i + 1) % n
            f = [rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]]
            mb.face(list(reversed(f)) if inward else f, m)
    for end, cap in ((0, caps[0]), (1, caps[1])):
        if not cap:
            continue
        ring = rings[0] if end == 0 else rings[-1]
        if inset > 0.0:
            pts = local[0] if end == 0 else local[-1]
            y = ys[0] if end == 0 else ys[-1]
            cx = sum(p[0] for p in pts) / n
            cz = sum(p[1] for p in pts) / n
            inner = [mb.vert((((x - cx) * (1 - inset) + cx) * S, y * S, ((z - cz) * (1 - inset) + cz) * S))
                     for x, z in pts]
            for i in range(n):
                j = (i + 1) % n
                f = [ring[i], ring[j], inner[j], inner[i]]
                if end == 0:
                    f = list(reversed(f))
                mb.face(list(reversed(f)) if inward else f, cap)
            ring = inner
        f = list(reversed(ring)) if end == 0 else list(ring)
        mb.face(list(reversed(f)) if inward else f, cap)
    if crease is not None:
        if not hasattr(mb, "creases"):
            mb.creases = []
        mb.creases.append((first, len(mb.v), crease))
    if end_crease > 0.0:
        if not hasattr(mb, "edge_creases"):
            mb.edge_creases = {}
        for ring in (rings[0], rings[-1]):
            for i in range(n):
                a, b = ring[i], ring[(i + 1) % n]
                mb.edge_creases[(min(a, b), max(a, b))] = end_crease
    return rings


def cage_object(mb, name, level=1):
    """Build a body cage as one object with edge creases (material boundaries 1.0, plus each loft's
    crease), subdivide it (Catmull-Clark) and apply. Returns the object or None."""
    import bmesh
    import bpy
    atlas.resolve(mb)
    ob = mb.build(name, uv_offset=(0.0, 0.0))
    if ob is None:
        return None
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    cl = bm.edges.layers.float.get("crease_edge") or bm.edges.layers.float.new("crease_edge")
    ranges = getattr(mb, "creases", [])
    ec = getattr(mb, "edge_creases", {})
    for e in bm.edges:
        fs = e.link_faces
        v = 0.0
        if len(fs) == 2 and fs[0].material_index != fs[1].material_index:
            v = 1.0
        elif len(fs) < 2:
            v = 1.0
        for a, b, c in ranges:
            if all(a <= vv.index < b for vv in e.verts):
                v = max(v, c)
        i0, i1 = sorted(vv.index for vv in e.verts)
        v = max(v, ec.get((i0, i1), 0.0))
        e[cl] = v
    for f in bm.faces:
        f.smooth = True
    bm.to_mesh(me)
    bm.free()
    if level > 0:
        mod = ob.modifiers.new("sub", "SUBSURF")
        mod.levels = level
        mod.render_levels = level
        mod.uv_smooth = "NONE"
        mod.boundary_smooth = "PRESERVE_CORNERS"
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.modifier_apply(modifier=mod.name)
    smooth(ob, 40)
    return ob


class Surf:
    """Ray casts against a built body (metres in, metres out) so details sit on the real surface."""

    def __init__(self, ob):
        import bpy
        from mathutils.bvhtree import BVHTree
        dg = bpy.context.evaluated_depsgraph_get()
        self.bvh = BVHTree.FromObject(ob, dg)

    def _ray(self, o, d):
        hit = self.bvh.ray_cast(Vector(o) * S, Vector(d), 20.0 * S)
        if hit[0] is None:
            return None, None
        return hit[0] / S, hit[1]

    def front(self, x, z):
        p, n = self._ray((x, -20.0, z), (0, 1, 0))
        return (p.y, n) if p is not None else (None, None)

    def rear(self, x, z):
        p, n = self._ray((x, 20.0, z), (0, -1, 0))
        return (p.y, n) if p is not None else (None, None)

    def side(self, sd, y, z):
        p, n = self._ray((sd * 5.0, y, z), (-sd, 0, 0))
        return (p.x, n) if p is not None else (None, None)

    def top(self, x, y):
        p, n = self._ray((x, y, 10.0), (0, 0, -1))
        return (p.z, n) if p is not None else (None, None)


def decal(mb, surf, face, u0, u1, v0, v1, mat, nu=4, nv=2, off=0.002):
    """A patch that hugs the body: a grid over (u, v) projected onto the surface and lifted off it.
    face: "front" / "rear" (u = x, v = z), ("side", sd) (u = y, v = z), "top" (u = x, v = y)."""
    us = [u0 + (u1 - u0) * i / nu for i in range(nu + 1)]
    vs = [v0 + (v1 - v0) * j / nv for j in range(nv + 1)]
    grid = {}
    for i, u in enumerate(us):
        for j, v in enumerate(vs):
            if face == "front":
                y, n = surf.front(u, v)
                p = None if y is None else (u, y - off, v)
            elif face == "rear":
                y, n = surf.rear(u, v)
                p = None if y is None else (u, y + off, v)
            elif face == "top":
                z, n = surf.top(u, v)
                p = None if z is None else (u, v, z + off)
            else:
                sd = face[1]
                x, n = surf.side(sd, u, v)
                p = None if x is None else (x + sd * off, u, v)
            grid[i, j] = (p, n)
    for i in range(nu):
        for j in range(nv):
            cs = [grid[i, j], grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]]
            if any(c[0] is None for c in cs):
                continue
            nrm = Vector((0, 0, 0))
            for c in cs:
                nrm += c[1]
            quad(mb, [c[0] for c in cs], mat, out=tuple(nrm))


# ----------------------------------------------------------------------------- car body (CAR_SHAPES)

class Shape:
    """A CAR_SHAPES entry with interpolation helpers (metres)."""

    def __init__(self, sp):
        self.sp = sp
        self.st = [tuple(s) + ((0.015,) if len(s) == 6 else ()) for s in sp["st"]]
        self.tags = sp["tags"]
        self.W, self.r = sp["W"], sp["r"]
        self.yf, self.yr = self.st[0][0], self.st[-1][0]

    def at(self, y):
        st = self.st
        if y <= st[0][0]:
            return st[0]
        if y >= st[-1][0]:
            return st[-1]
        for a, b in zip(st, st[1:]):
            if a[0] <= y <= b[0]:
                t = (y - a[0]) / (b[0] - a[0]) if b[0] > a[0] else 0.0
                return tuple(a[k] + (b[k] - a[k]) * t for k in range(7))
        return st[-1]

    def tag(self, y):
        st = self.st
        for k in range(len(st) - 1):
            if st[k][0] <= y <= st[k + 1][0]:
                return self.tags[k]
        return self.tags[-1]

    def seg(self, t, nth=0):
        """(y0, y1) of the nth segment tagged t."""
        k = [i for i, c in enumerate(self.tags) if c == t][nth]
        return self.st[k][0], self.st[k + 1][0]

    def hw(self, y):
        return self.W / 2 * self.at(y)[4]


def car_ring(shape, arches, full, crown=None):
    """Closed cross-section at y. Full detail (18 points per ring, index i on the left side, 17 - i on
    the right): 0 sill edge, 1 rocker, 2 door middle, 3 shoulder, 4 belt, 5 glass / pillar split,
    6 glass top, 7 roof rail, 8 roof crown. LOD: 10 points."""
    def fn(y):
        _, zs, zb, zr, wf, wrf, band = shape.at(y)
        W = shape.W
        hw, hr = W / 2 * wf, W / 2 * wrf
        zt = zr + band
        cr = crown if crown is not None else (0.035 if zr - zb > 0.25 else 0.012)
        z0 = arch_bottom(y, arches, zs)
        if full:
            z1 = max(zs + 0.08, z0 + 0.006)
            zm = max(zs + 0.45 * (zb - zs), z1 + 0.006)
            zsh = max(zb - 0.06, zm + 0.006)
            zq = max(zb + 0.001, zr - 0.05)
            tq = (zq - zb) / (zr - zb) if zr - zb > 1e-6 else 0.0
            xq = hw * 0.975 + (hr - hw * 0.975) * tq
            left = [(-hw * 0.93, z0), (-hw * 0.985, z1), (-hw, zm), (-hw * 0.995, zsh), (-hw * 0.975, zb),
                    (-xq, zq), (-hr, zr), (-hr * 0.985, zt), (-hr * 0.6, zt + cr * 0.9)]
        else:
            zm = max(zs + 0.45 * (zb - zs), z0 + 0.006)
            left = [(-hw * 0.94, z0), (-hw, zm), (-hw * 0.98, zb), (-hr, zr), (-hr * 0.7, zt + cr)]
        return left + [(-x, z) for x, z in reversed(left)]
    return fn


def car_mats(shape, look, mats, full):
    """Material per loft segment, keyed by the station tag (X end, H hood, W windscreen, G side glass,
    P pillar / panel, B rear window, T trunk)."""
    body = look(mats.get("body", "paint"))
    lower = look(mats["lower"]) if "lower" in mats else body
    roof = look(mats["roof"]) if "roof" in mats else body
    pillar = look(mats["pillar"]) if "pillar" in mats else body
    band = look(mats["band"]) if "band" in mats else None
    glass = look("glass")
    under = "@under"

    def fn(y, i):
        t = shape.tag(y)
        if full:
            if i == 17:
                return under
            side = i if i <= 8 else 16 - i
            if side in (0, 1):
                return lower
            if side in (2, 3):
                return body
            if side == 4:
                return glass if t in "GW" else (pillar if t in "PB" else body)
            if side == 5:
                if t == "G":
                    return "@trim_black"
                return pillar if t in "WPB" else body
            if side == 6:
                if t == "W":
                    return pillar
                if t == "B":
                    return glass
                if band and t in "GP":
                    return band
                return roof if t in "GP" else body
            return glass if t in "WB" else (roof if t in "GP" else body)
        if i == 9:
            return under
        side = i if i <= 4 else 8 - i
        if side == 0:
            return lower
        if side == 1:
            return body
        if side == 2:
            return glass if t in "G" else pillar
        return glass if t in "WB" else (roof if t in "GP" else body)
    return fn


# Modern cross-sections for v2 (metres): (y, sill_z, belt_z, glass_top_z, width_frac, roof_width_frac[, band]).
# Rounded noses and tails (several end stations), raked screens and tumblehome; dimensions, wheelbases
# and wheel sizes match the legacy CAR_SHAPES so identities carry over.
SHAPES2 = {
    "sedan": dict(L=4.7, W=1.82, r=0.33, axles=(-1.42, 1.38), tags="XHHHHWGPGBTTX", st=[
        (-2.35, .36, .70, .72, .84, .74), (-2.31, .28, .75, .77, .92, .84), (-2.22, .26, .79, .81, .97, .89),
        (-2.00, .26, .82, .84, .99, .92), (-1.50, .25, .86, .89, 1.0, .94), (-1.05, .24, .90, .93, 1.0, .93),
        (-0.25, .24, .94, 1.40, 1.0, .80), (0.10, .24, .95, 1.44, 1.0, .79), (0.20, .24, .95, 1.44, 1.0, .79),
        (1.00, .24, .96, 1.37, 1.0, .80), (1.65, .25, .97, 1.00, 1.0, .90), (2.15, .30, .97, 1.00, .98, .90),
        (2.30, .34, .94, .96, .94, .87), (2.35, .42, .88, .90, .88, .82)]),
    "hatchback": dict(L=4.1, W=1.76, r=0.31, axles=(-1.3, 1.25), tags="XHHHHWGPGPBXX", st=[
        (-2.05, .36, .68, .70, .84, .74), (-2.01, .28, .74, .76, .92, .84), (-1.92, .26, .78, .80, .97, .89),
        (-1.70, .26, .81, .83, .99, .92), (-1.30, .25, .85, .88, 1.0, .93), (-0.95, .25, .90, .93, 1.0, .92),
        (-0.15, .25, .94, 1.42, 1.0, .80), (0.15, .25, .95, 1.46, 1.0, .79), (0.25, .25, .95, 1.46, 1.0, .79),
        (1.05, .26, .96, 1.43, 1.0, .79), (1.45, .27, .97, 1.40, .99, .79), (1.85, .30, .97, 1.08, .98, .86),
        (2.00, .32, .95, .98, .95, .85), (2.05, .40, .88, .90, .88, .80)]),
    "suv": dict(L=4.8, W=1.95, r=0.38, axles=(-1.45, 1.42), tags="XHHHWGPGPGBXX", st=[
        (-2.40, .46, .90, .92, .85, .76), (-2.35, .38, .97, .99, .93, .85), (-2.24, .36, 1.02, 1.04, .97, .90),
        (-1.90, .36, 1.06, 1.08, 1.0, .93), (-1.30, .36, 1.10, 1.13, 1.0, .93), (-0.50, .36, 1.14, 1.70, 1.0, .84),
        (-0.10, .36, 1.15, 1.74, 1.0, .84), (0.02, .36, 1.15, 1.74, 1.0, .84), (1.05, .36, 1.16, 1.73, 1.0, .84),
        (1.15, .36, 1.16, 1.73, 1.0, .84), (1.80, .37, 1.17, 1.70, 1.0, .83), (2.22, .40, 1.15, 1.40, .98, .86),
        (2.34, .44, 1.08, 1.11, .94, .85), (2.40, .50, .98, 1.00, .88, .80)]),
    "coupe": dict(L=4.5, W=1.86, r=0.33, axles=(-1.38, 1.32), tags="XHHHWGBTTX", st=[
        (-2.25, .32, .64, .66, .84, .74), (-2.21, .25, .69, .71, .92, .84), (-2.10, .23, .73, .75, .97, .89),
        (-1.80, .23, .77, .79, .99, .92), (-1.00, .22, .84, .87, 1.0, .92), (-0.10, .22, .88, 1.28, 1.0, .76),
        (0.45, .22, .90, 1.30, 1.0, .76), (1.60, .24, .94, 1.00, 1.0, .90), (2.10, .28, .93, .96, .97, .90),
        (2.20, .34, .88, .90, .92, .85), (2.25, .42, .80, .82, .86, .80)]),
    "van": dict(L=5.3, W=2.0, r=0.35, axles=(-1.75, 1.75), tags="XHHHWGPX", st=[
        (-2.65, .40, .88, .90, .86, .78), (-2.60, .34, .96, .98, .93, .86), (-2.47, .33, 1.03, 1.05, .97, .90),
        (-2.15, .33, 1.09, 1.11, 1.0, .92), (-1.80, .33, 1.13, 1.16, 1.0, .92), (-1.05, .33, 1.16, 2.02, 1.0, .90, .05),
        (-0.45, .33, 1.16, 2.05, 1.0, .90, .05), (2.55, .33, 1.16, 2.05, 1.0, .90, .05),
        (2.65, .40, 1.10, 1.99, .97, .88, .05)]),
    "minibus": dict(L=5.3, W=2.0, r=0.35, axles=(-1.75, 1.75), tags="XHHHWGPGPX", st=[
        (-2.65, .40, .88, .90, .86, .78), (-2.60, .34, .96, .98, .93, .86), (-2.47, .33, 1.03, 1.05, .97, .90),
        (-2.15, .33, 1.09, 1.11, 1.0, .92), (-1.80, .33, 1.13, 1.16, 1.0, .92), (-1.05, .33, 1.16, 2.02, 1.0, .90, .05),
        (-0.45, .33, 1.16, 2.05, 1.0, .90, .05), (-0.30, .33, 1.16, 2.05, 1.0, .90, .05),
        (2.40, .33, 1.16, 2.05, 1.0, .90, .05), (2.55, .33, 1.16, 2.05, 1.0, .90, .05),
        (2.65, .40, 1.10, 1.99, .97, .88, .05)]),
    "pickup": dict(L=5.4, W=1.95, r=0.38, axles=(-1.7, 1.6), tags="XHHHWGPGB", st=[
        (-2.70, .46, .94, .96, .86, .76), (-2.65, .38, 1.01, 1.03, .93, .85), (-2.53, .37, 1.06, 1.08, .98, .90),
        (-2.20, .37, 1.10, 1.12, 1.0, .93), (-1.40, .36, 1.14, 1.17, 1.0, .93), (-0.62, .36, 1.16, 1.84, 1.0, .85),
        (-0.12, .36, 1.17, 1.87, 1.0, .85), (0.00, .36, 1.17, 1.87, 1.0, .85), (0.50, .36, 1.17, 1.85, 1.0, .85),
        (0.62, .36, 1.17, 1.22, 1.0, .90)]),
}


# ----------------------------------------------------------------------------- wheels

def wheel_geo(mb, R, Wd, look, style="alloy", spokes=5, side=1, dual=False, n=None):
    """A wheel around the local origin, axle along Blender X, outer face toward side * X."""
    lod = not look.full          # far LODs and baked parked cars use the simple wheel
    soft = not look.lod          # baked cars are seen close: smooth-shade the simple tyre
    n = n or (10 if lod else 20)
    h = Wd / 2
    axis = RY90 if side > 0 else rotz(math.pi) @ RY90
    tyres = [(-Wd * 0.56, False), (Wd * 0.56, True)] if dual else [(0.0, True)]
    for zc, outer in tyres:
        mb.push(axis @ Matrix.Translation(Vector((0, 0, zc * S))))
        if lod:
            mb.lathe([(R * 0.62 * S, -h * S), (R * S, -h * 0.8 * S), (R * S, h * 0.8 * S), (R * 0.62 * S, h * S)],
                     "@tyre", n=n, smooth=soft)
            rim = "@rim_steel" if style == "steel" else "@rim_alloy"
            mb.lathe([(R * 0.62 * S, h * 0.98 * S), (R * 0.05 * S, h * 0.8 * S)], rim if outer else "@rim_barrel",
                     n=n, smooth=False)
            mb.lathe([(R * 0.62 * S, -h * 0.98 * S), (R * 0.05 * S, -h * 0.8 * S)], "@rim_barrel", n=n,
                     smooth=False)
            mb.pop()
            continue
        prof = [(R * 0.64, -h * 0.90), (R * 0.80, -h), (R * 0.95, -h * 0.93), (R, -h * 0.72), (R, h * 0.72),
                (R * 0.95, h * 0.93), (R * 0.80, h), (R * 0.64, h * 0.90)]
        mb.lathe([(r * S, z * S) for r, z in prof], "@tyre", n=n, smooth=True,
                 mats=["@tyre_wall", "@tyre_wall", "@tyre", "@tyre", "@tyre", "@tyre_wall", "@tyre_wall"])
        rim = {"alloy": "@rim_alloy", "dark": "@rim_dark", "steel": "@rim_steel", "chrome": "@Chrome",
               "steel_dark": "@rim_dark"}[style]
        # rim flange, barrel and the back wall behind the spokes
        mb.lathe([(R * 0.655 * S, h * 0.90 * S), (R * 0.60 * S, h * 0.86 * S), (R * 0.575 * S, h * 0.78 * S)],
                 rim, n=n, smooth=True)
        mb.lathe([(R * 0.575 * S, h * 0.78 * S), (R * 0.575 * S, -h * 0.55 * S), (R * 0.06 * S, -h * 0.55 * S)],
                 "@rim_barrel", n=n, smooth=False, mats=["@rim_barrel", "@rim_barrel"])
        mb.lathe([(R * 0.64 * S, -h * 0.90 * S), (R * 0.06 * S, -h * 0.8 * S)], "@rim_barrel", n=n, smooth=False)
        if outer:
            if style in ("steel", "steel_dark"):
                mb.lathe([(R * 0.575 * S, h * 0.6 * S), (R * 0.25 * S, h * 0.45 * S)], rim, n=n, smooth=False)
                for k in range(6):
                    a = 2 * math.pi * k / 6 + math.pi / 6
                    mb.push(rotz(a))
                    z_ = h * 0.536 * S
                    mb.poly([(R * 0.36 * S, -R * 0.045 * S, z_), (R * 0.48 * S, -R * 0.06 * S, z_),
                             (R * 0.48 * S, R * 0.06 * S, z_), (R * 0.36 * S, R * 0.045 * S, z_)], "@rim_barrel")
                    mb.pop()
                mb.cyl((0, 0, h * 0.45 * S), R * 0.25 * S, h * 0.3 * S, "@Metal_Dark", n=10, smooth=False,
                       caps=(False, True))
                for k in range(6):
                    a = 2 * math.pi * k / 6
                    mb.cyl((math.cos(a) * R * 0.17 * S, math.sin(a) * R * 0.17 * S, h * 0.75 * S), R * 0.028 * S,
                           h * 0.1 * S, "@Chrome", n=4, smooth=False, caps=(False, True))
            else:
                mb.cyl((0, 0, -h * 0.2 * S), R * 0.48 * S, h * 0.06 * S, "@brake_disc", n=n, smooth=False,
                       caps=(False, True))
                for k in range(spokes):
                    a = 2 * math.pi * k / spokes
                    mb.push(rotz(a))
                    mb.prism([(R * 0.17 * S, -R * 0.075 * S), (R * 0.585 * S, -R * 0.045 * S),
                              (R * 0.585 * S, R * 0.045 * S), (R * 0.17 * S, R * 0.075 * S)],
                             h * 0.52 * S, h * 0.74 * S, rim, caps=(False, True))
                    mb.pop()
                mb.cyl((0, 0, h * 0.45 * S), R * 0.2 * S, h * 0.34 * S, rim, n=12, smooth=True, caps=(False, False))
                mb.cyl((0, 0, h * 0.79 * S), R * 0.2 * S, 0.0001, rim, n=12, smooth=False, caps=(False, True))
                mb.cyl((0, 0, h * 0.792 * S), R * 0.08 * S, 0.0001, "@trim_black", n=8, smooth=False,
                       caps=(False, True))
        mb.pop()


def wheel_part(name, loc, R, Wd, look, **kw):
    """Wheel_<xx> object, origin at the hub (Blender loc in metres)."""
    mb = MB()
    wheel_geo(mb, R, Wd, look, **kw)
    atlas.resolve(mb)
    ob = mb.build(name)
    ob.location = (loc[0] * S, loc[1] * S, loc[2] * S)
    smooth(ob)
    return ob


def smooth(ob, angle=38):
    import bpy
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))
    except Exception:
        pass


class Wheels:
    """Collects the wheel set: separate parts (full), or geometry merged into the body (lod, baked)."""

    def __init__(self, c, look):
        self.c, self.look = c, look
        self.items = []

    def axle(self, y, R, Wd, W, front, style="alloy", spokes=5, dual=False, inset=0.0):
        x = W / 2 - (Wd * 1.06 if dual else Wd * 0.5) - (0.01 if dual else 0.015) - inset
        for sd in (1, -1):
            nm = ("Wheel_F" if front else "Wheel_R") + ("L" if sd > 0 else "R")
            self.items.append((nm, (sd * x, y, R), R, Wd, dict(style=style, spokes=spokes, side=sd, dual=dual)))
        return x

    def emit(self, mb):
        for nm, loc, R, Wd, kw in self.items:
            if self.look.full:
                wheel_part(nm, loc, R, Wd, self.look, **kw)
            else:
                mb.push(Matrix.Translation(Vector((loc[0] * S, loc[1] * S, loc[2] * S))))
                wheel_geo(mb, R, Wd, self.look, n=10 if self.look.lod else 14, **kw)
                mb.pop()


# ----------------------------------------------------------------------------- shared details

def plate(mb, look, x, y, z, w=0.52, h=0.115, face=-1, rnd=None):
    """Number plate on a plane facing face * Y (front plate: face = -1)."""
    yy = y + face * 0.004
    bx(mb, x - w / 2, min(y, yy), z - h / 2, x + w / 2, max(y, yy), z + h / 2, "@plate")
    if not look.full:
        return
    n = 7
    cw = w * 0.82 / n
    for k in range(n):
        if k == 2:
            continue
        x0 = x - w * 0.41 + k * cw + cw * 0.15
        quad(mb, [(x0, yy + face * 0.0008, z - h * 0.28), (x0 + cw * 0.7, yy + face * 0.0008, z - h * 0.28),
                  (x0 + cw * 0.7, yy + face * 0.0008, z + h * 0.28), (x0, yy + face * 0.0008, z + h * 0.28)],
             "@plate_text", out=(0, face, 0))


def fin(mb, y, z, mat, L=0.16, h=0.06, w=0.045):
    """Shark-fin antenna on the roof centre line, pointing forward."""
    a, b, t = (y - L / 2, z), (y + L / 2, z), (y + L / 2 - 0.03, z + h)
    for sd in (-1, 1):
        quad(mb, [(sd * w / 2, a[0], a[1]), (sd * w / 2, b[0], b[1]), (sd * w * 0.3, t[0], t[1])], mat, out=(sd, 0, 0))
    quad(mb, [(-w / 2, a[0], a[1]), (-w * 0.3, t[0], t[1]), (w * 0.3, t[0], t[1]), (w / 2, a[0], a[1])], mat,
         out=(0, -1, 1))
    quad(mb, [(-w / 2, b[0], b[1]), (w / 2, b[0], b[1]), (w * 0.3, t[0], t[1]), (-w * 0.3, t[0], t[1])], mat,
         out=(0, 1, 0))


def mirror(mb, look, x, y, z, side, body, arm=0.07, w=0.2, h=0.13, d=0.085):
    """Door mirror: arm, housing (body colour) and glass facing the rear (+Y)."""
    x1 = x + side * arm
    bx(mb, min(x, x1), y, z, max(x, x1), y + 0.06, z + 0.05, "@plastic_black")
    xa, xb = x1 - side * 0.02, x1 + side * (w - 0.02)
    cx, cz = (xa + xb) / 2, z + h / 2 - 0.02
    if look.full:
        # D-shaped housing: a half dome facing forward, flat glass facing the rear
        mb.push(Matrix.Translation(Vector((cx * S, (y + d * 0.35) * S, cz * S))) @ RX(math.radians(90)))
        mb.sphere((0, 0, 0), 1.0 * S, body, n=10, rings=6, scale=(w / 2, h / 2, d), hemi=True)
        mb.pop()
        quad(mb, [(min(xa, xb) + 0.015, y + d * 0.35 + 0.002, cz - h * 0.4),
                  (max(xa, xb) - 0.015, y + d * 0.35 + 0.002, cz - h * 0.4),
                  (max(xa, xb) - 0.015, y + d * 0.35 + 0.002, cz + h * 0.4),
                  (min(xa, xb) + 0.015, y + d * 0.35 + 0.002, cz + h * 0.4)], "@mirror", out=(0, 1, 0))
    else:
        bx(mb, min(xa, xb), y - d / 2, z - 0.02, max(xa, xb), y + d / 2, z + h - 0.02, body)


def side_line(mb, shape_ring, y, w=0.006, mat="@trim_black", pts=(1, 2, 3, 4), out=0.0025):
    """A thin dark shut line on both body sides at station y, following ring points pts."""
    r0 = shape_ring(y - w / 2)
    r1 = shape_ring(y + w / 2)
    n = len(r0)
    for sd in (-1, 1):
        for a, b in zip(pts[:-1], pts[1:]):
            ia, ib = (a, b) if sd < 0 else (n - 1 - a, n - 1 - b)
            pa0, pb0, pa1, pb1 = r0[ia], r0[ib], r1[ia], r1[ib]
            P = [(pa0[0] + sd * out, y - w / 2, pa0[1]), (pb0[0] + sd * out, y - w / 2, pb0[1]),
                 (pb1[0] + sd * out, y + w / 2, pb1[1]), (pa1[0] + sd * out, y + w / 2, pa1[1])]
            quad(mb, P, mat, out=(sd, 0, 0))


def handle(mb, shape_ring, y, z, mat, out=0.006):
    """Door handle on both sides at station y, height z (metres)."""
    r = shape_ring(y)
    n = len(r)
    for sd in (-1, 1):
        # side x at height z: closest ring point on that side
        side_pts = r[:n // 2] if sd < 0 else r[n // 2:]
        x = min(side_pts, key=lambda p: abs(p[1] - z))[0]
        if sd > 0:
            bx(mb, x - 0.004, y - 0.08, z - 0.018, x + out, y + 0.08, z + 0.018, mat)
        else:
            bx(mb, x - out, y - 0.08, z - 0.018, x + 0.004, y + 0.08, z + 0.018, mat)


def steering_wheel(mb, x, y, z, R=0.19, t=0.017, tilt=-64):
    mb.push(Matrix.Translation(Vector((x * S, y * S, z * S))) @ RX(math.radians(tilt)))
    prof = [(R + t * math.cos(a), t * math.sin(a)) for a in [2 * math.pi * k / 6 for k in range(7)]]
    mb.lathe([(r * S, zz * S) for r, zz in prof], "@leather_black", n=16, smooth=True)
    mb.cyl((0, 0, -0.03 * S), 0.055 * S, 0.05 * S, "@dash", n=8, smooth=False)
    for a in (0.0, math.pi, -math.pi / 2):
        mb.box((math.cos(a) * R * 0.5 * S, math.sin(a) * R * 0.5 * S, -0.005 * S), (R * S, 0.035 * S, 0.015 * S),
               "@dash", rz=a)
    mb.pop()
    # column
    mb.push(Matrix.Translation(Vector((x * S, (y - 0.02) * S, (z - 0.03) * S))) @ RX(math.radians(tilt + 90)))
    mb.cyl((0, 0, 0), 0.03 * S, 0.3 * S, "@dash", n=6, smooth=False)
    mb.pop()


def seat(mb, x, y, z, w=0.5, mat="@int_dark", tilt=-15, back_h=0.62, head=True, depth=0.5):
    """Bucket seat: cushion top at height z, backrest pivot at (x, y + depth / 2)."""
    bx(mb, x - w / 2, y - depth / 2, z - 0.14, x + w / 2, y + depth / 2, z, mat)
    mb.push(Matrix.Translation(Vector((x * S, (y + depth / 2 - 0.06) * S, (z - 0.06) * S))) @ RX(math.radians(tilt)))
    mb.box((0, 0.05 * S, back_h / 2 * S), (w * S, 0.12 * S, back_h * S), mat)
    if head:
        mb.box((0, 0.07 * S, (back_h + 0.12) * S), (0.26 * S, 0.1 * S, 0.2 * S), mat)
        for sx in (-0.08, 0.08):
            mb.box((sx * S, 0.07 * S, (back_h + 0.02) * S), (0.012 * S, 0.012 * S, 0.06 * S), "@Chrome")
    mb.pop()


## The foot (ankle) bone rests this far above the sole when the foot stands flat (UAL drive pose).
ANKLE = 0.10


def driver_points(look, seat_at, floor, wheel, ceiling, fwd=0.45, spread=0.13):
    """Driver contact markers next to Seat_Driver (full models only, Blender metres): Pedal_L /
    Pedal_R (ankle targets on the footwell floor), Wheel_L / Wheel_R (grips on the steering rim at
    ten and two, tilted with it) and Cab_Roof (the headliner above the seat). drive_feature.gd
    seats the hero's feet and hands on them with IK and sinks the hips just enough that the head
    clears Cab_Roof, so the pose fits every cabin."""
    if not look.full:
        return
    x, y, z = seat_at
    for side, px in (("L", x + spread), ("R", x - spread)):
        e = make_empty("Pedal_" + side, (px * S, (y - fwd) * S, (floor + ANKLE) * S))
        e.empty_display_size = 0.01
    wx, wy, wz, R, tilt = wheel
    t = math.radians(tilt)
    for side, sx in (("L", 1.0), ("R", -1.0)):
        g = (wx + sx * 0.7071 * R, wy - 0.7071 * R * math.cos(t), wz - 0.7071 * R * math.sin(t))
        e = make_empty("Wheel_" + side, (g[0] * S, g[1] * S, g[2] * S))
        e.empty_display_size = 0.01
    e = make_empty("Cab_Roof", (x * S, y * S, ceiling * S))
    e.empty_display_size = 0.01


# ----------------------------------------------------------------------------- cars

class FlatSurf:
    """Analytic stand-in for Surf when the body is not subdivided (LOD and baked cars)."""

    def __init__(self, sh):
        self.sh = sh

    def front(self, x, z):
        return self.sh.yf, Vector((0, -1, 0))

    def rear(self, x, z):
        return self.sh.yr, Vector((0, 1, 0))

    def side(self, sd, y, z):
        return sd * self.sh.hw(y), Vector((sd, 0, 0))

    def top(self, x, y):
        s = self.sh.at(y)
        return s[3] + s[6], Vector((0, 0, 1))


def car(c, look, shape="sedan", mats=None, taxi=False, police=False, rims="alloy", spokes=5, interior="int_dark"):
    mats = dict(mats or {})
    full, lod = look.full, look.lod
    mb = c.mb
    sh = Shape(SHAPES2[shape])
    W, r = sh.W, sh.r
    st = sh.st
    yf, yr = sh.yf, sh.yr
    ax = sh.sp["axles"]
    arches = [Arch(ax[0], r), Arch(ax[1], r)]
    ring = car_ring(sh, arches, full)
    ys = loft_ys([s[0] for s in st], arches, 4, yf, yr)
    body = look(mats.get("body", "paint"))
    van_like = shape in ("van", "minibus")
    cage = MB() if full else mb
    loft(cage, ys, ring, car_mats(sh, look, mats, full), caps=(body, body), inset=0.45 if full else 0.0,
         crease=0.45 if van_like else None, end_crease=0.65)
    # --- pickup bed (U-section loft with the rear arch cut in)
    if shape == "pickup":
        yb0, yb1 = yr, sh.sp["L"] / 2
        hw = W / 2

        def bed_ring(y):
            z0 = arch_bottom(y, arches, 0.40)
            p = [(-hw * 0.97, z0), (-hw, 0.62), (-hw, 1.12), (-hw * 0.99, 1.15), (-hw + 0.07, 1.15),
                 (-hw + 0.07, 0.66)]
            return p + [(-x, z) for x, z in reversed(p)]

        def bed_mat(y, i):
            if i == 11:
                return "@under"
            if i in (4, 6):
                return "@plastic_black"
            if i == 5:
                return "@rubber_mat"
            return body
        loft(cage, loft_ys([yb0 + 0.03, yb1], arches, 5 if full else 4, yb0 + 0.03, yb1), bed_ring, bed_mat,
             caps=(body, body), crease=0.7)
    if full:
        c.body_obs.append(cage_object(cage, "_cage"))
        surf = Surf(c.body_obs[-1])
    else:
        surf = FlatSurf(sh)
    tw = 0.215 if shape in ("sedan", "hatchback", "coupe") else 0.235
    wh = Wheels(c, look)
    for k, y in enumerate(ax):
        wh.axle(y, r, tw, W, front=(k == 0), style=rims, spokes=spokes)
    s0 = sh.at(yf)
    hwf = W / 2 * s0[4]
    zf0, zfb = s0[1], s0[2]
    ind = lambda sd: look("ind_l" if sd > 0 else "ind_r")  # noqa: E731
    # --- front: lamps that wrap the rounded corners, grille with slats, fog lamps, plate
    if full:
        for sd in (-1, 1):
            # lamp unit: dark housing, a lit daytime strip along the top, two projector lenses
            xs = sorted((sd * hwf * 0.42, sd * hwf * 1.02))
            decal(mb, surf, "front", xs[0], xs[1], zfb - 0.115, zfb + 0.02, "@trim_black", nu=6, nv=2)
            decal(mb, surf, "front", xs[0], xs[1], zfb - 0.006, zfb + 0.012, look("head"), nu=6, nv=1, off=0.003)
            for u0, u1 in ((0.48, 0.64), (0.68, 0.84)):
                xs = sorted((sd * hwf * u0, sd * hwf * u1))
                decal(mb, surf, "front", xs[0], xs[1], zfb - 0.088, zfb - 0.02, "@Chrome", nu=1, nv=1, off=0.003)
                xs = sorted((sd * hwf * (u0 + 0.02), sd * hwf * (u1 - 0.02)))
                decal(mb, surf, "front", xs[0], xs[1], zfb - 0.08, zfb - 0.028, look("head"), nu=1, nv=1,
                      off=0.0045)
            xs = sorted((sd * hwf * 0.72, sd * hwf * 1.0))
            decal(mb, surf, "front", xs[0], xs[1], zfb - 0.15, zfb - 0.124, ind(sd), nu=4, nv=1)
            xs = sorted((sd * hwf * 0.66, sd * hwf * 0.84))
            decal(mb, surf, "front", xs[0], xs[1], zf0 + 0.015, zf0 + 0.06, "@lens_clear", nu=2, nv=1)
            xs = sorted((sd * hwf * 0.3, sd * hwf * 0.98))
            decal(mb, surf, "front", xs[0], xs[1], zf0 - 0.06, zf0 - 0.035, "@plastic_black", nu=5, nv=1, off=0.001)
            # side repeater on the front fender
            ya = ax[0] + r + 0.2
            zr_ = sh.at(ya)[2] - 0.11
            decal(mb, surf, ("side", sd), ya, ya + 0.06, zr_, zr_ + 0.022, ind(sd), nu=1, nv=1, off=0.003)
        zg0, zg1 = zf0 + 0.175, zfb - 0.045
        gw = 0.42 if shape not in ("van", "minibus") else 0.5
        decal(mb, surf, "front", -hwf * gw, hwf * gw, zg0, zg1, "@grille", nu=4, nv=1)
        slat = "@Chrome" if shape in ("sedan", "coupe", "suv") else "@trim_black"
        for k in range(3):
            zz = zg0 + 0.012 + k * (zg1 - zg0 - 0.03) / 2
            decal(mb, surf, "front", -hwf * (gw - 0.01), hwf * (gw - 0.01), zz, zz + 0.009, slat, nu=4, nv=1,
                  off=0.005)
        for z_a, z_b in ((zg1 - 0.004, zg1 + 0.008), (zg0 - 0.008, zg0 + 0.004)):
            decal(mb, surf, "front", -hwf * (gw + 0.01), hwf * (gw + 0.01), z_a, z_b, "@Chrome", nu=4, nv=1, off=0.004)
        decal(mb, surf, "front", -hwf * 0.66, hwf * 0.66, zf0 - 0.035, zf0 + 0.045, "@grille", nu=4, nv=1,
              off=0.0015)
        yp, _ = surf.front(0.0, zf0 + 0.11)
        plate(mb, look, 0.0, (yp if yp is not None else yf) - 0.003, zf0 + 0.11, face=-1)
    else:
        for sd in (-1, 1):
            xs = sorted((sd * hwf * 0.5, sd * hwf * 0.93))
            bx(mb, xs[0], yf - 0.01, zfb - 0.08, xs[1], yf + 0.05, zfb, look("head"))
            xs = sorted((sd * hwf * 0.74, sd * hwf * 0.92))
            bx(mb, xs[0], yf - 0.012, zfb - 0.12, xs[1], yf + 0.04, zfb - 0.085, ind(sd))
        bx(mb, -hwf * 0.4, yf - 0.008, zf0 + 0.15, hwf * 0.4, yf + 0.04, zfb - 0.02, "@grille")
        plate(mb, look, 0.0, yf - 0.002, zf0 + 0.1, face=-1)
    # --- rear: wrap-around tail lamps, brake and indicator bands, reversing lamps, plate, diffuser, exhaust
    if shape != "pickup":
        se = sh.at(yr)
        hwr = W / 2 * se[4]
        zr0, zrb = se[1], se[2]
        if van_like:
            zrb = zr0 + 0.62
        if full:
            for sd in (-1, 1):
                xs = sorted((sd * hwr * 0.5, sd * hwr * 1.02))
                if van_like:
                    xs = sorted((sd * hwr * 0.76, sd * hwr * 0.95))
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.08, zrb + 0.25, look("tail"), nu=2, nv=3)
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.2, zrb - 0.085, look("brake"), nu=2, nv=1)
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.3, zrb - 0.205, ind(sd), nu=2, nv=1)
                else:
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.075, zrb + 0.005, look("tail"), nu=6, nv=2)
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.13, zrb - 0.08, look("brake"), nu=6, nv=1)
                    xs = sorted((sd * hwr * 0.72, sd * hwr * 1.0))
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.165, zrb - 0.135, ind(sd), nu=3, nv=1)
                    xs = sorted((sd * hwr * 0.52, sd * hwr * 0.68))
                    decal(mb, surf, "rear", xs[0], xs[1], zrb - 0.165, zrb - 0.135, "@lens_clear", nu=2, nv=1)
                xs = sorted((sd * hwr * 0.2, sd * hwr * 0.98))
                decal(mb, surf, "rear", xs[0], xs[1], zr0 - 0.05, zr0 + 0.02, "@plastic_black", nu=5, nv=1, off=0.001)
            if van_like:
                # twin rear doors: dark rear glass, the centre split and a handle
                zg0, zg1 = se[2] + 0.04, se[3] - 0.12
                decal(mb, surf, "rear", -hwr * 0.7, hwr * 0.7, zg0, zg1, "@glass_dark", nu=6, nv=3, off=0.003)
                decal(mb, surf, "rear", -0.005, 0.005, zr0 + 0.06, se[3] - 0.06, "@trim_black", nu=1, nv=8,
                      off=0.0035)
                decal(mb, surf, "rear", 0.03, 0.17, zg0 - 0.12, zg0 - 0.08, "@Chrome", nu=2, nv=1, off=0.004)
            yp, _ = surf.rear(0.0, zr0 + 0.1)
            plate(mb, look, 0.0, (yp if yp is not None else yr) + 0.003, zr0 + 0.12, face=1)
            mb.cyl((-hwr * 0.6 * S, (yr - 0.16) * S, (zr0 - 0.03) * S), 0.035 * S, 0.14 * S, "@Chrome", n=8,
                   axis=Matrix.Rotation(-math.pi / 2, 4, "X"), smooth=False)
        else:
            for sd in (-1, 1):
                xs = sorted((sd * hwr * 0.55, sd * hwr * 0.95))
                bx(mb, xs[0], yr - 0.05, zrb - 0.13, xs[1], yr + 0.01, zrb - 0.02, look("tail"))
            plate(mb, look, 0.0, yr, zr0 + 0.12, face=1)
    else:
        yb1 = sh.sp["L"] / 2
        hw = W / 2
        for sd in (-1, 1):
            xs = sorted((sd * hw * 0.62, sd * hw * 0.97))
            bx(mb, xs[0], yb1 - 0.01, 0.92, xs[1], yb1 + 0.012, 1.08, look("tail"))
            bx(mb, xs[0], yb1 - 0.01, 0.82, xs[1], yb1 + 0.012, 0.92, look("brake"))
            xs = sorted((sd * hw * 0.5, sd * hw * 0.62))
            bx(mb, xs[0], yb1 - 0.01, 0.82, xs[1], yb1 + 0.012, 1.08, ind(sd))
        bx(mb, -hw * 0.95, yb1, 0.3, hw * 0.95, yb1 + 0.08, 0.45, "@Chrome")
        plate(mb, look, 0.0, yb1 + 0.012, 0.6, face=1)
        if full:
            bx(mb, -0.32, yb1 + 0.012, 1.0, 0.32, yb1 + 0.016, 1.1, "@trim_black")
    # --- mirrors, belt trim, shut lines, handles, wipers, antenna
    iw = sh.tags.index("W")
    yw0, yw1 = st[iw][0], st[iw + 1][0]
    ym = yw0 + (yw1 - yw0) * 0.5
    zb_m = sh.at(ym)[2]
    for sd in (-1, 1):
        xm, _ = surf.side(sd, ym, zb_m - 0.03)
        xm = xm if xm is not None else sd * sh.hw(ym)
        mirror(mb, look, xm - sd * 0.01, ym, zb_m + 0.015, sd, body)
    if full:
        trim = "@Chrome" if shape in ("sedan", "coupe") else "@trim_black"
        for k in [k for k, t in enumerate(sh.tags) if t == "G"]:
            y0, y1 = st[k][0], st[k + 1][0]
            zb0 = (sh.at(y0)[2] + sh.at(y1)[2]) / 2
            for sd in (-1, 1):
                decal(mb, surf, ("side", sd), y0 + 0.01, y1 - 0.01, zb0 - 0.016, zb0 + 0.004, trim,
                      nu=max(1, int((y1 - y0) / 0.25)), nv=1, off=0.0025)
        lines = [ax[0] + r + 0.12]
        if "P" in sh.tags and shape != "van":
            pk = sh.tags.index("P")
            lines.append((st[pk][0] + st[pk + 1][0]) / 2 + 0.03)
        if shape in ("sedan", "hatchback", "suv", "pickup", "minibus"):
            lines.append(ax[1] - r - 0.1 if shape != "pickup" else yr - 0.04)
        if shape == "coupe":
            lines = [ax[0] + r + 0.12, ax[1] - r - 0.35]
        for y in lines:
            zs, zb_ = sh.at(y)[1], sh.at(y)[2]
            for sd in (-1, 1):
                decal(mb, surf, ("side", sd), y - 0.003, y + 0.003, zs + 0.1, zb_ - 0.015, "@trim_black", nu=1, nv=5,
                      off=0.0012)
        hz = sh.at(lines[0] + 0.3)[2] - 0.075
        hm = "@Chrome" if shape in ("sedan", "coupe") else body
        hy = [y - 0.24 for y in lines[1:]] if len(lines) > 1 else [lines[0] + 0.75]
        for y in hy:
            for sd in (-1, 1):
                xh, _ = surf.side(sd, y, hz)
                if xh is not None:
                    xs = sorted((xh - sd * 0.003, xh + sd * 0.012))
                    bx(mb, xs[0], y - 0.08, hz - 0.016, xs[1], y + 0.08, hz + 0.016, hm)
        zc, _ = surf.top(0.0, yw0 + 0.06)
        if zc is not None:
            for x0 in (-0.55, 0.05):
                z1, _ = surf.top(x0 + 0.25, yw0 + 0.06)
                zz = (z1 if z1 is not None else zc) + 0.005
                bx(mb, x0, yw0 + 0.03, zz, x0 + 0.5, yw0 + 0.05, zz + 0.012, "@trim_black")
        if "B" in sh.tags and shape != "pickup":
            yb_r = st[sh.tags.index("B")][0] - 0.12
            zt_, _ = surf.top(0.0, yb_r)
            if zt_ is not None:
                fin(mb, yb_r, zt_ - 0.004, body)
        if shape in ("sedan", "hatchback", "suv"):
            bk = sh.tags.index("B")
            yb_top = st[bk][0]
            zz = st[bk][3] - 0.04
            bx(mb, -0.15, yb_top + 0.06, zz - 0.035, 0.15, yb_top + 0.08, zz, look("brake"))
    # --- taxi and police kit
    roof_s = max(st, key=lambda s_: s_[3])
    yroof = roof_s[0]
    zroof, _ = surf.top(0.0, yroof)
    zroof = (zroof if zroof is not None else roof_s[3] + roof_s[6]) + 0.01
    ya0, ya1 = arches[0].y + arches[0].R + 0.04, arches[1].y - arches[1].R - 0.04
    if taxi:
        bx(mb, -0.3, yroof - 0.13, zroof - 0.02, 0.3, yroof + 0.13, zroof + 0.03, "@plastic_black")
        bx(mb, -0.27, yroof - 0.1, zroof + 0.03, 0.27, yroof + 0.1, zroof + 0.22, "@taxi_sign")
        nk = int((ya1 - ya0) / 0.11)
        for sd in (-1, 1):
            for k in range(nk):
                y0 = ya0 + k * 0.11
                zc_ = sh.at(y0)[2] - 0.2
                decal(mb, surf, ("side", sd), y0, y0 + 0.11, zc_, zc_ + 0.08,
                      "@plastic_black" if k % 2 == 0 else "@Sign_White", nu=1, nv=1, off=0.002)
    if police:
        bx(mb, -0.6, yroof - 0.14, zroof - 0.02, 0.6, yroof + 0.14, zroof + 0.04, "@Metal_Dark")
        siren_pair(c, look, 0.0, yroof, zroof + 0.04, w=1.2)
        zc_ = sh.at((ya0 + ya1) / 2)[2] - 0.2
        for sd in (-1, 1):
            decal(mb, surf, ("side", sd), ya0, ya1, zc_, zc_ + 0.1, "@Sign_Blue", nu=8, nv=1, off=0.002)
            decal(mb, surf, ("side", sd), ya0, ya1, zc_ + 0.1, zc_ + 0.115, "@Sign_White", nu=8, nv=1, off=0.002)
        bx(mb, -0.45, yf - 0.14, zf0 + 0.02, 0.45, yf - 0.1, zf0 + 0.3, "@Metal_Dark")
    # --- cabin (full and baked only)
    hip = None
    if full:
        hip = cabin(c, look, sh, shape, arches, interior)
    wh.emit(mb)
    return hip


def siren_pair(c, look, x, y, z, w=1.2, n0=0, mats=("@siren_red", "@siren_blue")):
    """Light-bar lenses: Siren_<n> objects (full), or merged geometry."""
    for k in range(2):
        cx = x + (k - 0.5) * w * 0.5
        if look.full:
            mb = MB()
            mb.box((0, 0, 0.06 * S), (w * 0.48 * S, 0.24 * S, 0.12 * S), mats[k])
            atlas.resolve(mb)
            ob = mb.build("Siren_%d" % (n0 + k))
            ob.location = (cx * S, y * S, z * S)
        else:
            bc(c.mb, (cx, y, z + 0.06), (w * 0.48, 0.24, 0.12), mats[k])


def siren_at(c, look, n, x, y, z, sx, sy, sz, mat):
    if look.full:
        mb = MB()
        mb.box((0, 0, sz / 2 * S), (sx * S, sy * S, sz * S), mat)
        atlas.resolve(mb)
        ob = mb.build("Siren_%d" % n)
        ob.location = (x * S, y * S, z * S)
    else:
        bc(c.mb, (x, y, z + sz / 2), (sx, sy, sz), mat)


def cabin(c, look, sh, shape, arches, interior):
    """Inner shell (door cards, pillar trims, headliner, carpet), dashboard, seats and wheel.
    Returns the driver's hip point (metres, Blender axes)."""
    mb = c.mb
    st, tags, W = sh.st, sh.tags, sh.W
    iw = tags.index("W")
    y_cowl, y_wtop = st[iw][0], st[iw + 1][0]
    front_end = arches[0].y + arches[0].R + 0.03
    y0 = max(y_cowl, min(front_end, y_wtop - 0.1))
    if shape in ("van",):
        k = tags.index("G")
        y1 = st[k + 1][0] + 0.25
    else:
        last = max(k for k, t in enumerate(tags) if t in "GPB")
        y1 = st[last + 1][0]
    van_like = shape in ("van", "minibus", "pickup", "suv")
    hip_y = y_wtop + (0.38 if van_like else 0.3)
    sill = sh.at(hip_y)[1]
    hip_z = sill + (0.4 if van_like else 0.3)
    floor = sill + 0.1
    trim = "@" + ("int_grey" if interior != "int_tan" else "int_tan")

    def iring(y):
        _, zs, zb, zr, wf, wrf, band = sh.at(y)
        hw, hr = W / 2 * wf, W / 2 * wrf
        zt = zr + band
        cr = 0.035 if zr - zb > 0.25 else 0.012
        xb = hw * 0.975 - 0.05
        xt = max(hr - 0.045, 0.1)
        left = [(-xb, floor), (-xb, zb - 0.025), (-xt, zr - 0.02), (-xt * 0.75, zt + cr * 0.6 - 0.045)]
        return left + [(-x, z) for x, z in reversed(left)]

    def imat(y, i):
        t = sh.tag(y)
        if i in (0, 6):
            return trim
        if i in (1, 5):
            return None if t == "G" else "@int_light"
        if i in (2, 3, 4):
            return None if t in "WB" else "@int_light"
        return "@int_dark"
    ys = [y for y in loft_ys([s[0] for s in st], [], 1, y0, y1)]
    if ys[0] > y0 + 1e-4:
        ys.insert(0, y0)
    if ys[-1] < y1 - 1e-4:
        ys.append(y1)
    loft(mb, ys, iring, imat, caps=(None, "@int_dark"), inward=True)
    # dashboard, instrument hood, console
    zb_c = sh.at(y_cowl + 0.25)[2]
    xd = W / 2 * 0.42
    xin = sh.hw(y_cowl + 0.2) * 0.975 - 0.06
    bx(mb, -xin, y_cowl - 0.1, hip_z + 0.02, xin, y_cowl + 0.42, zb_c + 0.02, "@dash")
    bx(mb, xd - 0.2, y_cowl + 0.25, zb_c + 0.02, xd + 0.2, y_cowl + 0.4, zb_c + 0.07, "@dash")
    bx(mb, -0.11, y_cowl + 0.4, floor, 0.11, hip_y + 0.25, hip_z - 0.02, "@dash")
    steering_wheel(mb, xd, hip_y - 0.55, hip_z + 0.36)
    seat_mat = "@" + interior
    for sd in (1, -1):
        seat(mb, sd * xd, hip_y, hip_z, mat=seat_mat)
    yb0 = hip_y + (0.8 if shape != "coupe" else 0.7)
    rear_room = y1 - yb0
    if shape not in ("van",) and rear_room > 0.25 and shape != "pickup" or (shape == "pickup" and rear_room > 0.4):
        wb = min(W / 2 * 0.62, sh.hw(yb0) - 0.15)
        bx(mb, -wb, yb0 - 0.25, hip_z - 0.16, wb, yb0 + 0.2, hip_z - 0.04, seat_mat)
        mb.push(Matrix.Translation(Vector((0, (yb0 + 0.16) * S, (hip_z - 0.08) * S))) @ RX(math.radians(-18)))
        mb.box((0, 0.05 * S, 0.3 * S), (wb * 2 * S, 0.12 * S, 0.6 * S), seat_mat)
        for sx in (-wb * 0.6, wb * 0.6):
            mb.box((sx * S, 0.07 * S, 0.68 * S), (0.26 * S, 0.1 * S, 0.18 * S), seat_mat)
        mb.pop()
    if shape == "minibus":
        for k in range(1, 3):
            yy = yb0 + k * 0.85
            if yy + 0.3 > y1:
                break
            wb = W / 2 * 0.62
            bx(mb, -wb, yy - 0.25, hip_z - 0.16, wb, yy + 0.2, hip_z - 0.04, seat_mat)
            bx(mb, -wb, yy + 0.16, hip_z - 0.08, wb, yy + 0.28, hip_z + 0.52, seat_mat)
    if "T" in tags:
        # parcel shelf under the rear window
        bk = tags.index("B")
        ya, yb = st[bk][0], st[bk + 1][0]
        zb = sh.at(yb)[2]
        xs = sh.hw(yb) * 0.975 - 0.06
        bx(mb, -xs, ya, zb - 0.03, xs, yb, zb - 0.01, "@int_dark")
    if shape == "van":
        xb = sh.hw(y1) * 0.975 - 0.05
        bx(mb, -xb, y1 - 0.03, floor, xb, y1, sh.at(y1)[3], "@int_grey")
    at_seat = sh.at(hip_y)
    ceil = at_seat[3] + at_seat[6]
    ceil += (0.035 if ceil - at_seat[2] > 0.25 else 0.012) * 0.6 - 0.045
    driver_points(look, (xd, hip_y, hip_z), floor, (xd, hip_y - 0.55, hip_z + 0.36, 0.19, -64.0), ceil,
                  fwd=0.5 if van_like else 0.45)
    return (xd, hip_y, hip_z)


# ----------------------------------------------------------------------------- heavy vehicles

def box_body(mb, look, y0, y1, hw, zb, zt, arches, mat_fn, r_top=0.12, caps=("x", "x"), steps=8):
    """Box-section loft (rounded top edges) from y0 to y1 with wheel arches cut into the bottom."""
    def ring(y):
        z0 = arch_bottom(y, arches, zb)
        p = [(-hw, z0), (-hw, zt - r_top), (-hw * 0.985, zt - r_top * 0.3), (-hw * 0.94, zt)]
        return p + [(-x, z) for x, z in reversed(p)]
    ys = loft_ys([y0, y1], arches, 4, y0, y1)
    c0 = mat_fn(y0, -1) if caps[0] else None
    c1 = mat_fn(y1, -2) if caps[1] else None
    return loft(mb, ys, ring, mat_fn, caps=(c0, c1))


def cab_over(c, look, y0, W, Lc, wheel_y, wheel_r, roof=2.6, belt=1.32, z0=0.5, crew=False, mats=None):
    """Cab-over-engine truck cab with the front wheel arch cut in. Returns (front face y, hip)."""
    mb = c.mb
    mats = dict(mats or {})
    if crew:
        st = [(y0, z0 + .05, belt - .07, belt - .02, .96, .9, .02), (y0 + .16, z0, belt, roof, .99, .95, .14),
              (y0 + .95, z0, belt, roof, 1, .95, .14), (y0 + 1.1, z0, belt, roof, 1, .95, .14),
              (y0 + Lc - .25, z0, belt, roof, 1, .95, .14), (y0 + Lc, z0, belt, roof, 1, .95, .14)]
        tags = "WGPGP"
    else:
        st = [(y0, z0 + .05, belt - .07, belt - .02, .96, .9, .02), (y0 + .16, z0, belt, roof, .99, .95, .14),
              (y0 + Lc * .55, z0, belt, roof, 1, .95, .14), (y0 + Lc, z0, belt, roof, 1, .95, .14)]
        tags = "WGP"
    sh = Shape({"st": st, "tags": tags, "W": W, "r": wheel_r, "axles": (wheel_y, 0.0), "L": Lc})
    arches = [Arch(wheel_y, wheel_r, 0.07)]
    ring = car_ring(sh, arches, look.full, crown=0.05)
    ys = loft_ys([s[0] for s in st], arches, 4, st[0][0], st[-1][0])
    body = look(mats.get("body", "paint"))
    loft(c.cage if look.full else mb, ys, ring, car_mats(sh, look, mats, look.full), caps=(body, body),
         inset=0.35 if look.full else 0.0, crease=0.5)
    hw = W / 2 * .96
    bx(mb, -hw * .7, y0 - .015, z0 + .25, hw * .7, y0 + .1, belt - .15, "@grille")
    for sd in (-1, 1):
        xa, xb = sd * hw * .72, sd * hw * .97
        bx(mb, min(xa, xb), y0 - .02, z0 + .3, max(xa, xb), y0 + .1, z0 + .48, look("head"))
        bx(mb, min(sd * hw * .76, xb), y0 - .02, z0 + .52, max(sd * hw * .76, xb), y0 + .1, z0 + .62,
           look("ind_l" if sd > 0 else "ind_r"))
        # mirror on an arm, kept inside the 2.6 m envelope
        xm = sd * W / 2
        bx(mb, min(xm, xm + sd * 0.04), y0 + .45, belt + .1, max(xm, xm + sd * 0.04), y0 + .55, belt + .15, "@Metal_Dark")
        bx(mb, min(xm + sd * 0.02, xm + sd * 0.06), y0 + .4, belt + .05, max(xm + sd * 0.02, xm + sd * 0.06), y0 + .6,
           belt + .6, "@Metal_Dark")
        if look.full:
            quad(mb, [(xm + sd * 0.025, y0 + .601, belt + .08), (xm + sd * 0.055, y0 + .601, belt + .08),
                      (xm + sd * 0.055, y0 + .601, belt + .57), (xm + sd * 0.025, y0 + .601, belt + .57)],
                 "@mirror", out=(0, 1, 0))
        # step
        bx(mb, min(sd * (W / 2 - 0.05), sd * (W / 2 + 0.01)), y0 + 0.75, z0 - 0.15, max(sd * (W / 2 - 0.05), sd * (W / 2 + 0.01)),
           y0 + 1.3, z0 - 0.12, "@Metal_Galv")
    bx(mb, -W / 2, y0 - .06, z0 - .15, W / 2, y0 + .12, z0 + .12, "@Metal_Dark")
    plate(mb, look, 0.0, y0 - 0.06, z0 - 0.03, face=-1)
    hip = None
    if look.full:
        # cab interior: shell, dash, seats, wheel
        floor = z0 + 0.25
        y_in0, y_in1 = y0 + 0.25, y0 + Lc - 0.08
        xb = W / 2 * 0.95
        for sd in (-1, 1):
            quad(mb, [(sd * xb, y_in0, floor), (sd * xb, y_in1, floor), (sd * xb, y_in1, belt - 0.02),
                      (sd * xb, y_in0, belt - 0.02)], "@int_grey", out=(-sd, 0, 0))
        quad(mb, [(-xb, y_in0, floor), (xb, y_in0, floor), (xb, y_in1, floor), (-xb, y_in1, floor)], "@int_dark",
             out=(0, 0, 1))
        quad(mb, [(-xb, y_in0, roof - 0.05), (xb, y_in0, roof - 0.05), (xb, y_in1, roof - 0.05),
                  (-xb, y_in1, roof - 0.05)], "@int_light", out=(0, 0, -1))
        quad(mb, [(-xb, y_in1, floor), (xb, y_in1, floor), (xb, y_in1, roof - 0.05), (-xb, y_in1, roof - 0.05)],
             "@int_grey", out=(0, -1, 0))
        bx(mb, -xb, y0 + 0.2, belt - 0.35, xb, y0 + 0.6, belt + 0.02, "@dash")
        xd = W / 2 * 0.5
        hip_z = floor + 0.5
        hip_y = y0 + 1.25
        steering_wheel(mb, xd, hip_y - 0.55, hip_z + 0.38, R=0.23, tilt=-35)
        for sd in (1, -1):
            seat(mb, sd * xd, hip_y, hip_z, w=0.55, mat="@int_dark", tilt=-10, back_h=0.7)
        hip = (xd, hip_y, hip_z)
        driver_points(look, hip, floor, (xd, hip_y - 0.55, hip_z + 0.38, 0.23, -35.0), roof - 0.05, fwd=0.55)
    return hip


def truck_rear(mb, look, x, y, zt, sd):
    """Tail-light cluster on a heavy vehicle's rear: tail, brake and indicator stacked."""
    xa, xb = sd * x, sd * (x - 0.22)
    bx(mb, min(xa, xb), y - 0.03, zt + 0.1, max(xa, xb), y + 0.03, zt + 0.2, look("tail"))
    bx(mb, min(xa, xb), y - 0.03, zt, max(xa, xb), y + 0.03, zt + 0.1, look("brake"))
    bx(mb, min(xa, xb), y - 0.03, zt - 0.1, max(xa, xb), y + 0.03, zt, look("ind_l" if sd > 0 else "ind_r"))


def mud_flaps(mb, y, x, z0=0.15, z1=0.7, hw=0.3):
    for sd in (-1, 1):
        bx(mb, sd * x - hw, y, z0, sd * x + hw, y + 0.02, z1, "@rubber_mat")


def truck(c, look):
    mb = c.mb
    L, W = 8.0, 2.4
    y0 = -L / 2
    fy, ry, R = y0 + 1.05, L / 2 - 1.7, 0.5
    hip = cab_over(c, look, y0, W, 2.0, fy, R)
    bx(mb, -W * .3, y0 + .5, .43, W * .3, L / 2 - .2, .67, "@Metal_Dark")
    yb = y0 + 2.15
    hw = W / 2
    box = "@box_white"
    bx(mb, -hw, yb, 1.05, hw, L / 2, 3.6, box)
    for sd in (-1, 1):
        bx(mb, min(sd * hw, sd * (hw + .006)), yb + .3, 2.6, max(sd * hw, sd * (hw + .006)), L / 2 - .3, 3.0,
           "@Sign_Blue")
        # rear door seams and lock bars
        bx(mb, sd * 0.01 - 0.01, L / 2, 1.1, sd * 0.01 + 0.01, L / 2 + .012, 3.55, "@Metal_Galv")
        for k in range(2):
            xx = sd * (0.3 + k * 0.55)
            bx(mb, xx - 0.025, L / 2, 1.15, xx + 0.025, L / 2 + .03, 3.5, "@Metal_Galv")
        truck_rear(mb, look, hw * .97, L / 2, .85, sd)
        mb.cyl((sd * W * .3 * S, (y0 + 2.6) * S, .55 * S), .3 * S, .9 * S, "@Chrome", n=12,
               axis=Matrix.Rotation(-math.pi / 2, 4, "X"))
        bx(mb, min(sd * hw * .96, sd * hw * .99), y0 + 3.4, .55, max(sd * hw * .96, sd * hw * .99), L / 2 - 2.3, .65,
           "@Metal_Galv")
    bx(mb, -hw + .05, L / 2 - .05, .45, hw - .05, L / 2 + .05, .6, "@Metal_Dark")
    plate(mb, look, 0.0, L / 2 + 0.05, 0.75, face=1)
    mud_flaps(mb, L / 2 - 1.0, hw - 0.3)
    wh = Wheels(c, look)
    wh.axle(fy, R, .32, W, True, style="steel")
    wh.axle(ry, R, .3, W, False, style="steel", dual=True)
    wh.emit(mb)
    return hip


def garbage_truck(c, look):
    mb = c.mb
    L, W = 9.0, 2.4
    y0 = -L / 2
    fy, ry, R = y0 + 1.05, L / 2 - 2.3, 0.5
    hip = cab_over(c, look, y0, W, 2.0, fy, R, mats={"body": "paint:Paint_white", "lower": "paint"})
    bx(mb, -W * .3, y0 + .5, .43, W * .3, L / 2 - .5, .67, "@Metal_Dark")
    yb, ye = y0 + 2.15, L / 2 - 1.4
    hw = W / 2
    body = look("paint")
    arches = [Arch(ry, R, 0.08)]

    def mats(y, i):
        if i == 7:
            return "@under"
        return body
    box_body(mb, look, yb, ye, hw, 0.95, 3.3, arches, mats, r_top=0.45)

    def hopper(y, i):
        return "@Metal_Dark" if i in (7, -2) else body
    box_body(mb, look, ye, L / 2, hw * 0.98, 0.8, 3.2, [], hopper, r_top=0.5)
    for sd in (-1, 1):
        bx(mb, min(sd * hw, sd * (hw + .008)), yb + .2, 1.5, max(sd * hw, sd * (hw + .008)), ye - .2, 1.68,
           "@Reflective_White")
        truck_rear(mb, look, hw * .95, L / 2 + 0.02, .85, sd)
        bc(mb, (sd * hw * .5, ye + .75, 3.3), (0.16, 0.3, 0.16), "@lens_amber")
    bx(mb, -hw * .8, L / 2 - .1, .9, hw * .8, L / 2 + .25, 1.3, "@Metal_Galv")
    bx(mb, -hw * .8, L / 2 + .2, .5, hw * .8, L / 2 + .3, .95, "@Metal_Dark")
    plate(mb, look, 0.0, L / 2 + 0.31, 0.65, face=1)
    wh = Wheels(c, look)
    wh.axle(fy, R, .32, W, True, style="steel")
    wh.axle(ry, R, .3, W, False, style="steel", dual=True)
    wh.emit(mb)
    return hip


def firetruck(c, look):
    mb = c.mb
    L, W = 9.6, 2.45
    y0 = -L / 2
    fy, ry, R = y0 + 1.3, L / 2 - 1.9, 0.52
    hip = cab_over(c, look, y0, W, 2.7, fy, R, roof=2.7, crew=True, mats={"roof": "paint:Paint_white"})
    bx(mb, -W * .3, y0 + .5, .43, W * .3, L / 2 - .2, .67, "@Metal_Dark")
    yb = y0 + 2.8
    hw = W / 2
    body = look("paint")
    arches = [Arch(ry, R, 0.08)]

    def mats(y, i):
        if i == 7:
            return "@under"
        if i == 3:
            return "@Steel_White"
        return body
    box_body(mb, look, yb, L / 2, hw, 0.7, 2.75, arches, mats, r_top=0.05)
    for sd in (-1, 1):
        x = sd * hw
        for k in range(3):
            ya = yb + .25 + k * 1.95
            if ya < ry - R - 0.1 < ya + 1.7 or ya < ry + R + 0.1 < ya + 1.7:
                continue
            if not look.full:
                continue
            bx(mb, min(x, x + sd * .02), ya, 1.05, max(x, x + sd * .02), ya + 1.7, 2.6, "@shutter")
            if look.full:
                for j in range(12):
                    zz = 1.1 + j * 0.125
                    bx(mb, min(x + sd * .02, x + sd * .024), ya + 0.03, zz, max(x + sd * .02, x + sd * .024), ya + 1.67,
                       zz + 0.012, "@Metal_Galv")
        bx(mb, min(x, x + sd * .025), yb, .78, max(x, x + sd * .025), L / 2, .95, "@Reflective_White")
        bx(mb, min(sd * (hw + .01), sd * (hw + .025)), y0 + .2, .62, max(sd * (hw + .01), sd * (hw + .025)),
           y0 + 2.7, .74, "@Reflective_White")
        truck_rear(mb, look, hw * .95, L / 2 + 0.03, 1.0, sd)
    zl = 3.0
    for sd in (-1, 1):
        bx(mb, sd * .5 - .05, y0 + .4, zl, sd * .5 + .05, L / 2 - .4, zl + .16, "@Metal_Galv")
        bx(mb, sd * .7 - .06, L / 2 - 1.6, 2.75, sd * .7 + .06, L / 2 - 1.3, zl + .05, "@Metal_Galv")
        bx(mb, sd * .6 - .05, y0 + .6, 2.7, sd * .6 + .05, y0 + .8, zl + .02, "@Metal_Galv")
    n = 22 if look.full else 0
    for k in range(n):
        yy = y0 + .6 + k * (L - 1.2) / (n - 1)
        bx(mb, -.45, yy - .03, zl + .05, .45, yy + .03, zl + .1, "@Metal_Galv")
    mb.cyl((0, (L / 2 - 1.45) * S, 2.75 * S), .75 * S, .2 * S, "@Metal_Dark", n=14)
    plate(mb, look, 0.0, L / 2 + 0.01, 0.6, face=1)
    siren_pair(c, look, 0, y0 + .5, 2.7 + .02, w=1.6, mats=("@siren_red", "@siren_red"))
    for k, sd in enumerate((-1, 1)):
        siren_at(c, look, 2 + k, sd * (hw - .2), L / 2 - .25, 2.75, .25, .25, .2,
                 "@siren_blue" if k else "@siren_red")
    wh = Wheels(c, look)
    wh.axle(fy, R, .34, W, True, style="steel")
    wh.axle(ry, R, .3, W, False, style="steel", dual=True)
    wh.emit(mb)
    return hip


def ambulance(c, look):
    mb = c.mb
    W, Wb = 2.05, 2.3
    fy, ry, R = -2.0, 2.0, 0.36
    st = [(-3.1, .40, .80, .84, .88, .80), (-2.95, .34, .95, .98, .97, .90), (-2.3, .33, 1.10, 1.14, 1.0, .92),
          (-1.55, .33, 1.15, 2.0, 1.0, .90, .05), (-0.9, .33, 1.15, 2.02, 1.0, .90, .05)]
    sh = Shape({"st": st, "tags": "XHWG", "W": W, "r": R, "axles": (fy, ry), "L": 6.2})
    arches_f = [Arch(fy, R)]
    ring = car_ring(sh, arches_f, look.full)
    ys = loft_ys([s[0] for s in st], arches_f, 4, -3.1, -0.9)
    body = look("paint")
    loft(c.cage if look.full else mb, ys, ring, car_mats(sh, look, {}, look.full), caps=(body, body),
         inset=0.4 if look.full else 0.0)
    yf, hwf = -3.1, W / 2 * .88
    bx(mb, -hwf * .55, yf - .012, .44, hwf * .55, yf + .1, .62, "@grille")
    bx(mb, -hwf * .97, yf - .03, .36, hwf * .97, yf + .1, .5, "@plastic_black")
    for sd in (-1, 1):
        xa, xb = sd * hwf * .58, sd * hwf * .96
        bx(mb, min(xa, xb), yf - .012, .66, max(xa, xb), yf + .12, .8, look("head"))
        bx(mb, min(sd * hwf * .72, xb), yf - .034, .52, max(sd * hwf * .72, xb), yf - .02, .58,
           look("ind_l" if sd > 0 else "ind_r"))
        mirror(mb, look, sd * W / 2 * .97, -2.05, 1.15, sd, body, arm=0.06, w=0.13, h=0.28)
    plate(mb, look, 0.0, yf - 0.034, 0.43, face=-1)
    hb = Wb / 2
    yb0, yb1 = -1.0, 3.1
    arches_r = [Arch(ry, R, 0.07)]

    def mats(y, i):
        if i == 7:
            return "@under"
        return body
    box_body(mb, look, yb0, yb1, hb, 0.45, 2.85, arches_r, mats, r_top=0.12)
    for sd in (-1, 1):
        x = sd * hb
        bx(mb, min(x, x + sd * .012), yb0, 1.0, max(x, x + sd * .012), yb1, 1.3, "@Sign_Red")
        bx(mb, min(x, x + sd * .012), yb0, 1.3, max(x, x + sd * .012), yb1, 1.42, "@reflective_yellow")
        bx(mb, min(x, x + sd * .012), .2, 1.6, max(x, x + sd * .012), 1.4, 2.3, look("glass"))
        truck_rear(mb, look, hb * .92, yb1 + 0.01, .85, sd)
        bx(mb, sd * .05, yb1, 1.6, sd * hb * .8, yb1 + .02, 2.4, look("glass"))
    bx(mb, -hb, yb1, 1.0, hb, yb1 + .014, 1.3, "@Sign_Red")
    bx(mb, -hb * 0.95, yb1 - 0.02, 0.3, hb * 0.95, yb1 + 0.08, 0.45, "@plastic_black")
    plate(mb, look, 0.0, yb1 + 0.015, 0.6, face=1)
    hip = None
    if look.full:
        # cab interior plus the treatment room seen through the rear glass
        xb = hb - 0.05
        quad(mb, [(-xb, 0.0, 2.75), (xb, 0.0, 2.75), (xb, yb1 - 0.03, 2.75), (-xb, yb1 - 0.03, 2.75)], "@int_light",
             out=(0, 0, -1))
        for sd in (-1, 1):
            quad(mb, [(sd * xb, 0.0, 0.8), (sd * xb, yb1 - 0.03, 0.8), (sd * xb, yb1 - 0.03, 2.75),
                      (sd * xb, 0.0, 2.75)], "@int_light", out=(-sd, 0, 0))
        quad(mb, [(-xb, 0.0, 0.8), (xb, 0.0, 0.8), (xb, yb1 - 0.03, 0.8), (-xb, yb1 - 0.03, 0.8)], "@floor_grey",
             out=(0, 0, 1))
        quad(mb, [(-xb, 0.0, 0.8), (xb, 0.0, 0.8), (xb, 0.0, 2.75), (-xb, 0.0, 2.75)], "@int_light", out=(0, 1, 0))
        bx(mb, -0.3, 1.0, 0.8, 0.3, 2.9, 1.25, "@int_light")
        bx(mb, -0.32, 1.0, 1.25, 0.32, 2.9, 1.32, "@Sign_Blue")
        hip = cabin(c, look, sh, "van", arches_f, "int_dark")
    light = 2.02 + 0.05
    siren_pair(c, look, 0, -1.25, light, w=1.4)
    for k, sd in enumerate((-1, 1)):
        siren_at(c, look, 2 + k, sd * (hb - .15), yb1 - .2, 2.85, .2, .2, .14, "@siren_red" if k else "@siren_blue")
    wh = Wheels(c, look)
    wh.axle(fy, R, .23, W, True)
    wh.axle(ry, R, .23, Wb - 0.1, False, style="steel")
    wh.emit(mb)
    return hip


def bus(c, look):
    mb = c.mb
    L, W = 12.0, 2.45
    y0 = -L / 2
    fy, ry, R = y0 + 2.6, L / 2 - 3.3, 0.5
    st = [(y0, .40, .95, 1.0, .97, .95, .05), (y0 + .16, .32, 1.0, 2.62, 1, .985, .4),
          (L / 2 - .25, .32, 1.0, 2.62, 1, .985, .4), (L / 2, .38, 1.0, 2.55, .98, .965, .4)]
    sh = Shape({"st": st, "tags": "WGP", "W": W, "r": R, "axles": (fy, ry), "L": L})
    arches = [Arch(fy, R, 0.08), Arch(ry, R, 0.08)]
    ring = car_ring(sh, arches, look.full, crown=0.06)
    ys = loft_ys([s[0] for s in st], arches, 4, y0, L / 2)
    band = "paint:Paint_white"
    body = look("paint")
    loft(c.cage if look.full else mb, ys, ring, car_mats(sh, look, {"band": band, "roof": band}, look.full),
         caps=(body, body), inset=0.3 if look.full else 0.0, crease=0.6)
    hw = W / 2
    doors = (y0 + .9, 0.2)
    for sd in (-1, 1) if look.full else ():
        x = sd * hw * .995
        for k in range(9):
            yy = y0 + 1.4 + k * 1.3
            if sd < 0 and any(abs(yy - yd) < .8 for yd in doors):
                continue
            bx(mb, min(x, x + sd * .03), yy - .05, 1.0, max(x, x + sd * .03), yy + .05, 2.62, "@trim_black")
    for yd in doors:
        bx(mb, -hw - .02, yd - .65, .35, -hw + .02, yd + .65, 2.6, look("glass"))
        bx(mb, -hw - .03, yd - .02, .35, -hw + .02, yd + .02, 2.6, "@Metal_Dark")
        for e in (-.65, .65):
            bx(mb, -hw - .03, yd + e - .03, .35, -hw + .02, yd + e + .03, 2.6, "@trim_black")
    bx(mb, -hw * .8, y0 - .05, 2.62, hw * .8, y0 + .12, 2.92, "@dest_sign")
    for sd in (-1, 1):
        xa, xb = sd * hw * .65, sd * hw * .95
        bx(mb, min(xa, xb), y0 - .015, .5, max(xa, xb), y0 + .1, .68, look("head"))
        bx(mb, min(xa, xb), y0 - .015, .72, max(xa, xb), y0 + .1, .8, look("ind_l" if sd > 0 else "ind_r"))
        truck_rear(mb, look, hw * .95, L / 2 + 0.005, .75, sd)
        # mirrors hang forward on arms, inside the 2.6 m envelope
        xm = sd * hw
        bx(mb, min(xm, xm + sd * 0.05), y0 - 0.2, 2.3, max(xm, xm + sd * 0.05), y0 + 0.3, 2.36, "@Metal_Dark")
        bx(mb, min(xm + sd * 0.0, xm + sd * 0.05), y0 - 0.32, 1.75, max(xm, xm + sd * 0.05), y0 - 0.2, 2.35,
           "@Metal_Dark")
        if look.full:
            quad(mb, [(xm, y0 - 0.199, 1.8), (xm + sd * 0.05, y0 - 0.199, 1.8), (xm + sd * 0.05, y0 - 0.199, 2.3),
                      (xm, y0 - 0.199, 2.3)], "@mirror", out=(0, 1, 0))
    bx(mb, -hw * .6, y0 - .015, .45, hw * .6, y0 + .1, .85, "@grille")
    bx(mb, -hw * .98, y0 - .05, .3, hw * .98, y0 + .1, .45, "@plastic_black")
    bx(mb, -hw * .98, L / 2 - .05, .3, hw * .98, L / 2 + .06, .5, "@plastic_black")
    plate(mb, look, 0.0, y0 - 0.05, 0.58, face=-1)
    plate(mb, look, 0.0, L / 2 + 0.06, 0.62, face=1)
    bx(mb, -hw * .8, L / 2 - 2.2, 3.06, hw * .8, L / 2 - .3, 3.3, look(band))
    hip = None
    if look.full:
        floor, ceil = 0.75, 2.55
        y_in0, y_in1 = y0 + 0.2, L / 2 - 0.3
        xb = hw - 0.06
        for sd in (-1, 1):
            quad(mb, [(sd * xb, y_in0, floor), (sd * xb, y_in1, floor), (sd * xb, y_in1, 1.0),
                      (sd * xb, y_in0, 1.0)], "@int_grey", out=(-sd, 0, 0))
        quad(mb, [(-xb, y_in0, floor), (xb, y_in0, floor), (xb, y_in1, floor), (-xb, y_in1, floor)], "@floor_grey",
             out=(0, 0, 1))
        quad(mb, [(-xb, y_in0, ceil), (xb, y_in0, ceil), (xb, y_in1, ceil), (-xb, y_in1, ceil)], "@int_light",
             out=(0, 0, -1))
        quad(mb, [(-xb, y_in1, floor), (xb, y_in1, floor), (xb, y_in1, ceil), (-xb, y_in1, ceil)], "@int_grey",
             out=(0, -1, 0))
        # driver: front left
        xd, hip_y, hip_z = hw * 0.55, y0 + 1.1, floor + 0.45
        bx(mb, -xb, y0 + 0.2, floor, xb, y0 + 0.55, 1.15, "@dash")
        steering_wheel(mb, xd, hip_y - 0.5, hip_z + 0.35, R=0.24, tilt=-30)
        seat(mb, xd, hip_y, hip_z, w=0.55, mat="@int_dark", tilt=-10, back_h=0.7)
        hip = (xd, hip_y, hip_z)
        driver_points(look, hip, floor, (xd, hip_y - 0.5, hip_z + 0.35, 0.24, -30.0), ceil, fwd=0.5)
        # passenger seats (pairs on both sides, a gap at the doors), poles
        for k in range(10):
            yy = y0 + 2.6 + k * 0.85
            for sd in (1, -1):
                if sd < 0 and any(abs(yy - yd) < 1.0 for yd in doors):
                    continue
                xs = sd * (hw - 0.55)
                bx(mb, xs - 0.45, yy - 0.22, floor + 0.38, xs + 0.45, yy + 0.2, floor + 0.48, "@seat_blue")
                bx(mb, xs - 0.45, yy + 0.16, floor + 0.45, xs + 0.45, yy + 0.24, floor + 1.15, "@seat_blue")
        for k in range(6):
            yy = y0 + 2.2 + k * 1.6
            mb.cyl((0.35 * S, yy * S, floor * S), 0.02 * S, (ceil - floor) * S, "@handrail", n=6, smooth=False,
                   caps=(False, False))
    wh = Wheels(c, look)
    wh.axle(fy, R, .3, W, True, style="steel")
    wh.axle(ry, R, .28, W, False, style="steel", dual=True)
    wh.emit(mb)
    return hip


# ----------------------------------------------------------------------------- bicycle

def bicycle(c, look, frame="Paint_blue"):
    """Upright city bicycle, 1.75 m long, wheels 0.68 m; Wheel_F / Wheel_R spin about X."""
    mb = c.mb
    from indkit import tube
    lod = look.lod
    fp = look("paint")
    R, yf, yr = 0.34, -0.53, 0.52
    zw = R
    n = 4 if lod else 8
    t = lambda a, b, rr, m=fp: tube(mb, [v * S for v in a], [v * S for v in b], rr * S, m, n=n)  # noqa: E731
    bb = (0.0, 0.1, 0.3)          # bottom bracket
    st_top = (0.0, 0.3, 0.82)      # seat tube top
    ht_top = (0.0, -0.36, 0.86)    # head tube top
    ht_bot = (0.0, -0.4, 0.68)
    t(bb, st_top, 0.016)
    t(st_top, ht_top, 0.015)
    t(bb, ht_bot, 0.018)
    t(ht_bot, ht_top, 0.02)
    for sd in (-1, 1):
        t((sd * 0.05, yr, zw), (sd * 0.03, bb[1], bb[2]), 0.009)
        t((sd * 0.05, yr, zw), (sd * 0.025, st_top[1] - 0.02, st_top[2] - 0.03), 0.008)
        t((sd * 0.05, yf, zw), (sd * 0.03, ht_bot[1] + 0.01, ht_bot[2] - 0.02), 0.011)
    # seat post, saddle (pear-shaped, nose forward), stem, bars, grips
    t(st_top, (0.0, 0.33, 0.95), 0.012, "@Metal_Galv")
    sad = [(0.0, -0.13), (0.03, -0.11), (0.035, -0.02), (0.075, 0.06), (0.085, 0.11), (0.06, 0.135),
           (-0.06, 0.135), (-0.085, 0.11), (-0.075, 0.06), (-0.035, -0.02), (-0.03, -0.11)]
    mb.push(Matrix.Translation(Vector((0.0, 0.33 * S, 0.95 * S))))
    pts = [(x * S, y * S) for x, y in sad]
    if sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1])) < 0:
        pts = list(reversed(pts))
    mb.prism(pts, 0.0, 0.05 * S, "@leather_black")
    mb.pop()
    t(ht_top, (0.0, -0.33, 1.02), 0.013, "@Metal_Galv")
    t((-0.29, -0.28, 1.04), (0.29, -0.28, 1.04), 0.011, "@Metal_Galv")
    for sd in (-1, 1):
        t((sd * 0.22, -0.28, 1.04), (sd * 0.3, -0.27, 1.04), 0.015, "@leather_black")
    # crank, chainring and pedals: their own object (Crank, origin at the bottom bracket, spins about
    # X; the left pedal (+X) up at rest) on the full model, merged and static on the LOD
    def crank(m):
        m.cyl((0.06 * S, bb[1] * S, bb[2] * S), 0.1 * S, 0.006 * S, "@chain", n=16, axis=RY90, smooth=False)
        for sd, a in ((1, math.pi / 2), (-1, -math.pi / 2)):
            px = bb[1] + math.cos(a) * 0.17
            pz = bb[2] + math.sin(a) * 0.17
            tube(m, (sd * 0.07 * S, bb[1] * S, bb[2] * S), (sd * 0.07 * S, px * S, pz * S), 0.01 * S,
                 "@Metal_Galv", n=n)
            bc(m, (sd * 0.11, px, pz), (0.09, 0.06, 0.02), "@plastic_black")
    if not lod:
        if look.full:
            cmb = MB()
            cmb.push(Matrix.Translation(Vector((0.0, -bb[1] * S, -bb[2] * S))))
            crank(cmb)
            cmb.pop()
            atlas.resolve(cmb)
            cob = cmb.build("Crank")
            cob.location = (0.0, bb[1] * S, bb[2] * S)
        else:
            crank(mb)
    if lod:
        # Far LOD only: a rough rider, mid-stroke, so a bicycle beyond the range of the seated
        # bodies (traffic/occupants.gd) is still ridden. Hips on the saddle, forward is -Y.
        hip, sh = (0.0, 0.3, 0.98), (0.0, 0.04, 1.47)
        t(hip, sh, 0.15)
        bc(mb, (0.0, -0.02, 1.66), (0.18, 0.21, 0.22), "@leather_black")
        for sd in (-1, 1):
            t((sd * 0.17, sh[1], sh[2] - 0.04), (sd * 0.26, -0.28, 1.04), 0.04)
        for sd, knee, foot in ((1, (0.1, -0.1, 0.78), (0.11, 0.02, 0.42)),
                               (-1, (-0.1, 0.0, 0.6), (-0.11, 0.1, 0.14))):
            t((sd * 0.1, hip[1], hip[2]), knee, 0.065, "@int_dark")
            t(knee, foot, 0.05, "@int_dark")
    if not lod:
        t((0.06, bb[1], bb[2] + 0.1), (0.05, yr, zw + 0.04), 0.004, "@chain")
        t((0.06, bb[1], bb[2] - 0.1), (0.05, yr, zw - 0.04), 0.004, "@chain")
        # fenders
        for yc in (yf, yr):
            mb.lathe([(R * 1.08 * S, -0.03 * S), (R * 1.08 * S, 0.03 * S)], fp, n=12, c=(0, yc * S, zw * S),
                     axis=RY90, a0=math.radians(60), a1=math.radians(250), smooth=True)
        # rear rack on struts from the drop-outs, tail lamp on its back edge
        zk = 0.8
        for sd in (-1, 1):
            t((sd * 0.05, yr, zw), (sd * 0.065, yr + 0.12, zk), 0.006, "@Metal_Galv")
            t((sd * 0.065, 0.3, zk), (sd * 0.065, yr + 0.3, zk), 0.006, "@Metal_Galv")
            t((sd * 0.03, st_top[1] + 0.02, st_top[2] - 0.05), (sd * 0.065, 0.32, zk), 0.005, "@Metal_Galv")
        for yy in (0.45, 0.6, yr + 0.3):
            t((-0.065, yy, zk), (0.065, yy, zk), 0.005, "@Metal_Galv")
        bc(mb, (0.0, yr + 0.31, zk - 0.03), (0.07, 0.02, 0.035), "@plastic_black")
        bc(mb, (0.0, yr + 0.322, zk - 0.03), (0.06, 0.006, 0.025), look("tail"))
        # front lamp on a bracket at the fork crown
        t((0.0, ht_bot[1] - 0.01, ht_bot[2] + 0.04), (0.0, ht_bot[1] - 0.07, ht_bot[2] + 0.06), 0.006,
          "@Metal_Galv")
        mb.cyl((0.0, (ht_bot[1] - 0.06) * S, (ht_bot[2] + 0.06) * S), 0.028 * S, 0.05 * S, "@plastic_black", n=10,
               axis=Matrix.Rotation(math.pi / 2, 4, "X"), smooth=False, caps=(True, False))
        mb.cyl((0.0, (ht_bot[1] - 0.11) * S, (ht_bot[2] + 0.06) * S), 0.024 * S, 0.001 * S, look("head"), n=10,
               axis=Matrix.Rotation(math.pi / 2, 4, "X"), smooth=False, caps=(False, True))
    for name, y in (("Wheel_F", yf), ("Wheel_R", yr)):
        def geo(m, lod=lod):
            nn = 10 if lod else 28
            m.push(RY90)
            m.lathe([(R * 0.93 * S, -0.018 * S), (R * S, -0.012 * S), (R * S, 0.012 * S), (R * 0.93 * S, 0.018 * S)],
                    "@tyre", n=nn, smooth=True)
            m.lathe([(R * 0.93 * S, 0.012 * S), (R * 0.88 * S, 0.01 * S), (R * 0.88 * S, -0.01 * S),
                     (R * 0.93 * S, -0.012 * S)], "@rim_alloy", n=nn, smooth=False)
            m.cyl((0, 0, -0.04 * S), 0.022 * S, 0.08 * S, "@rim_alloy", n=8, smooth=False)
            if not lod:
                for k in range(16):
                    a = 2 * math.pi * k / 16
                    zz = (0.03 if k % 2 else -0.03) * S
                    m.push(rotz(a))
                    tube(m, (0.02 * S, 0, zz), (R * 0.88 * S, 0, 0), 0.0012 * S, "@Metal_Galv", n=3, smooth=False)
                    m.pop()
            else:
                m.lathe([(R * 0.88 * S, 0.0), (0.03 * S, 0.0)], "@rim_barrel", n=8, smooth=False)
            m.pop()
        if look.full:
            wmb = MB()
            geo(wmb)
            atlas.resolve(wmb)
            ob = wmb.build(name)
            ob.location = (0, y * S, zw * S)
        else:
            mb.push(Matrix.Translation(Vector((0, y * S, zw * S))))
            geo(mb)
            mb.pop()
    return (0.0, 0.33, 1.0)


# ----------------------------------------------------------------------------- backhoe loader

def backhoe(c, look):
    """JCB-style backhoe loader, 5.6 x 2.3 m: small front wheels, big dual rears, a loader arm
    and bucket over the nose, a folded backhoe arm and stabilisers over the tail, an offset cab
    (floor 0.9 m, right-hand seat) and an amber beacon. Parked workhorse, not a highway machine."""
    mb = c.mb
    from indkit import tube
    lod = look.lod
    full = look.full
    fp = look("paint")
    L, W = 5.6, 2.3
    fy, ry, rf, rr = -1.85, 1.25, 0.35, 0.55
    n = 6 if lod else 10
    t = lambda a, b, r, m=fp: tube(mb, [v * S for v in a], [v * S for v in b], r * S, m, n=n)  # noqa: E731

    # chassis frame, engine hood (left of the cab) and the cab floor on top of it
    bx(mb, -0.8, -1.45, 0.38, 0.8, 1.75, 0.9, "@Metal_Dark")
    bx(mb, -1.02, -1.45, 0.9, 0.0, -0.35, 1.5, fp)
    bx(mb, -0.98, -1.5, 1.02, -0.04, -1.4, 1.12, "@grille")
    for sd in (-1, 1):  # headlights either side of the grille
        bx(mb, min(sd * 0.7, sd * 0.92), -1.5, 1.02, max(sd * 0.7, sd * 0.92), -1.42, 1.2, look("head"))
    t((-0.75, -0.6, 1.5), (-0.75, -0.6, 1.82), 0.03, "@Metal_Galv")  # exhaust stack

    # loader arm and bucket over the nose
    for sd in (-1, 1):
        t((sd * 0.82, -1.3, 1.0), (sd * 0.82, -2.2, 1.42), 0.07)
        t((sd * 0.82, -1.15, 0.98), (sd * 0.82, -1.3, 1.0), 0.07)
    t((-0.82, -2.2, 1.42), (0.82, -2.2, 1.42), 0.05, "@Metal_Dark")
    bx(mb, -1.08, -2.62, 0.32, 1.08, -2.18, 1.02, "@Metal_Dark")  # bucket back
    bx(mb, -1.08, -2.78, 0.14, 1.08, -2.18, 0.34, "@Metal_Dark")  # bucket floor, lip forward
    for k in range(3):  # teeth on the lip
        bx(mb, -0.7 + k * 0.7, -2.84, 0.14, -0.5 + k * 0.7, -2.78, 0.26, "@Metal_Galv")
    for sd in (-1, 1):
        bx(mb, min(sd * 1.1, sd * 1.02), -2.78, 0.14, max(sd * 1.1, sd * 1.02), -2.18, 1.02, "@Metal_Dark")

    # backhoe arm folded over the tail: kingpost (left), boom up, dipper curled under, small bucket
    bx(mb, -0.6, 1.8, 0.55, -0.12, 2.0, 1.5, "@Metal_Dark")
    t((-0.36, 1.9, 1.45), (-0.05, 2.4, 2.2), 0.09)
    t((-0.05, 2.4, 2.2), (0.18, 2.62, 1.2), 0.07)
    bx(mb, -0.05, 2.5, 0.55, 0.31, 2.78, 1.05, "@Metal_Dark")
    for sd in (-1, 1):  # stabiliser legs, pads down
        t((sd * 0.7, 2.1, 0.55), (sd * 1.0, 2.4, 0.24), 0.045, "@Metal_Dark")
        bx(mb, sd * 1.0 - 0.09, 2.3, 0.08, sd * 1.0 + 0.09, 2.5, 0.2, "@Metal_Dark")

    # cab on the right: floor 0.9 m, ROPS posts, roof, glass, and the beacon on top
    bx(mb, 0.0, -0.35, 0.86, 1.12, 0.9, 0.9, "@Metal_Dark")
    for px in (0.04, 1.06):
        for py in (-0.3, 0.85):
            bx(mb, px - 0.04, py - 0.04, 0.9, px + 0.04, py + 0.04, 2.7, fp)
    bx(mb, 0.0, -0.35, 2.7, 1.12, 0.9, 2.78, fp)
    gl = look("glass")
    for pts, out in (
        ([(0.04, -0.3, 0.98), (1.06, -0.3, 0.98), (1.06, -0.3, 2.6), (0.04, -0.3, 2.6)], (0, -1, 0)),
        ([(0.04, 0.85, 0.98), (1.06, 0.85, 0.98), (1.06, 0.85, 2.6), (0.04, 0.85, 2.6)], (0, 1, 0)),
        ([(0.04, -0.3, 0.98), (0.04, 0.85, 0.98), (0.04, 0.85, 2.6), (0.04, -0.3, 2.6)], (-1, 0, 0)),
        ([(1.06, -0.3, 0.98), (1.06, 0.85, 0.98), (1.06, 0.85, 2.6), (1.06, -0.3, 2.6)], (1, 0, 0)),
    ):
        quad(mb, pts, gl, out=out)
    bx(mb, 1.0, 0.2, 0.98, 1.12, 0.36, 2.35, fp)  # door skin on the driver's side
    for sd in (-1, 1):  # work lights on the cab's front posts
        bx(mb, min(sd * 0.5 + 0.56, sd * 0.5 + 0.7), -0.32, 2.42, max(sd * 0.5 + 0.56, sd * 0.5 + 0.7),
           -0.28, 2.54, look("head"))
    bx(mb, 0.42, 0.16, 2.78, 0.7, 0.44, 2.92, look("ind_l"))  # the amber beacon on the roof
    bx(mb, 1.06, -0.42, 0.52, 1.18, -0.26, 0.6, "@Metal_Dark")  # a step up to the door
    plate(mb, look, -0.5, -1.5, 1.3, w=0.4, h=0.1, face=-1)
    for sd in (-1, 1):
        truck_rear(mb, look, sd * 0.78, 1.75, 0.72, sd)

    # cab interior (full models): floor, headliner, seat, wheel, driver contact markers
    hip = None
    if full:
        xd, hip_y, hip_z, floor, ceil = 0.55, 0.3, 1.4, 0.9, 2.6
        quad(mb, [(0.0, -0.35, floor), (1.12, -0.35, floor), (1.12, 0.9, floor), (0.0, 0.9, floor)],
             "@int_dark", out=(0, 0, 1))
        quad(mb, [(0.0, -0.35, ceil), (1.12, -0.35, ceil), (1.12, 0.9, ceil), (0.0, 0.9, ceil)],
             "@int_light", out=(0, 0, -1))
        bx(mb, 0.0, -0.35, 1.12, 1.12, -0.2, 1.9, "@int_grey")  # dash bulkhead
        seat(mb, xd, hip_y, hip_z, w=0.5, mat="@int_dark", tilt=-12, back_h=0.62)
        steering_wheel(mb, xd, hip_y - 0.55, hip_z + 0.38, R=0.2, tilt=-35)
        hip = (xd, hip_y, hip_z)
        driver_points(look, hip, floor, (xd, hip_y - 0.55, hip_z + 0.38, 0.2, -35.0), ceil, fwd=0.45)

    wh = Wheels(c, look)
    wh.axle(fy, rf, 0.26, W, True, style="steel", spokes=6)
    wh.axle(ry, rr, 0.4, W, False, style="steel", spokes=6, dual=True)
    wh.emit(mb)
    return hip


# ----------------------------------------------------------------------------- entry points

def _finish(c, name, look, hip):
    """Build the merged body: <name>_body (full: materials, smooth by angle), <name>_lod1 (flat colours)."""
    import bpy
    if look.lod:
        ob = atlas.build_lod(c.mb, name, smooth_angle=math.radians(38))
    else:
        if c.cage.f:
            c.body_obs.append(cage_object(c.cage, "_cage"))
        atlas.resolve(c.mb)
        ob = c.mb.build(name + "_body", uv_offset=(0.0, 0.0))
        smooth(ob)
        parts = [o for o in c.body_obs if o is not None]
        if parts:
            ob = core.join_objects([ob] + parts, name + "_body")
    c.mb = MB()
    c.cage = MB()
    c.body_obs = []
    if look.full and hip is not None:
        e = make_empty("Seat_Driver", (hip[0] * S, hip[1] * S, hip[2] * S))
        e.empty_display_size = 0.01
    _ = bpy
    return ob


def build_vehicle(c, kind="car", paint="Paint_blue", lod=False, name=None, **kw):
    look = Look("lod" if lod else "full", paint, c.rnd)
    setup_materials(look)
    c.cage = MB()
    c.body_obs = []
    fn = {"car": car, "truck": truck, "garbage_truck": garbage_truck, "firetruck": firetruck,
          "ambulance": ambulance, "bus": bus, "bicycle": bicycle, "backhoe": backhoe}[kind]
    hip = fn(c, look, **kw)
    _finish(c, name or kind, look, hip)


def baked_car(c, x, y, rz=0.0, paint="Paint_white", shape="sedan", z=0.0, rims="alloy"):
    """Mid-detail parked car merged into c.mb at (x, y, z) (units), turned rz; front toward local -Y."""
    look = Look("baked", paint, c.rnd)
    saved = c.mb
    tmp = MB()
    c.mb = tmp
    car(c, look, shape=shape, rims=rims)
    c.mb = saved
    atlas.resolve(tmp)
    m = saved.xf @ Matrix.Translation(Vector((x, y, z))) @ rotz(rz)
    base = len(saved.v)
    for v in tmp.v:
        saved.v.append(m @ v)
    for idx, mat, sm, uvs in tmp.f:
        saved.f.append(([i + base for i in idx], mat, sm, uvs))


def _v(paint, shape=None, kind="car", legacy=None, **kw):
    d = dict(kind=kind, paint=paint, **kw)
    if shape:
        d["shape"] = shape
    return d


CARS = {
    "sedan_blue": _v("Paint_blue", "sedan"),
    "sedan_silver": _v("Paint_silver", "sedan", rims="dark"),
    "sedan_red": _v("Paint_darkred", "sedan"),
    "sedan_white": _v("Paint_white", "sedan", spokes=6),
    "hatchback_red": _v("Paint_red", "hatchback"),
    "hatchback_white": _v("Paint_white", "hatchback", mats={"roof": "paint:Paint_black"}, rims="dark"),
    "hatchback_green": _v("Paint_green", "hatchback", rims="steel_dark"),
    "suv_black": _v("Paint_black", "suv", rims="dark", interior="int_tan"),
    "suv_grey": _v("Paint_grey", "suv", spokes=6),
    "suv_beige": _v("Paint_beige", "suv"),
    "coupe_yellow": _v("Paint_yellow", "coupe", rims="dark", spokes=10),
    "coupe_navy": _v("Paint_navy", "coupe", spokes=10, interior="int_tan"),
    "taxi": _v("Paint_yellow", "sedan", taxi=True, rims="steel_dark"),
    "van_white": _v("Paint_white", "van", rims="steel_dark", interior="int_grey"),
    "van_minibus": _v("Paint_silver", "minibus", interior="int_grey"),
    "pickup_red": _v("Paint_red", "pickup", rims="steel_dark"),
    "pickup_grey": _v("Paint_grey", "pickup", spokes=6),
    "police": _v("Paint_white", "sedan", mats={"lower": "paint:Paint_navy"}, police=True, rims="steel_dark"),
    "bus": _v("Paint_red", kind="bus"),
    "truck": _v("Paint_white", kind="truck"),
    "garbage_truck": _v("Paint_garbage", kind="garbage_truck"),
    "firetruck": _v("Paint_fire", kind="firetruck"),
    "ambulance": _v("Paint_white", kind="ambulance"),
    "backhoe_yellow": _v("Paint_backhoe", kind="backhoe"),
    "bicycle": _v("Paint_teal", kind="bicycle"),
}
core.MATS.setdefault("Paint_teal", ("flat", (0.02, 0.22, 0.24), 0.3, 0.2, {"coat": 1.0}))
core.MATS.setdefault("Paint_backhoe", ("flat", (0.96, 0.72, 0.02), 0.32, 0.15, {"coat": 1.0}))


def _entry(name, lod):
    d = dict(CARS[name])
    kind = d.pop("kind")
    paint = d.pop("paint")

    def fn(c, _name=name, _kind=kind, _paint=paint, _lod=lod, _kw=d):
        build_vehicle(c, kind=_kind, paint=_paint, lod=_lod, name=_name + ("_lod1" if _lod else ""), **_kw)
    legacy = "vehicles/" + name if name != "bicycle" else "vehicles_v2/bicycle"
    return (fn, {"_seed_key": legacy})


REGISTRY = {}
for _n in CARS:
    REGISTRY["vehicles_v2/" + _n] = _entry(_n, False)
    REGISTRY["vehicles_v2/" + _n + "_lod1"] = _entry(_n, True)
