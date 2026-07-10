"""Geometry tests for the key-face renderer (pure Pillow, no hardware).

These lock in the alignment contract: every face is exactly KEY_PX square, each
icon's ink is centered on the key, an icon+caption reads as a centered group,
the masked corners stay background, and the display calibration shifts the whole
face as one registered unit (frame + icon + caption + corner-rounding together).
"""
from streamdock.control import DISPLAY_CAL, Config, KeyConfig, Page, Runner
from streamdock.device import KEY_PX
from streamdock.layout import DEFAULT_LAYOUT
from streamdock.render import icon_names, render_key

DARK = (30, 30, 30)          # dark bg -> light auto-fg, so ink is high-luma
MID = KEY_PX / 2 - 0.5       # geometric center in pixel coordinates
# proportional-bar icons: their solid fill is level-dependent and left-aligned
# by design (a progress bar), so the visible ink is not meant to be centered.
LEVEL_ICONS = {"meter", "brightness"}


def _centered_icons():
    return [n for n in icon_names() if n not in LEVEL_ICONS]


def _luma(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def ink(img, thr=150):
    """Coordinates of foreground (icon/caption) pixels: bright ink over the
    dark gradient. The black masked corners fall well below the threshold."""
    px = img.load()
    return [(x, y) for y in range(img.height) for x in range(img.width)
            if _luma(px[x, y]) > thr]


def bbox_center(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2


# ---- basic output contract -------------------------------------------------
def test_output_is_key_sized_rgb():
    img = render_key(icon="power", color=DARK)
    assert img.size == (KEY_PX, KEY_PX)
    assert img.mode == "RGB"


def test_blank_face_still_key_sized():
    img = render_key(color=DARK)
    assert img.size == (KEY_PX, KEY_PX)


# ---- horizontal centering --------------------------------------------------
def test_every_icon_bbox_horizontally_centered():
    for name in _centered_icons():
        pts = ink(render_key(icon=name, color=DARK))
        assert pts, name
        cx, _ = bbox_center(pts)
        assert abs(cx - MID) <= 1.5, (name, cx)


def test_symmetric_icons_have_balanced_ink_mass():
    # symmetric-by-design glyphs: the ink centroid sits on the vertical midline
    for name in ("power", "sun", "plus", "minus", "gear", "dot", "monitor"):
        pts = ink(render_key(icon=name, color=DARK))
        centroid_x = sum(x for x, _ in pts) / len(pts)
        assert abs(centroid_x - MID) <= 1.0, (name, centroid_x)


def test_full_meter_bar_is_centered():
    # at level 1.0 the fill spans the whole track, so the ink is centered
    pts = ink(render_key(icon="meter", color=DARK, level=1.0))
    cx, _ = bbox_center(pts)
    assert abs(cx - MID) <= 1.5


# ---- vertical centering ----------------------------------------------------
def test_iconless_icon_bbox_vertically_centered():
    # with no caption the icon owns the whole face and sits dead-center
    for name in _centered_icons():
        pts = ink(render_key(icon=name, color=DARK))
        _, cy = bbox_center(pts)
        assert abs(cy - MID) <= 1.5, (name, cy)


# ---- icon + caption group --------------------------------------------------
def test_icon_and_caption_form_a_centered_group():
    pts = ink(render_key(icon="bulb", label="Lights", color=DARK))
    _, cy = bbox_center(pts)
    # the whole group sits in the middle band of the key
    assert 0.30 * KEY_PX <= cy <= 0.66 * KEY_PX
    # icon ink above the middle, caption ink below it
    assert any(y < 0.5 * KEY_PX for _, y in pts)
    assert any(y > 0.66 * KEY_PX for _, y in pts)


def test_caption_stays_off_the_masked_corners():
    # a wide caption must not bleed into the rounded corners / bottom edge
    img = render_key(icon="meter", label="MMMMMM", color=DARK)
    corner = int(KEY_PX * 0.16) + 1
    for x, y in ink(img):
        near_l, near_r = x < corner, x > KEY_PX - 1 - corner
        near_t, near_b = y < corner, y > KEY_PX - 1 - corner
        assert not ((near_l or near_r) and (near_t or near_b)), (x, y)


# ---- masked corners are background ----------------------------------------
def test_corners_are_black_background():
    img = render_key(icon="gear", label="Test", color=DARK)
    px = img.load()
    for x, y in ((0, 0), (KEY_PX - 1, 0), (0, KEY_PX - 1), (KEY_PX - 1, KEY_PX - 1)):
        assert px[x, y] == (0, 0, 0), (x, y, px[x, y])


# ---- whole-face calibration is a registered translation --------------------
def test_default_render_is_deterministic():
    a = render_key(icon="sun", label="Sun", color=DARK)
    b = render_key(icon="sun", label="Sun", color=DARK)
    assert a.tobytes() == b.tobytes()


def test_nudge_translates_the_icon_by_the_expected_amount():
    base = bbox_center(ink(render_key(icon="dot", color=DARK)))
    dn = 0.10
    shifted = bbox_center(ink(render_key(icon="dot", color=DARK, nudge_x=dn, nudge_y=dn)))
    assert abs((shifted[0] - base[0]) - dn * KEY_PX) <= 1.5
    assert abs((shifted[1] - base[1]) - dn * KEY_PX) <= 1.5


def test_nudge_keeps_icon_and_caption_registered():
    # the icon->caption spacing is a property of the group, invariant under nudge
    def spacing(**kw):
        img = render_key(icon="bulb", label="Lights", color=DARK, **kw)
        pts = ink(img)
        top = [p for p in pts if p[1] < 0.55 * KEY_PX]      # icon
        bot = [p for p in pts if p[1] > 0.62 * KEY_PX]      # caption
        return bbox_center(bot)[1] - bbox_center(top)[1]
    assert abs(spacing() - spacing(nudge_y=0.06)) <= 1.0


def test_nudge_moves_the_frame_with_the_content():
    # at rest the bottom-right corner is rounded (black); shifting the whole face
    # down-right moves the rounding off-canvas, filling that corner -> registered
    rest = render_key(icon="gear", color=DARK).load()[KEY_PX - 1, KEY_PX - 1]
    moved = render_key(icon="gear", color=DARK, nudge_x=0.12, nudge_y=0.12) \
        .load()[KEY_PX - 1, KEY_PX - 1]
    assert rest == (0, 0, 0)
    assert moved != (0, 0, 0)


# ---- calibration is uniform across rows (no per-row hack) -------------------
def test_calibration_is_a_single_uniform_offset():
    assert isinstance(DISPLAY_CAL, tuple) and len(DISPLAY_CAL) == 2


class _FakeDock:
    """Just enough of StreamDock for Runner.render_all, capturing per-position
    images so we can compare what each row would receive."""
    def __init__(self):
        self.layout = DEFAULT_LAYOUT
        self.sent = {}

    def clear_all(self):
        self.sent.clear()

    def has_screen(self, pos):
        return self.layout.has_screen(pos)

    def set_position_image(self, pos, img):
        self.sent[pos] = img


def test_same_icon_renders_identically_on_every_row():
    # positions 0, 5, 10 are top/middle/bottom row; uniform calibration => same
    keys = [KeyConfig(position=p, icon="power", label="Go") for p in (0, 5, 10)]
    cfg = Config(pages=[Page(name="main", keys=keys)])
    dock = _FakeDock()
    Runner(cfg, verbose=False).render_all(dock)
    imgs = [dock.sent[p].tobytes() for p in (0, 5, 10)]
    assert imgs[0] == imgs[1] == imgs[2]
