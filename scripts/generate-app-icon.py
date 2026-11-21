#!/usr/bin/env python3
# Copyright (C) 2026 Ardhitama
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms for the FanMac name and icon: see NOTICE.
#
"""Writes FanMac's app icon, fan/FanMac.icon, its menu bar glyph, and the
website's docs/assets/logo.png.

The mark is a four-blade pinwheel in flat facets: four tones of one hue, lit
from the top left, each stroked in its own colour to close the seams, as
glass layers over a light and a dark gradient. Each blade is one facet and one
layer, with a lighter set for the dark appearance. The menu bar glyph is the
same four blades in the template's ink at four strengths.

The script is the source: it overwrites the Icon Composer document and the
glyph, so change the constants here rather than those files. The logo is Icon
Composer's own render of the icon (ictool, from Xcode).
"""

import colorsys
import json
import math
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "fan" / "FanMac.icon"
GLYPH = ROOT / "fan" / "Assets.xcassets" / "MenuBarIcon.imageset"
LOGO = ROOT / "docs" / "assets" / "logo.png"

# The menu bar glyph's square, in points, and the pinwheel's span inside it:
# a point of clear space on each side, so the blades' edges fall on whole
# pixels at 1x and 2x.
GLYPH_SIZE = 16
GLYPH_SPAN = 14

# Blade half-width on the 1024 canvas: the pinwheel spans 2 * R.
R = 250
CENTRE = 512

# The tiles: white to #E6E8EC, and #23272E to #14161A.
BACKGROUNDS = {
    "light": ("srgb:1.00000,1.00000,1.00000,1.00000", "srgb:0.90196,0.90980,0.92549,1.00000"),
    "dark": ("srgb:0.13725,0.15294,0.18039,1.00000", "srgb:0.07843,0.08627,0.10196,1.00000"),
}

# Four tones, lightest to darkest, around hue 205°, a cool sky blue, shaded by
# the rules of a gold gem mark rather than its colours.
# - Neighbouring tones step apart in the gem's proportions, wider towards the
#   shadow; the dark appearance's set is lifted, with flatter steps.
# - Blue holds less luminance than gold before it fades to white or sinks to
#   black, so each set keeps the gem's step shape scaled to the range blue
#   allows: every step raised to one power, chosen to land on both ends.
# - The ends: the lightest keeps the gem's HSV saturation (0.46 light, 0.40
#   dark), so it stays a colour; the darkest is no darker than the gem's
#   (luminance 0.073). The blades, unlike the gem's facets, stand apart on the
#   tile, so the light set's lightest reads 1.7:1, and the dark set's darkest
#   3:1, on the tile beside it as Icon Composer renders it: #E9EAEB in the
#   blades' shadow, and #262A31 under the lighting. The glass lightens every
#   blade, so the light set's lightest renders at about 1.5:1, as it did
#   before these rules.
# - The hue drifts 9° from highlight to shadow, as the gem's gold does, with
#   the highlight towards the brighter cyan; the HSL saturations are the gem's.
HUES = (200.0, 203.5, 207.0, 209.0)
GEM_DARKEST = 0.073
SHADING = {
    # The gem's steps from the lightest down, its HSL saturations, the
    # lightest's HSV saturation, and the tile beside the weak end.
    "light": ((1.45, 1.94, 2.33), (1.00, 0.85, 0.85, 0.90), 0.46, ("lightest", "#E9EAEB", 1.7)),
    "dark": ((1.40, 1.70, 2.11), (1.00, 0.85, 0.68, 0.84), 0.40, ("darkest", "#262A31", 3.0)),
}
# The menu bar glyph's ink for each tone: full for
# the lit top left, down to half for the shadow. A dark bar tints the ink
# white, so the top left reads lightest, as on the icon; a light bar tints
# it black, and the order inverts.
GLYPH_OPACITY = (1.0, 0.8, 0.64, 0.5)


