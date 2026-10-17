"""Core helpers for the GridFall realistic asset library (Blender 4.2+ / 5.x, headless).

Conventions: Blender Z-up; model front faces Blender -Y (Godot +Z); 1 tile = 1 unit (~20 m).
Geometry is accumulated in MeshBuilder objects (fast, no bpy.ops) and turned into one Blender
mesh per builder with per-face materials and planar/cylindrical UVs scaled per material.
"""

import math
import os
import random
import zlib

import bpy
from mathutils import Matrix, Vector

CACHE = os.path.expanduser("~/.cache/gridfall_polyhaven")
TEX512 = os.path.join(CACHE, "derived", "tex512")
DERIVED = os.path.join(CACHE, "derived")
M = 1.0 / 20.0  # units per metre

# ----------------------------------------------------------------------------- materials
# Textured: ("tex", polyhaven_id, metres_per_repeat, tint)
# Flat:     ("flat", (r,g,b), roughness, metallic, extra-dict)
MATS = {
    # facades
    "Brick_Red": ("tex", "red_brick_03", 2.4, (1, 1, 1)),
    "Brick_Orange": ("tex", "brick_wall_006", 2.4, (1, 1, 1)),
    "Brick_Yellow": ("tex", "brown_brick_02", 2.4, (1, 1, 1)),
    "Brick_Old": ("tex", "red_bricks_04", 2.4, (1, 1, 1)),
    "Brick_Painted": ("tex", "red_bricks_04", 2.4, (0.95, 0.93, 0.88)),
    "Brick_Dark": ("tex", "red_brick_03", 2.4, (0.55, 0.5, 0.5)),
    "Plaster_Beige": ("tex", "beige_wall_001", 3.0, (1, 1, 1)),
    "Plaster_White": ("tex", "white_plaster_02", 3.0, (1, 1, 1)),
    "Plaster_Grey": ("tex", "plaster_grey_04", 3.0, (1, 1, 1)),
    "Plaster_Cream": ("tex", "painted_plaster_wall", 3.0, (1.0, 0.92, 0.78)),
    "Plaster_Terracotta": ("tex", "beige_wall_001", 3.0, (0.93, 0.62, 0.46)),
    "Plaster_Sage": ("tex", "beige_wall_001", 3.0, (0.74, 0.82, 0.70)),
    "Plaster_Blue": ("tex", "painted_plaster_wall", 3.0, (0.72, 0.80, 0.90)),
    "Plaster_Ochre": ("tex", "beige_wall_001", 3.0, (0.96, 0.80, 0.52)),
    "Plaster_Pink": ("tex", "painted_plaster_wall", 3.0, (0.95, 0.78, 0.74)),
    "Concrete": ("tex", "concrete_wall_008", 3.0, (1, 1, 1)),
    "Concrete_Dark": ("tex", "concrete_wall_008", 3.0, (0.62, 0.62, 0.64)),
    "Concrete_Panel": ("tex", "concrete_slab_wall", 3.5, (1, 1, 1)),
    "Concrete_Light": ("tex", "concrete_wall_004", 3.0, (1, 1, 1)),
    "Concrete_Floor": ("tex", "concrete_floor_02", 4.0, (1, 1, 1)),
    "Stone_Facade": ("tex", "rectangular_facade_tiles_02", 3.0, (1, 1, 1)),
    "Stone_Light": ("tex", "rectangular_facade_tiles_02", 3.0, (1.0, 0.97, 0.9)),
    "Siding_White": ("tex", "brown_planks_05", 1.6, (1.0, 1.0, 0.98)),
    "Siding_Blue": ("tex", "brown_planks_05", 1.6, (0.62, 0.74, 0.86)),
    "Siding_Grey": ("tex", "brown_planks_05", 1.6, (0.68, 0.70, 0.70)),
    "Siding_Yellow": ("tex", "brown_planks_05", 1.6, (1.0, 0.90, 0.62)),
    "Siding_Green": ("tex", "brown_planks_05", 1.6, (0.66, 0.78, 0.66)),
    "Siding_Red": ("tex", "brown_planks_05", 1.6, (0.78, 0.40, 0.34)),
    # roofs
    "Roof_Clay": ("tex", "clay_roof_tiles_02", 2.5, (1, 1, 1)),
    "Roof_Grey": ("tex", "grey_roof_tiles", 2.5, (1, 1, 1)),
    "Roof_Slate": ("tex", "roof_slates_02", 2.5, (1, 1, 1)),
    "Roof_Shingle": ("tex", "grey_roof_01", 2.5, (1, 1, 1)),
    "Roof_Shingle_Brown": ("tex", "grey_roof_01", 2.5, (0.85, 0.68, 0.55)),
    "Roof_Flat": ("tex", "bitumen", 3.0, (0.55, 0.55, 0.56)),
    "Roof_Gravel": ("tex", "gravel_floor", 2.0, (0.85, 0.85, 0.85)),
    # metals
    "Metal_Corrugated": ("tex", "corrugated_iron_02", 2.0, (1, 1, 1)),
    "Metal_Corrugated_Light": ("tex", "corrugated_iron", 2.0, (1, 1, 1)),
    "Metal_Cladding_Green": ("tex", "factory_wall", 2.5, (1, 1, 1)),
    "Metal_Cladding_Red": ("tex", "box_profile_metal_sheet", 2.5, (1, 1, 1)),
    "Metal_Cladding_Blue": ("tex", "corrugated_iron", 2.5, (0.30, 0.47, 0.78)),
    "Metal_Cladding_White": ("tex", "corrugated_iron", 2.5, (1.0, 1.0, 1.0)),
    "Metal_Container": ("tex", "container_side", 2.5, (1, 1, 1)),
    "Metal_Rusty": ("tex", "rusty_metal_02", 2.0, (1, 1, 1)),
    "Shutter": ("tex", "painted_metal_shutter", 1.6, (1, 1, 1)),
    "Metal_Plate": ("tex", "metal_plate", 1.5, (1, 1, 1)),
    # wood / ground
    "Wood_Weathered": ("tex", "brown_planks_03", 1.6, (1, 1, 1)),
    "Wood": ("tex", "wood_planks", 1.6, (1, 1, 1)),
    "Wood_Dark": ("tex", "wood_planks", 1.6, (0.5, 0.42, 0.36)),
    "Bark": ("tex", "bark_brown_02", 0.8, (1, 1, 1)),
    "Bark_Platanus": ("tex", "bark_platanus", 0.8, (1, 1, 1)),
    "Asphalt": ("tex", "asphalt_01", 4.0, (0.6, 0.6, 0.62)),
    "Asphalt_Dark": ("tex", "asphalt_01", 4.0, (0.42, 0.42, 0.44)),
    "Sidewalk": ("tex", "concrete_pavement", 3.0, (1, 1, 1)),
    "Curb": ("tex", "concrete_wall_004", 2.0, (0.92, 0.92, 0.9)),
    "Grass": ("tex", "leafy_grass", 3.0, (0.92, 1.0, 0.82)),
    "Dirt": ("tex", "dirt", 3.0, (1, 1, 1)),
    "Gravel": ("tex", "gravel", 2.0, (1, 1, 1)),
    "Rock": ("tex", "rocks_ground_02", 3.0, (1, 1, 1)),
    "Paint_White": ("tex", "concrete_floor_02", 2.0, (1.0, 1.0, 1.0)),
    "Paint_Yellow": ("tex", "concrete_floor_02", 2.0, (1.0, 0.78, 0.16)),
    # flat
    "Glass": ("flat", (0.030, 0.040, 0.050), 0.07, 0.55, {}),
    "Glass_Curtain": ("flat", (0.10, 0.15, 0.19), 0.05, 0.85, {}),
    "Glass_Green": ("flat", (0.07, 0.13, 0.12), 0.05, 0.85, {}),
    "Glass_Shop": ("flat", (0.05, 0.055, 0.06), 0.05, 0.45, {}),
    "Glass_Car": ("flat", (0.02, 0.025, 0.03), 0.04, 0.6, {}),
    "Frame_White": ("flat", (0.82, 0.82, 0.80), 0.45, 0.0, {}),
    "Frame_Dark": ("flat", (0.05, 0.05, 0.055), 0.40, 0.6, {}),
    "Frame_Alu": ("flat", (0.62, 0.64, 0.66), 0.32, 1.0, {}),
    "Frame_Wood": ("flat", (0.30, 0.18, 0.10), 0.6, 0.0, {}),
    "Trim_Stone": ("tex", "concrete_wall_004", 2.0, (0.95, 0.93, 0.88)),
    "Trim_White": ("flat", (0.86, 0.85, 0.82), 0.6, 0.0, {}),
    "Metal_Dark": ("flat", (0.07, 0.075, 0.08), 0.45, 0.8, {}),
    "Metal_Galv": ("flat", (0.55, 0.57, 0.58), 0.38, 1.0, {}),
    "Metal_White": ("flat", (0.80, 0.81, 0.82), 0.35, 0.3, {}),
    "Metal_Red": ("flat", (0.55, 0.06, 0.05), 0.35, 0.3, {}),
    "Metal_Yellow": ("flat", (0.85, 0.62, 0.05), 0.4, 0.3, {}),
    "Metal_Green": ("flat", (0.06, 0.25, 0.14), 0.4, 0.3, {}),
    "Metal_Blue": ("flat", (0.05, 0.16, 0.42), 0.35, 0.3, {}),
    "Chrome": ("flat", (0.9, 0.9, 0.9), 0.08, 1.0, {}),
    "Rubber": ("flat", (0.025, 0.025, 0.028), 0.85, 0.0, {}),
    "Plastic_Black": ("flat", (0.03, 0.03, 0.032), 0.5, 0.0, {}),
    "Plastic_Grey": ("flat", (0.25, 0.26, 0.27), 0.55, 0.0, {}),
    "Plastic_Green": ("flat", (0.06, 0.22, 0.10), 0.55, 0.0, {}),
    "Plastic_Blue": ("flat", (0.04, 0.12, 0.35), 0.55, 0.0, {}),
    "Plastic_Orange": ("flat", (0.95, 0.30, 0.02), 0.5, 0.0, {}),
    "Reflective_White": ("flat", (0.92, 0.92, 0.92), 0.3, 0.0, {}),
    "Door_Red": ("flat", (0.42, 0.06, 0.05), 0.4, 0.0, {}),
    "Door_Green": ("flat", (0.06, 0.20, 0.12), 0.4, 0.0, {}),
    "Door_Blue": ("flat", (0.06, 0.12, 0.26), 0.4, 0.0, {}),
    "Door_Black": ("flat", (0.03, 0.03, 0.035), 0.35, 0.0, {}),
    "Fabric_Red": ("flat", (0.45, 0.06, 0.05), 0.85, 0.0, {}),
    "Fabric_Green": ("flat", (0.05, 0.22, 0.12), 0.85, 0.0, {}),
    "Fabric_Navy": ("flat", (0.04, 0.07, 0.18), 0.85, 0.0, {}),
    "Fabric_Cream": ("flat", (0.85, 0.80, 0.66), 0.85, 0.0, {}),
    "Fabric_Orange": ("flat", (0.80, 0.32, 0.06), 0.85, 0.0, {}),
    "Hedge_Core": ("flat", (0.035, 0.075, 0.03), 0.9, 0.0, {}),
    "Clay_Pot": ("flat", (0.45, 0.20, 0.10), 0.8, 0.0, {}),
    "Solar_Panel": ("flat", (0.03, 0.06, 0.14), 0.12, 0.7, {}),
    "Water": ("flat", (0.04, 0.10, 0.12), 0.03, 0.2, {}),
    "Sign_Red": ("flat", (0.62, 0.05, 0.04), 0.4, 0.0, {}),
    "Sign_Blue": ("flat", (0.04, 0.16, 0.48), 0.4, 0.0, {}),
    "Sign_Green": ("flat", (0.03, 0.32, 0.14), 0.4, 0.0, {}),
    "Sign_White": ("flat", (0.92, 0.92, 0.9), 0.4, 0.0, {}),
    "Light_Head": ("flat", (1.0, 0.98, 0.92), 0.1, 0.0, {"emission": (1.0, 0.95, 0.85), "strength": 2.0}),
    "Light_Tail": ("flat", (0.5, 0.02, 0.02), 0.15, 0.0, {"emission": (0.6, 0.02, 0.01), "strength": 1.0}),
    "Light_Amber": ("flat", (0.9, 0.45, 0.02), 0.2, 0.0, {}),
    "Lamp_Glow": ("flat", (1.0, 0.92, 0.75), 0.2, 0.0, {"emission": (1.0, 0.85, 0.6), "strength": 3.0}),
    "Siren_Red": ("flat", (0.85, 0.05, 0.04), 0.15, 0.0, {"emission": (1.0, 0.05, 0.03), "strength": 1.5}),
    "Siren_Blue": ("flat", (0.05, 0.15, 0.9), 0.15, 0.0, {"emission": (0.05, 0.2, 1.0), "strength": 1.5}),
    "Beacon_Red": ("flat", (0.9, 0.05, 0.04), 0.2, 0.0, {"emission": (1.0, 0.05, 0.03), "strength": 3.0}),
    "Flood_Glow": ("flat", (1.0, 0.98, 0.9), 0.2, 0.0, {"emission": (1.0, 0.97, 0.88), "strength": 4.0}),
    "Skin": ("flat", (0.80, 0.58, 0.45), 0.55, 0.0, {}),
    "Shirt": ("flat", (0.20, 0.32, 0.55), 0.8, 0.0, {}),
    "Pants": ("flat", (0.12, 0.13, 0.17), 0.8, 0.0, {}),
    "Hair": ("flat", (0.08, 0.05, 0.03), 0.6, 0.0, {}),
    "Shoes": ("flat", (0.05, 0.045, 0.04), 0.5, 0.0, {}),
}
CAR_PAINTS = {
    "white": (0.80, 0.80, 0.78), "black": (0.012, 0.012, 0.014), "silver": (0.45, 0.46, 0.47),
    "red": (0.42, 0.015, 0.012), "blue": (0.02, 0.07, 0.25), "grey": (0.13, 0.14, 0.15),
    "green": (0.03, 0.14, 0.08), "yellow": (0.85, 0.55, 0.02), "beige": (0.55, 0.47, 0.34),
    "orange": (0.80, 0.22, 0.02), "darkred": (0.18, 0.01, 0.015), "navy": (0.015, 0.03, 0.09),
}
for _k, _c in CAR_PAINTS.items():
    MATS["Paint_" + _k] = ("flat", _c, 0.28, 0.45 if _k in ("silver", "grey", "blue", "darkred", "navy") else 0.0,
                           {"coat": 1.0})

