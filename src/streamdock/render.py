"""Key image rendering: gradient backgrounds, real typography, and a set of
clean vector icons drawn at 4x supersampling for smooth antialiased edges.

The public entry point is ``render_key(...)``. Icons are drawn by name; call
``icon_names()`` for the list. Everything is self-contained (no image assets).
"""
from __future__ import annotations

import math

from PIL import Image, ImageDraw, ImageFont

from .device import KEY_PX

SS = 4                     # supersample factor
S = KEY_PX * SS            # working canvas size
DEFAULT_BG = (46, 49, 57)
LIGHT_FG = (238, 240, 245)
DARK_FG = (28, 30, 36)

_FONTS = [
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/SFNSDisplay.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def _font(px: int):
    for p in _FONTS:
        try:
            return ImageFont.truetype(p, px)
        except Exception:
            continue
    return ImageFont.load_default()


def _c(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def _shade(rgb, f):
    return tuple(_c(x * f) for x in rgb)


def _luma(rgb):
    return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]


def _auto_fg(bg):
    return DARK_FG if _luma(bg) > 140 else LIGHT_FG


def _vgrad(w, h, top, bot):
    strip = Image.new("RGB", (1, h))
    px = strip.load()
    for y in range(h):
        t = y / (h - 1) if h > 1 else 0
        px[0, y] = tuple(_c(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    return strip.resize((w, h))


def _rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                        radius=radius, fill=255)
    return m


def _stroke(d, pts, col, lw):
    """Polyline with round joins/caps (PIL lines are butt-capped)."""
    d.line(pts, fill=col, width=lw, joint="curve")
    r = lw / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=col)


# ---------------------------------------------------------------- icons -------
# each icon: fn(d, cx, cy, r, col, lw, level)  drawing within radius r of (cx,cy)

def _i_power(d, cx, cy, r, col, lw, level):
    d.arc([cx - r, cy - r, cx + r, cy + r], -55, 235, fill=col, width=lw)
    _stroke(d, [(cx, cy - r * 1.15), (cx, cy - r * 0.05)], col, lw)


def _i_sun(d, cx, cy, r, col, lw, level):
    rr = r * 0.5
    d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=col, width=lw)
    for i in range(8):
        a = math.radians(i * 45)
        i0, i1 = r * 0.72, r * 1.08
        _stroke(d, [(cx + i0 * math.cos(a), cy + i0 * math.sin(a)),
                    (cx + i1 * math.cos(a), cy + i1 * math.sin(a))], col, int(lw * 0.85))


def _i_moon(d, cx, cy, r, col, lw, level):
    layer = Image.new("L", (S, S), 0)
    ld = ImageDraw.Draw(layer)
    ld.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    ld.ellipse([cx - r * 0.35, cy - r * 1.15, cx + r * 1.3, cy + r * 0.85], fill=0)
    d.bitmap((0, 0), layer, fill=col)


def _i_bulb(d, cx, cy, r, col, lw, level):
    rr = r * 0.72
    d.arc([cx - rr, cy - rr - r * 0.15, cx + rr, cy + rr - r * 0.15], 20, 160,
          fill=col, width=lw)
    d.ellipse([cx - rr, cy - rr - r * 0.15, cx + rr, cy + rr - r * 0.15],
              outline=col, width=lw)
    y0 = cy + rr - r * 0.15
    _stroke(d, [(cx - r * 0.34, y0 + r * 0.06), (cx + r * 0.34, y0 + r * 0.06)], col, lw)
    _stroke(d, [(cx - r * 0.24, y0 + r * 0.32), (cx + r * 0.24, y0 + r * 0.32)], col, lw)


def _i_monitor(d, cx, cy, r, col, lw, level):
    w, h = r * 2.05, r * 1.45
    d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2 - r * 0.2],
                        radius=r * 0.16, outline=col, width=lw)
    _stroke(d, [(cx, cy + h / 2 - r * 0.2), (cx, cy + h / 2 + r * 0.12)], col, lw)
    _stroke(d, [(cx - r * 0.5, cy + h / 2 + r * 0.18),
                (cx + r * 0.5, cy + h / 2 + r * 0.18)], col, lw)


def _i_droplet(d, cx, cy, r, col, lw, level):
    # filled teardrop — reads as a color swatch
    br = r * 0.62
    bcy = cy + r * 0.28
    d.ellipse([cx - br, bcy - br, cx + br, bcy + br], fill=col)
    d.polygon([(cx, cy - r * 0.95), (cx - br * 0.92, bcy), (cx + br * 0.92, bcy)], fill=col)


def _i_meter(d, cx, cy, r, col, lw, level):
    # progress bar: faint full-width track + solid proportional fill
    w, h = r * 2.3, r * 0.9
    x0, y0 = cx - w / 2, cy - h / 2
    rad = h / 2
    track = (col[0], col[1], col[2], 66)
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=rad, fill=track)
    lv = 0.5 if level is None else max(0.0, min(1.0, level))
    fw = max(h, w * lv)     # at least one rounded end so it renders
    d.rounded_rectangle([x0, y0, x0 + fw, y0 + h], radius=rad, fill=col)


def _i_contrast(d, cx, cy, r, col, lw, level):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=lw)
    d.pieslice([cx - r, cy - r, cx + r, cy + r], -90, 90, fill=col)


