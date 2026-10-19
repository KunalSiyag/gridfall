"""Palette atlas shared by the v2 vehicles, the baked parked cars and the street kit.

Small parts (tyres, trim, interior, plates, sign faces, secondary paint) do not each get a material:
builders give a face the pseudo-material "@<swatch>" and resolve(mb) turns it into the one
"Car_Atlas" material with UVs at the centre of that swatch in a fixed 128 x 64 palette texture
(base colour, ARM and emission maps, 8 x 8 px swatches). The palette is identical in every file.

Far LODs use no texture at all: build_vc() writes the swatch colours as vertex colours (COLOR_0)
under the single material "Car_LOD".

A swatch is either a custom entry of PALETTE or any flat material of core.MATS (e.g. "@Paint_blue",
"@Chrome", "@Sign_Red"), listed in MATS_SWATCHES so the atlas layout never depends on build order."""

import os
import struct
import zlib

import bpy

import core

ATLAS_DIR = os.path.join(core.DERIVED, "atlas")
COLS, ROWS, PX = 16, 8, 8
MAT_NAME = "Car_Atlas"
LOD_MAT = "Car_LOD"

# name: (albedo linear rgb, roughness, metallic, emission linear rgb or None)
PALETTE = [
    ("tyre", (0.026, 0.026, 0.028), 0.9, 0.0, None),
    ("tyre_wall", (0.042, 0.042, 0.045), 0.78, 0.0, None),
    ("rim_alloy", (0.60, 0.61, 0.63), 0.26, 1.0, None),
    ("rim_dark", (0.09, 0.09, 0.10), 0.32, 0.85, None),
    ("rim_steel", (0.70, 0.71, 0.72), 0.42, 0.55, None),
    ("rim_barrel", (0.16, 0.16, 0.17), 0.5, 0.8, None),
    ("brake_disc", (0.30, 0.30, 0.31), 0.42, 0.9, None),
    ("trim_black", (0.02, 0.02, 0.022), 0.35, 0.0, None),
    ("plastic_black", (0.032, 0.032, 0.034), 0.68, 0.0, None),
    ("grille", (0.012, 0.012, 0.013), 0.4, 0.3, None),
    ("under", (0.025, 0.025, 0.026), 0.92, 0.0, None),
    ("int_dark", (0.035, 0.035, 0.04), 0.92, 0.0, None),
    ("int_grey", (0.13, 0.13, 0.14), 0.88, 0.0, None),
    ("int_tan", (0.30, 0.21, 0.13), 0.62, 0.0, None),
    ("int_light", (0.40, 0.39, 0.37), 0.9, 0.0, None),
    ("dash", (0.025, 0.025, 0.028), 0.55, 0.0, None),
    ("plate", (0.82, 0.82, 0.80), 0.35, 0.0, None),
    ("plate_text", (0.015, 0.015, 0.025), 0.5, 0.0, None),
    ("mirror", (0.80, 0.81, 0.83), 0.03, 1.0, None),
    ("lens_clear", (0.70, 0.71, 0.72), 0.04, 0.0, None),
    ("reflective_yellow", (0.80, 0.68, 0.04), 0.35, 0.0, None),
    ("reflective_red", (0.62, 0.03, 0.02), 0.35, 0.0, None),
    ("shutter", (0.62, 0.63, 0.65), 0.42, 0.65, None),
    ("box_white", (0.78, 0.79, 0.80), 0.4, 0.2, None),
    ("glass_dark", (0.025, 0.03, 0.035), 0.06, 0.4, None),
    ("lens_head", (0.85, 0.85, 0.84), 0.08, 0.0, None),
    ("lens_tail", (0.40, 0.015, 0.012), 0.12, 0.0, None),
    ("lens_amber", (0.80, 0.36, 0.015), 0.15, 0.0, None),
    ("siren_red", (0.85, 0.05, 0.04), 0.15, 0.0, (1.0, 0.05, 0.03)),
    ("siren_blue", (0.05, 0.15, 0.9), 0.15, 0.0, (0.05, 0.2, 1.0)),
    ("taxi_sign", (0.95, 0.85, 0.25), 0.3, 0.0, (0.8, 0.64, 0.2)),
    ("dest_sign", (0.06, 0.05, 0.03), 0.3, 0.0, (1.0, 0.6, 0.05)),
    ("seat_blue", (0.04, 0.07, 0.18), 0.88, 0.0, None),
    ("seat_red", (0.20, 0.03, 0.03), 0.88, 0.0, None),
    ("floor_grey", (0.16, 0.16, 0.17), 0.85, 0.0, None),
    ("handrail", (0.80, 0.55, 0.04), 0.35, 0.3, None),
    ("frame_black", (0.018, 0.018, 0.02), 0.45, 0.5, None),
    ("leather_black", (0.02, 0.02, 0.022), 0.55, 0.0, None),
    ("cork", (0.45, 0.32, 0.20), 0.85, 0.0, None),
    ("chain", (0.25, 0.25, 0.26), 0.4, 0.9, None),
    ("signal_off", (0.05, 0.05, 0.05), 0.2, 0.0, None),
    ("housing_green", (0.04, 0.10, 0.07), 0.5, 0.3, None),
    ("housing_yellow", (0.70, 0.48, 0.02), 0.45, 0.2, None),
    ("tactile_yellow", (0.75, 0.55, 0.05), 0.75, 0.0, None),
    ("rubber_mat", (0.05, 0.05, 0.05), 0.9, 0.0, None),
    ("wood_slat", (0.30, 0.18, 0.09), 0.7, 0.0, None),
    ("ad_backlight", (0.85, 0.85, 0.83), 0.3, 0.0, (0.9, 0.88, 0.82)),
    ("meter_screen", (0.02, 0.05, 0.04), 0.1, 0.0, (0.05, 0.25, 0.18)),
    ("concrete_light", (0.50, 0.49, 0.46), 0.85, 0.0, None),
    ("concrete_dark", (0.22, 0.22, 0.22), 0.88, 0.0, None),
    ("timber", (0.42, 0.30, 0.18), 0.8, 0.0, None),
    ("plywood", (0.55, 0.42, 0.27), 0.8, 0.0, None),
    ("hoarding_paint", (0.10, 0.16, 0.12), 0.7, 0.0, None),
    ("stripe_red", (0.55, 0.04, 0.03), 0.5, 0.0, None),
    ("stripe_white", (0.85, 0.85, 0.83), 0.5, 0.0, None),
]
MATS_SWATCHES = [
    "Paint_white", "Paint_black", "Paint_silver", "Paint_red", "Paint_blue", "Paint_grey", "Paint_green",
    "Paint_yellow", "Paint_beige", "Paint_orange", "Paint_darkred", "Paint_navy", "Paint_garbage", "Paint_fire",
    "Sign_Red", "Sign_Blue", "Sign_Green", "Sign_White", "Reflective_White", "Chrome", "Rubber", "Plastic_Black",
    "Plastic_Grey", "Metal_Dark", "Metal_Galv", "Metal_White", "Metal_Yellow", "Metal_Red", "Metal_Green",
    "Metal_Blue", "Steel_White", "Paint_teal",
]
# Flat specs some MATS_SWATCHES need when the module that defines them is not imported.
_FALLBACK = {
    "Paint_garbage": ("flat", (0.10, 0.36, 0.15), 0.32, 0.1, {}),
    "Paint_fire": ("flat", (0.62, 0.03, 0.02), 0.28, 0.1, {}),
    "Steel_White": ("flat", (0.72, 0.73, 0.72), 0.4, 0.35, {}),
    "Paint_teal": ("flat", (0.02, 0.22, 0.24), 0.3, 0.2, {"coat": 1.0}),
}