def luminance(hex_colour):
    def linear(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def hex_of(rgb):
    return "#%02X%02X%02X" % tuple(round(channel * 255) for channel in rgb)


def hsv_saturation(hex_colour):
    channels = [int(hex_colour[i:i + 2], 16) for i in (1, 3, 5)]
    return 1 - min(channels) / max(channels)


def tone(hue, saturation, target):
    """The colour of this hue and HSL saturation whose relative luminance is
    `target`, found by bisecting the lightness."""
    def at(lightness):
        return hex_of(colorsys.hls_to_rgb(hue / 360, lightness, saturation))
    low, high = 0.0, 1.0
    for _ in range(40):
        middle = (low + high) / 2
        low, high = (middle, high) if luminance(at(middle)) < target else (low, middle)
    return at((low + high) / 2)


def tones(appearance):
    """The four tones, lightest first, and a check that they keep the rules."""
    steps, saturations, palest, (end, tile, ratio) = SHADING[appearance]
    # The luminance range: as wide as the ends allow.
    lightest = luminance(hex_of(colorsys.hsv_to_rgb(HUES[0] / 360, palest, 1)))
    darkest = GEM_DARKEST
    if end == "lightest":
        lightest = min(lightest, (luminance(tile) + 0.05) / ratio - 0.05)
    else:
        darkest = max(darkest, ratio * (luminance(tile) + 0.05) - 0.05)
    span = math.log((lightest + 0.05) / (darkest + 0.05))
    power = span / sum(math.log(step) for step in steps)
    scaled = [step ** power for step in steps]
    levels = [lightest]
    for step in scaled:
        levels.append((levels[-1] + 0.05) / step - 0.05)
    colours = [tone(hue, saturation, level) for hue, saturation, level in zip(HUES, saturations, levels)]

    for (lighter, darker), step in zip(zip(colours, colours[1:]), scaled):
        assert abs(contrast(lighter, darker) - step) < 0.03, (appearance, lighter, darker, step)
    assert scaled == sorted(scaled), (appearance, scaled)
    assert hsv_saturation(colours[0]) >= palest - 0.01, (appearance, colours[0])
    assert luminance(colours[-1]) >= GEM_DARKEST - 0.002, (appearance, colours[-1])
    anchored = colours[0] if end == "lightest" else colours[-1]
    assert contrast(anchored, tile) >= ratio - 0.02, (appearance, anchored, tile, ratio)
    return colours


TONES = {appearance: tones(appearance) for appearance in SHADING}

# Blades clockwise from the top right, each with its tone: light from the top
# left makes the top-left blade the lightest and the bottom-right the darkest.
BLADE_TONES = [1, 3, 2, 0]

# Maps the 824-unit icon grid the mark is drawn on onto the 1024 canvas.
LAYER_SCALE = 1.2427


def blade(index):
    """The centre, the top edge's midpoint and the top-right corner, turned a
    quarter clockwise `index` times (SVG's y axis points down)."""
    points = [(0, 0), (0, -R), (R, -R)]
    for _ in range(index):
        points = [(-y, x) for x, y in points]
    return [(CENTRE + x, CENTRE + y) for x, y in points]


def path_data(points):
    return " ".join(f"{'M' if i == 0 else 'L'}{x:.1f} {y:.1f}" for i, (x, y) in enumerate(points)) + " Z"


def facet_svg(number, points, colour):
    label = f"FanMac facet {number}"
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024.00 1024.00" width="1024.00" height="1024.00" '
        f'role="img" aria-label="{label}"><title>{label}</title>'
        f'<path d="{path_data(points)}" fill="{colour}" stroke="{colour}" stroke-width="1.5" stroke-linejoin="round"/></svg>\n'
    )


def write_glyph():
    """The four blades in black, each at its tone's GLYPH_OPACITY, on a
    GLYPH_SIZE-point square; the asset catalog marks it a template, so the
    menu bar tints it and keeps the strengths."""
    side = 2 * R * GLYPH_SIZE / GLYPH_SPAN
    origin = CENTRE - side / 2
    blades = "".join(
        # CoreSVG ignores fill-opacity on a path without an explicit fill.
        f'<path d="{path_data(blade(index))}" fill="#000000" fill-opacity="{GLYPH_OPACITY[tone]:g}"/>'
        for index, tone in enumerate(BLADE_TONES)
    )
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{origin:g} {origin:g} {side:g} {side:g}" '
        f'width="{GLYPH_SIZE}" height="{GLYPH_SIZE}">{blades}</svg>\n'
    )
    contents = {
        "images": [{"filename": "menu-bar-icon.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }
    GLYPH.mkdir(parents=True, exist_ok=True)
    (GLYPH / "menu-bar-icon.svg").write_text(svg, encoding="utf-8")
    (GLYPH / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def gradient(top, bottom):
    return {
        "linear-gradient": [top, bottom],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    }


def layer(number):
    return {
        "glass": True,
        "image-name-specializations": [
            {"value": f"facet-{number}.svg"},
            {"appearance": "dark", "value": f"facet-{number}-dark.svg"},
        ],
        "name": f"facet-{number}",
        "position": {"scale": LAYER_SCALE, "translation-in-points": [0, 0]},
    }


def write_icon():
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for index, tone in enumerate(BLADE_TONES):
        number = index + 1
        points = blade(index)
        (assets / f"facet-{number}.svg").write_text(facet_svg(number, points, TONES["light"][tone]), encoding="utf-8")
        (assets / f"facet-{number}-dark.svg").write_text(facet_svg(number, points, TONES["dark"][tone]), encoding="utf-8")

    document = {
        "fill-specializations": [
            {"value": gradient(*BACKGROUNDS["light"])},
            {"appearance": "dark", "value": gradient(*BACKGROUNDS["dark"])},
        ],
        "groups": [
            {
                "layers": [layer(number) for number in range(1, len(BLADE_TONES) + 1)],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.3},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (ICON / "icon.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def write_logo():
    developer = subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()
    ictool = Path(developer).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    subprocess.run(
        [str(ictool), str(ICON), "--export-image", "--output-file", str(LOGO), "--platform", "macOS",
         "--rendition", "Default", "--width", "512", "--height", "512", "--scale", "1"],
        check=True, capture_output=True,
    )


if __name__ == "__main__":
    write_icon()
    write_glyph()
    write_logo()
    for path in (ICON, GLYPH, LOGO):
        print(f"Wrote {path.relative_to(ROOT)}")
