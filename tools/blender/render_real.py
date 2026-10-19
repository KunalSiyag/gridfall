"""Render GridFall realistic GLBs with HDRI lighting (EEVEE).

    blender --background --python tools/blender/render_real.py -- --out shot.png [--cols 8] [--res 2400]
        [--hdri env/sky.hdr] [--view sheet|iso] models/real/zones/r1 ...
    blender --background --python tools/blender/render_real.py -- --hero block|crossing --out shot.png
    blender --background --python tools/blender/render_real.py -- --hero eye --out shot.png [--cam az,el,dist]
        [--spacing 6] model.glb ...   (eye level: models in a row on asphalt with a 1.8 m person for scale)
"""

import glob
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
opts = {"--out": None, "--cols": "8", "--res": "2400", "--hdri": os.path.join(PROJECT, "env", "sky.hdr"),
        "--view": "iso", "--hero": None, "--samples": "64", "--strength": "1.0", "--labels": "1",
        "--cam": "-35,12,9", "--spacing": "6", "--size": "1600x900", "--target": ""}
paths = []
i = 0
while i < len(argv):
    if argv[i] in opts:
        opts[argv[i]] = argv[i + 1]
        i += 2
    else:
        paths.append(argv[i])
        i += 1

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def setup_world(hdri, strength=1.0, rot=0.6):
    w = bpy.data.worlds.new("hdri")
    scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes["Background"]
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(hdri)
    mp = nt.nodes.new("ShaderNodeMapping")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp.inputs["Rotation"].default_value = (0, 0, rot)
    nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], env.inputs["Vector"])
    nt.links.new(env.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = strength


def add_sun(energy=3.5, elev=48, az=-35):
    sd = bpy.data.lights.new("sun", "SUN")
    sd.energy = energy
    sd.angle = math.radians(1.5)
    so = bpy.data.objects.new("sun", sd)
    so.rotation_euler = (math.radians(90 - elev), 0, math.radians(az))
    scene.collection.objects.link(so)


def import_glb(path, loc=(0, 0, 0), rz=0.0, scale=1.0):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    for o in objs:
        if o.parent is None:
            o.matrix_world = Matrix.Translation(Vector(loc)) @ Matrix.Rotation(rz, 4, "Z") @ \
                Matrix.Scale(scale, 4) @ o.matrix_world
    return objs


def setup_render(res_x, res_y, samples):
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = res_x
    scene.render.resolution_y = res_y
    scene.render.film_transparent = False
    try:
        scene.eevee.taa_render_samples = samples
        scene.eevee.use_shadows = True
        scene.eevee.use_raytracing = True
        scene.eevee.shadow_ray_count = 2
        scene.eevee.fast_gi_method = "GLOBAL_ILLUMINATION"
    except Exception as e:
        print("eevee opt", e)
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"


def camera(loc, target, lens=50, ortho=None):
    cd = bpy.data.cameras.new("cam")
    if ortho:
        cd.type = "ORTHO"
        cd.ortho_scale = ortho
    else:
        cd.lens = lens
    cd.clip_start = 0.01
    cd.clip_end = 500
    co = bpy.data.objects.new("cam", cd)
    scene.collection.objects.link(co)
    co.location = loc
    d = Vector(target) - Vector(loc)
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    scene.camera = co
    return co


def label(text, loc, size=0.08):
    bpy.ops.object.text_add(location=loc, rotation=(math.radians(60), 0, 0))
    t = bpy.context.view_layer.objects.active
    t.data.body = text
    t.data.size = size
    m = bpy.data.materials.new("label")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.02, 0.02, 0.02, 1)
    t.data.materials.append(m)


def ground(size=200, z=-0.0005):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, z))
    g = bpy.context.view_layer.objects.active
    m = bpy.data.materials.new("ground")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.32, 0.33, 0.3, 1)
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
    g.data.materials.append(m)


