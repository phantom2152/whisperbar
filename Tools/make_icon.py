#!/usr/bin/env python3
"""Renders the WhisperBar app icon (1024px PNG + .icns) and a preview sheet.
Usage: python3 Tools/make_icon.py        (needs: pip install pillow numpy)
"""
import math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources")
K = 2                       # supersampling factor
S = 1024 * K

def px(v): return int(round(v * K))

def thick_arc(draw, cx, cy, r, a0, a1, width, fill):
    """Arc with round caps, angles in degrees (0 = right, clockwise like PIL)."""
    steps = max(2, int(abs(a1 - a0) * 2))
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        draw.ellipse([px(x - width / 2), px(y - width / 2), px(x + width / 2), px(y + width / 2)], fill=fill)

def thick_line(draw, x0, y0, x1, y1, width, fill):
    draw.line([px(x0), px(y0), px(x1), px(y1)], fill=fill, width=px(width))
    for x, y in ((x0, y0), (x1, y1)):
        draw.ellipse([px(x - width / 2), px(y - width / 2), px(x + width / 2), px(y + width / 2)], fill=fill)

def gradient(size, c0, c1):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (xx + yy) / (2 * (size - 1))
    t = t[..., None]
    a = np.array(c0, np.float32); b = np.array(c1, np.float32)
    rgb = a + (b - a) * t
    img = np.dstack([rgb, np.full((size, size, 1), 255, np.float32)])
    return Image.fromarray(img.astype(np.uint8), "RGBA")

def app_icon():
    # --- background squircle (macOS grid: 824px artwork inside 1024 canvas)
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg = gradient(S, (136, 96, 255), (34, 20, 110))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([px(100), px(100), px(924), px(924)], radius=px(188), fill=255)
    art.paste(bg, (0, 0), mask)

    # soft top highlight
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = np.zeros((S, S, 4), np.uint8)
    ys = np.linspace(0, 1, S, dtype=np.float32)[:, None]
    hd[..., :3] = 255
    hd[..., 3] = (np.clip(1 - ys / 0.55, 0, 1) * 34).astype(np.uint8).repeat(S, axis=1)
    hl = Image.fromarray(hd, "RGBA")
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0)); clipped.paste(hl, (0, 0), mask)
    art = Image.alpha_composite(art, clipped)

    # --- microphone + whisper waves
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    white = (255, 255, 255, 255)
    cx, wy = 512, 440
    # waves (fade outward)
    for r, alpha in ((250, 175), (330, 95)):
        col = (255, 255, 255, alpha)
        thick_arc(d, cx, wy, r, -38, 38, 30, col)
        thick_arc(d, cx, wy, r, 142, 218, 30, col)
    # capsule
    d.rounded_rectangle([px(cx - 95), px(wy - 165), px(cx + 95), px(wy + 165)], radius=px(95), fill=white)
    # holder arc, stem, base
    thick_arc(d, cx, 470, 185, 0, 180, 34, white)
    thick_line(d, cx, 655, cx, 725, 34, white)
    thick_line(d, cx - 72, 725, cx + 72, 725, 34, white)

    # drop shadow under the glyph
    shadow = layer.filter(ImageFilter.GaussianBlur(px(14)))
    sh = np.array(shadow); sh[..., :3] = 20; sh[..., 3] = (sh[..., 3] * 0.35).astype(np.uint8)
    shadow = Image.fromarray(sh, "RGBA")
    shifted = Image.new("RGBA", (S, S), (0, 0, 0, 0)); shifted.paste(shadow, (0, px(10)))
    art = Image.alpha_composite(art, shifted)
    art = Image.alpha_composite(art, layer)

    # --- outer drop shadow of the whole tile
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sm = mask.filter(ImageFilter.GaussianBlur(px(18)))
    blk = Image.new("RGBA", (S, S), (0, 0, 0, 90)); sb = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sb.paste(blk, (0, px(14)), sm)
    base = Image.alpha_composite(base, sb)
    base = Image.alpha_composite(base, art)
    return base.resize((1024, 1024), Image.LANCZOS)

def menubar_glyph(state, scale=16):
    """Same geometry as MenuBarIcon.swift (18x18 pt cell). state: off | ready | recording"""
    W = 18 * scale
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    col = (255, 69, 58, 255) if state == "recording" else (255, 255, 255, 255)
    def p(v): return int(round(v * scale))
    def Y(y): return 18 - y                      # AppKit y-up -> image y-down
    cap = [p(6), p(Y(16.5)), p(12), p(Y(7))]
    if state == "off":
        d.rounded_rectangle(cap, radius=p(3), outline=col, width=p(1.3))
    else:
        d.rounded_rectangle(cap, radius=p(3), fill=col)
    def arc(cx, cy, r, a0, a1, w):
        for i in range(181):
            a = math.radians(a0 + (a1 - a0) * i / 180)
            x, yy = cx + r * math.cos(a), cy + r * math.sin(a)
            d.ellipse([p(x - w / 2), p(Y(yy) - w / 2), p(x + w / 2), p(Y(yy) + w / 2)], fill=col)
    arc(9, 9.5, 5.4, 180, 360, 1.4)
    for (x0, y0, x1, y1) in ((9, 4.1, 9, 2.0), (6.5, 2.0, 11.5, 2.0)):
        d.line([p(x0), p(Y(y0)), p(x1), p(Y(y1))], fill=col, width=p(1.4))
        for x, y in ((x0, y0), (x1, y1)):
            d.ellipse([p(x - .7), p(Y(y) - .7), p(x + .7), p(Y(y) + .7)], fill=col)
    return img

def preview(icon):
    sheet = Image.new("RGBA", (1500, 760), (24, 24, 30, 255))
    sheet.alpha_composite(icon.resize((512, 512), Image.LANCZOS), (60, 70))
    d = ImageDraw.Draw(sheet)
    # fake menu bars: dark (purple wallpaper) and light
    for i, color in enumerate(((52, 40, 92, 255), (236, 236, 242, 255))):
        y = 90 + i * 150
        d.rounded_rectangle([660, y, 1440, y + 110], radius=18, fill=color)
    states = ("off", "ready", "recording")
    for i, st in enumerate(states):
        g = menubar_glyph(st, 8)
        for row in (0, 1):
            gl = g.copy()
            if row == 1 and st != "recording":      # template tint on a light bar = black
                a = gl.split()[3]; gl = Image.new("RGBA", gl.size, (20, 20, 20, 255)); gl.putalpha(a)
            sheet.alpha_composite(gl.resize((96, 96), Image.LANCZOS), (720 + i * 220, 97 + row * 150))
    labels = ("server off", "ready", "recording")
    for i, t in enumerate(labels):
        d.text((730 + i * 220, 372), t, fill=(190, 190, 205, 255))
    d.text((60, 620), "WhisperBar", fill=(255, 255, 255, 255))
    d.text((60, 645), "Local speech-to-text in your menu bar", fill=(170, 170, 190, 255))
    return sheet

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    icon = app_icon()
    icon.save(os.path.join(OUT, "AppIcon-1024.png"))
    icon.save(os.path.join(OUT, "AppIcon.icns"), format="ICNS",
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    preview(icon).convert("RGB").save(os.path.join(OUT, "icon-preview.png"))
    print("ok")
