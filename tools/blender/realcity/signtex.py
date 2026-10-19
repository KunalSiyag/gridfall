"""Small baked faces for the street kit: sign faces (stop, yield, street-name blade, bus-stop flag) and
the default posters each Poster_<n> carries until slice D overrides it.

Each face is drawn on a supersampled numpy canvas (shapes, and text from Blender's built-in font turned
into triangles) and saved as a PNG under the derived cache, then embedded in the GLB. Faces are small
(at most 512 px wide) and deterministic, so a rebuild rewrites identical files."""

import math
import os

import bpy
import numpy as np
from mathutils.geometry import tessellate_polygon

import core

OUT_DIR = os.path.join(core.DERIVED, "signs")


def _lin(c):
    return np.array(c[:3], dtype=np.float32)


def _srgb(a):
    a = np.clip(a, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)


_glyphs = {}


def glyph_tris(text, bold=0.0):
    """Triangles [(x, y) * 3] of text set in Blender's built-in font, cap height ~0.72, centred at 0."""
    key = (text, bold)
    if key in _glyphs:
        return _glyphs[key]
    cu = bpy.data.curves.new("_txt", "FONT")
    cu.body = text
    cu.size = 1.0
    cu.offset = bold
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.resolution_u = 6
    cu.fill_mode = "BOTH"
    ob = bpy.data.objects.new("_txt", cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    tris = [[tuple(me.vertices[i].co[:2]) for i in t.vertices] for t in me.loop_triangles]
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.curves.remove(cu)
    _glyphs[key] = tris
    return tris


class Canvas:
    """w x h image (y down), painted in linear colour with ss x ss supersampling."""

    def __init__(self, w, h, bg, ss=3):
        self.w, self.h, self.ss = w, h, ss
        self.img = np.empty((h * ss, w * ss, 3), dtype=np.float32)
        self.img[:] = _lin(bg)

    # -- primitives (pixel coordinates, y down)
    def tris(self, tris, col):
        ss = self.ss
        c = _lin(col)
        H, W = self.img.shape[:2]
        for a, b, d in tris:
            xs = (a[0] * ss, b[0] * ss, d[0] * ss)
            ys = (a[1] * ss, b[1] * ss, d[1] * ss)
            x0, x1 = max(0, int(math.floor(min(xs)))), min(W, int(math.ceil(max(xs))) + 1)
            y0, y1 = max(0, int(math.floor(min(ys)))), min(H, int(math.ceil(max(ys))) + 1)
            if x0 >= x1 or y0 >= y1:
                continue
            px, py = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
            if abs(den) < 1e-9:
                continue
            l0 = ((ys[1] - ys[2]) * (px - xs[2]) + (xs[2] - xs[1]) * (py - ys[2])) / den
            l1 = ((ys[2] - ys[0]) * (px - xs[2]) + (xs[0] - xs[2]) * (py - ys[2])) / den
            m = (l0 >= -1e-6) & (l1 >= -1e-6) & (l0 + l1 <= 1 + 1e-6)
            self.img[y0:y1, x0:x1][m] = c

    def poly(self, pts, col):
        idx = tessellate_polygon([[(p[0], p[1], 0.0) for p in pts]])
        self.tris([[pts[i] for i in t] for t in idx], col)

    def rect(self, x0, y0, x1, y1, col, r=0.0):
        if r <= 0:
            self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], col)
            return
        pts = []
        for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
            for k in range(7):
                a = math.radians(a0 + 90 * k / 6)
                pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        self.poly(pts, col)

    def circle(self, cx, cy, r, col, n=40):
        self.poly([(cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n)) for k in range(n)],
                  col)

    def ngon(self, cx, cy, r, n, col, rot=0.0):
        self.poly([(cx + r * math.cos(rot + 2 * math.pi * k / n), cy + r * math.sin(rot + 2 * math.pi * k / n))
                   for k in range(n)], col)

    def text(self, s, cx, cy, cap, col, bold=0.03, max_w=None, track=1.0):
        """Text centred at (cx, cy) with capital height cap px (track > 1 stretches it horizontally)."""
        tris = glyph_tris(s, bold)
        if not tris:
            return
        xs = [p[0] for t in tris for p in t]
        ys = [p[1] for t in tris for p in t]
        h = max(ys) - min(ys)
        k = cap / max(h, 1e-6)
        kx = k * track
        w = (max(xs) - min(xs)) * kx
        if max_w is not None and w > max_w:
            kx *= max_w / w
        mx, my = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
        self.tris([[(cx + (p[0] - mx) * kx, cy - (p[1] - my) * k) for p in t] for t in tris], col)

    # -- output
    def save(self, name):
        ss = self.ss
        a = self.img.reshape(self.h, ss, self.w, ss, 3).mean(axis=(1, 3))
        a = _srgb(a)[::-1]  # Blender pixels are bottom-up
        rgba = np.concatenate([a, np.ones((self.h, self.w, 1), dtype=np.float32)], axis=2)
        path = os.path.join(OUT_DIR, name + ".png")
        os.makedirs(OUT_DIR, exist_ok=True)
        im = bpy.data.images.new("_sig_" + name, self.w, self.h, alpha=False)
        im.pixels.foreach_set(rgba.astype(np.float32).ravel())
        im.filepath_raw = path
        im.file_format = "PNG"
        im.save()
        bpy.data.images.remove(im)
        return path


