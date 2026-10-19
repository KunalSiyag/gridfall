#!/usr/bin/env python3
"""Download the Poly Haven (CC0) assets GridFall's realistic library is built from.

Everything lands in ~/.cache/gridfall_polyhaven/ (the Blender flatpak cannot see /tmp):
    meta/                 API listings (files_<id>.json)
    textures/<id>/        <id>_{diff,nor_gl,arm,rough}_<res>.jpg
    models/<id>/          glTF 1k with textures/ and .bin
    leaves/<id>/          leaf/twig atlases taken from Poly Haven plant models
    hdris/<id>_2k.hdr
    derived/              512 px building texture copies, leaf-cluster cards, water normal

Then the runtime files Godot loads directly are copied into the project:
    env/sky.hdr, env/sky_night.hdr, textures/real/*.jpg|png
and models/real/LICENSES/polyhaven.txt is rewritten.

Usage:  python3 tools/polyhaven_fetch.py            (idempotent; skips cached files)
        python3 tools/polyhaven_fetch.py --derive   (only rebuild derived/ + runtime copies)
"""

import json
import math
import os
import random
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image, ImageFilter

UA = "gridfall/1.0"
API = "https://api.polyhaven.com"
CACHE = os.path.expanduser("~/.cache/gridfall_polyhaven")
PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# Facade / roof / detail textures: fetched at 1k, embedded into GLBs as 512 px copies.
BUILDING_TEXTURES = [
    "red_brick_03", "brick_wall_006", "brown_brick_02", "red_bricks_04",
    "beige_wall_001", "white_plaster_02", "plaster_grey_04", "painted_plaster_wall",
    "concrete_wall_008", "concrete_slab_wall", "concrete_wall_004", "rectangular_facade_tiles_02",
    "concrete_floor_02", "brown_planks_05",
    "clay_roof_tiles_02", "grey_roof_tiles", "roof_slates_02", "grey_roof_01", "bitumen",
    "corrugated_iron_02", "corrugated_iron", "factory_wall", "box_profile_metal_sheet",
    "container_side", "rusty_metal_02", "painted_metal_shutter", "metal_plate",
    "gravel_floor", "brown_planks_03", "wood_planks", "bark_brown_02", "bark_platanus",
    "gravel", "rocks_ground_02",
]
# Ground textures used both by the models (512 copies) and by Godot directly (2k).
GROUND_TEXTURES = {
    "leafy_grass": "grass",
    "concrete_pavement": "sidewalk",
    "asphalt_01": "asphalt",
    "dirt": "dirt",
}
# Leaf atlases (diffuse + alpha [+ normal]) taken from Poly Haven plant models.
LEAF_SOURCES = {
    "jacaranda_tree": ("leaves_diff", "leaves_alpha", "leaves_nor_gl"),
    "tree_small_02": ("leaves_diff", "leaves_alpha", "leaves_nor_gl"),
    "island_tree_02": ("leaves_diff", "leaves_alpha", "leaves_nor_gl"),
    "searsia_lucida": ("Diffuse", "Alpha", "nor_gl"),
}
MODELS = [
    "street_lamp_01", "street_lamp_02", "fire_hydrant", "metal_trash_can", "painted_wooden_bench",
    "concrete_road_barrier", "exterior_aircon_unit", "utility_box_01", "planter_box_01",
    "shrub_03", "rock_07", "wooden_picnic_table", "modular_street_seating",
]
# Poly Haven models whose (decimated) geometry ships inside library GLBs.
EMBEDDED = {
    "painted_wooden_bench": "props/bench_park",
    "fire_hydrant": "props/hydrant",
    "metal_trash_can": "props/trash_bin",
    "planter_box_01": "props/planter_box",
    "wooden_picnic_table": "props/picnic_table",
    "utility_box_01": "props/utility_box",
    "exterior_aircon_unit": "props/aircon_unit",
    "concrete_road_barrier": "props/barrier_concrete",
    "rock_07": "props/rock_boulder",
}
HDRIS = {
    "kloofendal_48d_partly_cloudy_puresky": "sky.hdr",
    "modern_buildings_night": "sky_night.hdr",
    "qwantani_dusk_2_puresky": "sky_dusk.hdr",
}


