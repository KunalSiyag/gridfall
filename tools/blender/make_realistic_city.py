"""GridFall realistic model library builder (Blender 4.2+/5.x, headless).

Builds photoreal-textured (Poly Haven CC0) buildings, roads, props, vehicles and people as GLBs
under models/real/. Run tools/polyhaven_fetch.py first to populate ~/.cache/gridfall_polyhaven/.

    blender --background --python tools/blender/make_realistic_city.py -- all
    blender --background --python tools/blender/make_realistic_city.py -- zones/r1 roads
    blender --background --python tools/blender/make_realistic_city.py -- --list

Arguments are key prefixes (e.g. "zones", "zones/r1", "buildings/stadium", "vehicles").
Conventions: Godot Y up (Blender Z), front faces Godot +Z (Blender -Y), base at y=0,
1 tile = 1 unit (~20 m), zone/service footprints inside 0.94 x 0.94.
Animated / scripted parts keep their own objects: Rotor*, RotorTail, Floodlight*, Beacon*,
Bulb*, Siren*, StackTop_* (empties at smoke-stack tops). Lit window glass uses a material named
"WindowLit"; people use Shirt / Pants / Skin / Hair materials.
"""

import os
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "realcity"))

import bpy  # noqa: E402

import core  # noqa: E402
from arch import Ctx  # noqa: E402

PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(PROJECT, "models", "real")


def registry():
    reg = {}
    import zones_res
    reg.update(zones_res.R1)
    for mod in ("zones_res2", "zones_com", "zones_ind", "services", "services2", "roads", "props", "vehicles", "people"):
        try:
            m = __import__(mod)
        except ImportError as e:
            if mod in str(e):
                continue
            raise
        reg.update(m.REGISTRY)
    if hasattr(zones_res, "REGISTRY"):
        reg.update(zones_res.REGISTRY)
    return reg


def build(key, entry):
    fn, kw = entry[0], dict(entry[1])
    look = kw.pop("_lit", "Glass")
    core.reset()
    import nature
    nature.BOUND = (0.47 if key.startswith(("zones/", "buildings/")) else 0.2 if key.startswith("props/")
                    else 0.5 if key.startswith("roads/") else None)
    seed = zlib.crc32(key.encode())
    c = Ctx(seed=seed, lit_look=look)
    core.material("WindowLit", override=core.MATS[look])
    t0 = time.time()
    fn(c, **kw)
    name = key.split("/")[-1]
    c.mb.build(name + "_body")
    c.fol.build(name + "_foliage")
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH" and ob.data.users > 1:
            ob.data = ob.data.copy()
    tris = core.tri_count()
    path = os.path.join(OUT, key + ".glb")
    size = core.export_glb(path)
    anim = sorted(o.name for o in bpy.context.scene.objects if o.name.startswith(core.ANIM_PREFIXES))
    mats = sorted({s.material.name for o in bpy.context.scene.objects if o.type == "MESH"
                   for s in o.material_slots if s.material})
    print("BUILT %-40s tris=%6d size=%7.0fKB t=%.1fs anim=%s lit=%s" % (
        key, tris, size / 1024, time.time() - t0, anim, "WindowLit" in mats), flush=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["all"]
    reg = registry()
    if "--list" in argv:
        for k in reg:
            print("KEY", k)
        return
    wanted = [a for a in argv if not a.startswith("--")] or ["all"]
    keys = [k for k in reg if "all" in wanted or any(k == w or k.startswith(w.rstrip("/") + "/") or k.startswith(w)
                                                      for w in wanted)]
    failed = []
    for k in keys:
        try:
            build(k, reg[k])
        except Exception:
            import traceback
            traceback.print_exc()
            failed.append(k)
            print("FAILED", k, flush=True)
    print("DONE built=%d failed=%s" % (len(keys) - len(failed), failed), flush=True)


main()
