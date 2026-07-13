#!/usr/bin/env python3
"""Generate the Stream Deck plugin's PNG icons.

Produces, for every action, a monochrome list icon (20x20 / 40x40) plus a full
key image (72x72 / 144x144) with a glyph and short label, and the plugin /
category badges (28x28 / 56x56). No external tools required beyond Pillow
(`pip install pillow`).

Run:  python3 streamdeck-plugin/generate-icons.py
"""

import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(HERE, "com.unifiprotectviewer.sdPlugin", "icons")
os.makedirs(ICONS, exist_ok=True)

ACCENT = (26, 109, 255, 255)      # UniFi-ish blue
PTZ_ACCENT = (255, 159, 10, 255)  # amber for PTZ actions
KEY_BG = (28, 28, 30, 255)        # near-black rounded key background
WHITE = (255, 255, 255, 255)
SS = 4  # supersample factor for crisp edges


def _font(px):
    for name in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ):
        if os.path.exists(name):
            return ImageFont.truetype(name, px)
    return ImageFont.load_default()


def _centered_text(d, cx, y, text, font, fill):
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    d.text((cx - (r - l) / 2 - l, y), text, font=font, fill=fill)


def _save(img, name, size):
    img.resize((size, size), Image.LANCZOS).save(os.path.join(ICONS, f"{name}.png"))


def _canvas(size):
    return Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))


# ---- glyph primitives (draw at supersampled scale into a WxW box at x,y) ----

def g_grid(d, x, y, w, color, thick):
    """A 2x2 grid of rounded squares (view / grid)."""
    gap = w * 0.12
    cell = (w - gap) / 2
    for r in range(2):
        for c in range(2):
            cx = x + c * (cell + gap)
            cy = y + r * (cell + gap)
            d.rounded_rectangle([cx, cy, cx + cell, cy + cell], radius=cell * 0.22,
                                outline=color, width=thick)


def g_chevron(d, x, y, w, color, thick, right=True):
    h = w
    if right:
        pts = [(x + w * 0.32, y + h * 0.12), (x + w * 0.72, y + h * 0.5), (x + w * 0.32, y + h * 0.88)]
    else:
        pts = [(x + w * 0.68, y + h * 0.12), (x + w * 0.28, y + h * 0.5), (x + w * 0.68, y + h * 0.88)]
    d.line(pts, fill=color, width=thick, joint="curve")


def g_expand(d, x, y, w, color, thick, inward=False):
    """Four corner arrows pointing out (fullscreen) or in (exit)."""
    h = w
    corners = [(0, 0, 1, 1), (1, 0, -1, 1), (0, 1, 1, -1), (1, 1, -1, -1)]
    a = 0.10 * w
    b = 0.42 * w
    for (fx, fy, sx, sy) in corners:
        ox = x + fx * w
        oy = y + fy * h
        p_out = (ox + sx * a, oy + sy * a)
        p_in = (ox + sx * b, oy + sy * b)
        (p1, p2) = (p_in, p_out) if inward else (p_out, p_in)
        d.line([p1, p2], fill=color, width=thick)
        # arrow head at p1
        hx, hy = p1
        head = 0.16 * w
        d.line([(hx, hy), (hx + (-sx if not inward else sx) * head, hy)], fill=color, width=thick)
        d.line([(hx, hy), (hx, hy + (-sy if not inward else sy) * head)], fill=color, width=thick)


def g_house(d, x, y, w, color, thick):
    h = w
    roof = [(x + w * 0.5, y + h * 0.1), (x + w * 0.1, y + h * 0.48), (x + w * 0.9, y + h * 0.48)]
    d.line(roof + [roof[0]], fill=color, width=thick, joint="curve")
    d.rounded_rectangle([x + w * 0.22, y + h * 0.45, x + w * 0.78, y + h * 0.9],
                        radius=w * 0.05, outline=color, width=thick)


def g_target(d, x, y, w, color, thick):
    d.ellipse([x + w * 0.1, y + w * 0.1, x + w * 0.9, y + w * 0.9], outline=color, width=thick)
    d.ellipse([x + w * 0.33, y + w * 0.33, x + w * 0.67, y + w * 0.67], outline=color, width=thick)
    d.line([(x + w * 0.5, y), (x + w * 0.5, y + w * 0.18)], fill=color, width=thick)
    d.line([(x + w * 0.5, y + w), (x + w * 0.5, y + w * 0.82)], fill=color, width=thick)
    d.line([(x, y + w * 0.5), (x + w * 0.18, y + w * 0.5)], fill=color, width=thick)
    d.line([(x + w, y + w * 0.5), (x + w * 0.82, y + w * 0.5)], fill=color, width=thick)


