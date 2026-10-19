#!/usr/bin/env python3
"""Street-level textures for slice G1: road-wear decals and the site hoarding.

Writes PNGs next to this file: crack_0/1, patch_0, oil_0/1, drain_0, stain_0, puddle_0, the puddle
ORM map, hoarding.png (a greyscale painted-plywood hoarding, 4.8 m square, four 1.2 m panels,
tinted per site), grime_mask/grime_dust, hedge_leaves.png (a tiling clipped-hedge surface, 1 m
square, stamped from the shrub leaf cluster), grate.png (a 1.3 m cast-iron tree grate with slots,
alpha 0 in the slots), tactile.png (0.4 m of buff blister paving for the kerb ramps) and
noise_fbm.png (a tiling, equalised fbm for the asphalt and iron shaders). Deterministic (fixed
seeds); needs numpy and Pillow. Name textures to rebuild only those (hoarding, grime, hedge, grate,
tactile, noise).

    python3 textures/real/decals/make_decals.py [name ...]
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
N = 512


def value_noise(rng, size, cells):
    """Smooth value noise in [0, 1]: a random grid upsampled bicubically."""
    g = rng.random((cells + 1, cells + 1)).astype(np.float32)
    im = Image.fromarray((g * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
    return np.asarray(im, dtype=np.float32) / 255.0


def fbm(rng, size, base=4, octaves=4):
    acc = np.zeros((size, size), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        acc += value_noise(rng, size, base * 2 ** o) * amp
        tot += amp
        amp *= 0.5
    return acc / tot


def save(name, rgb, alpha):
    a = np.clip(alpha, 0, 255).astype(np.uint8)
    c = np.clip(rgb, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([c, a]), "RGBA").save(os.path.join(OUT, name + ".png"), optimize=True)


def cracks(seed):
    rng = np.random.default_rng(seed)
    s = 4
    im = Image.new("L", (N * s, N * s), 0)
    d = ImageDraw.Draw(im)

    def walk(x, y, ang, length, width, depth):
        pts = [(x, y)]
        for _ in range(int(length)):
            ang += rng.normal(0.0, 0.32)
            x += math.cos(ang) * 9 * s
            y += math.sin(ang) * 9 * s
            pts.append((x, y))
            if depth < 3 and rng.random() < 0.06:
                walk(x, y, ang + rng.choice([-1, 1]) * rng.uniform(0.6, 1.3), length * 0.45, max(1, width * 0.6), depth + 1)
        d.line(pts, fill=255, width=int(width * s), joint="curve")

    for _ in range(3):
        a = rng.uniform(0, math.tau)
        walk(N * s / 2 + rng.normal(0, 40 * s), N * s / 2 + rng.normal(0, 40 * s), a, rng.uniform(18, 30), rng.uniform(2.0, 3.2), 0)
    m = np.asarray(im.resize((N, N), Image.LANCZOS), np.float32)
    # Fade toward the decal's edges so the box never shows.
    yy, xx = np.mgrid[0:N, 0:N] / (N - 1.0)
    edge = np.clip(np.minimum(np.minimum(xx, 1 - xx), np.minimum(yy, 1 - yy)) / 0.12, 0, 1)
    halo = np.asarray(Image.fromarray(m.astype(np.uint8)).filter(ImageFilter.GaussianBlur(3)), np.float32)
    alpha = np.maximum(m * 0.95, halo * 0.35) * edge
    shade = 18 + 10 * fbm(rng, N, 8, 3)
    return np.dstack([shade, shade, shade * 1.05]), alpha


def patch(seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:N, 0:N] / (N - 1.0)
    n = fbm(rng, N, 6, 4)
    # A rounded rectangle with a ragged outline.
    dx = np.abs(xx - 0.5) - 0.36 + (n - 0.5) * 0.06
    dy = np.abs(yy - 0.5) - 0.34 + (n - 0.5) * 0.06
    dist = np.maximum(dx, dy)
    inside = np.clip(-dist / 0.01, 0, 1)
    seam = np.clip(1 - np.abs(dist) / 0.012, 0, 1)
    grain = fbm(rng, N, 64, 2)
    base = 46 + 18 * grain + 10 * n
    rgb = np.dstack([base, base, base * 1.03])
    rgb = rgb * (1 - seam[..., None]) + 14 * seam[..., None]
    alpha = np.maximum(inside * 225, seam * 240)
    return rgb, alpha


def oil(seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:N, 0:N] / (N - 1.0) - 0.5
    r = np.sqrt(xx * xx + yy * yy)
    n = fbm(rng, N, 5, 4)
    blob = np.clip(1 - (r + (n - 0.5) * 0.28) / 0.42, 0, 1) ** 0.8
    drips = (fbm(rng, N, 24, 2) > 0.62) * np.clip(1 - r / 0.48, 0, 1)
    alpha = np.clip(blob * 170 + drips * 60, 0, 200)
    shade = 18 + 12 * n
    return np.dstack([shade * 1.05, shade, shade * 0.95]), alpha


def drain(seed):
    rng = np.random.default_rng(seed)
    w, h = 256, 512
    rgb = np.zeros((h, w, 3), np.float32)
    alpha = np.zeros((h, w), np.float32)
    frame = 20
    n = fbm(rng, max(w, h), 16, 3)[:h, :w]
    metal = 58 + 30 * n
    rgb[:] = np.dstack([metal * 1.04, metal * 0.97, metal * 0.9])
    alpha[:] = 255
    slots = 9
    for k in range(slots):
        y0 = frame + 8 + k * ((h - 2 * frame - 8) // slots)
        rgb[y0:y0 + 26, frame + 14:w - frame - 14] = 8
    rust = (fbm(rng, max(w, h), 10, 3)[:h, :w] > 0.6)[..., None]
    rgb = rgb * (1 - rust * 0.25) + rust * np.array([70, 40, 22]) * 0.25
    img = np.dstack([rgb, alpha])
    return img


def stain(seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:N, 0:N] / (N - 1.0) - 0.5
    r = np.sqrt(xx * xx + yy * yy)
    grime = np.clip(fbm(rng, N, 6, 4) - 0.45, 0, 1) * 110 * np.clip(1 - r / 0.5, 0, 1)
    im = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(im)
    for _ in range(int(rng.integers(14, 26))):
        cx, cy = rng.uniform(60, N - 60, 2)
        rad = rng.uniform(3, 9)
        d.ellipse((cx - rad, cy - rad * rng.uniform(0.7, 1.0), cx + rad, cy + rad), fill=int(rng.uniform(150, 210)))
    spots = np.asarray(im.filter(ImageFilter.GaussianBlur(1)), np.float32)
    alpha = np.maximum(grime, spots)
    shade = 34 + 8 * fbm(rng, N, 12, 2)
    return np.dstack([shade * 1.05, shade, shade * 0.92]), alpha


def puddle(seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:N, 0:N] / (N - 1.0) - 0.5
    r = np.sqrt((xx * 1.0) ** 2 + (yy * 1.3) ** 2)
    n = fbm(rng, N, 4, 4)
    m = np.clip((0.4 - (r + (n - 0.5) * 0.35)) / 0.05, 0, 1)
    alpha = m * 175
    shade = 26 + 6 * n
    return np.dstack([shade * 0.95, shade, shade * 1.1]), alpha


def hoarding(seed):
    """Painted plywood panels; content is uniform vertically so any vertical mapping works."""
    rng = np.random.default_rng(seed)
    n = 1024
    xx = np.arange(n)[None, :].repeat(n, 0)
    grain = value_noise(rng, n, 160) * 0.5 + value_noise(rng, n, 40) * 0.5
    streak = np.asarray(Image.fromarray((rng.random((8, n)) * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC), np.float32) / 255.0
    base = 0.74 + 0.08 * (grain - 0.5) + 0.06 * (streak - 0.5)
    panel = (xx // (n // 4)).astype(np.int32)
    base *= np.array([1.0, 0.95, 1.03, 0.97])[panel]
    joint = np.minimum(xx % (n // 4), (n // 4) - xx % (n // 4))
    base *= np.where(joint < 3, 0.45, np.where(joint < 6, 0.8, 1.0))
    # Screw heads along the panel edges.
    yy = np.arange(n)[:, None].repeat(n, 1)
    screws = ((joint > 10) & (joint < 15) & (yy % 128 < 5)).astype(np.float32)
    base = base * (1 - screws * 0.35)
    g = np.clip(base * 255, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([g, g, g]), "RGB").save(os.path.join(OUT, "hoarding.png"), optimize=True)


def grime(seed):
    """A tiling dust mask (white = dusty) and the dust colour it blends in, for site machines."""
    rng = np.random.default_rng(seed)
    n = 256
    big = fbm(rng, n * 2, 4, 5)
    # Make it tile: blend the image with its half-shifted copy across the seams.
    m = big[:n, :n]
    w = np.minimum(np.arange(n), n - 1 - np.arange(n)) / (n / 2.0)
    w = np.clip(w * 2.0, 0, 1)
    ww = np.minimum(w[None, :], w[:, None])
    shifted = np.roll(np.roll(m, n // 2, 0), n // 2, 1)
    m = m * ww + shifted * (1 - ww)
    mask = np.clip((m - 0.45) * 3.0, 0, 1) ** 1.5 * 0.85
    g = (mask * 255).astype(np.uint8)
    Image.fromarray(g, "L").save(os.path.join(OUT, "grime_mask.png"), optimize=True)
    d = fbm(rng, 64, 8, 2)
    rgb = np.dstack([0.40 + 0.08 * d, 0.34 + 0.07 * d, 0.27 + 0.05 * d]) * 255
    Image.fromarray(rgb.astype(np.uint8), "RGB").save(os.path.join(OUT, "grime_dust.png"), optimize=True)


def hedge(seed):
    """A clipped hedge surface: shrub leaf clusters stamped densely over shade, tiling both ways."""
    rng = np.random.default_rng(seed)
    n = 512
    src = os.path.join(OUT, "..", "..", "..", "models", "real", "props", "tree_hedge_leafcluster_shrub.png")
    leaf = Image.open(src).convert("RGBA")
    # Stamps go on a transparent 2n canvas; its quadrants fold back onto the tile so it wraps.
    layer = Image.new("RGBA", (n * 2, n * 2), (0, 0, 0, 0))
    count = 320
    for k in range(count):
        size = int(rng.uniform(70, 130))
        stamp = leaf.resize((size, size), Image.LANCZOS).rotate(rng.uniform(0, 360), Image.BICUBIC)
        # Later (outer) stamps are brighter: leaves on the clipped face catch the light.
        arr = np.asarray(stamp, np.float32)
        arr[..., :3] *= (0.5 + 0.6 * k / count) * rng.uniform(0.85, 1.1)
        stamp = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
        layer.alpha_composite(stamp, (int(rng.uniform(0, n)), int(rng.uniform(0, n))))
    shade = fbm(rng, n, 8, 3)
    tile = Image.fromarray(np.dstack([10 + 10 * shade, 22 + 16 * shade, 8 + 8 * shade, np.full((n, n), 255.0)]).astype(np.uint8), "RGBA")
    for ox, oy in ((0, 0), (n, 0), (0, n), (n, n)):
        tile.alpha_composite(layer.crop((ox, oy, ox + n, oy + n)))
    Image.fromarray(np.asarray(tile.convert("RGB"), np.uint8), "RGB").save(os.path.join(OUT, "hedge_leaves.png"), optimize=True)


def grate(seed):
    """A square cast-iron tree grate, 1.3 m: rings of radial slots round a 0.76 m trunk opening."""
    rng = np.random.default_rng(seed)
    n = 512
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n - 0.5
    r = np.sqrt(xx * xx + yy * yy) * 1.3     # metres from the centre
    ang = np.arctan2(yy, xx)
    border = np.maximum(np.abs(xx), np.abs(yy)) * 1.3
    solid = np.ones((n, n), bool)
    solid &= r > 0.38                        # trunk opening
    # Three rings of slots, more slots on the outer rings, solid spokes between.
    for r0, r1, k in ((0.42, 0.5, 18), (0.53, 0.59, 24), (0.62, 0.69, 30)):
        ring = (r > r0) & (r < r1)
        spoke = np.abs(((ang / (2 * math.pi) * k) % 1.0) - 0.5) < 0.32
        solid &= ~(ring & spoke)
    solid |= border > 0.62                   # frame
    alpha = solid.astype(np.float32) * 255
    n2 = fbm(rng, n, 10, 3)
    iron = 44 + 22 * n2
    rust = np.clip((fbm(rng, n, 16, 3) - 0.58) * 3, 0, 1) * 0.6
    edge = np.clip(1 - np.abs(border - 0.62) / 0.012, 0, 1)
    rgb = np.dstack([iron + rust * 34, iron + rust * 14, iron - rust * 6]) * (1 - 0.25 * edge[..., None])
    save("grate", rgb, alpha)


def noise(seed):
    """A seamlessly tiling fbm (periodic value noise, five octaves), equalised so its values spread
    evenly over 0..1, for shaders that need a smooth noise field: the street asphalt's wear and
    variation, the cast-iron covers."""
    rng = np.random.default_rng(seed)
    n = 256
    t = (np.arange(n) + 0.5) / n
    acc = np.zeros((n, n), np.float32)
    amp = 1.0
    for o in range(5):
        c = 4 * 2 ** o
        g = rng.random((c, c)).astype(np.float32)
        u = t * c
        i0 = np.floor(u).astype(int) % c
        i1 = (i0 + 1) % c
        f = u - np.floor(u)
        f = f * f * (3.0 - 2.0 * f)
        a = g[i0[:, None], i0[None, :]]
        b = g[i0[:, None], i1[None, :]]
        cc = g[i1[:, None], i0[None, :]]
        d = g[i1[:, None], i1[None, :]]
        fx = f[None, :]
        fy = f[:, None]
        acc += amp * ((a * (1 - fx) + b * fx) * (1 - fy) + (cc * (1 - fx) + d * fx) * fy)
        amp *= 0.5
    # Equalise (a monotonic rank remap keeps it smooth): values spread evenly over 0..1.
    m = np.argsort(np.argsort(acc, axis=None)).reshape(acc.shape) / float(acc.size - 1)
    Image.fromarray((m * 255).astype(np.uint8), "L").save(os.path.join(OUT, "noise_fbm.png"), optimize=True)


def tactile(seed):
    """Buff blister paving at a kerb ramp, 0.4 m square and tiling: a 6 x 6 grid of 25 mm domes at
    66.7 mm, lit from the upper left, with light grime."""
    rng = np.random.default_rng(seed)
    n = 256
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n
    cell = 6.0
    fx = (xx * cell) % 1.0 - 0.5
    fy = (yy * cell) % 1.0 - 0.5
    rr = np.sqrt(fx * fx + fy * fy) / (0.0125 / (0.4 / cell))   # 1 at the dome's rim
    dome = np.clip(1.0 - rr, 0.0, 1.0)
    # Dome shading: the slope toward the light brightens, away from it darkens; a soft rim shadow.
    lit = np.where(rr < 1.0, (-fx - fy) / 0.5 * 0.35 * (1.0 - dome * 0.4), 0.0)
    rim = np.clip(1.0 - np.abs(rr - 1.05) / 0.12, 0.0, 1.0) * 0.18
    g = rng.random((9, 9)).astype(np.float32)
    g[-1, :] = g[0, :]
    g[:, -1] = g[:, 0]
    grime = np.asarray(Image.fromarray((g * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC), np.float32) / 255.0
    shade = (1.0 + lit - rim) * (0.93 + 0.07 * grime)
    base = np.array([200.0, 163.0, 98.0])
    rgb = base[None, None, :] * shade[..., None]
    save("tactile", rgb, np.full((n, n), 255.0))


def main():
    import sys
    want = set(sys.argv[1:])
    if want:
        for name in want:
            {"hoarding": lambda: hoarding(71), "grime": lambda: grime(81), "hedge": lambda: hedge(91), "grate": lambda: grate(101), "tactile": lambda: tactile(111), "noise": lambda: noise(121)}[name]()
        return
    for k in range(2):
        save("crack_%d" % k, *cracks(11 + k))
        save("oil_%d" % k, *oil(31 + k))
    save("patch_0", *patch(21))
    img = drain(41)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, "drain_0.png"), optimize=True)
    save("stain_0", *stain(51))
    save("puddle_0", *puddle(61))
    # ORM for puddles: full AO, near-mirror roughness, no metal.
    Image.fromarray(np.full((16, 16, 3), (255, 12, 0), np.uint8), "RGB").save(os.path.join(OUT, "puddle_orm.png"))
    hoarding(71)
    grime(81)
    hedge(91)
    grate(101)
    tactile(111)
    noise(121)


if __name__ == "__main__":
    main()
