"""Validate the realistic model library (models/real) against the GridFall game contracts.

Usage:
    blender --background --python /ABS/tools/blender/validate_real.py -- [--json out.json] [dirs...]
Dirs default to models/real. Prints one MODEL line per GLB (Godot-axis AABB, tris, size, scripted parts,
flags) and a SUMMARY line; exits non-zero when any model is flagged.

Checks (Godot axes: X right, Y up, Z toward the viewer = Blender -Y):
  * zones / buildings: footprint inside |x|,|z| <= 0.47, base at y = 0, height within the zone limit
  * roads: footprint inside 0.5, base at y = 0 except the bridge (piers go below the deck)
  * props: footprint limits shared with tools/blender/validate_models.py
  * road vehicles: tile scale (length 0.2-0.8, width <= 0.2), wheels on y = 0, headlights at +Z
  * boats float (waterline y = 0, hull below), plane / helicopter shape and Rotor parts
  * people: 0.07-0.11 tall with Shirt / Pants / Skin / Hair materials
  * required scripted parts: StackTop_* (coal plant, i2/i3), Beacon (police, fire, airport), Rotor_* (wind
    farm), Floodlight_* (stadium), Bulb* (lit roads, lamps, billboard), Siren_* (emergency vehicles)
  * budgets: triangles and GLB size per category
"""

import glob
import json
import os
import sys

import bpy
from mathutils import Vector

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REAL = os.path.join(PROJECT, "models", "real")
ANIM_PREFIXES = ("Rotor", "Floodlight", "Beacon", "Bulb", "Siren", "StackTop")
ROAD_VEHICLES = ("sedan", "hatchback", "suv", "coupe", "taxi", "van", "pickup", "police", "bus", "truck",
                 "garbage_truck", "firetruck", "ambulance")
# Sanity ceilings (tile units, before the game's 0.9 REAL_SCALE) that keep zone levels in order.
HEIGHT = {"zones/r1": 0.65, "zones/r2": 1.25, "zones/r3": 3.2, "zones/c1": 0.6, "zones/c2": 1.5, "zones/c3": 4.0,
          "zones/i1": 0.7, "zones/i2": 1.4, "zones/i3": 3.2, "buildings": 2.0}
TRIS = {"zones": 20000, "buildings": 16000, "roads": 6000, "props": 8000, "vehicles": 8000, "people": 3000}
SIZE_MB = {"zones": 3.5, "buildings": 3.0, "roads": 2.0, "props": 1.5, "vehicles": 1.5, "people": 0.5}
REQUIRED = {
    "buildings/coal_plant": ["StackTop_0", "StackTop_1"],
    "buildings/police_station": ["Beacon"],
    "buildings/fire_station": ["Beacon"],
    "buildings/airport": ["Beacon"],
    "buildings/wind_farm": ["Rotor_"],
    "buildings/stadium": ["Floodlight_"],
    "roads/road_straight_lights": ["Bulb_"],
    "roads/road_bridge": ["Bulb_"],
    "props/lamp_street": ["Bulb"],
    "props/lamp_classic": ["Bulb"],
    "props/lamp_double": ["Bulb_"],
    "props/billboard": ["Bulb_"],
    "vehicles/police": ["Siren_0", "Siren_1"],
    "vehicles/ambulance": ["Siren_0", "Siren_1"],
    "vehicles/firetruck": ["Siren_0", "Siren_1"],
    "vehicles/helicopter": ["Rotor", "RotorTail"],
}

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
json_out = None
dirs = []
i = 0
while i < len(argv):
    if argv[i] == "--json":
        json_out = argv[i + 1]
        i += 2
        continue
    dirs.append(argv[i])
    i += 1
dirs = dirs or [REAL]
files = []
for d in dirs:
    p = d if os.path.isabs(d) else os.path.join(PROJECT, d)
    files += sorted(glob.glob(os.path.join(p, "**", "*.glb"), recursive=True)) if os.path.isdir(p) else [p]


