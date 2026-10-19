"""Validate the realistic model library (models/real) against the GridFall game contracts.

Usage:
    blender --background --python /ABS/tools/blender/validate_real.py -- [--json out.json] [--root DIR] [dirs...]
Dirs default to models/real. --root is the library root that model keys are relative to (default models/real;
pass the --out folder of a make_realistic_city.py dry run). Prints one MODEL line per GLB (Godot-axis AABB, tris, size, scripted parts,
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
  * vehicles_v2 (1.0x): length 0.17-0.65 and width <= 0.13 for road vehicles, wheels on y = 0, the four
    Wheel_* objects (bicycle Wheel_F / Wheel_R) with their origin within 0.001 of their mesh bounds centre,
    Seat_Driver, tinted see-through Glass_Car, Light_Head at +Z, <= 8 materials; each <name>_lod1 is one
    mesh of <= 1,500 triangles with <= 16 flat untextured materials and an emissive Light_Head (road
    vehicles). The contract asked for a single material; slice E merges far LODs by material albedo and
    emission, so the colours live in a few flat materials instead (docs/fp/requests/H-needs.md)
  * street: footprint (AABB size) <= 0.25 except bus_shelter (<= 0.2 x 0.08), billboard and hoarding
    (<= 0.36) and traffic_light (<= 0.3 along X); base at y = 0 (the curb ramp sits in the road tile's height
    frame); every Poster_<n> object has one surface with material Poster, UVs within [0, 1] +- 1e-4 and its
    normal along +Z in node space; every SignFace UV within [0, 1] +- 1e-4; required parts (traffic_light:
    Signal_Red_*, Signal_Amber_*, Signal_Green_*, SignText_A, SignText_B; street_sign: SignText_A, SignText_B;
    hoarding: Poster_0, Poster_1; poster carriers: Poster_0); at most 3 base materials besides the
    functional ones (Poster*, SignFace, Signal_*, Walk, DontWalk, Lamp_Glow, Bulb*)
  * doors: every zone and building model has a Door_<n> empty with scale.y >= 0.1 and every DoorLeaf_*
    surface is at least 0.1 tall (models exported before the door fix flag MISSING_Door)
  * no object name ends in a physics import suffix (-colonly, -col, -rigid, ...)
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
WHEELS = ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
BIKE_WHEELS = ["Wheel_F", "Wheel_R"]
# Godot turns nodes with these name suffixes into physics bodies / colliders on import (use_name_suffixes)
PHYS_SUFFIXES = ("-colonly", "_colonly", "-col", "_col", "-convcolonly", "_convcolonly", "-convcol", "_convcol",
                 "-rigid", "_rigid", "-vehicle", "_vehicle", "-wheel", "_wheel", "-noimp", "_noimp", "-occonly",
                 "_occonly", "-navmesh", "_navmesh")
# Sanity ceilings (tile units, before the game's 0.9 REAL_SCALE) that keep zone levels in order.
HEIGHT = {"zones/r1": 0.65, "zones/r2": 1.25, "zones/r3": 3.2, "zones/c1": 0.6, "zones/c2": 1.5, "zones/c3": 4.0,
          "zones/i1": 0.7, "zones/i2": 1.4, "zones/i3": 3.2, "buildings": 2.0}
TRIS = {"zones": 20000, "buildings": 16000, "roads": 6000, "props": 8000, "vehicles": 8000, "people": 3000,
        "vehicles_v2": 9000, "street": 3000}
SIZE_MB = {"zones": 3.5, "buildings": 3.0, "roads": 2.0, "props": 1.5, "vehicles": 1.5, "people": 0.5,
           "vehicles_v2": 1.5, "street": 0.8}
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
    "vehicles_v2/police": ["Siren_0", "Siren_1"],
    "vehicles_v2/ambulance": ["Siren_0", "Siren_1"],
    "vehicles_v2/firetruck": ["Siren_0", "Siren_1"],
    "street/traffic_light": ["Signal_Red_", "Signal_Amber_", "Signal_Green_", "SignText_A", "SignText_B", "Walk_",
                             "DontWalk_"],
    "street/ped_signal": ["Walk_0", "DontWalk_0"],
    "street/street_sign": ["SignText_A", "SignText_B", "Blade_A", "Blade_B"],
    "street/hoarding": ["Poster_0", "Poster_1"],
    "street/bus_shelter": ["Poster_0"],
    "street/billboard": ["Poster_0", "Bulb_0", "Bulb_1"],
    "street/poster_frame": ["Poster_0"],
    "street/lease_sign": ["Poster_0"],
}
# street footprint limits (AABB size along Godot X, Z); default 0.25 x 0.25
STREET_FOOT = {"bus_shelter": (0.2, 0.08), "billboard": (0.36, 0.36), "hoarding": (0.36, 0.36),
               "traffic_light": (0.3, 0.25)}
FUNCTIONAL = ("Poster", "SignFace", "Signal_", "Walk", "DontWalk", "Lamp_Glow", "Bulb")
UV_EPS = 1e-4
LOD_MAX_MATS = 16

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
json_out = None
dirs = []
i = 0
while i < len(argv):
    if argv[i] == "--json":
        json_out = argv[i + 1]
        i += 2
        continue
    if argv[i] == "--root":
        REAL = os.path.abspath(os.path.expanduser(argv[i + 1]))
        i += 2
        continue
    dirs.append(argv[i])
    i += 1
dirs = dirs or [REAL]
files = []
for d in dirs:
    p = d if os.path.isabs(d) else os.path.join(PROJECT, d)
    files += sorted(glob.glob(os.path.join(p, "**", "*.glb"), recursive=True)) if os.path.isdir(p) else [p]


def _emissive(m):
    if m is None or not m.node_tree:
        return False
    for nd in m.node_tree.nodes:
        if nd.type == "BSDF_PRINCIPLED":
            c = nd.inputs["Emission Color"].default_value
            return nd.inputs["Emission Strength"].default_value > 0 and max(c[0], c[1], c[2]) > 0
    return False


def _is(o, prefix):
    """o is a <prefix><n> object (Blender may append .001 on a name clash)."""
    n = o.name.split(".")[0]
    return n.startswith(prefix) and n[len(prefix):].isdigit()


def uv_rules(objs):
    """Poster_<n>: one surface, material Poster, UVs 0..1, normal +Z in node space (Blender local -Y);
    SignFace: UVs 0..1 wherever it is used."""
    out = []
    for o in objs:
        if o.type != "MESH":
            continue
        me = o.data
        uv = me.uv_layers.active
        if _is(o, "Poster_"):
            used = {p.material_index for p in me.polygons}
            ms = [me.materials[i].name.split(".")[0] if me.materials[i] else None for i in used]
            if ms != ["Poster"]:
                out.append("POSTER_SURFACES:%s=%s" % (o.name, ms))
            if any(p.normal.y > -0.999 for p in me.polygons):
                out.append("POSTER_NORMAL:" + o.name)
            if uv is None or any(not (-UV_EPS <= c <= 1 + UV_EPS) for d in uv.data for c in d.uv):
                out.append("POSTER_UV:" + o.name)
        for p in me.polygons:
            m = me.materials[p.material_index] if me.materials else None
            if m is None or m.name.split(".")[0] != "SignFace":
                continue
            if uv is None or any(not (-UV_EPS <= c <= 1 + UV_EPS) for li in p.loop_indices for c in uv.data[li].uv):
                out.append("SIGNFACE_UV:" + o.name)
                break
    return out


def door_rules(objs):
    """Door_<n> empties with scale.y >= 0.1 (Godot y = Blender z) and DoorLeaf_* surfaces >= 0.1 tall
    (measured on their upright faces, which span the full leaf)."""
    out = []
    doors = [o for o in objs if o.type == "EMPTY" and _is(o, "Door_")]
    if not doors:
        out.append("MISSING_Door")
    for d in doors:
        if d.matrix_world.to_scale().z < 0.1 - 1e-4:
            out.append("DOOR_LOW:%s=%.3f" % (d.name, d.matrix_world.to_scale().z))
    tall = {}
    for o in objs:
        if o.type != "MESH":
            continue
        me = o.data
        for p in me.polygons:
            m = me.materials[p.material_index] if me.materials else None
            if m is None or not m.name.startswith("DoorLeaf_") or abs(p.normal.z) > 0.5:
                continue
            ws = [(o.matrix_world @ me.vertices[v].co).z for v in p.vertices]
            tall[m.name] = max(tall.get(m.name, 0.0), max(ws) - min(ws))
    low = sorted(n for n, h in tall.items() if h < 0.1 - 1e-4)
    if low:
        out.append("DOORLEAF_LOW:" + ",".join(low))
    return out


def check(f):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=f)
    bpy.context.view_layer.update()
    rel = os.path.relpath(f, REAL).replace("\\", "/")[:-4]
    cat = rel.split("/")[0]
    name = rel.split("/")[-1]
    objs = list(bpy.data.objects)
    flags = []
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    tris = 0
    mats = set()
    head = []
    for o in objs:
        stem = o.name.split(".")[0].rstrip("0123456789").lower()
        if stem.endswith(PHYS_SUFFIXES):
            flags.append("PHYS_SUFFIX:" + o.name)
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
    flags += uv_rules(objs)
    size_mb = os.path.getsize(f) / 1e6
    gx, gz = (mn.x, mx.x), (-mx.y, -mn.y)
    gy = (mn.z, mx.z)
    ext = max(abs(gx[0]), abs(gx[1]), abs(gz[0]), abs(gz[1]))
    tri_cap = TRIS.get(cat, 20000)
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
    elif cat == "vehicles_v2":
        length, width = gz[1] - gz[0], gx[1] - gx[0]
        lod = name.endswith("_lod1")
        base = name[:-5] if lod else name
        if lod:
            tri_cap = 1500
            # flat colour groups (slice E merges a far LOD by material albedo): one mesh, no textures,
            # at most LOD_MAX_MATS materials, emissive Light_Head on road vehicles
            if len([o for o in objs if o.type == "MESH"]) != 1:
                flags.append("LOD_MESHES")
            if len(mats) > LOD_MAX_MATS:
                flags.append("LOD_MATS=%d>%d" % (len(mats), LOD_MAX_MATS))
            if any(nd.type == "TEX_IMAGE" for m in bpy.data.materials if m.node_tree for nd in m.node_tree.nodes):
                flags.append("LOD_TEXTURED")
            if base != "bicycle" and not _emissive(bpy.data.materials.get("Light_Head")):
                flags.append("LOD_NO_LAMPS")
        if abs(gy[0]) > 2e-3:
            flags.append("WHEELS!=0")
        if base != "bicycle" and (not (0.17 <= length <= 0.65) or width > 0.13):
            flags.append("SCALE(len=%.3f,w=%.3f)" % (length, width))
        if not lod:
            if len(mats) > 8:
                flags.append("MATS=%d>8" % len(mats))
            for wn in (BIKE_WHEELS if base == "bicycle" else WHEELS):
                w = bpy.data.objects.get(wn)
                if w is None or w.type != "MESH":
                    flags.append("MISSING_" + wn)
                    continue
                bb = [w.matrix_world @ Vector(c) for c in w.bound_box]
                ctr = sum(bb, Vector()) / 8.0
                if (ctr - w.matrix_world.translation).length > 0.001:
                    flags.append("WHEEL_ORIGIN:%s" % wn)
                if min(p.z for p in bb) > 2e-3:
                    flags.append("WHEEL_AIR:%s" % wn)
            if "Seat_Driver" not in [o.name for o in objs]:
                flags.append("MISSING_Seat_Driver")
            if base != "bicycle":
                g = bpy.data.materials.get("Glass_Car")
                a = None
                if g is not None and g.node_tree:
                    for nd in g.node_tree.nodes:
                        if nd.type == "BSDF_PRINCIPLED":
                            a = nd.inputs["Alpha"].default_value
                if a is None or not (0.4 <= a <= 0.7):
                    flags.append("GLASS_ALPHA=%s" % a)
            if not head or sum(head) / len(head) > 0:
                flags.append("FRONT!=+Z")
    elif cat == "street":
        lx, lz = STREET_FOOT.get(name, (0.25, 0.25))
        if gx[1] - gx[0] > lx + 1e-3 or gz[1] - gz[0] > lz + 1e-3:
            flags.append("FOOTPRINT(%.3f x %.3f > %.2f x %.2f)" % (gx[1] - gx[0], gz[1] - gz[0], lx, lz))
        if name != "curb_ramp" and abs(gy[0]) > 2e-3:
            flags.append("BASE!=0")
        base_mats = sorted(m for m in mats if not m.startswith(FUNCTIONAL))
        if len(base_mats) > 3:
            flags.append("BASE_MATS=" + ",".join(base_mats))
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
    if cat in ("zones", "buildings"):
        flags += door_rules(objs)
    if tris > tri_cap:
        flags.append("TRIS>%d" % tri_cap)
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
