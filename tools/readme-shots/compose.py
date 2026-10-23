"""README images: Quiet's screens (1272x1696 screenshots from KOReader's emulator, public-domain demo books) set in a
Kindle-like frame on warm paper, so they read like the e-ink device they come from.

usage: python compose.py <screenshots dir> <output dir>
Each image below is made when all its screenshots are in the directory (the others are skipped, so one can be redone
alone). The screenshots are what the emulator's Screen:shot() saves (or bin/kshot, from the Kindle itself); they are grey-toned here like e-ink (the panel shows 16
greys, slightly warm), framed (a plain dark body, no logos), shadowed and laid out per image below.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)

PAPER = np.array([241, 238, 231], float)  # e-ink white, a touch warm
INK = np.array([28, 28, 30], float)
BG_TOP, BG_BOTTOM = (246, 242, 234), (230, 223, 210)
BODY_TOP, BODY_BOTTOM = (34, 34, 36), (16, 16, 18)


def eink(path):
    """A screenshot as the panel shows it: grey, mapped between e-ink's paper and ink."""
    g = np.asarray(Image.open(path).convert("L"), float)[..., None] / 255.0
    return Image.fromarray((INK + (PAPER - INK) * g).astype(np.uint8), "RGB")


def gradient(w, h, top, bottom):
    t = np.linspace(0, 1, h)[:, None, None]
    a = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    return Image.fromarray(np.repeat(a, w, axis=1).astype(np.uint8), "RGB")


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), r, fill=255)
    return m


def device(screen, width):
    """The screen in a slim dark body, `width` px wide, with its own soft shadow (RGBA, padded for the shadow)."""
    sw, sh = screen.size
    side, top, bottom = int(sw * 0.075), int(sw * 0.085), int(sw * 0.105)
    bw, bh = sw + 2 * side, sh + top + bottom
    radius = int(bw * 0.065)
    body = gradient(bw, bh, BODY_TOP, BODY_BOTTOM).convert("RGBA")
    rim = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((1, 1, bw - 2, bh - 2), radius - 1, outline=(70, 70, 74, 255), width=3)
    body.alpha_composite(rim)
    # the screen, with a faint inner shadow at its top edge and a whisper of glass sheen
    scr = screen.convert("RGBA")
    shade = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(shade).rectangle((0, 0, sw, int(sh * 0.012)), fill=60)
    shade = shade.filter(ImageFilter.GaussianBlur(sw * 0.006))
    scr = Image.composite(Image.new("RGBA", (sw, sh), (0, 0, 0, 255)), scr, shade)
    body.alpha_composite(scr, (side, top))
    sheen = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(sheen).polygon([(0, 0), (int(bw * 0.55), 0), (0, int(bh * 0.42))], fill=14)
    sheen = sheen.filter(ImageFilter.GaussianBlur(bw * 0.03))
    body = Image.composite(Image.new("RGBA", (bw, bh), (255, 255, 255, 255)), body, sheen)
    body.putalpha(rounded_mask(bw, bh, radius))
    # shadow
    s = width / bw
    body = body.resize((width, int(bh * s)), Image.LANCZOS)
    pad = int(width * 0.16)
    canvas = Image.new("RGBA", (width + 2 * pad, body.height + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (pad + int(width * 0.03), pad + int(width * 0.07), pad + width - int(width * 0.03), pad + body.height + int(width * 0.02)),
        int(radius * s), fill=120)
    shadow = shadow.filter(ImageFilter.GaussianBlur(width * 0.06))
    canvas.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", canvas.size, (60, 45, 25)).split(), shadow)))
    canvas.alpha_composite(body, (pad, pad))
    return canvas, pad


def card(w, h):
    bg = gradient(w, h, BG_TOP, BG_BOTTOM).convert("RGBA")
    bg.putalpha(rounded_mask(w, h, int(min(w, h) * 0.035)))
    return bg


def missing(names, out):
    gone = [n for n in names if not (SRC / f"{n}.png").exists()]
    if gone:
        print(out, "skipped: no", ", ".join(f"{n}.png" for n in gone))
    return gone


def row(names, out, dev_w=560, gap=70, margin=(120, 110), widths=None):
    """Devices side by side, centred on a card."""
    if missing(names, out):
        return
    devs = [device(eink(SRC / f"{n}.png"), (widths or {}).get(n, dev_w)) for n in names]
    inner_w = sum(d.width - 2 * p for d, p in devs) + gap * (len(devs) - 1)
    inner_h = max(d.height - 2 * p for d, p in devs)
    W, H = inner_w + 2 * margin[0], inner_h + 2 * margin[1]
    c = card(W, H)
    x = margin[0]
    for d, p in devs:
        dh = d.height - 2 * p
        c.alpha_composite(d, (x - p, margin[1] + (inner_h - dh) // 2 - p))
        x += d.width - 2 * p + gap
    c.save(OUT / out, optimize=True)
    print(out, c.size)


def hero(out, names=("home", "reader", "sleep-q3")):
    """Three devices: the book in the middle, a little larger and higher; Home and a sleep screen either side."""
    if missing(names, out):
        return
    side_w, mid_w = 600, 700
    left, lp = device(eink(SRC / f"{names[0]}.png"), side_w)
    mid, mp = device(eink(SRC / f"{names[1]}.png"), mid_w)
    right, rp = device(eink(SRC / f"{names[2]}.png"), side_w)
    overlap = -70  # a gap: every screen shows whole
    inner_w = side_w * 2 + mid_w - 2 * overlap
    mh, sh = mid.height - 2 * mp, left.height - 2 * lp
    W, H = inner_w + 260, mh + 220
    c = card(W, H)
    x0, y_mid = 130, 110
    y_side = y_mid + (mh - sh) // 2 + 40
    c.alpha_composite(left, (x0 - lp, y_side - lp))
    c.alpha_composite(right, (x0 + inner_w - side_w - rp, y_side - rp))
    c.alpha_composite(mid, (x0 + side_w - overlap - mp, y_mid - mp))
    c.save(OUT / out, optimize=True)
    print(out, c.size)


hero("hero.png")
row(["home", "library-list", "library-sort", "library-grid"], "home-library.png", dev_w=500, gap=60)
row(["reader", "reader-toolbar", "goto"], "reading.png")
row(["text-tab", "layout-tab", "more-sheet"], "sheets.png")
row(["ask", "stats"], "ask-stats.png", dev_w=640)
row(["sleep-q3", "sleep-q2-dark", "sleep-q5", "sleep-cover", "sleep-frosted"], "sleep.png", dev_w=380, gap=50)
row(["light", "sleep-sheet"], "light-sleep.png", dev_w=600)
row(["keyboard-fix", "keyboard-undo"], "keyboard.png", dev_w=640)