def check(f):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=f)
    bpy.context.view_layer.update()
    rel = os.path.relpath(f, REAL).replace("\\", "/")[:-4]
    cat = rel.split("/")[0]
    name = rel.split("/")[-1]
    objs = list(bpy.data.objects)
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    tris = 0
    mats = set()
    head = []
    for o in objs:
        if o.type != "MESH":
            continue
        me = o.data
        me.calc_loop_triangles()
        tris += len(me.loop_triangles)
        for s in o.material_slots:
            if s.material:
                mats.add(s.material.name)
        for v in me.vertices:
            w = o.matrix_world @ v.co
            mn = Vector(map(min, mn, w))
            mx = Vector(map(max, mx, w))
        for p in me.polygons:
            m = me.materials[p.material_index] if me.materials else None
            if m is not None and m.name.startswith("Light_Head"):
                head.append((o.matrix_world @ p.center).y)
    names = sorted(o.name for o in objs)
    anim = [n for n in names if n.startswith(ANIM_PREFIXES)]
    size_mb = os.path.getsize(f) / 1e6
    gx, gz = (mn.x, mx.x), (-mx.y, -mn.y)
    gy = (mn.z, mx.z)
    ext = max(abs(gx[0]), abs(gx[1]), abs(gz[0]), abs(gz[1]))
    flags = []
    if cat in ("zones", "buildings"):
        if ext > 0.47 + 6e-3:
            flags.append("FOOTPRINT>0.47")
        if abs(gy[0]) > 2e-3:
            flags.append("BASE!=0")
        key = "/".join(rel.split("/")[:2]) if cat == "zones" else "buildings"
        if gy[1] > HEIGHT.get(key, 9.0):
            flags.append("TALL>%.2f" % HEIGHT[key])
    elif cat == "roads":
        if ext > 0.5 + 1e-3:
            flags.append("FOOTPRINT>0.5")
        if "bridge" not in name and abs(gy[0]) > 2e-3:
            flags.append("BASE!=0")
    elif cat == "props":
        lim = 0.25 if "fountain" in name else (0.2 if ("tree" in name or "billboard" in name or "bus_stop" in name)
                                                else 0.15)
        if ext > lim + 1e-3:
            flags.append("FOOTPRINT>%.2f" % lim)
        if abs(gy[0]) > 2e-3:
            flags.append("BASE!=0")
    elif cat == "vehicles":
        length, width = gz[1] - gz[0], gx[1] - gx[0]
        if name.startswith(ROAD_VEHICLES):
            if not (0.2 <= length <= 0.8) or width > 0.2:
                flags.append("SCALE(len=%.2f,w=%.2f)" % (length, width))
            if abs(gy[0]) > 2e-3:
                flags.append("WHEELS!=0")
            if not head or sum(head) / len(head) > 0:
                flags.append("FRONT!=+Z")
        elif name.startswith("boat"):
            if not (gy[0] < -0.005 and gy[1] > 0.05):
                flags.append("WATERLINE")
        elif name == "plane":
            if not (0.8 < length < 2.0 and gy[0] < -0.05):
                flags.append("PLANE_SHAPE")
    elif cat == "people":
        if not (0.07 <= gy[1] - gy[0] <= 0.11):
            flags.append("HEIGHT=%.3f" % (gy[1] - gy[0]))
        for m in ("Shirt", "Pants", "Skin", "Hair"):
            if m not in mats and not (m == "Hair" and "Hat" in mats):
                flags.append("NO_" + m.upper())
    for req in REQUIRED.get(rel, []):
        if not any(n == req or (req.endswith("_") and n.startswith(req)) for n in names):
            flags.append("MISSING_" + req)
    if cat == "zones" and rel.split("/")[1] in ("i2", "i3") and not any(n.startswith("StackTop") for n in names):
        flags.append("MISSING_StackTop")
    if tris > TRIS.get(cat, 20000):
        flags.append("TRIS>%d" % TRIS[cat])
    if size_mb > SIZE_MB.get(cat, 3.0):
        flags.append("SIZE>%.1fMB" % SIZE_MB[cat])
    rec = {"model": rel, "size": [round(gx[1] - gx[0], 3), round(gy[1] - gy[0], 3), round(gz[1] - gz[0], 3)],
           "min_y": round(gy[0], 4), "max_y": round(gy[1], 4), "tris": tris, "mb": round(size_mb, 2),
           "anim": anim, "lit": "WindowLit" in mats, "flags": flags}
    print("MODEL %-34s size=(%.3f, %.3f, %.3f) y=[%.3f,%.3f] tris=%6d %.2fMB lit=%d anim=%s %s" % (
        rel, rec["size"][0], rec["size"][1], rec["size"][2], gy[0], gy[1], tris, size_mb, rec["lit"],
        ",".join(anim[:6]) + ("..." if len(anim) > 6 else ""), " ".join(flags)), flush=True)
    return rec


records = [check(f) for f in files]
bad = [r for r in records if r["flags"]]
by_cat = {}
for r in records:
    by_cat[r["model"].split("/")[0]] = by_cat.get(r["model"].split("/")[0], 0) + 1
print("SUMMARY files=%d flagged=%d per_category=%s" % (len(records), len(bad), json.dumps(by_cat)), flush=True)
for r in bad:
    print("FLAGGED", r["model"], " ".join(r["flags"]))
if json_out:
    with open(json_out, "w") as fh:
        json.dump(records, fh, indent=1)
sys.exit(1 if bad else 0)
