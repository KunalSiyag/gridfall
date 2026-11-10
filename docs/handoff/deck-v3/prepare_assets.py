"""Deck v3 assets: GMI mascot cut-outs (from the GMI Cloud Dev Talk template PDF), QR codes, pixel-dither textures.
Run: python3 prepare_assets.py <template.pdf-extracted-dir> (dir made with `pdfimages -png`, see README). QR needs segno."""
import os, random, sys
from PIL import Image

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "img")
os.makedirs(OUT, exist_ok=True)


def cut(num, name, maxw=900):
    im = Image.open(f"{SRC}/i-{num:03d}.png").convert("RGB")
    m = Image.open(f"{SRC}/i-{num + 1:03d}.png").convert("L")
    im.putalpha(m)
    im.thumbnail((maxw, maxw))
    im.save(f"{OUT}/{name}.png", optimize=True)


for num, name in [(8, "skull_headphones"), (112, "skull_question"), (114, "skull_sunglasses"), (132, "skull_star_l"),
                  (134, "skull_star_r"), (185, "trophy"), (197, "skull_heart"), (199, "trophy_skull"),
                  (104, "ufo_skull"), (226, "skull_glow")]:
    cut(num, name)

LIME, LIME_DARK = (221, 234, 77), (176, 190, 40)


def dither(w, h, name, fg, direction="left", cell=12, seed=7):
    """Pixel-square dither fading out towards `direction` ('left' keeps the right edge dense)."""
    rnd = random.Random(seed)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for cy in range(h // cell):
        for cx in range(w // cell):
            t = cx / (w // cell - 1) if direction == "left" else cy / (h // cell - 1)
            p = (t ** 1.7) * 0.95
            p *= 0.75 + 0.25 * ((cx * 7 + cy * 13) % 5) / 4
            if rnd.random() < p:
                for dx in range(cell - 2):
                    for dy in range(cell - 2):
                        px[cx * cell + dx, cy * cell + dy] = fg + (255,)
    im.save(f"{OUT}/{name}.png", optimize=True)


dither(720, 1080, "dither_right", LIME)
dither(1920, 360, "dither_bottom_lime", LIME_DARK, direction="up")
dither(720, 1080, "dither_right_dark", LIME_DARK, seed=11)

import segno
for name, url in [("qr_gmi", "https://www.gmicloud.ai/company/ambassador-program"),
                  ("qr_factory", "https://factory.com/ambassador"),
                  ("qr_github", "https://github.com/KunalSiyag/gridfall")]:
    segno.make(url, error="m").save(f"{OUT}/{name}.png", scale=12, border=2, dark="#000000", light="#FFFFFF")
print(sorted(os.listdir(OUT)))
