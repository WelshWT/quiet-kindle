"""The Quiet sleep covers (asked for: "QUIET ... saying QUIET in a really loud and dynamic way", rounded like the UI).

Five covers, each light and dark, at the Paperwhite's 1272x1696 in its 16 greys, plus the picker's tiles:
  quiet-1  Block      QUI over ET, each line the full width, flat
  quiet-2  Big Q      a giant Q over UIET, flat
  quiet-3  3D block   QUI over ET extruded into solid letters (the default)
  quiet-4  3D Q       the giant Q extruded, its inner walls showing
  quiet-5  Diagonal   QUIET on one line in 3D, tilted down to the right
Rubik Black (Google Fonts, OFL): rounded corners like Quiet's pills and covers. The 3D ones are real extrusions of the
letters' outlines seen through a perspective camera, shaded flat: one grey per face direction, no gradients.

usage (fontTools needed: python3 -m venv --system-site-packages v && v/bin/pip install fonttools):
  v/bin/python -I make_covers.py <Rubik[wght].ttf> <out dir>   (out: kindle/data/quiet-sleep)
"""
import math
import os
import sys

import numpy as np
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageChops, ImageDraw, ImageFont

RUBIK, OUT = sys.argv[1], sys.argv[2]
W, H = 1272, 1696
SS = 2                      # drawn at 2x, then reduced
LEVELS = [i * 17 for i in range(16)]  # the panel's 16 greys
TILE = (264, 352)           # the picker's thumbnails


# --- shared ------------------------------------------------------------------------------------------------------

def to_panel(img):
    """Reduce a 2x drawing to the screen and to the panel's 16 greys (dithered only where edges are anti-aliased)."""
    img = img.resize((W, H), Image.LANCZOS)
    pal = Image.new("P", (1, 1))
    pal.putpalette([v for g in LEVELS for v in (g, g, g)] + [0, 0, 0] * (256 - 16))
    return img.convert("RGB").quantize(palette=pal, dither=Image.Dither.FLOYDSTEINBERG).convert("L")


def save(img, name):
    img.save(os.path.join(OUT, f"{name}.png"), optimize=True)
    tile = img.resize(TILE, Image.LANCZOS)
    pal = Image.new("P", (1, 1))
    pal.putpalette([v for g in LEVELS for v in (g, g, g)] + [0, 0, 0] * (256 - 16))
    tile.convert("RGB").quantize(palette=pal, dither=Image.Dither.FLOYDSTEINBERG).convert("L").save(
        os.path.join(OUT, "tiles", f"{name}.png"), optimize=True)
    print(name)


def rubik(size, wght=900):
    f = ImageFont.truetype(RUBIK, int(size))
    f.set_variation_by_axes([wght])
    return f


# --- flat: justified lines ---------------------------------------------------------------------------------------

def line_mask(text, size, tracking=-0.03):
    f = rubik(size)
    widths = [f.getlength(c) for c in text]
    extra = tracking * size
    img = Image.new("L", (int(sum(widths) + extra * (len(text) - 1) + size), int(size * 1.6)), 0)
    d = ImageDraw.Draw(img)
    x = size * 0.2
    for c, cw in zip(text, widths):
        d.text((x, size * 0.2), c, font=f, fill=255)
        x += cw + extra
    return img.crop(img.getbbox())


def fit_width(text, width):
    size = 400.0
    for _ in range(6):
        size *= width / line_mask(text, size).size[0]
    return line_mask(text, size)


