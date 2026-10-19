#!/usr/bin/env python3
"""Street-level textures for slice G1: road-wear decals and the site hoarding.

Writes PNGs next to this file: crack_0/1, patch_0, oil_0/1, drain_0, stain_0, puddle_0, the puddle
ORM map, and hoarding.png (a greyscale painted-plywood hoarding, 4.8 m square, four 1.2 m panels,
tinted per site). Deterministic (fixed seeds); needs numpy and Pillow.

    python3 textures/real/decals/make_decals.py
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


def main():
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


if __name__ == "__main__":
    main()
