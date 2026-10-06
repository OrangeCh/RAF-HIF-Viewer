#!/usr/bin/env python3
"""生成 App 图标。

设计：一张照片左右两半渲染不同（暖色 vs 冷色），中间一道对比滑杆 ——
这正是这个工具在做的事：把同一张照片的两种渲染摆在一起看。

**必须铺满整张 1024×1024 画布，四周不留透明边。**

这一点是被系统「教」出来的：如果按老规范把圆角矩形缩到 824×824 居中留白，
macOS 27 会把它当成旧式图标做自动加工 —— 套一层浅色底板、再把图案缩小塞进去，
呈现出来就是一个白色大方块里嵌着个小图标。

铺满之后，系统就原样使用了，观感与 Moonlight、FolderSync 这类同样只用 .icns 的
第三方 App 一致（它们外面那圈浅灰边是系统的正常渲染，不是缺陷）。

用法： python3 Tools/make-app-icon.py
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_ICNS = os.path.join(ROOT, "Resources", "AppIcon.icns")

S = 1024                          # 画布边长
PAD = 0                           # 不吃留白，铺满
BOX = S - PAD * 2                 # 1024
RADIUS = int(S * 0.2237)          # macOS 的圆角比例

WARM_TOP, WARM_BOT = (240, 176, 92), (198, 118, 52)
COOL_TOP, COOL_BOT = (108, 168, 232), (46, 106, 184)


def gradient(size, top, bottom):
    w, h = size
    im = Image.new("RGB", size)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)],
               fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return im


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                        radius=radius, fill=255)
    return m


def build_master():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ① 底板：深蓝灰渐变，铺满画布（系统自己会加投影和外形）
    plate = gradient((BOX, BOX), (48, 57, 76), (24, 29, 41)).convert("RGBA")
    plate.putalpha(rounded_mask((BOX, BOX), RADIUS))
    canvas.paste(plate, (PAD, PAD), plate)

    # ② 顶部高光，让底板有体积感
    hl = Image.new("L", (BOX, BOX), 0)
    ImageDraw.Draw(hl).rounded_rectangle([0, 0, BOX - 1, int(BOX * 0.5)],
                                         radius=RADIUS, fill=46)
    hl = hl.filter(ImageFilter.GaussianBlur(22))
    canvas.paste(Image.new("RGBA", (BOX, BOX), (255, 255, 255, 255)), (PAD, PAD), hl)

    # ③ 中间的「照片」：左暖右冷
    cw, ch = 560, 424
    cx, cy = (S - cw) // 2, (S - ch) // 2 + 6
    card = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    card.paste(gradient((cw // 2, ch), WARM_TOP, WARM_BOT).convert("RGBA"), (0, 0))
    card.paste(gradient((cw - cw // 2, ch), COOL_TOP, COOL_BOT).convert("RGBA"),
               (cw // 2, 0))
    card.putalpha(rounded_mask((cw, ch), 44))

    # 照片描边
    ImageDraw.Draw(card).rounded_rectangle([1, 1, cw - 2, ch - 2], radius=44,
                                           outline=(255, 255, 255, 200), width=5)
    canvas.paste(card, (cx, cy), card)

    # ④ 对比滑杆：竖白条 + 中间旋钮
    bw = 13
    bar = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bar)
    # 上下与照片齐平 —— 之前多探出 6px，渲染出来像两根戳出来的白刺
    bd.rectangle([S // 2 - bw // 2, cy, S // 2 + bw // 2, cy + ch],
                 fill=(255, 255, 255, 242))
    knob_r = 52
    bd.ellipse([S // 2 - knob_r, S // 2 + 6 - knob_r,
                S // 2 + knob_r, S // 2 + 6 + knob_r],
               fill=(255, 255, 255, 252))
    canvas.alpha_composite(bar)

    # 旋钮上画一对左右箭头，点明「对比」
    ad = ImageDraw.Draw(canvas)
    kx, ky = S // 2, S // 2 + 6
    ink = (36, 44, 60, 255)
    for sign in (-1, 1):
        x0 = kx + sign * 10
        ad.polygon([(x0, ky - 17), (x0, ky + 17), (x0 + sign * 17, ky)], fill=ink)
    return canvas


def main():
    master = build_master()
    tmp = os.path.join(ROOT, "build", "AppIcon.iconset")
    os.makedirs(tmp, exist_ok=True)

    # macOS 要求的全套尺寸
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for size, scale in specs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(tmp, name))
    print(f"  ✅ 已生成 {len(specs)} 个尺寸到 build/AppIcon.iconset")

    os.makedirs(os.path.dirname(OUT_ICNS), exist_ok=True)
    r = subprocess.run(["iconutil", "-c", "icns", tmp, "-o", OUT_ICNS],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ❌ iconutil 失败: {r.stderr.strip()}")
        return 1
    print(f"  ✅ {os.path.relpath(OUT_ICNS, ROOT)}"
          f"  ({os.path.getsize(OUT_ICNS) // 1024} KB)")
    master.resize((256, 256), Image.LANCZOS).save("/tmp/icon-preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