def flat(lines, gap_ratio, margin=64):
    """Lines stacked, each exactly the page's inner width, centred on the page: a 2x mask."""
    canvas = Image.new("L", (W * SS, H * SS), 0)
    width = (W - 2 * margin) * SS
    masks = [fit_width(t, width) for t in lines]
    gap = int(min(m.size[1] for m in masks) * gap_ratio)
    total = sum(m.size[1] for m in masks) + gap * (len(masks) - 1)
    avail = (H - 2 * margin) * SS
    if total > avail:
        k = avail / total
        masks = [m.resize((int(m.size[0] * k), int(m.size[1] * k)), Image.LANCZOS) for m in masks]
        gap = int(gap * k)
        total = sum(m.size[1] for m in masks) + gap * (len(masks) - 1)
    y = margin * SS + (avail - total) // 2
    for m in masks:
        canvas.paste(255, ((W * SS - m.size[0]) // 2, y), m)
        y += m.size[1] + gap
    return canvas


def flat_cover(name, lines, gap_ratio):
    ink = flat(lines, gap_ratio)
    light = Image.new("L", ink.size, 255)
    light.paste(0, (0, 0), ink)
    save(to_panel(light), name)
    dark = Image.new("L", ink.size, 0)
    dark.paste(255, (0, 0), ink)
    save(to_panel(dark), name + "-dark")


# --- 3D: extruded outlines through a camera ----------------------------------------------------------------------

TT = instantiateVariableFont(TTFont(RUBIK), {"wght": 900})
UPM = TT["head"].unitsPerEm
GLYPHS, CMAP, HMTX = TT.getGlyphSet(), TT.getBestCmap(), TT["hmtx"]
CAP = (getattr(TT["OS/2"], "sCapHeight", 0) or 0.7 * UPM) / UPM


class Flatten(BasePen):
    def __init__(self, gs, steps=10):
        super().__init__(gs)
        self.contours, self.cur, self.steps = [], [], steps

    def _moveTo(self, p):
        self.cur = [p]

    def _lineTo(self, p):
        self.cur.append(p)

    def _curveToOne(self, p1, p2, p3):
        p0 = self.cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            m = 1 - t
            self.cur.append((m ** 3 * p0[0] + 3 * m * m * t * p1[0] + 3 * m * t * t * p2[0] + t ** 3 * p3[0],
                             m ** 3 * p0[1] + 3 * m * m * t * p1[1] + 3 * m * t * t * p2[1] + t ** 3 * p3[1]))

    def _qCurveToOne(self, p1, p2):
        p0 = self.cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            m = 1 - t
            self.cur.append((m * m * p0[0] + 2 * m * t * p1[0] + t * t * p2[0],
                             m * m * p0[1] + 2 * m * t * p1[1] + t * t * p2[1]))

    def _closePath(self):
        if len(self.cur) > 2:
            if self.cur[0] == self.cur[-1]:
                self.cur.pop()
            self.contours.append(self.cur)
        self.cur = []

    _endPath = _closePath


def glyph(ch):
    name = CMAP[ord(ch)]
    pen = Flatten(GLYPHS)
    GLYPHS[name].draw(pen)
    return pen.contours, HMTX[name][0]


def inside(pt, contours):
    x, y = pt
    c = False
    for poly in contours:
        n = len(poly)
        for i in range(n):
            x1, y1 = poly[i]
            x2, y2 = poly[(i + 1) % n]
            if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
                c = not c
    return c


def solids(lines, tracking=-0.02, gap=0.13, depth=0.32):
    """The extruded letters' faces in em units (y down), centred: (kind, points, normal)."""
    rows = []
    for text in lines:
        x, letters = 0.0, []
        for ch in text:
            contours, adv = glyph(ch)
            letters.append((contours, x))
            x += adv / UPM + tracking
        rows.append((letters, x - tracking))
    widest = max(w for _, w in rows)
    letters2d, base = [], 0.0
    for letters, wl in rows:
        s = widest / wl
        base += CAP * s
        for contours, x0 in letters:
            letters2d.append([[((x0 + px / UPM) * s, base - (py / UPM) * s) for px, py in c] for c in contours])
        base += gap * CAP
    pts = np.array([p for L in letters2d for c in L for p in c])
    cx, cy = (pts[:, 0].min() + pts[:, 0].max()) / 2, (pts[:, 1].min() + pts[:, 1].max()) / 2
    faces = []
    for L in letters2d:
        conts = [[(px - cx, py - cy) for px, py in c] for c in L]
        faces.append(("front", conts, np.array([0, 0, -1.0])))
        for c in conts:
            for i in range(len(c)):
                (x1, y1), (x2, y2) = c[i], c[(i + 1) % len(c)]
                ln = math.hypot(x2 - x1, y2 - y1)
                if ln < 1e-9:
                    continue
                nx, ny = -(y2 - y1) / ln, (x2 - x1) / ln
                if inside(((x1 + x2) / 2 + nx * 0.004, (y1 + y2) / 2 + ny * 0.004), conts):
                    nx, ny = -nx, -ny  # away from the letter's body
                faces.append(("side", [(x1, y1, 0), (x2, y2, 0), (x2, y2, depth), (x1, y1, depth)],
                              np.array([nx, ny, 0.0])))
    return faces


def rotation(yaw, pitch, roll):
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    cr, sr = math.cos(math.radians(roll)), math.sin(math.radians(roll))
    Rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    return Ry @ Rx @ Rz


# one flat grey per face direction: tops, left sides, right sides, undersides (the panel's own levels)
GREYS_LIGHT = (204, 153, 102, 68)
GREYS_DARK = (153, 119, 85, 51)


def render3d(lines, yaw, pitch, roll, focal, dark, box=(80, 110, 1192, 1586)):
    R = rotation(yaw, pitch, roll)
    dist = 4.0
    f = focal * SS
    drawn = []
    for kind, pts, n in solids(lines):
        if kind == "front":
            P = [[R @ np.array([x, y, 0.0]) + np.array([0, 0, dist]) for x, y in c] for c in pts]
            if (R @ n)[2] > 0:
                continue
            drawn.append((np.mean([p[2] for c in P for p in c]), kind, P, n))
        else:
            P = [R @ np.array(p) + np.array([0, 0, dist]) for p in pts]
            if np.dot(R @ n, np.mean(P, axis=0)) > 0:
                continue  # faces away from the camera
            drawn.append((np.mean([p[2] for p in P]), kind, P, n))
    drawn.sort(key=lambda t: -t[0])  # far to near

    def raw(p):
        return (f * p[0] / p[2], f * p[1] / p[2])

    xs, ys = [], []
    for _, kind, P, _ in drawn:
        for p in (P if kind == "side" else [q for c in P for q in c]):
            x, y = raw(p)
            xs.append(x)
            ys.append(y)
    mx0, my0, mx1, my1 = [v * SS for v in box]
    k = min((mx1 - mx0) / (max(xs) - min(xs)), (my1 - my0) / (max(ys) - min(ys)))
    ox = (mx0 + mx1) / 2 - k * (min(xs) + max(xs)) / 2
    oy = (my0 + my1) / 2 - k * (min(ys) + max(ys)) / 2

    def project(p):
        x, y = raw(p)
        return (ox + k * x, oy + k * y)

    greys = GREYS_DARK if dark else GREYS_LIGHT
    canvas = Image.new("L", (W * SS, H * SS), 0 if dark else 255)
    draw = ImageDraw.Draw(canvas)
    for _, kind, P, n in drawn:
        if kind == "side":
            nx, ny = n[0], n[1]
            g = greys[0] if ny < -0.55 else greys[3] if ny > 0.55 else greys[1] if nx < 0 else greys[2]
            draw.polygon([project(p) for p in P], fill=g)
        else:
            mask = Image.new("1", canvas.size, 0)
            for c in P:
                layer = Image.new("1", canvas.size, 0)
                ImageDraw.Draw(layer).polygon([project(p) for p in c], fill=1)
                mask = ImageChops.logical_xor(mask, layer)
            canvas.paste(255 if dark else 0, (0, 0), mask.convert("L"))
    return canvas


def cover3d(name, lines, **cam):
    save(to_panel(render3d(lines, dark=False, **cam)), name)
    save(to_panel(render3d(lines, dark=True, **cam)), name + "-dark")


if __name__ == "__main__":
    os.makedirs(os.path.join(OUT, "tiles"), exist_ok=True)
    flat_cover("quiet-1", ["QUI", "ET"], 0.075)
    flat_cover("quiet-2", ["Q", "UIET"], 0.05)
    cover3d("quiet-3", ["QUI", "ET"], yaw=-20, pitch=15, roll=-3, focal=2600)
    cover3d("quiet-4", ["Q", "UIET"], yaw=-18, pitch=12, roll=-3, focal=2600)
    cover3d("quiet-5", ["QUIET"], yaw=30, pitch=20, roll=14, focal=2200)
