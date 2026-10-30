#!/usr/bin/env python3
"""Draws the flat app icon: a heavy italic BR whose R breaks into render tiles.

Usage: python3 make_icon.py AppIcon.icns   (needs numpy, Pillow and macOS iconutil)
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2048
FONT = ("/System/Library/Fonts/Avenir Next.ttc", 9)  # Heavy Italic
TEXT_WIDTH = 0.7
TILE = S // 32
NAVY = np.array([0.075, 0.095, 0.145])
ORANGE = np.array([1.0, 0.48, 0.1])
CYAN = np.array([0.3, 0.86, 1.0])


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def letters():
    """The BR as a coverage mask, optically centred."""
    font = ImageFont.truetype(FONT[0], 1000, index=FONT[1])
    box = font.getbbox("BR")
    font = ImageFont.truetype(FONT[0], int(1000 * TEXT_WIDTH * S / (box[2] - box[0])), index=FONT[1])
    box = font.getbbox("BR")
    image = Image.new("L", (S, S), 0)
    at = ((S - box[0] - box[2]) / 2, (S - box[1] - box[3]) / 2)
    ImageDraw.Draw(image).text(at, "BR", font=font, fill=255)
    return np.asarray(image, float) / 255


def tiles(mask):
    """Splits the right of the letters into tiles: some solid, some gone, some cyan."""
    rng = np.random.default_rng(7)
    count = S // TILE + 1
    cells = np.arange(S) // TILE
    average = np.zeros((count, count))
    np.add.at(average, (cells[:, None], cells[None, :]), mask)
    average /= TILE**2

    centre = (np.arange(count) + 0.5) * TILE / S
    cx, cy = np.meshgrid(centre, centre)
    # Tiles start to appear right of this slanted line, matching the italic.
    progress = smooth(0.0, 0.11, cx - 0.745 + (cy - 0.5) * 0.2)
    filled = average > 0.5

    lose = filled & (rng.random((count, count)) < progress * 0.45)
    glow = filled & ~lose & (rng.random((count, count)) < progress * 0.5)
    # A few tiles drift off to the right of the letters.
    drift = (average == 0) & (rng.random((count, count)) < 0.1)
    drift &= (cx > 0.815) & (cx < 0.85) & (cy > 0.3) & (cy < 0.72)

    tiled = (progress > 0)[np.ix_(cells, cells)]
    solid = (filled & ~lose)[np.ix_(cells, cells)]
    gap = np.arange(S) % TILE > TILE * 0.12
    gap = np.outer(gap, gap)
    face = np.where(tiled, solid * gap, mask)
    cyan = (glow | drift)[np.ix_(cells, cells)] & gap
    return face, cyan


def render():
    mask = letters()
    face, cyan = tiles(mask)

    out = np.ones((S, S, 3)) * NAVY
    out = out * (1 - face[..., None]) + ORANGE * face[..., None]
    return np.where(cyan[..., None], CYAN, out)


def squircle():
    """The macOS icon shape: 824 of 1024, centred, with a superellipse edge."""
    px = (np.arange(S) + 0.5) / S
    x, y = np.meshgrid(px, px)
    half = 412 / 1024
    d = (np.abs(x - 0.5) ** 5 + np.abs(y - 0.5) ** 5) ** 0.2 / half
    return 1 - smooth(1 - 0.002, 1 + 0.002, d)


def compose():
    mask = squircle()
    art = (render() * 255).astype(np.uint8)
    icon = Image.fromarray(np.dstack([art, (mask * 255).astype(np.uint8)]))

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(Image.fromarray((mask * 110).astype(np.uint8)))
    shadow = shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -24))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    return Image.alpha_composite(shadow, icon)


def main(out):
    icon = compose()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", out], check=True)
    icon.resize((1024, 1024), Image.LANCZOS).save(Path(out).with_suffix(".png"))


if __name__ == "__main__":
    main(sys.argv[1])