def _i_refresh(d, cx, cy, r, col, lw, level):
    d.arc([cx - r, cy - r, cx + r, cy + r], 30, 300, fill=col, width=lw)
    a = math.radians(30)
    tx, ty = cx + r * math.cos(a), cy + r * math.sin(a)
    s = r * 0.42
    d.polygon([(tx + s, ty), (tx - s * 0.2, ty - s * 0.9), (tx - s * 0.2, ty + s * 0.9)],
              fill=col)


def _i_plus(d, cx, cy, r, col, lw, level):
    _stroke(d, [(cx - r * 0.8, cy), (cx + r * 0.8, cy)], col, lw)
    _stroke(d, [(cx, cy - r * 0.8), (cx, cy + r * 0.8)], col, lw)


def _i_minus(d, cx, cy, r, col, lw, level):
    _stroke(d, [(cx - r * 0.8, cy), (cx + r * 0.8, cy)], col, lw)


def _i_play(d, cx, cy, r, col, lw, level):
    d.polygon([(cx - r * 0.6, cy - r * 0.85), (cx - r * 0.6, cy + r * 0.85),
               (cx + r * 0.85, cy)], fill=col)


def _i_lock(d, cx, cy, r, col, lw, level):
    bw, bh = r * 1.5, r * 1.15
    d.rounded_rectangle([cx - bw / 2, cy - r * 0.1, cx + bw / 2, cy - r * 0.1 + bh],
                        radius=r * 0.2, outline=col, width=lw)
    sr = r * 0.5
    d.arc([cx - sr, cy - r * 0.95, cx + sr, cy - r * 0.05], 180, 360, fill=col, width=lw)


def _i_gear(d, cx, cy, r, col, lw, level):
    teeth = 8
    outer, inner = r, r * 0.78
    pts = []
    for i in range(teeth * 2):
        a = math.pi * i / teeth
        rad = outer if i % 2 == 0 else inner
        pts.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    d.polygon(pts, outline=col, width=lw)
    hr = r * 0.34
    d.ellipse([cx - hr, cy - hr, cx + hr, cy + hr], outline=col, width=lw)


def _i_dot(d, cx, cy, r, col, lw, level):
    d.ellipse([cx - r * 0.5, cy - r * 0.5, cx + r * 0.5, cy + r * 0.5], fill=col)


ICONS = {
    "power": _i_power, "sun": _i_sun, "moon": _i_moon, "bulb": _i_bulb,
    "monitor": _i_monitor, "droplet": _i_droplet, "meter": _i_meter,
    "brightness": _i_meter, "contrast": _i_contrast, "refresh": _i_refresh,
    "cycle": _i_refresh, "plus": _i_plus, "minus": _i_minus, "play": _i_play,
    "lock": _i_lock, "gear": _i_gear, "dot": _i_dot,
}


def icon_names():
    return sorted(ICONS)


# ---------------------------------------------------------------- label -------
def _draw_label(d, text, fg, has_icon):
    if has_icon:
        size = int(S * 0.16)
        f = _font(size)
        b = d.textbbox((0, 0), text, font=f)
        while b[2] - b[0] > S * 0.86 and size > 10:
            size -= 4
            f = _font(size)
            b = d.textbbox((0, 0), text, font=f)
        w = b[2] - b[0]
        d.text((S / 2 - w / 2 - b[0], S * 0.80 - b[1]), text, font=f, fill=fg)
    else:
        size = int(S * 0.30)
        f = _font(size)
        b = d.textbbox((0, 0), text, font=f)
        while b[2] - b[0] > S * 0.82 and size > 12:
            size -= 4
            f = _font(size)
            b = d.textbbox((0, 0), text, font=f)
        w, h = b[2] - b[0], b[3] - b[1]
        d.text((S / 2 - w / 2 - b[0], S / 2 - h / 2 - b[1]), text, font=f, fill=fg)


def render_key(label=None, icon=None, color=None, fg=None, level=None):
    """Render a professional-looking key face.

    label  : text (centered, or a caption under the icon)
    icon   : icon name (see icon_names())
    color  : base background color (r,g,b); a subtle gradient is derived from it
    fg     : foreground; auto-picked for contrast if omitted
    level  : 0..1 fill for the 'brightness'/'meter'/'contrast' icons
    """
    base = tuple(color) if color else DEFAULT_BG
    fg = tuple(fg) if fg else _auto_fg(base)
    img = _vgrad(S, S, _shade(base, 1.30), _shade(base, 0.66)).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")

    # faint inset border for depth
    sheen = (255, 255, 255, 30) if _luma(base) <= 140 else (0, 0, 0, 30)
    d.rounded_rectangle([S * 0.05, S * 0.05, S * 0.95, S * 0.95],
                        radius=S * 0.12, outline=sheen, width=max(1, int(S * 0.006)))

    lw = max(2, int(S * 0.052))
    if icon and icon in ICONS:
        cy = S * 0.40 if label else S * 0.5
        r = S * (0.20 if label else 0.26)
        ICONS[icon](d, S / 2, cy, r, fg, lw, level)
    if label:
        _draw_label(d, label, fg, has_icon=bool(icon and icon in ICONS))

    img = img.resize((KEY_PX, KEY_PX), Image.LANCZOS)
    out = Image.new("RGB", (KEY_PX, KEY_PX), (0, 0, 0))
    out.paste(img, (0, 0), _rounded_mask((KEY_PX, KEY_PX), int(KEY_PX * 0.16)))
    return out
