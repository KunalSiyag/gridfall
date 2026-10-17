"""Validate GridFall model library GLBs and render a contact sheet.

Prints, per file, the AABB in Godot axes (X, Y up, Z forward) and flags footprint /
base violations, plus the animatable sub-objects (Rotor*, Floodlight*, Beacon*,
Bulb*, Siren*).

Usage:
    blender --background --python /ABS/tools/blender/validate_models.py -- \
        --out /abs/sheet.png [--no-render] models/zones models/props ...
Folders are relative to the project root.  Road vehicles (vehicles/ except boats,
plane, helicopter) are drawn at the game's 0.17 scale on the contact sheet.
"""

import glob
import math
import os
import sys

import bpy
from mathutils import Vector

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ANIM_PREFIXES = ("Rotor", "Floodlight", "Beacon", "Bulb", "Siren")
TILE_SCALE_VEHICLES = ("boat", "plane", "helicopter")

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_png = None
render = True
folders = []
opts = {"--road-scale": 0.17, "--cols": 12, "--cell-z": 4.0}
i = 0
while i < len(argv):
    if argv[i] == "--out":
        out_png = argv[i + 1]
        i += 2
        continue
    if argv[i] in ("--road-scale", "--cols", "--cell-z"):
        opts[argv[i]] = float(argv[i + 1])
        i += 2
        continue
    if argv[i] == "--no-render":
        render = False
    else:
        folders.append(argv[i])
    i += 1

files = []
for f in folders:
    p = os.path.join(PROJECT_ROOT, f)
    files += sorted(glob.glob(os.path.join(p, "**", "*.glb"), recursive=True)) if os.path.isdir(p) else [p]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

COLS = int(opts["--cols"])
CELL_X = 1.5
CELL_Z = opts["--cell-z"]
rows_meta = []
for idx, f in enumerate(files):
    rel = os.path.relpath(f, os.path.join(PROJECT_ROOT, "models"))
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=f)
    objs = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in objs if o.parent is None]
    bpy.context.view_layer.update()
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for o in objs:
        if o.type != "MESH":
            continue
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            mn = Vector(map(min, mn, w))
            mx = Vector(map(max, mx, w))
    size = mx - mn
    anim = sorted(o.name for o in objs if o.name.startswith(ANIM_PREFIXES))
    # Godot axes: X = bx, Y = bz, Z = -by
    gx = (mn.x, mx.x)
    gz = (-mx.y, -mn.y)
    flags = []
    is_vehicle = rel.startswith("vehicles/")
    if not is_vehicle:
        lim = 0.47
        if rel.startswith("props/"):
            lim = 0.25 if "fountain" in rel else (0.2 if ("tree" in rel or "billboard" in rel or "bus_stop" in rel) else 0.15)
        if max(abs(gx[0]), abs(gx[1]), abs(gz[0]), abs(gz[1])) > lim + 1e-3:
            flags.append("FOOTPRINT>%.2f" % lim)
        if abs(mn.z) > 1e-3:
            flags.append("BASE!=0")
    print("MODEL %-40s size=(%.3f, %.3f, %.3f) minY=%.3f x=[%.3f,%.3f] z=[%.3f,%.3f] anim=%s %s" % (
        rel, size.x, size.z, size.y, mn.z, gx[0], gx[1], gz[0], gz[1], anim, " ".join(flags)))
    disp = 1.0
    if is_vehicle and not any(t in rel for t in TILE_SCALE_VEHICLES):
        disp = opts["--road-scale"]
    col = idx % COLS
    row = idx // COLS
    for o in roots:
        o.matrix_world = (
            __import__("mathutils").Matrix.Translation((col * CELL_X, 0.0, -row * CELL_Z))
            @ __import__("mathutils").Matrix.Scale(disp, 4) @ o.matrix_world
        )
    bpy.ops.object.text_add(location=(col * CELL_X - 0.6, -0.5, -row * CELL_Z - 0.35),
                            rotation=(math.radians(90), 0, 0))
    t = bpy.context.view_layer.objects.active
    t.data.body = rel.replace(".glb", "")
    t.data.size = 0.1
    rows_meta.append(row)

if render and out_png and files:
    nrows = max(rows_meta) + 1
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    width = COLS * CELL_X
    height = nrows * CELL_Z
    cam_data.ortho_scale = max(width, height) * 1.02
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cx = (COLS - 1) * CELL_X / 2.0
    cz = -(nrows - 1) * CELL_Z / 2.0 + 1.2
    # view from the front (-Y in Blender = +Z in Godot), slightly from the right and above
    cam.rotation_euler = (math.radians(80), 0.0, math.radians(12))
    d = cam.rotation_euler.to_matrix() @ Vector((0, 0, 1))
    cam.location = Vector((cx, 0.0, cz)) + d * 40.0
    scene.camera = cam
    cam_data.clip_end = 200
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.show_shadows = False
    scene.render.resolution_x = int(2400 * width / max(width, height))
    scene.render.resolution_y = int(2400 * height / max(width, height))
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("w")
    scene.world = world
    scene.render.filepath = out_png
    bpy.ops.render.render(write_still=True)
    print("RENDERED " + out_png)
print("COUNT %d" % len(files))