def tex_material(name, path, rough=0.45, metal=0.0, emission=0.0):
    """A material `name` showing image `path` (cached per build like core.material)."""
    if name in core._mat_cache:
        return core._mat_cache[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.use_backface_culling = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = core._img(path)
    t.extension = "EXTEND"
    nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emission > 0:
        nt.links.new(t.outputs["Color"], b.inputs["Emission Color"])
        b.inputs["Emission Strength"].default_value = emission
    m.diffuse_color = (0.5, 0.5, 0.5, 1)
    core._mat_cache[name] = m
    return m


# ----------------------------------------------------------------------------- faces

WHITE = (0.86, 0.86, 0.84)
RED = (0.50, 0.012, 0.014)
GREEN = (0.006, 0.17, 0.065)
BLUE = (0.008, 0.06, 0.26)
INK = (0.012, 0.012, 0.014)


def stop_face():
    """Octagon (flat sides top and bottom) filling the square, white rim, STOP."""
    c = Canvas(256, 256, (0.4, 0.4, 0.4))
    r = 128 / math.cos(math.pi / 8)
    c.ngon(128, 128, r, 8, WHITE, rot=math.pi / 8)
    c.ngon(128, 128, r * 0.915, 8, RED, rot=math.pi / 8)
    c.text("STOP", 128, 129, 74, WHITE, bold=0.045, max_w=200, track=0.9)
    return c.save("stop_face")


def yield_face():
    """Point-down triangle in the square (top edge at v = 1), wide red border, YIELD."""
    c = Canvas(256, 256, (0.4, 0.4, 0.4))
    top, bot = 22, 243
    hw = (bot - top) / math.sqrt(3)
    c.poly([(128 - hw, top), (128 + hw, top), (128, bot)], RED)
    inset = 34
    t2, b2 = top + inset * 0.6, bot - inset * 1.25
    hw2 = (b2 - t2) / math.sqrt(3)
    c.poly([(128 - hw2, t2), (128 + hw2, t2), (128, b2)], WHITE)
    c.text("YIELD", 128, t2 + 38, 24, RED, bold=0.04, max_w=120)
    return c.save("yield_face")


def blade_face():
    """Street-name blade: green, white rim (the name is G1's Label3D at SignText_*)."""
    c = Canvas(512, 116, (0.4, 0.4, 0.4))
    c.rect(0, 0, 512, 116, WHITE, r=14)
    c.rect(6, 6, 506, 110, GREEN, r=10)
    return c.save("blade_face")


def bus_flag():
    """Bus-stop flag on the shelter fascia: blue, white bus pictogram, BUS."""
    c = Canvas(256, 128, BLUE)
    c.rect(4, 4, 252, 124, WHITE, r=8)
    c.rect(9, 9, 247, 119, BLUE, r=6)
    c.rect(28, 30, 112, 92, WHITE, r=7)
    for k in range(3):
        c.rect(34 + k * 25, 37, 54 + k * 25, 58, BLUE, r=2)
    c.rect(34, 66, 106, 70, BLUE)
    for x in (46, 94):
        c.circle(x, 94, 9, BLUE)
        c.circle(x, 94, 6, WHITE)
    c.text("BUS", 178, 64, 44, WHITE, bold=0.05)
    return c.save("bus_flag")


def _poster_bg(c, top, bottom):
    w, h = c.w, c.h
    t = np.linspace(0, 1, h * c.ss, dtype=np.float32)[:, None, None]
    c.img[:] = _lin(top) * (1 - t) + _lin(bottom) * t


def poster_billboard():
    """6.8 x 3.0 m: a city transit ad."""
    c = Canvas(512, 226, (0, 0, 0))
    _poster_bg(c, (0.30, 0.55, 0.85), (0.80, 0.86, 0.92))
    c.circle(410, 70, 46, (0.95, 0.62, 0.12))
    c.poly([(0, 226), (0, 182), (90, 146), (170, 172), (260, 138), (380, 168), (512, 144), (512, 226)],
           (0.05, 0.12, 0.10))
    c.rect(0, 186, 512, 226, (0.02, 0.03, 0.06))
    c.text("RIDE THE LINE", 186, 70, 34, (0.012, 0.035, 0.11), bold=0.05, max_w=330)
    c.text("EVERY 10 MINUTES  ALL NIGHT", 186, 114, 13, (0.012, 0.035, 0.11), bold=0.03, max_w=300)
    c.rect(330, 196, 496, 216, (0.95, 0.62, 0.12), r=4)
    c.text("CITY TRANSIT", 413, 206, 11, (0.02, 0.03, 0.06), bold=0.04)
    return c.save("poster_billboard")


def poster_portrait(name="poster_portrait", accent=(0.85, 0.12, 0.10)):
    """Portrait 1.2 x 1.8 to 1.26 x 2.12 m: a concert night."""
    c = Canvas(256, 400, (0, 0, 0))
    _poster_bg(c, (0.02, 0.02, 0.05), (0.10, 0.03, 0.12))
    c.circle(128, 150, 92, accent)
    c.circle(128, 150, 60, (0.02, 0.02, 0.05))
    c.circle(128, 150, 18, (0.95, 0.85, 0.6))
    c.text("LIVE", 128, 285, 46, (0.98, 0.96, 0.92), bold=0.06)
    c.text("FRIDAY  NIGHTS", 128, 330, 15, accent, bold=0.04, max_w=200)
    c.text("RIVERSIDE HALL", 128, 360, 11, (0.75, 0.75, 0.78), bold=0.02, max_w=200)
    return c.save(name)


def poster_hoarding():
    """2.9 x 2.2 m: coming soon."""
    c = Canvas(384, 292, (0.93, 0.92, 0.88))
    c.rect(0, 0, 384, 70, (0.02, 0.12, 0.08))
    c.text("COMING SOON", 192, 36, 30, (0.98, 0.97, 0.94), bold=0.05, max_w=330)
    for k, (x, hgt) in enumerate(((60, 120), (120, 170), (190, 140), (260, 190), (320, 110))):
        c.rect(x - 28, 262 - hgt, x + 28, 262, (0.10 + 0.04 * k, 0.16, 0.14))
        for j in range(int(hgt / 22)):
            c.rect(x - 18, 270 - hgt + j * 22, x + 18, 276 - hgt + j * 22, (0.75, 0.78, 0.7))
    c.rect(0, 262, 384, 292, (0.02, 0.12, 0.08))
    c.text("NEW HOMES  SHOPS  PARK", 192, 277, 12, (0.98, 0.97, 0.94), bold=0.03, max_w=340)
    return c.save("poster_hoarding")


def poster_lease():
    """1.8 x 1.2 m: FOR LEASE board."""
    c = Canvas(384, 256, (0.93, 0.93, 0.90))
    c.rect(0, 0, 384, 96, (0.55, 0.035, 0.03))
    c.text("FOR LEASE", 192, 49, 46, (0.98, 0.97, 0.94), bold=0.06, max_w=340)
    c.text("COMMERCIAL / RESIDENTIAL", 192, 132, 17, INK, bold=0.03, max_w=330)
    c.rect(40, 156, 344, 159, (0.55, 0.035, 0.03))
    c.text("555-0142", 192, 196, 34, INK, bold=0.05)
    c.text("CITY LAND OFFICE", 192, 234, 12, (0.3, 0.3, 0.32), bold=0.02)
    return c.save("poster_lease")
