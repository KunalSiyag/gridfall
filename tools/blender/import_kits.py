"""Normalize Kenney CC0 kit models into the GridFall model library.

Each job imports one source model (or composes several kit pieces), cleans it up
(clears parents, joins meshes, applies transforms), recenters it on the origin in
X/Z, scales it to the tile footprint / height band, then exports a GLB with
embedded textures.

Blender's flatpak sandbox cannot read the host /tmp, so the unzipped kits are
expected under KIT_ROOT (default ~/.cache/gridfall_kenney/<kit>/glb/*.glb).

Usage:
    blender --background --python /ABS/tools/blender/import_kits.py -- all
    blender --background --python /ABS/tools/blender/import_kits.py -- zones/r1 vehicles/bus
    (filters match any job whose output path starts with the given prefix)
    Optional: --kits /path/to/kit/root
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODELS = os.path.join(PROJECT_ROOT, "models")
KIT_ROOT = os.environ.get("GRIDFALL_KIT_ROOT", os.path.expanduser("~/.cache/gridfall_kenney"))

FP = 0.94  # max tile footprint (X and Z in Godot)

# Height bands per zone density level.
BANDS = {1: (0.30, 0.70), 2: (0.70, 1.40), 3: (1.40, 3.20)}


def kit(kit_name, model):
    return os.path.join(KIT_ROOT, kit_name, "glb", model + ".glb")


def proj(rel):
    return os.path.join(MODELS, rel)


COM = "city-kit-commercial"
IND = "city-kit-industrial"
SUB = "city-kit-suburban"
CAR = "car-kit"
WAT = "watercraft-kit"
NAT = "nature-kit"


def zone(folder, level, name, src, **kw):
    lo, hi = BANDS[level]
    job = dict(out="zones/%s/%s.glb" % (folder, name), src=src, fp=FP, hmin=lo, hmax=hi)
    job.update(kw)
    return job


JOBS = []
# r1: small suburban houses
for m in ("a", "c", "e", "h", "k", "r"):
    JOBS.append(zone("r1", 1, "house_" + m, kit(SUB, "building-type-" + m)))
# r2: townhouses / small apartments (Blender-built r2 variants come from make_gridfall_assets_v3.py)
for m in ("f", "i", "j"):
    JOBS.append(zone("r2", 2, "apartment_" + m, kit(COM, "building-" + m)))
# r3: towers (Blender variants also come from v3)
JOBS.append(zone("r3", 3, "apartment_tower", proj("blender/apartment_tower.glb")))
# c1: small shops
for m in ("c", "e"):
    JOBS.append(zone("c1", 1, "shop_" + m, kit(COM, "building-" + m)))
# c2: mid-rise shops / offices
for m in ("a", "b", "d", "h", "n"):
    JOBS.append(zone("c2", 2, "midrise_" + m, kit(COM, "building-" + m)))
JOBS.append(zone("c2", 2, "office", proj("blender/office.glb")))
# c3: skyscrapers
for m in ("a", "b", "c", "d", "e"):
    JOBS.append(zone("c3", 3, "skyscraper_" + m, kit(COM, "building-skyscraper-" + m)))
JOBS.append(zone("c3", 3, "tower_m", kit(COM, "building-m")))
# i1: sheds / warehouses
for m in ("h", "i", "k", "p", "q", "s"):
    JOBS.append(zone("i1", 1, "warehouse_" + m, kit(IND, "building-" + m)))
# i2: factories
for m in ("d", "e", "f", "m", "n"):
    JOBS.append(zone("i2", 2, "factory_" + m, kit(IND, "building-" + m)))
JOBS.append(zone("i2", 2, "factory_sawtooth", proj("blender/factory.glb")))
# i3: heavy plants composed from industrial kit pieces (native kit units, scaled to fit afterwards)
JOBS.append(zone("i3", 3, "plant_chimneys", None, parts=[
    (kit(IND, "building-e"), (1.0, 1.0, 1.0), (0.0, 0.25, 0.0), 0),
    (kit(IND, "chimney-medium"), (1.0, 1.0, 1.7), (-0.55, -0.55, 0.0), 0),
    (kit(IND, "chimney-medium"), (1.0, 1.0, 1.5), (0.0, -0.55, 0.0), 0),
    (kit(IND, "chimney-basic"), (1.2, 1.2, 2.6), (0.6, -0.55, 0.0), 0),
]))
JOBS.append(zone("i3", 3, "plant_tanks", None, parts=[
    (kit(IND, "building-d"), (1.0, 1.0, 1.0), (-0.45, 0.35, 0.0), 0),
    (kit(IND, "detail-tank-large"), (0.62, 0.62, 0.62), (0.5, 0.5, 0.0), 0),
    (kit(IND, "detail-tank-large"), (0.62, 0.62, 0.62), (0.5, -0.5, 0.0), 0),
    (kit(IND, "chimney-medium"), (1.0, 1.0, 1.9), (-0.6, -0.6, 0.0), 0),
]))
JOBS.append(zone("i3", 3, "plant_cooling", None, parts=[
    (kit(IND, "chimney-large"), (0.85, 0.85, 1.45), (0.4, 0.35, 0.0), 0),
    (kit(IND, "building-p"), (0.75, 0.75, 0.75), (-0.2, -0.7, 0.0), 0),
    (kit(IND, "chimney-medium"), (0.9, 0.9, 1.7), (-0.7, 0.3, 0.0), 0),
]))
JOBS.append(zone("i3", 3, "plant_works", None, parts=[
    (kit(IND, "building-l"), (1.0, 1.0, 1.0), (0.42, 0.22, 0.0), 0),
    (kit(IND, "chimney-medium"), (1.0, 1.0, 1.85), (-0.85, -0.8, 0.0), 0),
    (kit(IND, "detail-tank"), (1.0, 1.0, 1.0), (0.3, -0.95, 0.0), 0),
]))

# props
def prop(name, src, fp=0.3, hmax=10.0, **kw):
    job = dict(out="props/%s.glb" % name, src=src, fp=fp, hmin=0.0, hmax=hmax)
    job.update(kw)
    return job


JOBS += [
    prop("tree_round", kit(NAT, "tree_default"), fp=0.32, height=0.50),
    prop("tree_oak", kit(NAT, "tree_oak"), fp=0.38, height=0.55),
    prop("tree_cone", kit(NAT, "tree_cone"), fp=0.30, height=0.55),
    prop("tree_tall", kit(SUB, "tree-large"), fp=0.30, height=0.60),
    prop("tree_small", kit(SUB, "tree-small"), fp=0.25, height=0.40),
    prop("tree_bush", kit(NAT, "plant_bushLarge"), fp=0.28, height=0.16),
    prop("planter_box", kit(SUB, "planter"), fp=0.30),
]

# vehicles: road vehicles stay in native Kenney Car Kit units (same as models/cars/sedan.glb)
JOBS += [
    dict(out="vehicles/truck.glb", src=kit(CAR, "delivery"), native=True),
    dict(out="vehicles/garbage_truck.glb", src=kit(CAR, "garbage-truck"), native=True),
    # Siren boxes: (name, color, center, size) in Blender coords (front = -Y).
    # Siren boxes overlay the kit's own light bars, split in left/right halves.
    dict(out="vehicles/firetruck.glb", src=kit(CAR, "firetruck"), native=True, sirens=[
        ("SirenFrontLeft", "red", (-0.285, -1.06, 1.55), (0.57, 0.23, 0.12)),
        ("SirenFrontRight", "blue", (0.285, -1.06, 1.55), (0.57, 0.23, 0.12)),
        ("SirenRearLeft", "red", (-0.285, 1.45, 1.65), (0.57, 0.23, 0.12)),
        ("SirenRearRight", "blue", (0.285, 1.45, 1.65), (0.57, 0.23, 0.12)),
    ]),
    dict(out="vehicles/ambulance.glb", src=kit(CAR, "ambulance"), native=True, sirens=[
        ("SirenCabLeft", "red", (-0.205, -0.70, 1.35), (0.42, 0.23, 0.12)),
        ("SirenCabRight", "blue", (0.205, -0.70, 1.35), (0.42, 0.23, 0.12)),
        ("SirenBoxLeft", "red", (-0.205, -0.15, 1.65), (0.42, 0.23, 0.12)),
        ("SirenBoxRight", "blue", (0.205, -0.15, 1.65), (0.42, 0.23, 0.12)),
    ]),
    dict(out="vehicles/police.glb", src=kit(CAR, "police"), native=True, sirens=[
        ("SirenLeft", "blue", (-0.18, -0.10, 1.25), (0.36, 0.23, 0.12)),
        ("SirenRight", "red", (0.18, -0.10, 1.25), (0.36, 0.23, 0.12)),
    ]),
]
# boats at tile scale, forward +Z (Godot), waterline at y=0 (sink = fraction of model height below water)
JOBS += [
    dict(out="vehicles/boat_speed.glb", src=kit(WAT, "boat-speed-a"), length=0.55, sink=0.22),
    dict(out="vehicles/boat_tug.glb", src=kit(WAT, "boat-tug-a"), length=0.62, sink=0.18),
    dict(out="vehicles/boat_fishing.glb", src=kit(WAT, "boat-fishing-small"), length=0.72, sink=0.15),
]

GLOW = {"red": (1.0, 0.12, 0.12, 1.0), "blue": (0.15, 0.40, 1.0, 1.0)}
_glow_mats = {}


def glow_mat(color):
    if color in _glow_mats:
        return _glow_mats[color]
    m = bpy.data.materials.new("gf_siren_" + color)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = GLOW[color]
    b.inputs["Emission Color"].default_value = GLOW[color]
    b.inputs["Emission Strength"].default_value = 3.0
    b.inputs["Roughness"].default_value = 0.3
    _glow_mats[color] = m
    return m


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _glow_mats.clear()


def import_any(path):
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    before = set(bpy.data.objects)
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise ValueError("unsupported source: " + path)
    return [o for o in bpy.data.objects if o not in before]


def bake_to_world(objs):
    """Unparent (keeping transforms), drop non-meshes, bake transforms into mesh data."""
    meshes = []
    for o in objs:
        if o.type == "MESH":
            mw = o.matrix_world.copy()
            o.parent = None
            if o.data.users > 1:
                o.data = o.data.copy()
            o.data.transform(mw)
            o.matrix_world = Matrix.Identity(4)
            meshes.append(o)
    for o in objs:
        if o.type != "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    return meshes


def bbox(objs):
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            mn = Vector(map(min, mn, w))
            mx = Vector(map(max, mx, w))
    return mn, mx


def join(objs, name):
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


def add_sirens(specs):
    """Add separate emissive light-bar boxes (origin at their own center) so the game can flash them."""
    names = []
    for name, col, center, size in specs:
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=center)
        s = bpy.context.view_layer.objects.active
        s.scale = size
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        s.name = name
        s.data.name = name
        s.data.materials.append(glow_mat(col))
        names.append(s.name)
    return names


def run_job(job):
    reset()
    out = os.path.join(MODELS, job["out"])
    name = os.path.splitext(os.path.basename(out))[0]
    extra = []
    if job.get("native"):
        objs = import_any(job["src"])
        if job.get("sirens"):
            extra = add_sirens(job["sirens"])
    else:
        if job.get("parts"):
            meshes = []
            for path, scl, loc, rot in job["parts"]:
                part = bake_to_world(import_any(path))
                m = (Matrix.Translation(loc) @ Matrix.Rotation(math.radians(rot), 4, "Z")
                     @ Matrix.Diagonal((scl[0], scl[1], scl[2], 1.0)))
                for o in part:
                    o.data.transform(m)
                meshes += part
        else:
            meshes = bake_to_world(import_any(job["src"]))
        if job.get("rot"):
            for o in meshes:
                o.data.transform(Matrix.Rotation(math.radians(job["rot"]), 4, "Z"))
        obj = join(meshes, name)
        mn, mx = bbox([obj])
        size = mx - mn
        if "length" in job:
            s = job["length"] / size.y
        elif "height" in job:
            s = min(job["height"] / size.z, job["fp"] / max(size.x, size.y))
        else:
            s = min(job["fp"] / max(size.x, size.y), job["hmax"] / size.z)
        center = Vector(((mn.x + mx.x) / 2.0, (mn.y + mx.y) / 2.0, mn.z))
        sink = job.get("sink", 0.0) * size.z * s
        obj.data.transform(Matrix.Translation((0.0, 0.0, -sink)) @ Matrix.Scale(s, 4)
                           @ Matrix.Translation(-center))
        obj.data.update()
        mn, mx = bbox([obj])
        h = mx.z - mn.z
        if h + 1e-4 < job.get("hmin", 0.0):
            print("WARN height %.3f below band for %s" % (h, job["out"]))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=out, export_format="GLB", use_selection=True, export_yup=True,
        export_apply=True, export_materials="EXPORT", export_cameras=False, export_lights=False,
    )
    print("WROTE %s extra=%s" % (job["out"], extra))


def main():
    global KIT_ROOT
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["all"]
    if "--kits" in argv:
        i = argv.index("--kits")
        KIT_ROOT = argv[i + 1]
        del argv[i:i + 2]
    wanted = argv or ["all"]
    failures = []
    for job in JOBS:
        if "all" not in wanted and not any(job["out"].startswith(w) for w in wanted):
            continue
        try:
            run_job(job)
        except Exception as exc:  # keep going so one bad source does not stop the batch
            failures.append((job["out"], repr(exc)))
            print("FAILED %s: %r" % (job["out"], exc))
    print("DONE failures=%d %s" % (len(failures), failures))


main()
