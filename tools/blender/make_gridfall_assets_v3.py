"""GridFall v3 model library: Blender-built zone variants, service buildings, props and vehicles.

Same style, palette and export settings as make_gridfall_assets.py (flat low-poly, Blender
Z-up, front of every model faces Blender -Y which is Godot +Z, 1 tile = 1 unit).

All static parts of a model are joined into one mesh ("<name>_body"); parts the game
animates keep their own object and name prefix:
    Rotor*      wind turbine rotors (origin at hub, spin about local Z = forward axis);
                helicopter main rotor spins about local Y (up), tail rotor about local X
    Floodlight* stadium light heads      Beacon* airport tower beacon
    Bulb*       street lamp bulbs        Siren*  emergency light bars

Usage:
    blender --background --python /ABS/tools/blender/make_gridfall_assets_v3.py -- all
    blender --background --python /ABS/tools/blender/make_gridfall_assets_v3.py -- buildings/stadium props
    (filters match any output path starting with the given prefix)
"""

import math
import os
import sys

import bmesh
import bpy

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODELS = os.path.join(PROJECT_ROOT, "models")
ANIM_PREFIXES = ("Rotor", "Floodlight", "Beacon", "Bulb", "Siren")

PALETTE = {
    "basalt": ((0.075, 0.090, 0.133, 1.0), 0.25, 0.78, None, 0.0),
    "titanium": ((0.839, 0.875, 0.922, 1.0), 0.18, 0.55, None, 0.0),
    "slate": ((0.18, 0.21, 0.28, 1.0), 0.30, 0.65, None, 0.0),
    "copper": ((0.82, 0.46, 0.20, 1.0), 0.75, 0.35, None, 0.0),
    "dark_glass": ((0.06, 0.11, 0.18, 1.0), 0.65, 0.18, None, 0.0),
    "cyan_glow": ((0.0, 0.94, 1.0, 1.0), 0.0, 0.25, (0.0, 0.94, 1.0, 1.0), 2.8),
    "amber_glow": ((1.0, 0.72, 0.0, 1.0), 0.0, 0.30, (1.0, 0.72, 0.0, 1.0), 2.6),
    "crimson_glow": ((1.0, 0.180, 0.329, 1.0), 0.0, 0.28, (1.0, 0.180, 0.329, 1.0), 2.8),
    "lamp_glow": ((1.0, 0.93, 0.70, 1.0), 0.0, 0.30, (1.0, 0.90, 0.62, 1.0), 4.0),
    "concrete": ((0.56, 0.57, 0.58, 1.0), 0.05, 0.85, None, 0.0),
    "light_concrete": ((0.74, 0.74, 0.72, 1.0), 0.05, 0.85, None, 0.0),
    "asphalt": ((0.16, 0.16, 0.18, 1.0), 0.0, 0.92, None, 0.0),
    "stack_red": ((0.78, 0.12, 0.10, 1.0), 0.10, 0.60, None, 0.0),
    "white": ((0.93, 0.94, 0.95, 1.0), 0.05, 0.55, None, 0.0),
    "sky_blue": ((0.48, 0.74, 0.92, 1.0), 0.35, 0.45, None, 0.0),
    "water": ((0.20, 0.55, 0.85, 1.0), 0.30, 0.15, None, 0.0),
    "navy": ((0.08, 0.14, 0.36, 1.0), 0.20, 0.55, None, 0.0),
    "brick": ((0.62, 0.17, 0.12, 1.0), 0.05, 0.80, None, 0.0),
    "terracotta": ((0.86, 0.50, 0.28, 1.0), 0.05, 0.75, None, 0.0),
    "roof_red": ((0.55, 0.18, 0.14, 1.0), 0.10, 0.65, None, 0.0),
    "grass": ((0.30, 0.58, 0.28, 1.0), 0.0, 0.90, None, 0.0),
    "leaf": ((0.22, 0.48, 0.22, 1.0), 0.0, 0.90, None, 0.0),
    "cream": ((0.93, 0.87, 0.72, 1.0), 0.05, 0.70, None, 0.0),
    "beige": ((0.82, 0.74, 0.60, 1.0), 0.05, 0.75, None, 0.0),
    "teal": ((0.07, 0.52, 0.52, 1.0), 0.20, 0.50, None, 0.0),
    "factory_yellow": ((0.80, 0.66, 0.26, 1.0), 0.15, 0.60, None, 0.0),
    "wood": ((0.52, 0.33, 0.18, 1.0), 0.0, 0.80, None, 0.0),
    "dirt": ((0.45, 0.34, 0.22, 1.0), 0.0, 0.95, None, 0.0),
    "dirt_dark": ((0.33, 0.25, 0.17, 1.0), 0.0, 0.95, None, 0.0),
    "iron": ((0.12, 0.13, 0.15, 1.0), 0.60, 0.45, None, 0.0),
    "sage": ((0.55, 0.68, 0.58, 1.0), 0.05, 0.70, None, 0.0),
    "mustard": ((0.88, 0.72, 0.30, 1.0), 0.05, 0.70, None, 0.0),
    "orange": ((0.95, 0.48, 0.12, 1.0), 0.10, 0.60, None, 0.0),
    "bus_blue": ((0.12, 0.38, 0.72, 1.0), 0.15, 0.45, None, 0.0),
    "trash_a": ((0.30, 0.42, 0.62, 1.0), 0.0, 0.90, None, 0.0),
    "trash_b": ((0.62, 0.58, 0.30, 1.0), 0.0, 0.90, None, 0.0),
    "rubber": ((0.06, 0.06, 0.07, 1.0), 0.0, 0.90, None, 0.0),
    "rail": ((0.55, 0.55, 0.58, 1.0), 0.80, 0.30, None, 0.0),
    "ad_pink": ((0.95, 0.30, 0.55, 1.0), 0.0, 0.40, (0.95, 0.30, 0.55, 1.0), 1.2),
    "flood_glow": ((1.0, 0.98, 0.88, 1.0), 0.0, 0.25, (1.0, 0.98, 0.88, 1.0), 5.0),
}

_materials = {}


