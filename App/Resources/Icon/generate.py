#!/usr/bin/env python3
"""Generates Constellation's app icon as an Icon Composer document.

Two cards from a pile, the front one with a constellation etched into it and
one amber "needs you" star glowing. Each depth is its own layer so macOS can
apply Liquid Glass and build the dark, clear and tinted variants itself.

Run from anywhere:  python3 App/Resources/Icon/generate.py
It rewrites App/Resources/Icon/AppIcon.icon (icon.json + Assets/*.svg).
Preview with Icon Composer, or:
  ictool AppIcon.icon --export-image --output-file out.png --platform macOS \
    --rendition Default --width 1024 --height 1024 --scale 1
"""
import json
import math
import pathlib

from PIL import Image  # pip install pillow

HERE = pathlib.Path(__file__).resolve().parent
ICON = HERE / "AppIcon.icon"

# The artwork lives on Icon Composer's 1024pt canvas; the system masks it to
# the macOS squircle, insets it on the icon grid and adds the drop shadow.
SIZE = 1024

CREAM = "#EFE9DE"
AMBER = "#E5A94F"
AMBER_CORE = "#FFE2A8"

# Both cards share a size, like the cards on the desk; the back one is turned
# the other way so the pair reads as a slightly untidy pile.
CARD_W, CARD_H, CARD_R = 600, 640, 112
BACK = dict(cx=566, cy=532, rot=9)
FRONT = dict(cx=494, cy=516, rot=-6)

# The constellation, in the front card's own coordinates (origin at its
# centre). A lopsided four-star bowl with a handle of one more star reaching
# up to the amber one, the way linked work hangs together on the desk.
STARS = [(-200, 150), (-118, -22), (40, 36), (-22, 206), (92, -74)]
AMBER_STAR = (164, -196)
LINKS = [(0, 1), (1, 2), (2, 3), (3, 0), (2, 4)]
# Faint pinpricks so the card reads as a patch of night sky at large sizes.
DUST = [(-196, -214, 5), (-24, -150, 4), (196, 92, 5), (-130, 64, 3.5), (118, 236, 4), (-226, 30, 3)]


def svg(body, defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">'
        f"<defs>{defs}</defs>{body}</svg>\n"
    )


def card_transform(c):
    return f'translate({c["cx"]} {c["cy"]}) rotate({c["rot"]})'


def card_rect(fill, inset=0, extra=""):
    w, h, r = CARD_W - 2 * inset, CARD_H - 2 * inset, CARD_R - inset
    return f'<rect x="{-w / 2}" y="{-h / 2}" width="{w}" height="{h}" rx="{r}" fill="{fill}" {extra}/>'


def dusk():
    """The wallpaper's pink and purple sunset, rising from the bottom edge."""
    defs = (
        '<radialGradient id="dusk" cx="512" cy="1120" r="760" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="#D0729A" stop-opacity="0.85"/>'
        '<stop offset="0.42" stop-color="#7A4F93" stop-opacity="0.45"/>'
        '<stop offset="1" stop-color="#4A3560" stop-opacity="0"/>'
        "</radialGradient>"
    )
    return svg(f'<rect width="{SIZE}" height="{SIZE}" fill="url(#dusk)"/>', defs)


def card(c, top, bottom, edge, edge_opacity):
    defs = (
        f'<linearGradient id="face" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>'
    )
    body = (
        f'<g transform="{card_transform(c)}">'
        + card_rect("url(#face)")
        + card_rect("none", 2, f'stroke="{edge}" stroke-opacity="{edge_opacity}" stroke-width="4"')
        + "</g>"
    )
    return svg(body, defs)


