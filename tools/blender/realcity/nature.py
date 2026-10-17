"""Trees, shrubs and hedges built from photographed Poly Haven leaf clusters on alpha-tested cards.

Foliage cards get custom normals pointing away from the crown centre, which gives the soft,
volumetric shading of real tree crowns instead of flat-card shading.
"""

import math
import random

from mathutils import Matrix, Vector

from core import MB


class FoliageMB(MB):
    def __init__(self):
        super().__init__()
        self.vn = []

    def vert(self, p):
        i = super().vert(p)
        self.vn.append(None)
        return i

    def leaf_card(self, c, size, centre, mat, rnd, outward=0.65, droop=0.0, stretch=1.0):
        c = Vector(c)
        centre = Vector(centre)
        out = c - centre
        if out.length < 1e-6:
            out = Vector((0, 0, 1))
        out.normalize()
        rv = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1)))
        if rv.length < 1e-4:
            rv = Vector((0, 0, 1))
        n = (out * outward + rv.normalized() * (1 - outward)).normalized()
        n.z -= droop
        n.normalize()
        up = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1)))
        fi = self.card(c, size, size * stretch, n, up, mat, smooth=True)
        for vi in self.f[fi][0]:
            p = self.v[vi]
            sn = (p - (self.xf @ centre))
            sn = sn.normalized() if sn.length > 1e-6 else Vector((0, 0, 1))
            self.vn[vi] = sn
        return fi

    def build(self, name, **kw):
        normals = [n if n is not None else Vector((0, 0, 1)) for n in self.vn]
        return super().build(name, custom_normals=normals, **kw)


def _branch(mb, base, tip, r0, r1, mat, n=5):
    base, tip = Vector(base), Vector(tip)
    d = tip - base
    L = d.length
    z = Vector((0, 0, 1))
    rot = z.rotation_difference(d.normalized()).to_matrix().to_4x4()
    mb.lathe([(r0, 0.0), (r1, L)], mat, n=n, c=tuple(base), axis=rot, smooth=True)


# Half-extent the foliage of one model must stay inside (set per model by the builder; None = no limit).
BOUND = None


def _fit(mb, fol, i0, j0, x, y, z0, scale=True):
    """Keep the plant just added (mb.v[i0:], fol.v[j0:]) inside +-BOUND and above its base: first shrink it
    uniformly about its base (never below 60 %), then slide it inward, then lift stray card corners."""
    vs = mb.v[i0:] + fol.v[j0:]
    if not vs:
        return
    base = mb.xf @ Vector((x, y, z0))
    if BOUND is not None:
        if scale:
            f = 1.0
            for ax in (0, 1):
                c = base[ax]
                hi = max(v[ax] for v in vs)
                lo = min(v[ax] for v in vs)
                if hi > BOUND and hi > c:
                    f = min(f, max(0.0, BOUND - c) / (hi - c))
                if lo < -BOUND and lo < c:
                    f = min(f, max(0.0, BOUND + c) / (c - lo))
            f = max(f, 0.6)
            if f < 1.0:
                for v in vs:
                    v.x = base.x + (v.x - base.x) * f
                    v.y = base.y + (v.y - base.y) * f
                    v.z = base.z + (v.z - base.z) * f
        for ax in (0, 1):
            hi = max(v[ax] for v in vs)
            lo = min(v[ax] for v in vs)
            d = 0.0
            if hi > BOUND:
                d = BOUND - hi
            elif lo < -BOUND:
                d = -BOUND - lo
            if d:
                for v in vs:
                    v[ax] += d
    for v in fol.v[j0:]:
        if v.z < base.z + 0.0005:
            v.z = base.z + 0.0005


def tree(mb, fol, x, y, h=0.45, kind="broad", seed=0, z0=0.0, bark=None):
    """Add a tree with base (x,y,z0) and total height h to builder mb (bark) and fol (FoliageMB)."""
    i0, j0 = len(mb.v), len(fol.v)
    _tree(mb, fol, x, y, h, kind, seed, z0, bark)
    _fit(mb, fol, i0, j0, x, y, z0)