def _table():
    out = {}
    for i, (n, col, r, m, e) in enumerate(PALETTE):
        out[n] = (i, col, r, m, e)
    k = len(PALETTE)
    for n in MATS_SWATCHES:
        spec = core.MATS.get(n) or _FALLBACK[n]
        _, col, r, m, extra = spec
        e = extra.get("emission") if extra else None
        out[n] = (k, col, r, m, e)
        k += 1
    assert k <= COLS * ROWS, "palette overflow"
    return out


SWATCHES = _table()


def has(name):
    return name in SWATCHES


def uv(name):
    """Blender UV of the centre of a swatch (v up; the exporter flips it for glTF)."""
    i = SWATCHES[name][0]
    col, row = i % COLS, i // COLS
    return ((col + 0.5) / COLS, 1.0 - (row + 0.5) / ROWS)


def colour(name):
    return SWATCHES[name][1]


# ----------------------------------------------------------------------------- texture files

def _srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def _png(path, w, h, pix):
    """Write an 8-bit RGB PNG (pix: function (x, y) -> (r, g, b) bytes, y = 0 at the top)."""
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            row += bytes(pix(x, y))
        rows.append(bytes(row))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
    if os.path.exists(path):
        with open(path, "rb") as fh:
            if fh.read() == data:
                return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def write_textures():
    """(Re)write the three palette maps under the derived cache; returns their paths."""
    w, h = COLS * PX, ROWS * PX
    by_index = {sw[0]: sw for sw in SWATCHES.values()}

    def sw(x, y):
        return by_index.get((y // PX) * COLS + x // PX)

    def diff(x, y):
        s = sw(x, y)
        c = s[1] if s else (0.5, 0.5, 0.5)
        return [int(round(_srgb(v) * 255)) for v in c]

    def arm(x, y):
        s = sw(x, y)
        return [255, int(round((s[2] if s else 0.8) * 255)), int(round((s[3] if s else 0.0) * 255))]

    def emit(x, y):
        s = sw(x, y)
        e = s[4] if s and s[4] else (0.0, 0.0, 0.0)
        return [int(round(_srgb(v) * 255)) for v in e]
    paths = {k: os.path.join(ATLAS_DIR, "car_atlas_%s.png" % k) for k in ("diff", "arm", "emit")}
    _png(paths["diff"], w, h, diff)
    _png(paths["arm"], w, h, arm)
    _png(paths["emit"], w, h, emit)
    return paths


# ----------------------------------------------------------------------------- materials

def material():
    """The Car_Atlas material (cached per build in core._mat_cache)."""
    if MAT_NAME in core._mat_cache:
        return core._mat_cache[MAT_NAME]
    paths = write_textures()
    m = bpy.data.materials.new(MAT_NAME)
    m.use_nodes = True
    m.use_backface_culling = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")

    def tex(p, noncolor=False):
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = core._img(p, noncolor)
        t.interpolation = "Closest"
        return t
    d = tex(paths["diff"])
    nt.links.new(d.outputs["Color"], b.inputs["Base Color"])
    a = tex(paths["arm"], True)
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(a.outputs["Color"], sep.inputs[0])
    nt.links.new(sep.outputs[1], b.inputs["Roughness"])
    nt.links.new(sep.outputs[2], b.inputs["Metallic"])
    e = tex(paths["emit"])
    nt.links.new(e.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 1.0
    m.diffuse_color = (0.3, 0.3, 0.3, 1)
    core._mat_cache[MAT_NAME] = m
    return m


def lod_material():
    if LOD_MAT in core._mat_cache:
        return core._mat_cache[LOD_MAT]
    m = bpy.data.materials.new(LOD_MAT)
    m.use_nodes = True
    m.use_backface_culling = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    ca = nt.nodes.new("ShaderNodeVertexColor")
    ca.layer_name = "Color"
    nt.links.new(ca.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.45
    b.inputs["Metallic"].default_value = 0.0
    m.diffuse_color = (0.5, 0.5, 0.5, 1)
    core._mat_cache[LOD_MAT] = m
    return m


def resolve(mb):
    """Turn every "@swatch" face of mb into a Car_Atlas face with swatch-centre UVs."""
    used = False
    for k, (idx, m, smooth, uvs) in enumerate(mb.f):
        if isinstance(m, str) and m.startswith("@"):
            u = uv(m[1:])
            mb.f[k] = (idx, MAT_NAME, smooth, [u] * len(idx))
            used = True
    if used:
        material()
    return used


LAMP_SWATCHES = ("lens_head", "lens_tail")


def build_vc(mb, name, smooth_angle=None):
    """Build mb as one mesh with the single vertex-coloured material Car_LOD; every face must use a
    "@swatch" (or a flat MATS name). Returns the object.

    The material has no texture, so UV0 carries a flag instead: u = 1 on head- and tail-lamp faces
    (LAMP_SWATCHES), 0 elsewhere (glTF export drops vertex-colour alpha, so alpha cannot carry it)."""
    if not mb.f:
        return None
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in mb.v], [], [f[0] for f in mb.f])
    me.materials.append(lod_material())
    ca = me.color_attributes.new("Color", "BYTE_COLOR", "CORNER")
    uvl = me.uv_layers.new(name="UVMap")
    for pi, (idx, m, smooth, uvs) in enumerate(mb.f):
        n = m[1:] if m.startswith("@") else m
        c = SWATCHES[n][1]
        lamp = 1.0 if n in LAMP_SWATCHES else 0.0
        poly = me.polygons[pi]
        poly.material_index = 0
        poly.use_smooth = smooth
        for li in poly.loop_indices:
            ca.data[li].color = (c[0], c[1], c[2], 1.0)
            uvl.data[li].uv = (lamp, 0.0)
    me.validate(clean_customdata=False)
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if smooth_angle is not None:
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        try:
            bpy.ops.object.shade_smooth_by_angle(angle=smooth_angle)
        except Exception:
            pass
    return ob