def log(*a):
    print(*a, flush=True)


def curl(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    for attempt in range(4):
        r = subprocess.run(["curl", "-sSfL", "-A", UA, "--retry", "3", "-o", tmp, url])
        if r.returncode == 0 and os.path.getsize(tmp) > 0:
            os.replace(tmp, dest)
            return dest
    raise RuntimeError("download failed: " + url)


def files_json(asset_id):
    p = os.path.join(CACHE, "meta", "files_%s.json" % asset_id)
    curl("%s/files/%s" % (API, asset_id), p)
    with open(p) as f:
        return json.load(f)


def pick(d, *keys):
    for k in keys:
        if k in d:
            return d[k]
    raise KeyError("none of %s in %s" % (keys, list(d)))


def fetch_texture(asset_id, res):
    d = files_json(asset_id)
    out = {}
    for role, keys in (("diff", ("Diffuse", "diff")), ("nor_gl", ("nor_gl",)), ("arm", ("arm",)),
                       ("rough", ("Rough", "rough"))):
        try:
            entry = pick(d, *keys)
        except KeyError:
            continue
        r = res if res in entry else sorted(entry)[0]
        url = entry[r]["jpg"]["url"] if "jpg" in entry[r] else entry[r]["png"]["url"]
        ext = os.path.splitext(url)[1]
        dest = os.path.join(CACHE, "textures", asset_id, "%s_%s_%s%s" % (asset_id, role, r, ext))
        out[role] = curl(url, dest)
    return out


def fetch_model(asset_id, res="1k"):
    d = files_json(asset_id)
    g = d["gltf"][res]["gltf"]
    base = os.path.join(CACHE, "models", asset_id)
    main = curl(g["url"], os.path.join(base, os.path.basename(g["url"])))
    for rel, info in g.get("include", {}).items():
        curl(info["url"], os.path.join(base, rel))
    return main


def fetch_leaves(asset_id, keys):
    d = files_json(asset_id)
    out = []
    for k in keys:
        url = d[k]["1k"]["jpg"]["url"]
        out.append(curl(url, os.path.join(CACHE, "leaves", asset_id, "%s_%s_1k.jpg" % (asset_id, k))))
    return out


def fetch_hdri(asset_id, res="2k"):
    d = files_json(asset_id)
    url = d["hdri"][res]["hdr"]["url"]
    return curl(url, os.path.join(CACHE, "hdris", "%s_%s.hdr" % (asset_id, res)))


# ------------------------------------------------------------------ derived assets

TEX512_DIR = os.path.join(CACHE, "derived", "tex512")


def derive_512(asset_id, maps):
    out_dir = TEX512_DIR
    os.makedirs(out_dir, exist_ok=True)
    for role, src in maps.items():
        if role == "rough":
            continue
        dest = os.path.join(out_dir, "%s_%s.jpg" % (asset_id, role))
        if os.path.exists(dest):
            continue
        im = Image.open(src).convert("RGB").resize((512, 512), Image.LANCZOS)
        im.save(dest, quality=88)


def _components(alpha, min_px=400):
    from scipy import ndimage
    mask = alpha > 96
    lab, n = ndimage.label(ndimage.binary_dilation(mask, iterations=2))
    boxes = ndimage.find_objects(lab)
    out = []
    for i, sl in enumerate(boxes):
        if sl is None:
            continue
        h = sl[0].stop - sl[0].start
        w = sl[1].stop - sl[1].start
        if (lab[sl] == i + 1).sum() >= min_px and w < alpha.shape[1] * 0.6 and h < alpha.shape[0] * 0.6:
            out.append((sl, i + 1))
    return lab, out


def make_leaf_cluster(asset_id, keys, name, tint=(1.0, 1.0, 1.0), count=150, size=512, scale=(0.22, 0.42),
                      seed=1, fill=0.46):
    """Scatter photographed leaves from a Poly Haven atlas into a dense, alpha-tested foliage card."""
    src = [os.path.join(CACHE, "leaves", asset_id, "%s_%s_1k.jpg" % (asset_id, k)) for k in keys]
    diff = Image.open(src[0]).convert("RGB")
    alpha = np.array(Image.open(src[1]).convert("L"))
    lab, comps = _components(alpha)
    if not comps:
        raise RuntimeError("no leaf sprites found in " + asset_id)
    sprites = []
    darr = np.array(diff)
    for sl, idx in comps:
        rgb = darr[sl]
        a = np.where(lab[sl] == idx, alpha[sl], 0).astype(np.uint8)
        sprites.append(Image.fromarray(np.dstack([rgb, a]), "RGBA"))
    rnd = random.Random(seed)
    big = size * 2
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    cx = cy = big / 2
    for i in range(count):
        sp = rnd.choice(sprites)
        s = rnd.uniform(*scale) * size / max(sp.size)
        im = sp.resize((max(2, int(sp.size[0] * s)), max(2, int(sp.size[1] * s))), Image.LANCZOS)
        im = im.rotate(rnd.uniform(0, 360), expand=True, resample=Image.BICUBIC)
        # later (outer, upper) leaves are brighter: cheap self-shadowing of the clump
        r = math.sqrt(rnd.random()) * size * fill
        th = rnd.uniform(0, 2 * math.pi)
        x = cx + math.cos(th) * r - im.size[0] / 2
        y = cy + math.sin(th) * r - im.size[1] / 2
        shade = 0.6 + 0.4 * (i / count)
        arr = np.array(im).astype(np.float32)
        arr[..., 0] *= shade * tint[0]
        arr[..., 1] *= shade * tint[1]
        arr[..., 2] *= shade * tint[2]
        im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
        canvas.alpha_composite(im, (int(x), int(y)))
    # fade the clump to a ragged round silhouette so cards do not show square edges
    canvas = canvas.crop((size // 2, size // 2, size // 2 + size, size // 2 + size))
    a = np.array(canvas).astype(np.float32)
    yy, xx = np.mgrid[0:size, 0:size]
    rr = np.hypot(xx - size / 2, yy - size / 2) / (size / 2)
    noise = np.array(Image.fromarray((np.random.default_rng(seed).random((16, 16)) * 255).astype(np.uint8))
                     .resize((size, size), Image.BICUBIC)).astype(np.float32) / 255.0
    keep = rr < (0.78 + 0.22 * noise)
    a[..., 3] *= keep
    a = a.astype(np.uint8)
    # binarise alpha for alpha-scissor and bleed colour into transparent texels (no dark fringes)
    rgb = Image.fromarray(a[..., :3])
    mask = a[..., 3] > 110
    bleed = rgb.filter(ImageFilter.GaussianBlur(6))
    out = np.where(mask[..., None], a[..., :3], np.array(bleed))
    final = np.dstack([out, (mask * 255).astype(np.uint8)])
    dest = os.path.join(CACHE, "derived", "leafcluster_%s.png" % name)
    im = Image.fromarray(final.astype(np.uint8), "RGBA").resize((384, 384), Image.LANCZOS)
    arr = np.array(im)
    arr[..., 3] = np.where(arr[..., 3] > 127, 255, 0)
    im = Image.fromarray(arr, "RGBA").quantize(colors=255, method=Image.FASTOCTREE, dither=Image.NONE)
    im.save(dest, optimize=True)
    return dest


def green_grass(src, dest, size=None):
    """Shift the Poly Haven lawn texture (brown leaf litter) toward a healthy park-lawn green."""
    im = Image.open(src).convert("RGB")
    if size:
        im = im.resize((size, size), Image.LANCZOS)
    a = np.array(im).astype(np.float32) / 255.0
    lum = a @ np.array([0.3, 0.59, 0.11])
    green = np.dstack([lum * 0.50, lum * 0.80, lum * 0.30]) * 1.15
    out = np.clip(a * 0.45 + green * 0.55, 0, 1)
    Image.fromarray((out * 255).astype(np.uint8)).save(dest, quality=90)


def derive_models_512():
    for m in MODELS:
        src = os.path.join(CACHE, "models", m, "textures")
        dst = os.path.join(CACHE, "derived", "models512", m)
        os.makedirs(dst, exist_ok=True)
        for fn in os.listdir(src) if os.path.isdir(src) else []:
            d = os.path.join(dst, fn)
            if os.path.exists(d):
                continue
            im = Image.open(os.path.join(src, fn))
            im = im.convert("RGBA" if im.mode in ("RGBA", "LA") else "RGB").resize((512, 512), Image.LANCZOS)
            im.save(d, quality=88) if fn.lower().endswith(".jpg") else im.save(d)


def make_water_normal(dest, size=1024, seed=3):
    """Tileable procedural water-ripple normal map (OpenGL convention). Not a Poly Haven asset."""
    rnd = np.random.default_rng(seed)
    y, x = np.mgrid[0:size, 0:size] / size
    h = np.zeros((size, size))
    for _ in range(48):
        kx, ky = rnd.integers(-14, 15, 2)
        if kx == 0 and ky == 0:
            continue
        amp = 1.0 / math.hypot(kx, ky) ** 1.3
        h += amp * np.sin(2 * math.pi * (kx * x + ky * y) + rnd.uniform(0, 2 * math.pi))
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * size / 2
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * size / 2
    k = 0.012
    n = np.dstack([-gx * k, gy * k, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save(dest)


def make_solar_cells(size=256):
    """Procedural photovoltaic-module texture (6 x 6 cells per repeat). Not a Poly Haven asset."""
    n = 6
    y, x = np.mgrid[0:size, 0:size]
    cell = size / n
    fx, fy = (x % cell) / cell, (y % cell) / cell
    gap = (fx < 0.04) | (fx > 0.96) | (fy < 0.04) | (fy > 0.96)
    busbar = (np.abs(fx - 0.33) < 0.012) | (np.abs(fx - 0.66) < 0.012)
    rnd = np.random.default_rng(1)
    base = np.array([18, 30, 62], float) + rnd.normal(0, 3, (size, size, 1))
    img = np.broadcast_to(base, (size, size, 3)).copy()
    img[busbar] = (90, 98, 112)
    img[gap] = (170, 176, 184)
    frame = (x < 3) | (y < 3) | (x > size - 4) | (y > size - 4)
    img[frame] = (150, 152, 156)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(os.path.join(TEX512_DIR, "solar_cells_diff.jpg"),
                                                                 quality=90)
    arm = np.zeros((size, size, 3), np.uint8)
    arm[..., 0] = 255
    arm[..., 1] = np.where(gap | frame, 110, 30)
    arm[..., 2] = np.where(gap | frame, 220, 60)
    Image.fromarray(arm).save(os.path.join(TEX512_DIR, "solar_cells_arm.jpg"), quality=90)


def derive_all(tex_maps):
    os.makedirs(os.path.join(CACHE, "derived"), exist_ok=True)
    for asset_id, maps in tex_maps.items():
        derive_512(asset_id, maps)
    green_grass(tex_maps["leafy_grass"]["diff"], os.path.join(TEX512_DIR, "leafy_grass_diff.jpg"), 512)
    derive_models_512()
    make_leaf_cluster("tree_small_02", LEAF_SOURCES["tree_small_02"], "broad", count=260, seed=11,
                      scale=(0.12, 0.24), fill=0.42, tint=(0.85, 1.0, 0.8))
    make_leaf_cluster("island_tree_02", LEAF_SOURCES["island_tree_02"], "round", count=220, seed=5,
                      scale=(0.12, 0.22), fill=0.42, tint=(0.9, 1.0, 0.75))
    make_leaf_cluster("jacaranda_tree", LEAF_SOURCES["jacaranda_tree"], "fern", count=90, seed=7,
                      scale=(0.3, 0.55), fill=0.36, tint=(0.85, 1.0, 0.7))
    make_leaf_cluster("jacaranda_tree", LEAF_SOURCES["jacaranda_tree"], "conifer", count=110, seed=9,
                      tint=(0.45, 0.66, 0.5), scale=(0.3, 0.55), fill=0.36)
    make_leaf_cluster("searsia_lucida", LEAF_SOURCES["searsia_lucida"], "shrub", count=240, seed=13,
                      tint=(0.7, 0.95, 0.62), scale=(0.1, 0.2), fill=0.42)
    make_water_normal(os.path.join(CACHE, "derived", "water_normal.png"))
    make_solar_cells()


def copy_runtime(tex_maps, hdri_paths):
    env = os.path.join(PROJECT, "env")
    real = os.path.join(PROJECT, "textures", "real")
    os.makedirs(env, exist_ok=True)
    os.makedirs(real, exist_ok=True)
    for asset_id, fname in HDRIS.items():
        shutil.copyfile(hdri_paths[asset_id], os.path.join(env, fname))
    for asset_id, short in GROUND_TEXTURES.items():
        maps = tex_maps[asset_id + "@2k"]
        if short == "grass":
            green_grass(maps["diff"], os.path.join(real, "grass_albedo.jpg"))
        else:
            shutil.copyfile(maps["diff"], os.path.join(real, "%s_albedo.jpg" % short))
        shutil.copyfile(maps["nor_gl"], os.path.join(real, "%s_normal.jpg" % short))
        shutil.copyfile(maps["rough"], os.path.join(real, "%s_rough.jpg" % short))
    shutil.copyfile(os.path.join(CACHE, "derived", "water_normal.png"), os.path.join(real, "water_normal.png"))


def write_license():
    path = os.path.join(PROJECT, "models", "real", "LICENSES", "polyhaven.txt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [
        "GridFall realistic asset library - third-party content",
        "",
        "All assets below come from Poly Haven (https://polyhaven.com) and are licensed CC0 1.0",
        "(public domain, https://creativecommons.org/publicdomain/zero/1.0/). No attribution is",
        "required; they are listed here for provenance. Geometry for buildings, roads, vehicles and",
        "people was modelled procedurally by tools/blender/make_realistic_city.py and uses these",
        "textures. textures/real/water_normal.png and the embedded solar-cell texture are procedurally",
        "generated (not Poly Haven).",
        "",
        "Textures (https://polyhaven.com/a/<id>):",
    ]
    lines += ["  " + t for t in BUILDING_TEXTURES + list(GROUND_TEXTURES)]
    lines += ["", "Leaf atlases taken from these plant models (used to compose foliage cards):"]
    lines += ["  " + t for t in LEAF_SOURCES]
    lines += ["", "Models (fetched; decimated copies with 512 px textures are embedded where noted):"]
    lines += ["  %s%s" % (m, ("  -> " + EMBEDDED[m]) if m in EMBEDDED else "") for m in MODELS]
    lines += ["", "Procedural (no third-party content): all vehicles (models/real/vehicles), all people",
              "(models/real/people), road pieces, and every building / zone mesh."]
    lines += ["", "HDRIs:"] + ["  %s  -> env/%s" % (k, v) for k, v in HDRIS.items()]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    derive_only = "--derive" in sys.argv
    tex_maps = {}
    for t in BUILDING_TEXTURES:
        tex_maps[t] = fetch_texture(t, "1k")
    for t in GROUND_TEXTURES:
        tex_maps[t] = fetch_texture(t, "1k")
        tex_maps[t + "@2k"] = fetch_texture(t, "2k")
    if not derive_only:
        for m, keys in LEAF_SOURCES.items():
            fetch_leaves(m, keys)
        for m in MODELS:
            log("model", m, fetch_model(m))
    hdri_paths = {h: fetch_hdri(h) for h in HDRIS}
    derive_all({k: v for k, v in tex_maps.items() if not k.endswith("@2k")})
    copy_runtime(tex_maps, hdri_paths)
    write_license()
    total = 0
    for root, _, files in os.walk(CACHE):
        total += sum(os.path.getsize(os.path.join(root, f)) for f in files)
    log("cache size %.1f MB" % (total / 1e6))


if __name__ == "__main__":
    main()