def sheet():
    files = []
    for p in paths:
        ap = p if os.path.isabs(p) else os.path.join(PROJECT, p)
        files += sorted(glob.glob(os.path.join(ap, "**", "*.glb"), recursive=True)) if os.path.isdir(ap) else [ap]
    cols = int(opts["--cols"])
    cell = 1.25
    items = []
    for f in files:
        sc = 1.0
        if "/vehicles/" in f and not any(t in f for t in ("plane", "boat")):
            sc = 2.0
        if "/people/" in f:
            sc = 6.0
        if "/props/" in f:
            sc = 2.2
        if "/vehicles_v2/" in f:
            sc = 2.0
        if "/street/" in f:
            sc = 3.0
        objs = import_glb(f, (0, 0, 0), scale=sc)
        bpy.context.view_layer.update()
        hz = max([(o.matrix_world @ Vector(c)).z for o in objs if o.type == "MESH" for c in o.bound_box] or [0.5])
        lz = min([(o.matrix_world @ Vector(c)).z for o in objs if o.type == "MESH" for c in o.bound_box] or [0.0])
        if "/vehicles/" in f and "boat" not in f and lz < -1e-3:
            # the plane's origin is its fuselage axis; stand it on its gear for the sheet
            for o in objs:
                if o.parent is None:
                    o.matrix_world = Matrix.Translation(Vector((0, 0, -lz))) @ o.matrix_world
            hz -= lz
        items.append((f, objs, hz))
    y = 0.0
    for idx, (f, objs, hz) in enumerate(items):
        col, row = idx % cols, idx // cols
        if col == 0 and row > 0:
            row_h = max(it[2] for it in items[row * cols:(row + 1) * cols])
            y -= cell + max(0.0, row_h - 0.6) * 0.75
        x = col * cell
        for o in objs:
            if o.parent is None:
                o.matrix_world = Matrix.Translation(Vector((x, y, 0))) @ o.matrix_world
        rel = os.path.relpath(f, os.path.join(PROJECT, "models", "real"))
        if opts["--labels"] == "1":
            label(rel.replace(".glb", ""), (x - 0.55, y - 0.62, 0.0), size=0.07)
    # 3/4 view from the south (front faces -Y), framed to the actual content bounds
    d = Vector((0.35, -1.0, 0.85)).normalized()
    bpy.context.view_layer.update()
    pts = []
    for o in scene.objects:
        if o.type in ("MESH", "FONT"):
            pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
    ground()
    cam = camera(Vector((0, 0, 0)) + d * 60, Vector((0, 0, 0)), ortho=10)
    rot = cam.rotation_euler.to_matrix()
    right, up = rot @ Vector((1, 0, 0)), rot @ Vector((0, 1, 0))
    xs = [p.dot(right) for p in pts]
    ys = [p.dot(up) for p in pts]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    cxv = (max(xs) + min(xs)) / 2
    cyv = (max(ys) + min(ys)) / 2
    centre = right * cxv + up * cyv
    cam.location = centre + d * 60
    cam.data.ortho_scale = max(w, h) * 1.04
    res = int(opts["--res"])
    if w >= h:
        setup_render(res, max(300, int(res * h / w)), int(opts["--samples"]))
    else:
        setup_render(max(300, int(res * w / h)), res, int(opts["--samples"]))


def _mat_flat(name, col, rough=0.9):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Roughness"].default_value = rough
    return m


def _plane(x0, y0, x1, y1, z, mat):
    bpy.ops.mesh.primitive_plane_add(size=1, location=((x0 + x1) / 2, (y0 + y1) / 2, z))
    p = bpy.context.view_layer.objects.active
    p.scale = (x1 - x0, y1 - y0, 1)
    p.data.materials.append(mat)
    return p