def _tree(mb, fol, x, y, h, kind, seed, z0, bark):
    rnd = random.Random(seed * 7919 + int(x * 1000) * 31 + int(y * 1000))
    leaf = {"broad": "Leaves_Broad", "round": "Leaves_Round", "fern": "Leaves_Fern", "conifer": "Leaves_Conifer",
            "poplar": "Leaves_Round", "birch": "Leaves_Broad", "shrub": "Leaves_Shrub"}[kind]
    bark = bark or ("Bark_Platanus" if kind in ("round", "birch") else "Bark")
    if kind == "conifer":
        tr = h * 0.022
        _branch(mb, (x, y, z0), (x, y, z0 + h * 0.98), tr, tr * 0.25, bark, n=6)
        tiers = 9
        for t in range(tiers):
            f = t / (tiers - 1)
            zc = z0 + h * (0.16 + 0.80 * f)
            rad = h * 0.26 * (1 - f) + h * 0.03
            k = int(10 - f * 6)
            for i in range(k):
                a = 2 * math.pi * (i + rnd.random() * 0.6) / k + t
                rr = rad * rnd.uniform(0.45, 0.95)
                c = (x + math.cos(a) * rr, y + math.sin(a) * rr, zc - rr * 0.25)
                fol.leaf_card(c, rad * 1.25 + h * 0.05, (x, y, zc + rad * 0.5), leaf, rnd, outward=0.5, droop=-0.4)
        return
    if kind == "shrub":
        r = h * 0.75
        for i in range(int(18 + r * 120)):
            th = rnd.uniform(0, 2 * math.pi)
            ph = rnd.uniform(0.05, 1.0) * math.pi / 2
            rr = r * rnd.uniform(0.5, 1.0)
            c = (x + math.cos(th) * math.cos(ph) * rr, y + math.sin(th) * math.cos(ph) * rr,
                 z0 + math.sin(ph) * rr * (h / r) * 0.9 + h * 0.05)
            fol.leaf_card(c, r * 0.9, (x, y, z0), leaf, rnd, outward=0.75)
        return
    trunk_h = {"broad": 0.34, "round": 0.30, "fern": 0.40, "poplar": 0.18, "birch": 0.38}[kind] * h
    tr = h * (0.03 if kind != "birch" else 0.022)
    lean = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0)) * h * 0.03
    top = Vector((x, y, z0 + trunk_h)) + lean
    _branch(mb, (x, y, z0), top, tr, tr * 0.72, bark, n=7)
    if kind == "poplar":
        rx, rz = h * 0.15, h * 0.42
    elif kind == "fern":
        rx, rz = h * 0.36, h * 0.26
    elif kind == "round":
        rx, rz = h * 0.32, h * 0.34
    else:
        rx, rz = h * 0.34, h * 0.32
    centre = Vector((top.x, top.y, z0 + h - rz))
    # main limbs into the crown
    nb = 4 if kind != "poplar" else 3
    for i in range(nb):
        a = 2 * math.pi * i / nb + rnd.uniform(-0.4, 0.4)
        tip = centre + Vector((math.cos(a) * rx * 0.62, math.sin(a) * rx * 0.62, rnd.uniform(-0.1, 0.35) * rz))
        _branch(mb, top, tip, tr * 0.6, tr * 0.18, bark, n=5)
    _branch(mb, top, centre + Vector((0, 0, rz * 0.5)), tr * 0.6, tr * 0.15, bark, n=5)
    # foliage: several sub-clumps for an irregular silhouette
    clumps = [(centre, 1.0)]
    for i in range(5 if kind != "poplar" else 3):
        a = rnd.uniform(0, 2 * math.pi)
        off = Vector((math.cos(a) * rx * 0.5, math.sin(a) * rx * 0.5, rnd.uniform(-0.25, 0.45) * rz))
        clumps.append((centre + off, rnd.uniform(0.55, 0.75)))
    ncards = int({"broad": 90, "round": 90, "fern": 80, "poplar": 64, "birch": 72}[kind])
    card = (rx + rz) * 0.48
    for i in range(ncards):
        cc, s = clumps[i % len(clumps)]
        while True:
            p = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1)))
            if 0.3 < p.length <= 1.0:
                break
        p = Vector((p.x * rx * s * 0.8, p.y * rx * s * 0.8, p.z * rz * s * 0.8))
        fol.leaf_card(cc + p, card * s * rnd.uniform(0.75, 1.1), centre, leaf, rnd, outward=0.8,
                      droop=0.15 if kind == "fern" else 0.0)


def hedge(mb, fol, x0, y0, x1, y1, h=0.035, w=0.03, seed=0, z0=0.0):
    """Clipped hedge: a leafy box core plus cards breaking up the silhouette."""
    rnd = random.Random(seed)
    i0, j0 = len(mb.v), len(fol.v)
    _hedge(fol, x0, y0, x1, y1, h, w, rnd, z0)
    _fit(mb, fol, i0, j0, (x0 + x1) / 2, (y0 + y1) / 2, z0, scale=False)


def _hedge(fol, x0, y0, x1, y1, h, w, rnd, z0):
    L = math.hypot(x1 - x0, y1 - y0)
    ang = math.atan2(y1 - y0, x1 - x0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    n = max(2, int(L / 0.02))
    for i in range(n):
        t = (i + 0.5) / n - 0.5
        px = cx + math.cos(ang) * t * L
        py = cy + math.sin(ang) * t * L
        for k in range(2):
            c = (px + rnd.uniform(-w, w) * 0.3, py + rnd.uniform(-w, w) * 0.3, z0 + h * rnd.uniform(0.35, 0.8))
            fol.leaf_card(c, max(w, h) * 1.6, (px, py, z0), "Leaves_Shrub", rnd, outward=0.6)


def shrub(mb, fol, x, y, h=0.04, seed=0, z0=0.0, kind="shrub"):
    tree(mb, fol, x, y, h=h, kind="shrub", seed=seed, z0=z0)
