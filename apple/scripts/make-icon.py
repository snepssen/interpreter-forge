"""Draw the app icon: speech in, English out.

    python3 apple/scripts/make-icon.py

Faint white arcs arrive from the left, the speech in a language you don't
have; a glowing point in the middle is the interpreter; the arcs leaving on
the right are the English, in the project's cyan (--eco-interpreter in the
workshop's ecosystem.css). The ground and the glow follow Gateway Forge's
icon, so the two sit together in a dock.

Writes the iPhone's single 1024 px icon (full bleed: iOS applies the mask),
the Mac's AppIcon.icns (the rounded square drawn in, on Apple's 824 px grid),
and docs/icon.png for the project page. Needs Pillow; iconutil is macOS's.
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
CYAN = (79, 208, 240)
WHITE = (236, 240, 246)
TOP, BOTTOM = (10, 14, 21), (20, 27, 39)  # Gateway Forge's ground
SCALE = 4  # draw large, then shrink: smooth edges without an SVG renderer


def ground(size):
    image = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        draw.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    return image


def glyph(size):
    """The arcs and the point, on transparency, centred in a square of `size`."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    c = size / 2
    unit = size / 1024

    # The glow first, so everything else sits on it.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([c - 230 * unit, c - 230 * unit, c + 230 * unit, c + 230 * unit],
                                 fill=CYAN + (120,))
    layer.alpha_composite(glow.filter(ImageFilter.GaussianBlur(120 * unit)))

    draw = ImageDraw.Draw(layer)
    width = round(30 * unit)
    # One wave, travelling left to right: it arrives as plain wavefronts and
    # leaves the point as English. Both sides curve the same way, or it reads
    # as a broadcast symbol rather than something passing through.
    for i, (apex, alpha) in enumerate(zip((190, 270, 350), (210, 140, 80))):
        r = 300 * unit  # arriving fronts: parallel, from somewhere further left
        x = c - apex * unit - r
        draw.arc([x - r, c - r, x + r, c + r], -30, 30, fill=WHITE + (alpha,), width=width)
    for i, radius in enumerate((190, 270, 350)):
        r = radius * unit  # leaving fronts: spreading from the point
        spread = 36 - i * 5
        draw.arc([c - r, c - r, c + r, c + r], -spread, spread, fill=CYAN + ((255, 200, 130)[i],), width=width)
    r = 92 * unit
    draw.ellipse([c - r, c - r, c + r, c + r], fill=CYAN + (255,))
    r = 26 * unit
    draw.ellipse([c - r, c - r, c + r, c + r], fill=TOP + (255,))  # the listener's ear, as Gateway's dot
    return layer


def phone_icon():
    size = 1024 * SCALE
    image = ground(size)
    image.alpha_composite(glyph(size))
    return image.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def mac_icon():
    """Apple's macOS grid: an 824 px rounded square, radius 185, in 1024."""
    size = 1024 * SCALE
    inset, side, radius = 100 * SCALE, 824 * SCALE, 185 * SCALE
    tile = ground(side)
    tile.alpha_composite(glyph(side).resize((side, side), Image.LANCZOS))
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side - 1, side - 1], radius=radius, fill=255)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    image.paste(tile, (inset, inset), mask)
    return image.resize((1024, 1024), Image.LANCZOS)


def main():
    phone = phone_icon()
    catalog = ROOT / "apple/iOS/App/Assets.xcassets"
    icons = catalog / "AppIcon.appiconset"
    icons.mkdir(parents=True, exist_ok=True)
    phone.save(icons / "icon-1024.png")
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (icons / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    mac = mac_icon()
    with tempfile.TemporaryDirectory() as scratch:
        iconset = Path(scratch) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for factor in (1, 2):
                pixels = points * factor
                name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
                mac.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
        target = ROOT / "apple/Resources/AppIcon.icns"
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(target)], check=True)

    docs = ROOT / "docs"
    mac.resize((512, 512), Image.LANCZOS).save(docs / "icon.png")
    shutil.copy(icons / "icon-1024.png", Path(tempfile.gettempdir()) / "interpreter-icon-preview.png")
    print("wrote", icons / "icon-1024.png", ROOT / "apple/Resources/AppIcon.icns", docs / "icon.png")


if __name__ == "__main__":
    main()