# Road pieces in their base orientation (mask bits N=1, E=2, S=4, W=8) and the turn that maps them
# onto every other mask; the turn is applied about the tile's vertical axis like the game does.
_ROAD_BASE = {"straight": 5, "corner": 12, "tee": 14, "cross": 15, "end": 4}


def _rot_mask(m, q):
    for _ in range(q):
        m = ((m << 1) | (m >> 3)) & 15
    return m


def _road_for(mask):
    for kind, base in _ROAD_BASE.items():
        for q in range(4):
            if _rot_mask(base, q) == mask:
                return kind, q
    return "straight", 0


def hero(kind):
    M = os.path.join(PROJECT, "models", "real")
    g = lambda p: os.path.join(M, p + ".glb")
    RS = 0.9  # the game's REAL_SCALE for zone and service buildings
    T = lambda i, j: Vector((i, -j, 0))  # game tile (x, z) -> Blender

    def put(p, i, j, rot=0, scale=1.0, dx=0.0, dz=0.0, y=0.0):
        """rot: quarter turns as the game's rotation_degrees.y; dx/dz offsets in Godot tile units."""
        loc = T(i, j) + Vector((dx, -dz, y))
        return import_glb(g(p), loc, rz=math.radians(90 * rot), scale=scale)

    if kind == "eye":
        # metres -> units; models stand in a row along X, front (Godot +Z = Blender -Y) toward the camera
        Mu = 1.0 / 20.0
        asphalt = _mat_flat("asphalt", (0.05, 0.05, 0.052), 0.85)
        _plane(-5, -5, 5, 5, -0.0002, asphalt)
        sp = float(opts["--spacing"]) * Mu
        xs = [(i - (len(paths) - 1) / 2) * sp for i in range(len(paths))]
        for x, p in zip(xs, paths):
            ap = p if os.path.isabs(p) else os.path.join(PROJECT, p)
            import_glb(ap, (x, 0, 0))
        person = os.path.join(M, "people", "person_a.glb")
        if os.path.exists(person):
            import_glb(person, (xs[-1] + sp * 0.55, -1.2 * Mu, 0), rz=0.4)
        az, el, dist = (float(v) for v in opts["--cam"].split(","))
        tgt = Vector((0, 0, 0.9 * Mu))
        if opts["--target"]:
            tgt = Vector([float(v) * Mu for v in opts["--target"].split(",")])
        d = Vector((math.sin(math.radians(az)) * math.cos(math.radians(el)), -math.cos(math.radians(az)) *
                    math.cos(math.radians(el)), math.sin(math.radians(el))))
        loc = tgt + d * dist * Mu
        cam = camera(loc, tgt, lens=30)
        cam.data.clip_start = 0.002
        w, h = (int(v) for v in opts["--size"].split("x"))
        setup_render(w, h, int(opts["--samples"]))
        return
    if kind == "single":
        ground()
        import_glb(paths[0])
        camera((1.6, -2.6, 1.9), (0, 0, 0.25), lens=55)
        setup_render(1920, 1080, int(opts["--samples"]))
        return
    grass = _mat_flat("grass_ground", (0.085, 0.13, 0.05))
    _plane(-20, -20, 20, 20, -0.002, grass)
    W, H = 7, 7
    roads = set()
    for k in range(W):
        roads.add((k, 3))
        roads.add((3, k))
    if kind == "district":
        for k in range(W):
            roads.add((k, 0))
        for k in range(1, 3):
            roads.add((0, k))
    masks = {}
    for (i, j) in roads:
        mask = (1 if (i, j - 1) in roads else 0) | (2 if (i + 1, j) in roads else 0) | \
               (4 if (i, j + 1) in roads else 0) | (8 if (i - 1, j) in roads else 0)
        masks[(i, j)] = mask
        rk, q = _road_for(mask)
        if rk == "straight" and (i + j) % 4 == 0:
            rk = "straight_lights"
        put("roads/road_" + rk, i, j, rot=-q)
    blocks = {
        "block": {
            (2, 2): ("zones/c3/sky_glass", 0), (1, 2): ("zones/c2/office_stone", 0), (2, 1): ("zones/c2/office_ribbon", 1),
            (1, 1): ("zones/c3/sky_octagon", 0), (0, 2): ("zones/c1/cafe", 0), (2, 0): ("zones/c1/bank", 1),
            (4, 2): ("zones/r3/tower_glass_balcony", 0), (5, 2): ("zones/r2/euro_apartment", 0),
            (4, 1): ("zones/r2/walkup_brick", -1), (5, 1): ("buildings/park", 0), (6, 2): ("zones/r2/townhouse_row", 0),
            (2, 4): ("zones/c1/shop_row", 2), (1, 4): ("zones/c1/corner_store", 2), (2, 5): ("zones/c2/office_loft", 1),
            (0, 4): ("zones/r2/walkup_yellow", 2), (1, 5): ("buildings/city_hall", 2),
            (4, 4): ("zones/r1/house_gable_white", 2), (5, 4): ("zones/r1/house_cottage", 2),
            (6, 4): ("zones/r1/house_hip_brick", 2), (4, 5): ("zones/r1/house_modern", -1),
            (5, 5): ("zones/r1/house_bungalow", 0), (4, 6): ("zones/r1/house_gable_yellow", -1),
            (0, 1): ("zones/c2/office_glass", 0), (1, 0): ("zones/r3/tower_slab", 0),
            (4, 0): ("zones/r3/tower_brick_point", 0), (6, 1): ("zones/r2/modern_midrise", 0),
            (0, 5): ("buildings/school", 2), (2, 6): ("zones/c1/mini_mart", 1), (6, 5): ("buildings/hospital", 1),
        },
        "district": {
            (1, 1): ("buildings/train_station", 0), (2, 1): ("zones/c2/office_glass", 0), (2, 2): ("zones/c3/sky_deco", 0),
            (1, 2): ("zones/c3/sky_grid", 0), (4, 2): ("zones/c2/office_loft", 0), (5, 2): ("buildings/stadium", 0),
            (4, 1): ("buildings/police_station", 1), (5, 1): ("buildings/fire_station", 0), (6, 2): ("buildings/university", 0),
            (2, 4): ("zones/i2/factory_brick", 2), (1, 4): ("zones/i2/factory_modern", 2), (2, 5): ("zones/i1/warehouse_steel", 1),
            (1, 5): ("zones/i3/refinery", 0), (0, 4): ("zones/i1/depot_cladded", 2), (0, 5): ("zones/i3/steel_mill", 0),
            (4, 4): ("buildings/coal_plant", 2), (5, 4): ("buildings/water_pump", 2), (6, 4): ("buildings/sewage_plant", 2),
            (4, 5): ("buildings/solar_farm", 0), (5, 5): ("buildings/wind_farm", 0), (6, 5): ("buildings/landfill", 0),
            (2, 6): ("zones/i2/plant_food", 1), (1, 6): ("zones/i3/chemical_plant", 0), (0, 6): ("zones/i3/cement_works", 0),
            (4, 6): ("buildings/airport", 0), (6, 1): ("buildings/hospital", 0),
        },
    }
    lay = blocks["district" if kind == "district" else "block"]
    for (i, j), (p, rot) in lay.items():
        if (i, j) not in roads:
            put(p, i, j, rot=rot, scale=RS)
    # traffic: right-hand lanes; a model's front is Godot +Z, rot turns it like rotation_degrees.y
    cars = ["sedan_blue", "taxi", "suv_black", "hatchback_red", "van_white", "sedan_silver", "pickup_red",
            "coupe_yellow", "suv_grey", "sedan_red", "hatchback_white", "police", "van_minibus", "sedan_white"]
    k = 0
    busy = {(3, 4), (5, 3), (1, 3), (3, 5)}
    for (i, j) in sorted(roads):
        if masks[(i, j)] not in (5, 10) or (i, j) in busy:
            continue
        if masks[(i, j)] == 5:  # north-south: northbound keeps to +X, southbound to -X
            put("vehicles/" + cars[k % len(cars)], i, j, rot=2, dx=0.15, dz=0.1 * ((k % 3) - 1))
            if (j + k) % 2 == 0:
                put("vehicles/" + cars[(k + 5) % len(cars)], i, j, rot=0, dx=-0.15, dz=-0.2)
        else:  # east-west: eastbound keeps to +Z, westbound to -Z
            put("vehicles/" + cars[k % len(cars)], i, j, rot=1, dx=0.1 * ((k % 3) - 1), dz=0.15)
            if (i + k) % 2 == 1:
                put("vehicles/" + cars[(k + 3) % len(cars)], i, j, rot=-1, dx=0.2, dz=-0.15)
        k += 1
    put("vehicles/bus", 3, 4, rot=2, dx=0.15, dz=0.05)
    put("vehicles/firetruck", 5, 3, rot=1, dx=-0.1, dz=0.15)
    put("vehicles/ambulance", 1, 3, rot=-1, dx=0.1, dz=-0.15)
    put("vehicles/taxi", 3, 5, rot=0, dx=-0.15, dz=-0.1)
    if kind == "district":
        put("vehicles/garbage_truck", 3, 5, rot=0, dx=-0.15, dz=0.35)
        put("vehicles/plane", 7.4, 5.2, rot=2, y=1.5)
        put("vehicles/helicopter", 5.6, 1.4, rot=1, y=1.3)
    # sidewalk life: people (game draws them at 1.5x), lamps, trees, benches, hydrants, bus stop
    people = ["person_%s" % c for c in "abcdefgh"]
    pk = 0
    for (i, j) in sorted(roads):
        if masks[(i, j)] not in (5, 10):
            continue
        vertical = masks[(i, j)] == 5
        for s in (-1, 1):
            if (i * 7 + j * 3 + s) % 3 == 0:
                continue
            if vertical:
                put("people/" + people[pk % 8], i, j, rot=(0 if pk % 2 else 2), scale=1.5, dx=s * 0.4,
                    dz=0.3 * ((pk % 3) - 1))
            else:
                put("people/" + people[pk % 8], i, j, rot=(1 if pk % 2 else -1), scale=1.5, dz=s * 0.4,
                    dx=0.3 * ((pk % 3) - 1))
            pk += 1
    for (i, j), (p, rot) in lay.items():
        if (i, j) in roads or p.startswith("buildings/"):
            continue
        h = (i * 73856093) ^ (j * 19349663)
        prop = ("props/tree_round", "props/lamp_street", "props/tree_oak", "props/bench_park", "props/hydrant",
                "props/trash_bin")[h % 6]
        if "/i" in p:
            prop = ("props/lamp_street", "props/hydrant", "props/trash_bin_wheelie")[h % 3]
        put(prop, i, j, rot=rot, dx=0.4 if h % 2 else -0.4, dz=0.4)
    put("props/bus_stop", 3, 4, rot=-1, dx=0.42, dz=0.15)
    if kind == "crossing":
        camera((3.95, -4.55, 0.55), (3.05, -2.85, 0.32), lens=24)
    elif kind == "district":
        camera((9.3, -10.6, 7.2), (3.3, -3.4, 0.2), lens=33)
    else:
        camera((9.6, -10.6, 6.3), (3.1, -3.0, 0.75), lens=29)
    setup_render(1920, 1080, int(opts["--samples"]))

if opts["--hero"]:
    hero(opts["--hero"])
else:
    sheet()
setup_world(opts["--hdri"], float(opts["--strength"]))
add_sun()
scene.render.filepath = opts["--out"]
bpy.ops.render.render(write_still=True)
print("RENDERED", opts["--out"])