def g_loop(d, x, y, w, color, thick):
    """Circular arrows (patrol / tour)."""
    d.arc([x + w * 0.12, y + w * 0.12, x + w * 0.88, y + w * 0.88], start=30, end=300,
          fill=color, width=thick)
    # arrow head near the 300deg end
    import math
    ang = math.radians(300)
    cx, cy = x + w * 0.5, y + w * 0.5
    r = w * 0.38
    hx, hy = cx + r * math.cos(ang), cy + r * math.sin(ang)
    hs = w * 0.16
    d.line([(hx, hy), (hx - hs, hy - hs * 0.2)], fill=color, width=thick)
    d.line([(hx, hy), (hx - hs * 0.2, hy - hs)], fill=color, width=thick)


def g_stop(d, x, y, w, color, thick):
    d.rounded_rectangle([x + w * 0.2, y + w * 0.2, x + w * 0.8, y + w * 0.8],
                        radius=w * 0.12, fill=color)


GLYPHS = {
    "switchView": (g_grid, ACCENT, "VIEW"),
    "nextView": (lambda d, x, y, w, c, t: g_chevron(d, x, y, w, c, t, right=True), ACCENT, "NEXT"),
    "prevView": (lambda d, x, y, w, c, t: g_chevron(d, x, y, w, c, t, right=False), ACCENT, "PREV"),
    "fullscreen": (lambda d, x, y, w, c, t: g_expand(d, x, y, w, c, t, inward=False), ACCENT, "FULL"),
    "exitFullscreen": (lambda d, x, y, w, c, t: g_expand(d, x, y, w, c, t, inward=True), ACCENT, "GRID"),
    "ptz": (g_target, PTZ_ACCENT, "PTZ"),
    "ptzHome": (g_house, PTZ_ACCENT, "HOME"),
    "ptzPatrol": (g_loop, PTZ_ACCENT, "TOUR"),
    "ptzStop": (g_stop, PTZ_ACCENT, "STOP"),
}


def make_list_icon(name, glyph):
    """20x20 / 40x40 white glyph on transparent (actions list)."""
    fn, _accent, _label = glyph
    img = _canvas(40)
    d = ImageDraw.Draw(img)
    w = 40 * SS
    m = w * 0.16
    fn(d, m, m, w - 2 * m, WHITE, int(2.4 * SS))
    _save(img, f"{name}@2x", 40)
    _save(img, name, 20)


def make_key_icon(name, glyph):
    """72x72 / 144x144 rounded key image with glyph + label."""
    fn, accent, label = glyph
    img = _canvas(144)
    d = ImageDraw.Draw(img)
    w = 144 * SS
    d.rounded_rectangle([0, 0, w, w], radius=w * 0.16, fill=KEY_BG)
    # accent bar at the bottom
    d.rounded_rectangle([0, w * 0.86, w, w], radius=w * 0.16, fill=accent)
    d.rectangle([0, w * 0.86, w, w * 0.93], fill=accent)
    gm = w * 0.24
    gw = w - 2 * gm
    fn(d, gm, w * 0.12, gw, WHITE, int(4.2 * SS))
    font = _font(int(w * 0.13))
    _centered_text(d, w / 2, w * 0.62, label, font, WHITE)
    _save(img, f"{name}Key", 144)
    _save(img, f"{name}Key@2x", 144)
    # @1x
    small = img.resize((72, 72), Image.LANCZOS)
    small.save(os.path.join(ICONS, f"{name}Key.png"))
    small.resize((144, 144), Image.LANCZOS).save(os.path.join(ICONS, f"{name}Key@2x.png"))


def make_badge(name, size1, size2, label):
    for size, suffix in ((size2, "@2x"), (size1, "")):
        img = _canvas(size2)
        d = ImageDraw.Draw(img)
        w = size2 * SS
        d.rounded_rectangle([0, 0, w, w], radius=w * 0.22, fill=ACCENT)
        font = _font(int(w * 0.42))
        _centered_text(d, w / 2, w * 0.27, label, font, WHITE)
        _save(img, f"{name}{suffix}", size)


def make_default_key():
    """Generic fallback key image used if an action lacks its own."""
    img = _canvas(144)
    d = ImageDraw.Draw(img)
    w = 144 * SS
    d.rounded_rectangle([0, 0, w, w], radius=w * 0.16, fill=KEY_BG)
    font = _font(int(w * 0.34))
    _centered_text(d, w / 2, w * 0.33, "UP", font, ACCENT)
    _save(img, "key@2x", 144)
    img.resize((72, 72), Image.LANCZOS).save(os.path.join(ICONS, "key.png"))


def main():
    for name, glyph in GLYPHS.items():
        make_list_icon(name, glyph)
        make_key_icon(name, glyph)
    make_badge("plugin", 28, 56, "UP")
    make_badge("category", 28, 56, "UP")
    make_default_key()
    print(f"Icons written to {ICONS}")


if __name__ == "__main__":
    main()
