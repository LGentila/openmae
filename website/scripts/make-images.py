"""Draws the website's raster images: the share images (og-fr.png, og-en.png) and the PNG icons.

    python3 website/scripts/make-images.py

Needs Pillow built with FreeType (the fonts are the app's WOFF2 files, read as they are). Everything is drawn at
twice the size, then scaled down, for smooth edges. The colors are the design tokens; the orb is the app's orb in
the thinking state's four colors, frozen.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent / "public"
FONTS = ROOT / "assets" / "fonts"

SURFACE = (0xFB, 0xF6, 0xEC)
INK = (0x1F, 0x1B, 0x16)
INK_MUTED = (0x6B, 0x65, 0x5C)
CORAL = (0xFF, 0x6A, 0x4D)
SUN = (0xFF, 0xC8, 0x3D)
TURQUOISE = (0x14, 0xBF, 0xAE)
AZURE = (0x2E, 0x93, 0xF5)

SCALE = 2  # drawn at twice the size


def font(name, size, axes):
    face = ImageFont.truetype(str(FONTS / name), size * SCALE)
    face.set_variation_by_axes(axes)
    return face


def display(size, weight):
    return font("BricolageGrotesque-latin-opsz.woff2", size, [96, weight])


def sans(size, weight):
    return font("Figtree-latin-wght.woff2", size, [weight])


def mark(draw, x, y, unit):
    """The three-disc mark (28 x 22 at unit 1), its top-left corner at x, y."""
    for cx, cy, r, color in ((8.5, 11.5, 7.5, CORAL), (17, 8.5, 6.5, SUN), (19, 14.5, 6, TURQUOISE)):
        draw.ellipse([x + (cx - r) * unit, y + (cy - r) * unit, x + (cx + r) * unit, y + (cy + r) * unit], fill=color)


def wordmark(draw, x, y, size):
    """The logotype: the mark, 10 px apart at 18 px type, then "Open" in 500 ink-muted and "Maé" in 700 ink."""
    unit = size / 18 * SCALE
    mark(draw, x, y, unit)
    tx = x + 28 * unit + 10 * unit
    regular, bold = display(size, 500), display(size, 700)
    baseline = y + 11 * unit + 0.36 * size * SCALE  # the capitals centered on the mark
    draw.text((tx, baseline), "Open", font=regular, fill=INK_MUTED, anchor="ls")
    tx += draw.textlength("Open", font=regular)
    draw.text((tx, baseline), "Maé", font=bold, fill=INK, anchor="ls")


def orb(size):
    """The orb (scene of 380 drawn `size` px wide) in the thinking colors, centered on a transparent square half as
    large again, so that its halos fit."""
    k = size / 380
    canvas = int(size * 1.5)
    layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    center = canvas / 2

    halos = ImageDraw.Draw(layer)
    for diameter, alpha in ((800, 77), (560, 140)):
        d = diameter * k * 0.62
        halos.ellipse([center - d / 2, center - d / 2, center + d / 2, center + d / 2], fill=(255, 255, 255, alpha))

    floor = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    ImageDraw.Draw(floor).ellipse(
        [center - 100 * k, center + 158 * k, center + 100 * k, center + 186 * k], fill=SUN + (102,)
    )
    layer.alpha_composite(floor.filter(ImageFilter.GaussianBlur(18 * k)))

    radius = 40 * k  # between rest (28) and thinking (80), so that the four colors show
    arms = ((0, 1, CORAL), (90, 0.8, SUN), (180, 1.15, TURQUOISE), (270, 0.92, AZURE))
    turn = -24
    for angle, rk, color in arms:
        blob = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        a = math.radians(angle + turn)
        bx, by = center + math.cos(a) * radius * rk, center + math.sin(a) * radius * rk
        w, h = 214 * k, 200 * k
        ImageDraw.Draw(blob).ellipse([bx - w / 2, by - h / 2, bx + w / 2, by + h / 2], fill=color + (255,))
        layer.alpha_composite(blob.rotate(angle * 0.3 + 12, center=(bx, by), resample=Image.BICUBIC))

    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [center - 70 * k, center - 70 * k + 14 * k, center + 70 * k, center + 70 * k + 14 * k], fill=INK + (36,)
    )
    layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(17 * k)))
    core = ImageDraw.Draw(layer)
    core.ellipse([center - 70 * k, center - 70 * k, center + 70 * k, center + 70 * k], fill=(255, 255, 255, 255))
    for i, height in enumerate((16, 30, 40, 26, 14)):
        x = center + (i - 2) * 18 * k
        core.rounded_rectangle(
            [x - 5 * k, center - height / 2 * k, x + 5 * k, center + height / 2 * k], radius=5 * k, fill=INK + (255,)
        )
    return layer


def share_image(path, title_lines, sub_lines):
    width, height = 1200 * SCALE, 630 * SCALE
    image = Image.new("RGBA", (width, height), SURFACE + (255,))
    layer = orb(540 * SCALE)
    image.paste(layer, (int(925 * SCALE - layer.width / 2), int(318 * SCALE - layer.height / 2)), layer)
    draw = ImageDraw.Draw(image)
    wordmark(draw, 72 * SCALE, 64 * SCALE, 30)
    size = 70  # smaller when a line would run into the orb
    title = display(size, 700)
    while max(draw.textlength(line, font=title) for line in title_lines) > 590 * SCALE:
        size -= 1
        title = display(size, 700)
    y = 222 * SCALE
    for line in title_lines:
        draw.text((72 * SCALE, y), line, font=title, fill=INK, anchor="ls")
        y += 74 * SCALE
    sub = sans(29, 450)
    y += 26 * SCALE
    for line in sub_lines:
        draw.text((72 * SCALE, y), line, font=sub, fill=INK_MUTED, anchor="ls")
        y += 42 * SCALE
    image.convert("RGB").resize((1200, 630), Image.LANCZOS).save(path, optimize=True)


def icon(path, size, background):
    big = size * 4
    image = Image.new("RGBA", (big, big), (SURFACE + (255,)) if background else (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    unit = big * (0.62 if background else 0.86) / 24  # the mark spans 24 x 18.5 units
    mark(draw, (big - 24 * unit) / 2 - 1 * unit, (big - 18.5 * unit) / 2 - 2 * unit, unit)
    image.resize((size, size), Image.LANCZOS).save(path, optimize=True)


if __name__ == "__main__":
    share_image(
        ROOT / "assets" / "og-fr.png",
        ["L’assistant vocal", "qui vit sur ton Mac."],
        ["Tu parles, Maé te répond à voix haute.", "Tout tourne sur ton Mac."],
    )
    share_image(
        ROOT / "assets" / "og-en.png",
        ["The voice assistant", "that lives on your Mac."],
        ["You talk, Maé answers out loud.", "Everything runs on your Mac."],
    )
    icon(ROOT / "favicon-32.png", 32, background=False)
    icon(ROOT / "apple-touch-icon.png", 180, background=True)
    print("written: og-fr.png, og-en.png, favicon-32.png, apple-touch-icon.png")