LEAF_MATS = {
    "Leaves_Broad": "leafcluster_broad.png",
    "Leaves_Round": "leafcluster_round.png",
    "Leaves_Fern": "leafcluster_fern.png",
    "Leaves_Conifer": "leafcluster_conifer.png",
    "Leaves_Shrub": "leafcluster_shrub.png",
}

# small/distant surfaces: base colour only (keeps GLBs small)
LITE = {"Bark", "Bark_Platanus", "Paint_White", "Paint_Yellow", "Wood_Dark"}

_mat_cache = {}
_img_cache = {}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mat_cache.clear()
    _img_cache.clear()


def _img(path, noncolor=False):
    key = (path, noncolor)
    if key in _img_cache:
        return _img_cache[key]
    im = bpy.data.images.load(path, check_existing=False)
    if noncolor:
        im.colorspace_settings.name = "Non-Color"
    _img_cache[key] = im
    return im


def mat_size(name):
    spec = MATS.get(name)
    if spec and spec[0] == "tex":
        return spec[2] * M
    return 2.0 * M


def material(name, override=None):
    """Return (and cache) the Blender material for a library name.
    `override` lets one GLB give a name (e.g. WindowLit) the look of another spec."""
    if name in _mat_cache:
        return _mat_cache[name]
    spec = override or MATS.get(name)
    if spec is None:
        spec = MATS["Glass"]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.use_backface_culling = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    if name in LEAF_MATS or (override and override[0] == "leaf"):
        fn = LEAF_MATS.get(name) or override[1]
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = _img(os.path.join(DERIVED, fn))
        nt.links.new(tex.outputs["Color"], b.inputs["Base Color"])
        rnd = nt.nodes.new("ShaderNodeMath")
        rnd.operation = "ROUND"
        nt.links.new(tex.outputs["Alpha"], rnd.inputs[0])
        nt.links.new(rnd.outputs[0], b.inputs["Alpha"])
        b.inputs["Roughness"].default_value = 0.7
        m.use_backface_culling = False
        try:
            m.surface_render_method = "DITHERED"
        except Exception:
            pass
        m.diffuse_color = (0.2, 0.35, 0.15, 1)
    elif spec[0] == "tex":
        _, pid, _, tint = spec
        d = nt.nodes.new("ShaderNodeTexImage")
        d.image = _img(os.path.join(TEX512, pid + "_diff.jpg"))
        if tuple(tint) != (1, 1, 1):
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            mix.inputs["Factor"].default_value = 1.0
            nt.links.new(d.outputs["Color"], mix.inputs[6])
            mix.inputs[7].default_value = (tint[0], tint[1], tint[2], 1.0)
            nt.links.new(mix.outputs[2], b.inputs["Base Color"])
        else:
            nt.links.new(d.outputs["Color"], b.inputs["Base Color"])
        a_path = os.path.join(TEX512, pid + "_arm.jpg")
        if name in LITE:
            b.inputs["Roughness"].default_value = 0.85
        elif os.path.exists(a_path):
            a = nt.nodes.new("ShaderNodeTexImage")
            a.image = _img(a_path, True)
            sep = nt.nodes.new("ShaderNodeSeparateColor")
            nt.links.new(a.outputs["Color"], sep.inputs[0])
            nt.links.new(sep.outputs[1], b.inputs["Roughness"])
            nt.links.new(sep.outputs[2], b.inputs["Metallic"])
        n_path = os.path.join(TEX512, pid + "_nor_gl.jpg")
        if os.path.exists(n_path) and name not in LITE:
            n = nt.nodes.new("ShaderNodeTexImage")
            n.image = _img(n_path, True)
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(n.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
        m.diffuse_color = (tint[0] * 0.6, tint[1] * 0.6, tint[2] * 0.6, 1)
    else:
        _, col, rough, metal, extra = spec
        b.inputs["Base Color"].default_value = (col[0], col[1], col[2], 1.0)
        b.inputs["Roughness"].default_value = rough
        b.inputs["Metallic"].default_value = metal
        if "emission" in extra:
            b.inputs["Emission Color"].default_value = (*extra["emission"], 1.0)
            b.inputs["Emission Strength"].default_value = extra.get("strength", 1.0)
        if "coat" in extra:
            b.inputs["Coat Weight"].default_value = extra["coat"]
            b.inputs["Coat Roughness"].default_value = 0.03
        m.diffuse_color = (col[0], col[1], col[2], 1)
    _mat_cache[name] = m
    return m


# ----------------------------------------------------------------------------- mesh builder

def rotz(a):
    return Matrix.Rotation(a, 4, "Z")


class MB:
    """Accumulates polygons. Faces are lists of vertex indices (CCW seen from outside)."""

    def __init__(self):
        self.v = []
        self.f = []  # (idx, mat, smooth, uvs|None)
        self.xf = Matrix.Identity(4)
        self._stack = []

    # -- transforms
    def push(self, m):
        self._stack.append(self.xf)
        self.xf = self.xf @ m

    def pop(self):
        self.xf = self._stack.pop()

    def at(self, loc=(0, 0, 0), rz=0.0):
        """Context helper: mb.push(mb.at(...)) ... mb.pop()"""
        return Matrix.Translation(Vector(loc)) @ rotz(rz)

    def vert(self, p):
        self.v.append(self.xf @ Vector(p))
        return len(self.v) - 1

    def poly(self, pts, mat, smooth=False, uvs=None):
        idx = [self.vert(p) for p in pts]
        self.f.append((idx, mat, smooth, uvs))
        return idx

    def face(self, idx, mat, smooth=False, uvs=None):
        self.f.append((list(idx), mat, smooth, uvs))

    def polyo(self, pts, mat, out, uvs=None):
        """poly() that flips the winding so the face normal points along local direction out."""
        n = Vector((0.0, 0.0, 0.0))
        P = [Vector(p) for p in pts]
        for i in range(len(P)):
            a, b = P[i], P[(i + 1) % len(P)]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        if n.dot(Vector(out)) < 0:
            pts = list(reversed(pts))
            uvs = list(reversed(uvs)) if uvs else None
        return self.poly(pts, mat, uvs=uvs)

    def quad(self, a, b, c, d, mat):
        return self.poly([a, b, c, d], mat)

    # -- primitives
    def box(self, c, s, mat, rz=0.0, skip=(), mats=None):
        """Axis-aligned (after rz rotation about Z) box centred at c with size s.
        skip: subset of {'+x','-x','+y','-y','+z','-z'}. mats: per-face overrides."""
        cx, cy, cz = c
        hx, hy, hz = s[0] / 2, s[1] / 2, s[2] / 2
        self.push(Matrix.Translation(Vector((cx, cy, cz))) @ rotz(rz))
        P = lambda x, y, z: (x * hx, y * hy, z * hz)
        faces = {
            "+x": [P(1, -1, -1), P(1, 1, -1), P(1, 1, 1), P(1, -1, 1)],
            "-x": [P(-1, 1, -1), P(-1, -1, -1), P(-1, -1, 1), P(-1, 1, 1)],
            "+y": [P(1, 1, -1), P(-1, 1, -1), P(-1, 1, 1), P(1, 1, 1)],
            "-y": [P(-1, -1, -1), P(1, -1, -1), P(1, -1, 1), P(-1, -1, 1)],
            "+z": [P(-1, -1, 1), P(1, -1, 1), P(1, 1, 1), P(-1, 1, 1)],
            "-z": [P(-1, 1, -1), P(1, 1, -1), P(1, -1, -1), P(-1, -1, -1)],
        }
        for k, pts in faces.items():
            if k in skip:
                continue
            self.poly(pts, (mats or {}).get(k, mat))
        self.pop()

    def box2(self, x0, y0, z0, x1, y1, z1, mat, skip=(), mats=None):
        self.box(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (abs(x1 - x0), abs(y1 - y0), abs(z1 - z0)), mat,
                 skip=skip, mats=mats)

    def lathe(self, prof, mat, n=16, c=(0, 0, 0), smooth=True, axis=None, cap_top=False, cap_bottom=False,
              mats=None, a0=0.0, a1=2 * math.pi, uv_size=None):
        """Revolve profile [(r, z), ...] (bottom to top) about local Z. axis: optional Matrix applied
        before translation (to lay the solid along X/Y). mats: per-segment material list."""
        full = abs((a1 - a0) - 2 * math.pi) < 1e-6
        m = Matrix.Translation(Vector(c)) @ (axis or Matrix.Identity(4))
        self.push(m)
        ring_n = n if full else n + 1
        rings = []
        for (r, z) in prof:
            ring = []
            for i in range(ring_n):
                a = a0 + (a1 - a0) * i / n
                ring.append(self.vert((r * math.cos(a), r * math.sin(a), z)))
            rings.append(ring)
        size = uv_size or mat_size(mat)
        # arc length along profile for v
        vs = [0.0]
        for k in range(1, len(prof)):
            vs.append(vs[-1] + math.hypot(prof[k][0] - prof[k - 1][0], prof[k][1] - prof[k - 1][1]))
        rmax = max(p[0] for p in prof) or 1e-3
        for k in range(len(prof) - 1):
            mk = (mats[k] if mats else mat)
            for i in range(n):
                i2 = (i + 1) % ring_n if full else i + 1
                a, b = rings[k][i], rings[k][i2]
                cc, d = rings[k + 1][i2], rings[k + 1][i]
                u0 = (a0 + (a1 - a0) * i / n) * rmax / size
                u1 = (a0 + (a1 - a0) * (i + 1) / n) * rmax / size
                v0, v1 = vs[k] / size, vs[k + 1] / size
                if prof[k][0] < 1e-6 and prof[k + 1][0] < 1e-6:
                    continue
                self.face([a, b, cc, d], mk, smooth, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
        if cap_bottom and prof[0][0] > 1e-6:
            idx = list(reversed(rings[0][:n]))
            self.face(idx, mats[0] if mats else mat, False)
        if cap_top and prof[-1][0] > 1e-6:
            self.face(rings[-1][:n], mats[-1] if mats else mat, False)
        self.pop()

    def cyl(self, c, r, h, mat, n=12, r2=None, caps=(True, True), smooth=True, axis=None, mat_cap=None):
        """Cylinder/frustum with base at c (local Z up unless axis given)."""
        r2 = r if r2 is None else r2
        self.lathe([(r, 0.0), (r2, h)], mat, n=n, c=c, smooth=smooth, axis=axis)
        m = Matrix.Translation(Vector(c)) @ (axis or Matrix.Identity(4))
        self.push(m)
        if caps[0] and r > 0:
            self.poly([(r * math.cos(-2 * math.pi * i / n), r * math.sin(-2 * math.pi * i / n), 0) for i in range(n)],
                      mat_cap or mat)
        if caps[1] and r2 > 0:
            self.poly([(r2 * math.cos(2 * math.pi * i / n), r2 * math.sin(2 * math.pi * i / n), h) for i in range(n)],
                      mat_cap or mat)
        self.pop()

    def sphere(self, c, r, mat, n=12, rings=8, scale=(1, 1, 1), smooth=True, hemi=False):
        prof = []
        lo = 0 if hemi else -rings // 2
        for k in range(lo, rings // 2 + 1):
            t = math.pi * k / rings
            prof.append((math.cos(t) * r, math.sin(t) * r))
        self.push(Matrix.Translation(Vector(c)) @ Matrix.Diagonal((*scale, 1)))
        self.lathe(prof, mat, n=n, smooth=smooth, cap_bottom=hemi)
        self.pop()

    def prism(self, poly2d, z0, z1, mat, mat_caps=None, axis=None, caps=(True, True), side_mats=None):
        """Extrude a CCW (x,y) polygon from z0 to z1 (local); axis lays it along other directions."""
        self.push(axis or Matrix.Identity(4))
        n = len(poly2d)
        bot = [self.vert((x, y, z0)) for x, y in poly2d]
        top = [self.vert((x, y, z1)) for x, y in poly2d]
        for i in range(n):
            j = (i + 1) % n
            self.face([bot[i], bot[j], top[j], top[i]], side_mats[i] if side_mats else mat)
        if caps[1]:
            self.face(top, mat_caps or mat)
        if caps[0]:
            self.face(list(reversed(bot)), mat_caps or mat)
        self.pop()

    def loft(self, rings, matfn, smooth=True, cap_start=True, cap_end=True, cap_mat=None):
        """rings: list of closed point rings (same count). matfn(ring_idx, seg_idx) -> material."""
        idx = [[self.vert(p) for p in ring] for ring in rings]
        n = len(rings[0])
        for k in range(len(rings) - 1):
            for i in range(n):
                j = (i + 1) % n
                self.face([idx[k][i], idx[k][j], idx[k + 1][j], idx[k + 1][i]], matfn(k, i), smooth)
        if cap_start:
            self.face(list(reversed(idx[0])), cap_mat or matfn(0, 0), False)
        if cap_end:
            self.face(idx[-1], cap_mat or matfn(len(rings) - 2, 0), False)
        return idx

    def card(self, c, w, h, normal, up, mat, uv=(0, 0, 1, 1), smooth=False):
        """Two-sided-material leaf card centred at c."""
        n = Vector(normal).normalized()
        upv = Vector(up)
        t = upv.cross(n)
        if t.length < 1e-4:
            t = Vector((1, 0, 0))
        t.normalize()
        u2 = n.cross(t).normalized()
        c = Vector(c)
        pts = [c - t * w / 2 - u2 * h / 2, c + t * w / 2 - u2 * h / 2, c + t * w / 2 + u2 * h / 2,
               c - t * w / 2 + u2 * h / 2]
        u0, v0, u1, v1 = uv
        self.poly(pts, mat, smooth, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
        return len(self.f) - 1

    # -- build
    def build(self, name, uv_offset=None, custom_normals=None, collection=None):
        if not self.f:
            return None
        rnd = random.Random(zlib.crc32(name.encode()))
        mats = []
        for _, m, _, _ in self.f:
            if m not in mats:
                mats.append(m)
        me = bpy.data.meshes.new(name)
        me.from_pydata([tuple(v) for v in self.v], [], [f[0] for f in self.f])
        for m in mats:
            me.materials.append(material(m))
        uvl = me.uv_layers.new(name="UVMap")
        offs = {m: ((rnd.random(), rnd.random()) if uv_offset is None else uv_offset) for m in mats}
        for pi, (idx, m, smooth, uvs) in enumerate(self.f):
            poly = me.polygons[pi]
            poly.material_index = mats.index(m)
            poly.use_smooth = smooth
            size = mat_size(m)
            ou, ov = offs[m]
            if uvs is not None:
                for li, uv in zip(poly.loop_indices, uvs):
                    uvl.data[li].uv = (uv[0] + ou, uv[1] + ov)
                continue
            nrm = poly.normal
            if abs(nrm.z) > 0.999:
                t = Vector((1, 0, 0))
            else:
                t = Vector((0, 0, 1)).cross(nrm).normalized()
            b = nrm.cross(t).normalized()
            for li in poly.loop_indices:
                p = me.vertices[me.loops[li].vertex_index].co
                uvl.data[li].uv = (p.dot(t) / size + ou, p.dot(b) / size + ov)
        me.validate(clean_customdata=False)
        me.update()
        if custom_normals is not None:
            me.normals_split_custom_set_from_vertices(custom_normals)
        ob = bpy.data.objects.new(name, me)
        (collection or bpy.context.scene.collection).objects.link(ob)
        return ob


# ----------------------------------------------------------------------------- export / import

ANIM_PREFIXES = ("Rotor", "Floodlight", "Beacon", "Bulb", "Siren", "StackTop")


def export_glb(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for ob in bpy.context.scene.objects:
        ob.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=False, export_yup=True, export_apply=True,
        export_materials="EXPORT", export_cameras=False, export_lights=False, export_image_format="AUTO",
        export_extras=False,
    )
    return os.path.getsize(path)


def make_empty(name, loc, parent=None):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = 0.02
    e.location = loc
    bpy.context.scene.collection.objects.link(e)
    if parent is not None:
        e.parent = parent
    return e


def import_polyhaven(model_id, target_height=None, target_size=None, decimate=None, name=None, loc=(0, 0, 0),
                     rz=0.0, keep_mats=True, keep=None):
    """Import a cached Poly Haven glTF, join it, optionally decimate, scale and drop to z=0.
    With no target size the model keeps its real-world size (1 unit = 20 m).
    keep: optional predicate on node names (drops alternative variants shipped in one file).
    Textures are swapped for the 512 px derived copies when available."""
    path = os.path.join(CACHE, "models", model_id, "%s_1k.gltf" % model_id)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in objs if o.type == "MESH"]
    if keep is not None:
        drop = {o.name for o in meshes if not keep(o.name)}
        meshes = [o for o in meshes if o.name not in drop]
        objs = [o for o in objs if o.name not in drop]
        for n in drop:
            bpy.data.objects.remove(bpy.data.objects[n], do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    # bake parent transforms into the meshes
    for o in meshes:
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    names = [o.name for o in objs]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    for n in names:
        o = bpy.data.objects.get(n)
        if o is not None and o != ob:
            bpy.data.objects.remove(o, do_unlink=True)
    if decimate:
        mod = ob.modifiers.new("dec", "DECIMATE")
        mod.ratio = decimate
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.modifier_apply(modifier=mod.name)
    # normalise: the imported glTF is Y-up converted to Z-up by the importer already
    me = ob.data
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    h = max(zs) - min(zs)
    ext = max(max(xs) - min(xs), max(ys) - min(ys))
    s = M
    if target_height:
        s = target_height / h
    elif target_size:
        s = target_size / ext
    cx, cy, z0 = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, min(zs)
    for v in me.vertices:
        v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - z0) * s))
    ob.matrix_world = Matrix.Translation(Vector(loc)) @ rotz(rz)
    ob.name = name or model_id
    # swap textures to 512 copies
    d512 = os.path.join(DERIVED, "models512", model_id)
    for slot in ob.material_slots:
        m = slot.material
        if m is None or not m.use_nodes:
            continue
        m.use_backface_culling = True
        for nd in m.node_tree.nodes:
            if nd.type == "TEX_IMAGE" and nd.image is not None:
                im = nd.image
                cands = [os.path.basename(im.filepath)] if im.filepath else []
                cands += [im.name, im.name + ".jpg", im.name + ".png"]
                for fn in cands:
                    alt = os.path.join(d512, fn)
                    if fn and os.path.isfile(alt):
                        new = _img(alt, im.colorspace_settings.name == "Non-Color")
                        new.alpha_mode = im.alpha_mode
                        nd.image = new
                        break
    return ob


def join_objects(objs, name):
    objs = [o for o in objs if o is not None]
    if not objs:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def tri_count():
    t = 0
    for o in bpy.context.scene.objects:
        if o.type == "MESH":
            o.data.calc_loop_triangles()
            t += len(o.data.loop_triangles)
    return t