def mat(name):
    if name in _materials:
        return _materials[name]
    color, metallic, roughness, emission, strength = PALETTE[name]
    m = bpy.data.materials.new(name="gf_" + name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = emission
        bsdf.inputs["Emission Strength"].default_value = strength
    m.diffuse_color = color  # workbench preview colour
    _materials[name] = m
    return m


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _materials.clear()


def _finish(obj, material, name, smooth=False):
    obj.name = name
    obj.data.materials.append(mat(material))
    for poly in obj.data.polygons:
        poly.use_smooth = smooth
    return obj


def box(material, center, size, name="part", rot_euler=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=center, rotation=rot_euler)
    obj = bpy.context.view_layer.objects.active
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    return _finish(obj, material, name)


def cylinder(material, center, radius, height, vertices=12, name="part", rot_euler=(0.0, 0.0, 0.0), scale_xy=(1.0, 1.0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=height, location=center)
    obj = bpy.context.view_layer.objects.active
    obj.scale = (scale_xy[0], scale_xy[1], 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.rotation_euler = rot_euler
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return _finish(obj, material, name)


def cone(material, center, radius1, radius2, height, vertices=12, name="part", rot_euler=(0.0, 0.0, 0.0), scale_xy=(1.0, 1.0)):
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius1, radius2=radius2, depth=height, location=center)
    obj = bpy.context.view_layer.objects.active
    obj.scale = (scale_xy[0], scale_xy[1], 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.rotation_euler = rot_euler
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return _finish(obj, material, name)


def sphere(material, center, radius, segments=12, rings=8, name="part", scale=(1.0, 1.0, 1.0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=radius, location=center)
    obj = bpy.context.view_layer.objects.active
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _finish(obj, material, name)


def ico(material, center, radius, name="part", scale=(1.0, 1.0, 1.0), subdiv=1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdiv, radius=radius, location=center)
    obj = bpy.context.view_layer.objects.active
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _finish(obj, material, name)


def prism_x(material, profile_yz, x_min, x_max, name="part"):
    """Extrude a closed (y, z) polygon profile along X (gable roofs, pediments)."""
    n = len(profile_yz)
    verts = [(x_min, y, z) for y, z in profile_yz] + [(x_max, y, z) for y, z in profile_yz]
    faces = [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return _finish(obj, material, name)


def prism_y(material, profile_xz, y_min, y_max, name="part"):
    """Extrude a closed (x, z) polygon profile along Y."""
    n = len(profile_xz)
    verts = [(x, y_min, z) for x, z in profile_xz] + [(x, y_max, z) for x, z in profile_xz]
    faces = [tuple(range(n)), tuple(reversed(range(n, 2 * n)))]
    faces += [(i, n + i, n + (i + 1) % n, (i + 1) % n) for i in range(n)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return _finish(obj, material, name)


def join(objs, name):
    """Join objs into objs[0]; the result keeps objs[0]'s origin."""
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


# ---------------------------------------------------------------- facade helpers

def windows_ring(cx, cy, w, d, z, h, material="dark_glass", cols_x=3, cols_y=3, inset=0.012, win_w=None):
    """Window panes on all four faces of a w x d block centred at (cx, cy) at height z."""
    for side in (-1, 1):
        for i in range(cols_x):
            ww = win_w or (w / cols_x) * 0.6
            x = cx - w / 2 + (i + 0.5) * w / cols_x
            box(material, (x, cy + side * (d / 2 + inset / 2), z), (ww, inset, h), "win")
        for i in range(cols_y):
            ww = win_w or (d / cols_y) * 0.6
            y = cy - d / 2 + (i + 0.5) * d / cols_y
            box(material, (cx + side * (w / 2 + inset / 2), y, z), (inset, ww, h), "win")


def bands_ring(cx, cy, w, d, z, h, material="dark_glass", inset=0.012):
    for side in (-1, 1):
        box(material, (cx, cy + side * (d / 2 + inset / 2), z), (w * 0.86, inset, h), "band")
        box(material, (cx + side * (w / 2 + inset / 2), cy, z), (inset, d * 0.86, h), "band")


def gable_house(cx, cy, w, d, wall_h, roof_h, wall="cream", roof="roof_red", z0=0.0, door=True):
    box(wall, (cx, cy, z0 + wall_h / 2), (w, d, wall_h), "walls")
    prism_x(roof, [(cy - d / 2 - 0.02, z0 + wall_h), (cy + d / 2 + 0.02, z0 + wall_h), (cy, z0 + wall_h + roof_h)],
            cx - w / 2 - 0.015, cx + w / 2 + 0.015, "roof")
    if door:
        box("wood", (cx, cy - d / 2 - 0.005, z0 + 0.06), (min(0.07, w * 0.3), 0.01, 0.12), "door")


def tree(x, y, s=1.0, crown="leaf"):
    cylinder("wood", (x, y, 0.03 * s), 0.012 * s, 0.06 * s, vertices=6, name="trunk")
    ico(crown, (x, y, 0.10 * s), 0.055 * s, name="crown", scale=(1.0, 1.0, 1.15))


def plinth(size=0.94, h=0.04, material="basalt"):
    box(material, (0.0, 0.0, h / 2), (size, size, h), "plinth")


# ---------------------------------------------------------------- zones: r2

def build_r2_townhouse_row():
    plinth(material="light_concrete", h=0.03)
    colors = ["cream", "terracotta", "sage", "mustard"]
    w = 0.21
    for i, c in enumerate(colors):
        x = -0.33 + i * 0.22
        h = 0.62 + (i % 2) * 0.08
        gable_house(x, 0.05, w, 0.56, h, 0.16, wall=c, roof="slate" if i % 2 else "roof_red", z0=0.03)
        for z in (0.22, 0.42) + ((0.60,) if h > 0.65 else ()):
            box("dark_glass", (x, 0.05 - 0.285, z), (0.11, 0.01, 0.09), "win")
            box("white", (x, 0.05 - 0.29, z - 0.05), (0.13, 0.02, 0.012), "sill")
        box("light_concrete", (x, -0.28, 0.045), (0.08, 0.06, 0.03), "stoop")
    box("leaf", (0.0, -0.40, 0.05), (0.88, 0.06, 0.04), "hedge")


def build_r2_walkup_brick():
    plinth(h=0.04)
    box("brick", (0.0, 0.04, 0.04 + 0.55), (0.82, 0.62, 1.10), "block")
    box("light_concrete", (0.0, 0.04, 1.16), (0.86, 0.66, 0.04), "cornice")
    for f in range(5):
        z = 0.16 + f * 0.21
        windows_ring(0.0, 0.04, 0.82, 0.62, z, 0.11, cols_x=4, cols_y=3, material="amber_glow" if f == 2 else "dark_glass")
    # fire escape on the east side
    for f in range(1, 5):
        z = 0.06 + f * 0.21
        box("iron", (0.425, 0.04, z), (0.04, 0.30, 0.012), "escape")
        box("iron", (0.445, 0.04, z + 0.035), (0.004, 0.30, 0.004), "rail")
    box("iron", (0.445, 0.04, 0.60), (0.008, 0.008, 0.9), "ladder")
    box("dark_glass", (0.0, -0.28, 0.12), (0.14, 0.02, 0.16), "door")
    box("navy", (0.0, -0.31, 0.22), (0.22, 0.06, 0.015), "door_canopy")
    box("slate", (0.15, 0.10, 1.23), (0.16, 0.14, 0.10), "roof_access")
    cylinder("wood", (-0.2, 0.15, 1.25), 0.06, 0.12, vertices=10, name="water_tank")
    cone("slate", (-0.2, 0.15, 1.34), 0.065, 0.0, 0.06, vertices=10, name="tank_roof")


def build_r2_duplex():
    box("grass", (0.0, 0.0, 0.01), (0.94, 0.94, 0.02), "lawn")
    box("light_concrete", (0.0, -0.33, 0.021), (0.12, 0.28, 0.004), "path")
    for sx, wall in ((-1, "beige"), (1, "white")):
        x = sx * 0.19
        box(wall, (x, 0.08, 0.02 + 0.30), (0.36, 0.48, 0.60), "half")
        for z in (0.17, 0.42):
            for dx in (-0.08, 0.08):
                box("dark_glass", (x + dx, 0.08 - 0.245, z), (0.08, 0.01, 0.10), "win")
        box("wood", (x - sx * 0.12, 0.08 - 0.245, 0.09), (0.06, 0.01, 0.13), "door")
    prism_x("slate", [(-0.20, 0.62), (0.36, 0.62), (0.08, 0.80)], -0.40, 0.40, "roof")
    box("white", (0.0, -0.215, 0.33), (0.74, 0.06, 0.012), "porch_roof")
    tree(-0.36, -0.36, 1.2)
    tree(0.37, -0.32, 1.0)


# ---------------------------------------------------------------- zones: r3

def build_r3_tower_slab():
    plinth()
    box("light_concrete", (0.0, 0.0, 0.04 + 0.11), (0.86, 0.56, 0.22), "podium")
    box("dark_glass", (0.0, -0.285, 0.13), (0.6, 0.012, 0.12), "lobby_glass")
    fh = 0.16
    n = 12
    box("white", (0.0, 0.04, 0.26 + fh * n / 2), (0.78, 0.40, fh * n), "slab")
    for i in range(n):
        z = 0.26 + i * fh + 0.08
        bands_ring(0.0, 0.04, 0.78, 0.40, z, 0.07, material="amber_glow" if i in (3, 8) else "dark_glass")
        box("light_concrete", (0.0, 0.04 - 0.23, z - 0.055), (0.74, 0.06, 0.012), "balcony")
    box("slate", (0.0, 0.04, 0.26 + fh * n + 0.03), (0.80, 0.42, 0.06), "roof")
    box("slate", (0.2, 0.06, 0.26 + fh * n + 0.10), (0.16, 0.14, 0.10), "plant_room")


def build_r3_tower_twin():
    plinth()
    box("sage", (0.0, 0.0, 0.04 + 0.08), (0.88, 0.88, 0.16), "podium")
    box("grass", (0.0, 0.0, 0.205), (0.80, 0.80, 0.01), "roof_garden")
    for (x, y, floors, c) in ((-0.2, 0.18, 13, "cream"), (0.2, -0.16, 10, "beige")):
        fh = 0.15
        box(c, (x, y, 0.20 + fh * floors / 2), (0.34, 0.34, fh * floors), "tower")
        for i in range(floors):
            windows_ring(x, y, 0.34, 0.34, 0.20 + i * fh + 0.08, 0.075, cols_x=3, cols_y=3,
                         material="amber_glow" if (i * 7 + floors) % 5 == 0 else "dark_glass")
        box("teal", (x, y, 0.20 + fh * floors + 0.02), (0.36, 0.36, 0.04), "crown")
    box("dark_glass", (0.0, -0.445, 0.11), (0.3, 0.012, 0.1), "lobby")


def build_r3_tower_stepped():
    plinth()
    tiers = [(0.82, 0.82, 0.04, 0.40, "terracotta"), (0.66, 0.66, 0.44, 0.60, "cream"),
             (0.50, 0.50, 1.04, 0.60, "cream"), (0.34, 0.34, 1.64, 0.42, "terracotta")]
    for w, d, z0, h, c in tiers:
        box(c, (0.0, 0.0, z0 + h / 2), (w, d, h), "tier")
        floors = int(round(h / 0.14))
        for i in range(floors):
            windows_ring(0.0, 0.0, w, d, z0 + (i + 0.5) * h / floors, 0.07, cols_x=max(2, int(w / 0.14)),
                         cols_y=max(2, int(d / 0.14)))
        box("grass", (0.0, 0.0, z0 + h + 0.005), (w - 0.02, d - 0.02, 0.01), "terrace")
    cylinder("slate", (0.0, 0.0, 2.12), 0.012, 0.18, vertices=6, name="mast")
    box("dark_glass", (0.0, -0.416, 0.13), (0.2, 0.012, 0.16), "lobby")


def build_r3_tower_round():
    plinth()
    cylinder("light_concrete", (0.0, 0.0, 0.04 + 0.08), 0.44, 0.16, vertices=16, name="podium")
    fh = 0.15
    n = 15
    cylinder("white", (0.0, 0.0, 0.20 + fh * n / 2), 0.30, fh * n, vertices=16, name="shaft")
    for i in range(n):
        z = 0.20 + i * fh
        cylinder("amber_glow" if i % 6 == 2 else "dark_glass", (0.0, 0.0, z + 0.08), 0.305, 0.07, vertices=16, name="band")
        cylinder("light_concrete", (0.0, 0.0, z + 0.025), 0.335, 0.014, vertices=16, name="balcony")
    cylinder("teal", (0.0, 0.0, 0.20 + fh * n + 0.03), 0.31, 0.06, vertices=16, name="crown")
    cylinder("slate", (0.0, 0.0, 0.20 + fh * n + 0.12), 0.12, 0.12, vertices=12, name="cap")
    box("dark_glass", (0.0, -0.44, 0.12), (0.2, 0.02, 0.12), "lobby")


# ---------------------------------------------------------------- zones: c1

def awning(cx, cy, w, z, colors=("stack_red", "white"), stripes=6, depth=0.12):
    for i in range(stripes):
        x = cx - w / 2 + (i + 0.5) * w / stripes
        box(colors[i % 2], (x, cy - depth / 2, z), (w / stripes, depth, 0.012), "awning",
            rot_euler=(math.radians(-14), 0, 0))


def build_c1_corner_store():
    box("light_concrete", (0.0, 0.0, 0.01), (0.94, 0.94, 0.02), "sidewalk")
    box("mustard", (0.0, 0.1, 0.02 + 0.22), (0.76, 0.56, 0.44), "store")
    box("slate", (0.0, 0.1, 0.475), (0.80, 0.60, 0.03), "parapet")
    box("dark_glass", (0.0, -0.185, 0.15), (0.62, 0.012, 0.18), "shopfront")
    box("dark_glass", (0.385, 0.1, 0.15), (0.012, 0.40, 0.18), "side_glass")
    awning(0.0, -0.19, 0.70, 0.27)
    box("white", (0.0, -0.19, 0.36), (0.44, 0.012, 0.07), "sign")
    box("crimson_glow", (0.0, -0.197, 0.36), (0.36, 0.006, 0.035), "sign_text")
    for x in (-0.25, 0.25):
        box("wood", (x, -0.30, 0.045), (0.12, 0.06, 0.05), "crate")
        box("leaf", (x, -0.30, 0.08), (0.11, 0.05, 0.02), "produce")
    box("slate", (-0.2, 0.25, 0.53), (0.14, 0.12, 0.07), "hvac")


def build_c1_cafe():
    box("light_concrete", (0.0, 0.0, 0.01), (0.94, 0.94, 0.02), "sidewalk")
    box("white", (0.0, 0.16, 0.02 + 0.19), (0.72, 0.44, 0.38), "cafe")
    box("wood", (0.0, 0.16, 0.415), (0.76, 0.48, 0.03), "roof")
    box("dark_glass", (0.0, -0.065, 0.16), (0.60, 0.012, 0.22), "glass")
    box("teal", (0.0, -0.08, 0.31), (0.66, 0.02, 0.05), "sign_band")
    box("amber_glow", (0.0, -0.092, 0.31), (0.3, 0.006, 0.025), "sign_text")
    box("wood", (0.0, -0.25, 0.022), (0.86, 0.32, 0.006), "deck")
    for i, x in enumerate((-0.27, 0.0, 0.27)):
        cylinder("white", (x, -0.25, 0.04), 0.035, 0.006, vertices=10, name="table_top_low")
        cylinder("iron", (x, -0.25, 0.07), 0.006, 0.10, vertices=6, name="table_leg")
        cylinder("white", (x, -0.25, 0.10), 0.04, 0.006, vertices=10, name="table_top")
        cylinder("iron", (x, -0.25, 0.16), 0.004, 0.16, vertices=6, name="parasol_pole")
        cone("stack_red" if i % 2 else "teal", (x, -0.25, 0.24), 0.11, 0.0, 0.05, vertices=8, name="parasol")
    for x in (-0.4, 0.4):
        cylinder("concrete", (x, -0.4, 0.05), 0.035, 0.06, vertices=8, name="pot")
        ico("leaf", (x, -0.4, 0.11), 0.045, name="shrub")


def build_c1_diner():
    box("asphalt", (0.0, 0.0, 0.01), (0.94, 0.94, 0.02), "lot")
    for x in (-0.3, -0.1, 0.1, 0.3):
        box("white", (x, -0.33, 0.021), (0.01, 0.2, 0.002), "stall_line")
    cylinder("titanium", (0.0, 0.16, 0.02 + 0.15), 0.36, 0.30, vertices=24, name="diner", scale_xy=(1.0, 0.55))
    cylinder("crimson_glow", (0.0, 0.16, 0.20), 0.365, 0.03, vertices=24, name="stripe", scale_xy=(1.0, 0.56))
    cylinder("dark_glass", (0.0, 0.16, 0.13), 0.362, 0.08, vertices=24, name="windows", scale_xy=(1.0, 0.555))
    cylinder("slate", (0.0, 0.16, 0.335), 0.37, 0.03, vertices=24, name="roof", scale_xy=(1.0, 0.57))
    box("dark_glass", (0.0, -0.045, 0.11), (0.08, 0.02, 0.16), "door")
    # tall roadside sign
    box("iron", (-0.38, -0.25, 0.25), (0.02, 0.02, 0.46), "sign_pole")
    box("stack_red", (-0.38, -0.25, 0.50), (0.16, 0.03, 0.10), "sign")
    box("amber_glow", (-0.38, -0.267, 0.50), (0.12, 0.004, 0.05), "sign_text")
    box("slate", (0.2, 0.2, 0.37), (0.12, 0.1, 0.05), "hvac")


# ---------------------------------------------------------------- zones: i3

def build_i3_refinery():
    plinth(material="concrete")
    for i, (x, y, r) in enumerate(((-0.27, 0.24, 0.15), (0.06, 0.28, 0.12), (0.30, 0.25, 0.12))):
        cylinder("white", (x, y, 0.04 + 0.14), r, 0.28, vertices=16, name="tank")
        cone("light_concrete", (x, y, 0.35), r, r * 0.8, 0.04, vertices=16, name="tank_roof")
        cylinder("factory_yellow", (x, y, 0.22), r + 0.004, 0.025, vertices=16, name="tank_band")
    for i, (x, h) in enumerate(((-0.28, 1.55), (-0.1, 1.85), (0.08, 1.35))):
        cylinder("titanium", (x, -0.18, 0.04 + h / 2), 0.055, h, vertices=10, name="column")
        for z in range(3):
            cylinder("slate", (x, -0.18, 0.3 + z * h / 3.5), 0.062, 0.02, vertices=10, name="platform")
        cone("slate", (x, -0.18, 0.04 + h + 0.03), 0.055, 0.02, 0.06, vertices=10, name="column_cap")
    box("copper", (-0.1, -0.18, 0.6), (0.4, 0.03, 0.03), "pipe_rack")
    box("copper", (0.1, -0.02, 0.2), (0.03, 0.34, 0.03), "pipe")
    # flare stack
    cylinder("stack_red", (0.33, -0.25, 0.04 + 1.1), 0.025, 2.2, vertices=8, name="flare")
    cone("orange", (0.33, -0.25, 2.30), 0.03, 0.0, 0.1, vertices=8, name="flare_tip")
    box("slate", (0.30, -0.02, 0.12), (0.22, 0.16, 0.16), "control_room")
    box("dark_glass", (0.30, -0.101, 0.13), (0.16, 0.01, 0.05), "control_glass")


def build_i3_cooling_plant():
    plinth(material="concrete")
    for i, (x, y) in enumerate(((-0.22, 0.20), (0.22, 0.20))):
        cone("light_concrete", (x, y, 0.04 + 0.45), 0.21, 0.14, 0.90, vertices=18, name="tower_low")
        cone("light_concrete", (x, y, 0.04 + 0.90 + 0.30), 0.14, 0.17, 0.60, vertices=18, name="tower_high")
        cylinder("stack_red", (x, y, 1.47), 0.172, 0.04, vertices=18, name="tower_rim")
    box("titanium", (-0.12, -0.24, 0.04 + 0.2), (0.48, 0.34, 0.40), "turbine_hall")
    box("slate", (-0.12, -0.24, 0.455), (0.50, 0.36, 0.03), "hall_roof")
    box("dark_glass", (-0.12, -0.415, 0.30), (0.40, 0.01, 0.06), "hall_windows")
    cylinder("white", (0.27, -0.24, 0.04 + 0.22), 0.13, 0.44, vertices=16, name="reactor")
    sphere("white", (0.27, -0.24, 0.48), 0.13, segments=16, rings=8, name="dome")
    cylinder("concrete", (0.36, 0.0, 0.04 + 0.85), 0.035, 1.7, vertices=10, name="vent_stack")
    for k in range(4):
        cylinder("stack_red" if k % 2 else "white", (0.36, 0.0, 1.3 + k * 0.1), 0.037, 0.1, vertices=10, name="stack_band")


# ---------------------------------------------------------------- service buildings

def blade_rotor(name, hub, radius, n=3, blade_w=0.03, mat_blade="white", phase=0.0):
    hx, hy, hz = hub
    parts = [sphere("titanium", hub, radius * 0.14, segments=10, rings=6, name=name)]
    for k in range(n):
        th = phase + 2 * math.pi * k / n
        c = (hx + math.sin(th) * radius / 2, hy - 0.01, hz + math.cos(th) * radius / 2)
        parts.append(box(mat_blade, c, (blade_w, 0.012, radius), "blade", rot_euler=(0.0, th, 0.0)))
    return join(parts, name)


def build_wind_farm():
    box("grass", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "pad")
    box("light_concrete", (0.0, 0.0, 0.031), (0.10, 0.90, 0.004), "service_road")
    for i, (x, y, h) in enumerate(((-0.25, 0.22, 0.88), (0.25, 0.22, 0.78), (0.0, -0.22, 0.95))):
        cylinder("concrete", (x, y, 0.045), 0.06, 0.03, vertices=8, name="footing")
        cone("white", (x, y, 0.03 + h / 2), 0.022, 0.012, h, vertices=10, name="tower")
        box("white", (x, y + 0.01, 0.03 + h + 0.015), (0.04, 0.09, 0.04), "nacelle")
        blade_rotor("Rotor_%d" % i, (x, y - 0.04, 0.03 + h + 0.015), 0.19, phase=0.4 * i)
    box("slate", (0.32, -0.33, 0.08), (0.18, 0.12, 0.10), "substation")
    box("factory_yellow", (0.32, -0.395, 0.08), (0.12, 0.01, 0.02), "stripe")


def build_stadium():
    box("light_concrete", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "plaza")
    sx = 1.0
    sy = 0.80
    cylinder("concrete", (0.0, 0.0, 0.03 + 0.12), 0.43, 0.24, vertices=28, name="outer_wall", scale_xy=(sx, sy))
    cylinder("navy", (0.0, 0.0, 0.03 + 0.115), 0.433, 0.05, vertices=28, name="band", scale_xy=(sx, sy))
    for k, (r, h) in enumerate(((0.40, 0.23), (0.36, 0.19), (0.32, 0.15), (0.28, 0.11))):
        cylinder("stack_red" if k % 2 else "white", (0.0, 0.0, 0.03 + h / 2 + 0.005), r, h, vertices=28,
                 name="tier", scale_xy=(sx, sy))
    cylinder("grass", (0.0, 0.0, 0.03 + 0.06), 0.25, 0.12, vertices=28, name="field", scale_xy=(sx, sy))
    box("white", (0.0, 0.0, 0.151), (0.004, 0.36, 0.002), "halfway")
    box("white", (0.0, 0.0, 0.151), (0.30, 0.004, 0.002), "touchline")
    cylinder("white", (0.0, 0.0, 0.151), 0.04, 0.002, vertices=16, name="centre_circle")
    cylinder("grass", (0.0, 0.0, 0.1515), 0.036, 0.002, vertices=16, name="centre_fill")
    for k, (x, y) in enumerate(((-0.42, -0.40), (0.42, -0.40), (-0.42, 0.40), (0.42, 0.40))):
        box("slate", (x, y, 0.03 + 0.30), (0.018, 0.018, 0.60), "mast")
        box("slate", (x * 0.97, y * 0.97, 0.63), (0.10, 0.03, 0.06), "head_frame",
            rot_euler=(0, 0, math.atan2(y, x) + math.pi / 2))
        box("flood_glow", (x * 0.95, y * 0.95, 0.63), (0.09, 0.012, 0.05), "Floodlight_%d" % k,
            rot_euler=(math.radians(-30) if y < 0 else math.radians(30), 0, math.atan2(y, x) + math.pi / 2))
    box("dark_glass", (0.0, -0.345, 0.12), (0.18, 0.01, 0.08), "entrance")


def build_train_station():
    box("light_concrete", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "ground")
    # track along X at the front
    ty = -0.26
    box("dirt_dark", (0.0, ty, 0.04), (0.94, 0.20, 0.02), "ballast")
    for i in range(11):
        box("wood", (-0.42 + i * 0.084, ty, 0.055), (0.03, 0.17, 0.012), "sleeper")
    for dy in (-0.055, 0.055):
        box("rail", (0.0, ty + dy, 0.068), (0.94, 0.012, 0.016), "rail")
    # platform + canopy
    box("concrete", (0.0, 0.0, 0.03 + 0.04), (0.90, 0.24, 0.08), "platform")
    box("factory_yellow", (0.0, -0.115, 0.111), (0.90, 0.012, 0.002), "edge_line")
    for x in (-0.36, -0.12, 0.12, 0.36):
        box("iron", (x, 0.02, 0.11 + 0.11), (0.016, 0.016, 0.22), "post")
    box("navy", (0.0, -0.02, 0.34), (0.92, 0.30, 0.02), "canopy", rot_euler=(math.radians(-6), 0, 0))
    for x in (-0.2, 0.2):
        box("wood", (x, 0.06, 0.13), (0.10, 0.03, 0.02), "bench")
    box("amber_glow", (0.0, -0.13, 0.27), (0.12, 0.01, 0.04), "board")
    # station hall at the back
    box("brick", (0.0, 0.31, 0.03 + 0.16), (0.70, 0.24, 0.32), "hall")
    prism_x("slate", [(0.18, 0.35), (0.44, 0.35), (0.31, 0.45)], -0.37, 0.37, "hall_roof")
    for x in (-0.24, -0.08, 0.08, 0.24):
        box("dark_glass", (x, 0.188, 0.22), (0.08, 0.01, 0.12), "arch_window")
    box("white", (0.0, 0.18, 0.40), (0.06, 0.01, 0.06), "clock")
    # parked train car on the track
    box("white", (0.05, ty, 0.08 + 0.085), (0.62, 0.15, 0.15), "car_body")
    box("stack_red", (0.05, ty, 0.10), (0.625, 0.155, 0.03), "car_stripe")
    box("dark_glass", (0.05, ty, 0.19), (0.56, 0.156, 0.05), "car_windows")
    box("slate", (0.05, ty, 0.25), (0.60, 0.13, 0.02), "car_roof")
    box("dark_glass", (-0.26, ty, 0.18), (0.012, 0.12, 0.07), "car_cab_glass")
    for x in (-0.18, 0.28):
        box("iron", (x, ty, 0.077), (0.12, 0.13, 0.025), "bogie")


def build_university():
    box("grass", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "campus")
    # quad paths
    box("light_concrete", (0.0, -0.25, 0.031), (0.08, 0.44, 0.004), "path_ns")
    box("light_concrete", (0.0, -0.25, 0.031), (0.62, 0.06, 0.004), "path_ew")
    cylinder("light_concrete", (0.0, -0.25, 0.034), 0.07, 0.008, vertices=12, name="quad_circle")
    for x, y in ((-0.30, -0.15), (0.30, -0.15), (-0.30, -0.38), (0.30, -0.38)):
        tree(x, y, 1.1)
    # main hall
    box("cream", (0.0, 0.22, 0.03 + 0.17), (0.80, 0.34, 0.34), "hall")
    box("light_concrete", (0.0, 0.22, 0.385), (0.84, 0.38, 0.03), "cornice")
    for x in (-0.32, -0.22, 0.22, 0.32):
        for z in (0.13, 0.27):
            box("dark_glass", (x, 0.045, z), (0.06, 0.01, 0.08), "win")
    # columned portico
    box("light_concrete", (0.0, 0.0, 0.03 + 0.02), (0.36, 0.12, 0.04), "steps")
    for k in range(6):
        cylinder("white", (-0.15 + k * 0.06, -0.01, 0.07 + 0.12), 0.012, 0.24, vertices=8, name="column")
    box("white", (0.0, 0.0, 0.325), (0.36, 0.12, 0.03), "entablature")
    prism_x("white", [(-0.06, 0.34), (0.06, 0.34), (0.0, 0.40)], -0.18, 0.18, "pediment")
    prism_x("roof_red", [(0.04, 0.40), (0.40, 0.40), (0.22, 0.48)], -0.40, 0.40, "hall_roof")
    # clock tower
    box("cream", (0.30, 0.30, 0.03 + 0.36), (0.12, 0.12, 0.72), "tower")
    box("light_concrete", (0.30, 0.30, 0.76), (0.14, 0.14, 0.03), "tower_cornice")
    for (dx, dy, rx) in ((0, -0.061, math.pi / 2),):
        cylinder("white", (0.30 + dx, 0.30 + dy, 0.66), 0.035, 0.006, vertices=16, name="clock_face",
                 rot_euler=(rx, 0, 0))
        box("slate", (0.30, 0.30 + dy - 0.004, 0.672), (0.004, 0.003, 0.025), "hand_h")
        box("slate", (0.308, 0.30 + dy - 0.004, 0.66), (0.02, 0.003, 0.004), "hand_m")
    cone("roof_red", (0.30, 0.30, 0.86), 0.1, 0.0, 0.16, vertices=4, name="spire", rot_euler=(0, 0, math.pi / 4))
    cylinder("amber_glow", (0.30, 0.30, 0.96), 0.008, 0.05, vertices=6, name="finial")


def build_landfill():
    box("dirt", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "ground")
    # perimeter fence
    for i in range(9):
        t = -0.45 + i * 0.1125
        for (x, y) in ((t, -0.45), (t, 0.45), (-0.45, t), (0.45, t)):
            box("iron", (x, y, 0.03 + 0.045), (0.01, 0.01, 0.09), "fence_post")
    for z in (0.06, 0.11):
        box("rail", (0.0, -0.45, z), (0.90, 0.004, 0.006), "wire")
        box("rail", (0.0, 0.45, z), (0.90, 0.004, 0.006), "wire")
        box("rail", (-0.45, 0.0, z), (0.004, 0.90, 0.006), "wire")
        box("rail", (0.45, 0.0, z), (0.004, 0.90, 0.006), "wire")
    # dirt mounds
    ico("dirt_dark", (-0.15, 0.18, 0.03), 0.26, name="mound", scale=(1.2, 0.9, 0.55), subdiv=2)
    ico("dirt", (0.22, 0.24, 0.03), 0.18, name="mound", scale=(1.0, 1.0, 0.6), subdiv=2)
    ico("grass", (-0.26, 0.30, 0.10), 0.08, name="capped", scale=(1.3, 0.8, 0.4), subdiv=1)
    for o in bpy.context.scene.objects:
        if o.name.startswith(("mound", "capped")):
            for v in o.data.vertices:
                v.co.z = max(v.co.z, 0.03 - o.location.z)
    # trash piles
    import random
    rnd = random.Random(7)
    for (px, py) in ((0.18, -0.12), (-0.28, -0.18), (0.30, 0.02)):
        for _ in range(9):
            m = rnd.choice(("trash_a", "trash_b", "white", "stack_red", "concrete"))
            s = rnd.uniform(0.025, 0.05)
            box(m, (px + rnd.uniform(-0.07, 0.07), py + rnd.uniform(-0.05, 0.05), 0.03 + s / 2 + rnd.uniform(0, 0.03)),
                (s, s * rnd.uniform(0.7, 1.3), s), "trash", rot_euler=(0, rnd.uniform(-0.4, 0.4), rnd.uniform(0, 3)))
    # bulldozer
    bx, by = -0.05, -0.20
    for dx in (-0.045, 0.045):
        box("rubber", (bx + dx, by, 0.03 + 0.02), (0.03, 0.12, 0.04), "track")
    box("factory_yellow", (bx, by + 0.01, 0.03 + 0.06), (0.10, 0.09, 0.05), "dozer_body")
    box("factory_yellow", (bx, by + 0.03, 0.03 + 0.11), (0.07, 0.05, 0.05), "cab")
    box("dark_glass", (bx, by + 0.004, 0.14), (0.06, 0.004, 0.03), "cab_glass")
    box("iron", (bx, by - 0.075, 0.03 + 0.03), (0.14, 0.012, 0.05), "blade")
    cylinder("iron", (bx + 0.03, by + 0.04, 0.03 + 0.15), 0.006, 0.04, vertices=6, name="exhaust")
    # gate hut
    box("white", (0.36, -0.36, 0.03 + 0.05), (0.10, 0.08, 0.10), "hut")
    box("slate", (0.36, -0.36, 0.135), (0.12, 0.10, 0.01), "hut_roof")


def build_airport():
    box("grass", (0.0, 0.0, 0.015), (0.94, 0.94, 0.03), "apron_grass")
    # runway across the front of the tile (along X)
    box("asphalt", (0.0, -0.27, 0.035), (0.94, 0.26, 0.01), "runway")
    for i in range(6):
        box("white", (-0.39 + i * 0.156, -0.27, 0.041), (0.08, 0.012, 0.002), "centerline")
    for sx in (-1, 1):
        for k in range(4):
            box("white", (sx * 0.43, -0.33 + k * 0.04, 0.041), (0.05, 0.016, 0.002), "threshold")
    box("concrete", (0.0, 0.08, 0.032), (0.80, 0.34, 0.004), "apron")
    box("asphalt", (-0.32, -0.08, 0.033), (0.06, 0.12, 0.004), "taxiway")
    # terminal
    box("white", (0.05, 0.30, 0.03 + 0.10), (0.70, 0.22, 0.20), "terminal")
    box("dark_glass", (0.05, 0.188, 0.14), (0.66, 0.01, 0.10), "terminal_glass")
    cylinder("titanium", (0.05, 0.30, 0.24), 0.36, 0.06, vertices=20, name="terminal_roof", scale_xy=(1.0, 0.36))
    for x in (-0.15, 0.15):
        box("titanium", (x, 0.13, 0.11), (0.04, 0.12, 0.04), "jet_bridge")
    # control tower
    tx, ty = -0.36, 0.30
    cylinder("light_concrete", (tx, ty, 0.03 + 0.30), 0.04, 0.60, vertices=10, name="tower_shaft")
    cylinder("white", (tx, ty, 0.66), 0.075, 0.03, vertices=10, name="tower_deck")
    cylinder("dark_glass", (tx, ty, 0.71), 0.07, 0.07, vertices=10, name="tower_cab")
    cone("slate", (tx, ty, 0.765), 0.08, 0.05, 0.04, vertices=10, name="tower_roof")
    cylinder("iron", (tx, ty, 0.81), 0.005, 0.05, vertices=6, name="tower_mast")
    sphere("crimson_glow", (tx, ty, 0.845), 0.018, segments=10, rings=6, name="Beacon")
    # windsock
    box("iron", (0.40, -0.06, 0.08), (0.006, 0.006, 0.10), "sock_pole")
    cone("orange", (0.42, -0.06, 0.125), 0.012, 0.006, 0.04, vertices=6, name="sock",
         rot_euler=(0, math.radians(90), 0))


# ---------------------------------------------------------------- props

def build_bench_park():
    for x in (-0.10, 0.10):
        box("iron", (x, 0.0, 0.025), (0.012, 0.07, 0.05), "leg")
        box("iron", (x, 0.03, 0.075), (0.012, 0.012, 0.06), "back_leg")
    for k in range(3):
        box("wood", (0.0, -0.025 + k * 0.022, 0.052), (0.24, 0.018, 0.008), "seat_slat")
    for k in range(2):
        box("wood", (0.0, 0.034, 0.07 + k * 0.025), (0.24, 0.006, 0.016), "back_slat")


def build_bench_modern():
    for x in (-0.09, 0.09):
        box("light_concrete", (x, 0.0, 0.022), (0.04, 0.07, 0.044), "block")
    box("wood", (0.0, 0.0, 0.05), (0.26, 0.075, 0.012), "seat")


def build_lamp_classic():
    cylinder("iron", (0.0, 0.0, 0.015), 0.022, 0.03, vertices=8, name="base")
    cylinder("iron", (0.0, 0.0, 0.17), 0.008, 0.30, vertices=8, name="post")
    cylinder("iron", (0.0, 0.0, 0.322), 0.022, 0.006, vertices=8, name="lantern_floor")
    cone("iron", (0.0, 0.0, 0.352), 0.026, 0.004, 0.018, vertices=8, name="lantern_cap")
    sphere("lamp_glow", (0.0, 0.0, 0.335), 0.017, segments=10, rings=6, name="Bulb")


def build_lamp_modern():
    cylinder("slate", (0.0, 0.08, 0.17), 0.007, 0.34, vertices=8, name="post")
    box("slate", (0.0, 0.035, 0.335), (0.012, 0.10, 0.01), "arm")
    box("slate", (0.0, -0.02, 0.335), (0.04, 0.06, 0.014), "head")
    box("lamp_glow", (0.0, -0.02, 0.326), (0.032, 0.05, 0.004), "Bulb")


def build_bus_stop():
    box("light_concrete", (0.0, 0.0, 0.005), (0.34, 0.14, 0.01), "pad")
    for x in (-0.15, 0.15):
        box("iron", (x, 0.05, 0.08), (0.01, 0.01, 0.15), "post")
    box("sky_blue", (0.0, 0.055, 0.09), (0.29, 0.006, 0.11), "back_glass")
    box("sky_blue", (-0.15, 0.015, 0.09), (0.006, 0.07, 0.11), "side_glass")
    box("navy", (0.0, 0.02, 0.162), (0.33, 0.12, 0.01), "roof")
    box("wood", (0.0, 0.035, 0.045), (0.20, 0.03, 0.008), "bench")
    box("ad_pink", (0.10, 0.058, 0.09), (0.08, 0.004, 0.09), "ad")
    box("iron", (0.145, -0.05, 0.10), (0.008, 0.008, 0.19), "sign_pole")
    cylinder("bus_blue", (0.145, -0.05, 0.18), 0.022, 0.006, vertices=12, name="sign", rot_euler=(math.pi / 2, 0, 0))


def build_fountain():
    cylinder("light_concrete", (0.0, 0.0, 0.02), 0.24, 0.04, vertices=8, name="basin_rim")
    cylinder("water", (0.0, 0.0, 0.035), 0.215, 0.012, vertices=8, name="basin_water")
    cylinder("light_concrete", (0.0, 0.0, 0.08), 0.03, 0.10, vertices=8, name="column")
    cone("light_concrete", (0.0, 0.0, 0.14), 0.03, 0.09, 0.03, vertices=8, name="bowl")
    cylinder("water", (0.0, 0.0, 0.153), 0.08, 0.006, vertices=8, name="bowl_water")
    cylinder("light_concrete", (0.0, 0.0, 0.18), 0.012, 0.05, vertices=8, name="spout")
    cone("sky_blue", (0.0, 0.0, 0.225), 0.025, 0.004, 0.04, vertices=8, name="jet")


def build_planter_round():
    cylinder("terracotta", (0.0, 0.0, 0.035), 0.07, 0.07, vertices=12, name="pot")
    cylinder("dirt_dark", (0.0, 0.0, 0.07), 0.062, 0.004, vertices=12, name="soil")
    ico("leaf", (0.0, 0.0, 0.11), 0.06, name="shrub", scale=(1, 1, 0.9))
    ico("grass", (0.03, -0.02, 0.15), 0.035, name="shrub_top")


def build_planter_long():
    box("light_concrete", (0.0, 0.0, 0.03), (0.26, 0.08, 0.06), "trough")
    box("dirt_dark", (0.0, 0.0, 0.061), (0.24, 0.06, 0.004), "soil")
    for k, x in enumerate((-0.08, 0.0, 0.08)):
        ico("leaf" if k % 2 == 0 else "grass", (x, 0.0, 0.085), 0.035, name="shrub")
    for x in (-0.04, 0.04):
        sphere("ad_pink", (x, -0.02, 0.10), 0.012, segments=8, rings=4, name="flower")


def build_hydrant():
    cylinder("stack_red", (0.0, 0.0, 0.005), 0.022, 0.01, vertices=10, name="flange")
    cylinder("stack_red", (0.0, 0.0, 0.035), 0.016, 0.06, vertices=10, name="barrel")
    sphere("stack_red", (0.0, 0.0, 0.065), 0.017, segments=10, rings=6, name="cap")
    cylinder("titanium", (0.0, 0.0, 0.084), 0.004, 0.008, vertices=6, name="nut")
    cylinder("stack_red", (0.0, 0.0, 0.04), 0.007, 0.05, vertices=8, name="nozzles", rot_euler=(0, math.pi / 2, 0))
    cylinder("stack_red", (0.0, -0.012, 0.04), 0.009, 0.02, vertices=8, name="front_nozzle", rot_euler=(math.pi / 2, 0, 0))


def build_trash_bin():
    cylinder("leaf", (0.0, 0.0, 0.045), 0.03, 0.09, vertices=10, name="bin")
    cylinder("slate", (0.0, 0.0, 0.094), 0.032, 0.008, vertices=10, name="lid")
    cylinder("iron", (0.0, 0.0, 0.03), 0.031, 0.008, vertices=10, name="band")


def build_billboard():
    for x in (-0.12, 0.12):
        box("iron", (x, 0.02, 0.15), (0.016, 0.016, 0.30), "pole")
    box("slate", (0.0, 0.02, 0.34), (0.38, 0.02, 0.18), "frame")
    box("white", (0.0, 0.008, 0.34), (0.36, 0.006, 0.16), "panel")
    box("ad_pink", (-0.07, 0.003, 0.36), (0.18, 0.004, 0.08), "ad_block")
    box("bus_blue", (0.10, 0.003, 0.31), (0.10, 0.004, 0.06), "ad_block2")
    box("iron", (0.0, -0.01, 0.255), (0.36, 0.03, 0.006), "catwalk")
    for x in (-0.12, 0.12):
        box("lamp_glow", (x, -0.03, 0.44), (0.03, 0.02, 0.01), "Bulb_%d" % (0 if x < 0 else 1))


# ---------------------------------------------------------------- vehicles

def wheel(name, x, y, r=0.30, w=0.24):
    t = cylinder("rubber", (x, y, r), r, w, vertices=12, name=name, rot_euler=(0, math.pi / 2, 0))
    h = cylinder("titanium", (x + (w / 2 + 0.005) * (1 if x > 0 else -1), y, r), r * 0.5, 0.01, vertices=10,
                 name="hub", rot_euler=(0, math.pi / 2, 0))
    return join([t, h], name)


def build_bus():
    """City bus in Kenney Car Kit units (sedan.glb: 1.5 wide, 2.55 long, front = -Y)."""
    L, W = 4.30, 1.44
    y0 = 0.0
    box("bus_blue", (0.0, y0, 0.30 + 0.62), (W, L, 1.24), "body")
    box("white", (0.0, y0, 1.60), (W, L, 0.12), "upper")
    box("white", (0.0, y0, 0.36), (W + 0.01, L + 0.01, 0.12), "skirt_stripe")
    box("titanium", (0.0, y0 + 0.2, 1.72), (W * 0.8, L * 0.5, 0.12), "roof_unit")
    for side in (-1, 1):
        box("dark_glass", (side * (W / 2 + 0.005), y0 + 0.25, 1.15), (0.01, L - 1.0, 0.48), "side_windows")
    box("dark_glass", (0.0, y0 - L / 2 - 0.005, 1.05), (W - 0.16, 0.01, 0.70), "windshield")
    box("dark_glass", (0.0, y0 + L / 2 + 0.005, 1.20), (W - 0.3, 0.01, 0.36), "rear_window")
    box("amber_glow", (0.0, y0 - L / 2 - 0.008, 1.56), (W - 0.4, 0.01, 0.14), "destination")
    box("dark_glass", (W / 2 + 0.006, y0 - 1.55, 0.85), (0.01, 0.55, 1.00), "door_front")
    box("dark_glass", (W / 2 + 0.006, y0 + 0.45, 0.85), (0.01, 0.55, 1.00), "door_mid")
    for x in (-0.5, 0.5):
        box("lamp_glow", (x, y0 - L / 2 - 0.008, 0.52), (0.18, 0.01, 0.10), "headlight")
        box("stack_red", (x, y0 + L / 2 + 0.008, 0.55), (0.16, 0.01, 0.12), "taillight")
    box("slate", (0.0, y0 - L / 2 - 0.02, 0.32), (W, 0.06, 0.14), "bumper")
    box("slate", (0.0, y0 + L / 2 + 0.02, 0.32), (W, 0.06, 0.14), "rear_bumper")
    for side in (-1, 1):
        box("slate", (side * (W / 2 + 0.06), y0 - L / 2 + 0.15, 1.15), (0.05, 0.05, 0.25), "mirror")
    body_parts = [o for o in bpy.context.scene.objects]
    join(body_parts, "body")
    for name, x, y in (("wheel-front-left", 0.62, -1.30), ("wheel-front-right", -0.62, -1.30),
                       ("wheel-back-left", 0.62, 1.25), ("wheel-back-right", -0.62, 1.25)):
        wheel(name, x, y)


def build_plane():
    """Airliner at tile scale: wingspan 1.4 (X), nose toward -Y (Godot +Z), wheels at z=0."""
    fz = 0.13
    cylinder("white", (0.0, 0.0, fz), 0.07, 1.0, vertices=14, name="fuselage", rot_euler=(math.pi / 2, 0, 0))
    cone("white", (0.0, -0.56, fz - 0.005), 0.07, 0.015, 0.12, vertices=14, name="nose", rot_euler=(math.pi / 2, 0, 0))
    cone("white", (0.0, 0.59, fz + 0.025), 0.07, 0.015, 0.18, vertices=14, name="tail_cone", rot_euler=(-math.pi / 2, 0, 0))
    box("dark_glass", (0.0, -0.57, fz + 0.035), (0.08, 0.04, 0.02), "cockpit")
    for side in (-1, 1):
        box("dark_glass", (side * 0.069, -0.05, fz + 0.025), (0.004, 0.75, 0.012), "window_strip")
    box("bus_blue", (0.0, 0.0, fz - 0.03), (0.142, 1.0, 0.02), "belly_stripe")
    # wings: swept panels
    for side in (-1, 1):
        prism_y("titanium", [(side * 0.05, fz - 0.04), (side * 0.70, fz - 0.015), (side * 0.70, fz - 0.005), (side * 0.05, fz - 0.02)],
                -0.12, 0.08, "wing_flat")
    wing_objs = [o for o in bpy.context.scene.objects if o.name.startswith("wing_flat")]
    for o in wing_objs:
        # sweep: shear vertices backward with |x|
        for v in o.data.vertices:
            v.co.y += abs(v.co.x) * 0.45
            if abs(v.co.x) > 0.6:
                v.co.y -= (v.co.y - 0.25) * 0.55 if v.co.y > 0.25 else 0.0
    for side in (-1, 1):
        cylinder("slate", (side * 0.26, -0.06, fz - 0.07), 0.032, 0.14, vertices=10, name="engine",
                 rot_euler=(math.pi / 2, 0, 0))
        cylinder("rubber", (side * 0.26, -0.131, fz - 0.07), 0.026, 0.004, vertices=10, name="intake",
                 rot_euler=(math.pi / 2, 0, 0))
        prism_y("titanium", [(side * 0.03, fz + 0.02), (side * 0.25, fz + 0.03), (side * 0.25, fz + 0.04), (side * 0.03, fz + 0.04)],
                0.50, 0.60, "stabilizer")
    prism_x("bus_blue", [(0.48, fz + 0.05), (0.64, fz + 0.05), (0.68, fz + 0.30), (0.62, fz + 0.30)], -0.006, 0.006, "fin")
    # landing gear
    for (x, y) in ((0.0, -0.40), (-0.10, 0.06), (0.10, 0.06)):
        box("iron", (x, y, 0.05), (0.008, 0.008, 0.07), "strut")
        cylinder("rubber", (x, y, 0.02), 0.02, 0.02, vertices=8, name="tyre", rot_euler=(0, math.pi / 2, 0))


def build_helicopter():
    """Tile-scale helicopter, nose toward -Y. Rotor spins about local up axis, RotorTail about local X."""
    sphere("stack_red", (0.0, -0.02, 0.10), 0.07, segments=14, rings=8, name="cabin", scale=(0.85, 1.4, 0.9))
    sphere("dark_glass", (0.0, -0.09, 0.115), 0.05, segments=12, rings=8, name="canopy", scale=(0.95, 1.0, 0.8))
    cone("stack_red", (0.0, 0.18, 0.12), 0.03, 0.012, 0.24, vertices=8, name="boom", rot_euler=(-math.pi / 2, 0, 0))
    box("stack_red", (0.0, 0.29, 0.16), (0.006, 0.05, 0.07), "tail_fin")
    box("white", (0.0, 0.29, 0.12), (0.08, 0.02, 0.005), "tail_plane")
    for x in (-0.05, 0.05):
        box("iron", (x, -0.02, 0.008), (0.008, 0.20, 0.008), "skid")
        for y in (-0.07, 0.04):
            box("iron", (x, y, 0.03), (0.006, 0.006, 0.04), "skid_strut")
    cylinder("iron", (0.0, -0.02, 0.18), 0.008, 0.03, vertices=6, name="mast")
    hub = cylinder("slate", (0.0, -0.02, 0.198), 0.014, 0.012, vertices=8, name="Rotor")
    blades = [hub]
    for k in range(4):
        th = k * math.pi / 2 + math.pi / 4
        blades.append(box("slate", (math.cos(th) * 0.1, -0.02 + math.sin(th) * 0.1, 0.198), (0.2, 0.014, 0.003),
                          "blade", rot_euler=(0, 0, th)))
    join(blades, "Rotor")
    thub = cylinder("slate", (0.012, 0.30, 0.16), 0.006, 0.006, vertices=6, name="RotorTail", rot_euler=(0, math.pi / 2, 0))
    tb = [thub]
    for k in range(2):
        th = k * math.pi
        tb.append(box("slate", (0.014, 0.30 + math.sin(th) * 0.022, 0.16 + math.cos(th) * 0.022), (0.002, 0.008, 0.044),
                      "tblade", rot_euler=(th, 0, 0)))
    join(tb, "RotorTail")


BUILDERS = {
    "zones/r2/townhouse_row": build_r2_townhouse_row,
    "zones/r2/walkup_brick": build_r2_walkup_brick,
    "zones/r2/duplex": build_r2_duplex,
    "zones/r3/tower_slab": build_r3_tower_slab,
    "zones/r3/tower_twin": build_r3_tower_twin,
    "zones/r3/tower_stepped": build_r3_tower_stepped,
    "zones/r3/tower_round": build_r3_tower_round,
    "zones/c1/corner_store": build_c1_corner_store,
    "zones/c1/cafe": build_c1_cafe,
    "zones/c1/diner": build_c1_diner,
    "zones/i3/refinery": build_i3_refinery,
    "zones/i3/cooling_plant": build_i3_cooling_plant,
    "buildings/wind_farm": build_wind_farm,
    "buildings/stadium": build_stadium,
    "buildings/train_station": build_train_station,
    "buildings/university": build_university,
    "buildings/landfill": build_landfill,
    "buildings/airport": build_airport,
    "props/bench_park": build_bench_park,
    "props/bench_modern": build_bench_modern,
    "props/lamp_classic": build_lamp_classic,
    "props/lamp_modern": build_lamp_modern,
    "props/bus_stop": build_bus_stop,
    "props/fountain": build_fountain,
    "props/planter_round": build_planter_round,
    "props/planter_long": build_planter_long,
    "props/hydrant": build_hydrant,
    "props/trash_bin": build_trash_bin,
    "props/billboard": build_billboard,
    "vehicles/bus": build_bus,
    "vehicles/plane": build_plane,
    "vehicles/helicopter": build_helicopter,
}

# Vehicles keep their part structure (wheels, rotors); everything else is merged.
KEEP_STRUCTURE = ("vehicles/bus",)


def merge_static(key):
    name = key.split("/")[-1]
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    static = [o for o in objs if not o.name.startswith(ANIM_PREFIXES)
              and not (key in KEEP_STRUCTURE and o.name.startswith(("wheel", "body")))]
    if key in KEEP_STRUCTURE:
        return
    if static:
        join(static, name + "_body")


def export_asset(key):
    path = os.path.join(MODELS, key + ".glb")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
        export_materials="EXPORT", export_cameras=False, export_lights=False,
    )
    anim = sorted(o.name for o in bpy.context.scene.objects if o.name.startswith(ANIM_PREFIXES))
    print("WROTE %s anim=%s" % (key, anim))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["all"]
    wanted = argv or ["all"]
    for key, fn in BUILDERS.items():
        if "all" not in wanted and not any(key.startswith(w) for w in wanted):
            continue
        clear_scene()
        fn()
        merge_static(key)
        export_asset(key)


main()