def constellation():
    links = "".join(
        f'<line x1="{STARS[a][0]}" y1="{STARS[a][1]}" x2="{STARS[b][0]}" y2="{STARS[b][1]}"/>' for a, b in LINKS
    )
    handle = f'<line x1="{STARS[4][0]}" y1="{STARS[4][1]}" x2="{AMBER_STAR[0]}" y2="{AMBER_STAR[1]}"/>'
    dust = "".join(f'<circle cx="{x}" cy="{y}" r="{r}"/>' for x, y, r in DUST)
    stars = "".join(f'<circle cx="{x}" cy="{y}" r="20"/>' for x, y in STARS)
    body = (
        f'<g transform="{card_transform(FRONT)}">'
        f'<g fill="{CREAM}" fill-opacity="0.32">{dust}</g>'
        f'<g stroke="{CREAM}" stroke-opacity="0.42" stroke-width="9" stroke-linecap="round">{links}{handle}</g>'
        f'<g fill="{CREAM}">{stars}</g>'
        "</g>"
    )
    return svg(body)


def canvas_point(c, p):
    a = math.radians(c["rot"])
    x, y = p
    return c["cx"] + x * math.cos(a) - y * math.sin(a), c["cy"] + x * math.sin(a) + y * math.cos(a)


def halo():
    """The amber star's glow, spilling past the card. A raster layer, because
    Icon Composer's SVG renderer bands soft radial gradients."""
    cx, cy = canvas_point(FRONT, AMBER_STAR)
    r, g, b = (int(AMBER[i : i + 2], 16) for i in (1, 3, 5))
    radius = 300
    img = Image.new("RGBA", (SIZE, SIZE), (r, g, b, 0))
    px = img.load()
    for y in range(int(cy - radius), int(cy + radius) + 1):
        for x in range(int(cx - radius), int(cx + radius) + 1):
            d = math.hypot(x + 0.5 - cx, y + 0.5 - cy) / radius
            if d < 1:
                px[x, y] = (r, g, b, round(255 * 0.9 * math.exp(-3.4 * d * d) * (1 - d * d)))
    return img


def beacon():
    """The amber star's hot core."""
    x, y = AMBER_STAR
    body = (
        f'<g transform="{card_transform(FRONT)}">'
        f'<circle cx="{x}" cy="{y}" r="36" fill="{AMBER_CORE}"/>'
        "</g>"
    )
    return svg(body)


def srgb(hex_colour, alpha=1.0):
    r, g, b = (int(hex_colour[i : i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def layer(name, ext="svg", **extra):
    return {"image-name": f"{name}.{ext}", "name": name, **extra}


def document():
    return {
        "fill": {
            "linear-gradient": [srgb("#2D2823"), srgb("#100F0E")],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
        },
        # Icon Composer lists groups front to back.
        "groups": [
            {
                "name": "Beacon",
                "layers": [layer("beacon", glass=False), layer("halo", "png", glass=False)],
                "shadow": {"kind": "none", "opacity": 0},
                "translucency": {"enabled": False, "value": 0},
                "specular": False,
            },
            {
                "name": "Front card",
                "layers": [layer("constellation", glass=False), layer("front-card")],
                "shadow": {"kind": "neutral", "opacity": 0.6},
                "translucency": {"enabled": True, "value": 0.25},
            },
            {
                "name": "Back card",
                "layers": [layer("back-card")],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.35},
            },
            {
                "name": "Dusk",
                "layers": [layer("dusk", glass=False)],
                "shadow": {"kind": "none", "opacity": 0},
                "translucency": {"enabled": False, "value": 0},
                "specular": False,
            },
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def main():
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.iterdir():
        old.unlink()
    halo().save(assets / "halo.png")
    files = {
        "dusk": dusk(),
        "back-card": card(BACK, "#2E2A25", "#1A1815", CREAM, 0.14),
        "front-card": card(FRONT, "#3B352E", "#221F1B", CREAM, 0.26),
        "constellation": constellation(),
        "beacon": beacon(),
    }
    for name, text in files.items():
        (assets / f"{name}.svg").write_text(text)
    (ICON / "icon.json").write_text(json.dumps(document(), indent=2) + "\n")


if __name__ == "__main__":
    main()
