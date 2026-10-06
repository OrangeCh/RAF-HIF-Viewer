#!/usr/bin/env python3
"""生成 DMG 的背景图。

用法： python3 Tools/make-dmg-background.py

注意字体：本机 **没有** /System/Library/Fonts/PingFang.ttc，而 PIL 找不到字体时
会静默退回默认位图字体 —— 结果是中文全渲染成方框（豆腐块），而且不报错。
所以这里逐个试候选字体，并用「两个不同汉字是否渲染成同一张图」来检测豆腐块。
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 660, 500
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "Resources", "dmg")

FONT_CANDIDATES = [
    ("/System/Library/Fonts/STHeiti Medium.ttc", 0),
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
    ("/System/Library/Fonts/STHeiti Medium.ttc", 0),
    ("/System/Library/Fonts/STHeiti Light.ttc", 0),
    ("/System/Library/Fonts/Supplemental/Songti.ttc", 0),
    ("/Library/Fonts/Arial Unicode.ttf", None),
]


def pick_font(size):
    """挑一个能正常渲染中文的字体；返回 (ImageFont, 字体名)"""
    for path, index in FONT_CANDIDATES:
        if not os.path.exists(path):
            continue
        try:
            f = (ImageFont.truetype(path, size) if index is None
                 else ImageFont.truetype(path, size, index=index))
        except Exception:
            continue
        # 豆腐块检测：两个不同汉字若渲染结果完全相同，说明是 .notdef 方块
        def render(text):
            im = Image.new("L", (300, size + 20), 0)
            ImageDraw.Draw(im).text((4, 4), text, font=f, fill=255)
            return im.tobytes()
        if render("把左") != render("边的"):
            return f, os.path.basename(path)
    print("❌ 找不到能渲染中文的字体，背景图里的中文会变成方框", file=sys.stderr)
    sys.exit(1)


# 图标在窗口里的位置（必须和 make-dmg.sh 里 AppleScript 设的一致）
ICON_CENTER_Y = 200     # 两个主图标
ICON_SIZE = 104
APP_ICON_X = 170
APPS_ICON_X = 490


def make(scale, font_name_holder):
    w, h = W * scale, H * scale
    im = Image.new("RGB", (w, h), (30, 30, 32))
    d = ImageDraw.Draw(im)

    # 浅色底。
    #
    # 关键：Finder 渲染的**图标标签是黑色**（实测亮度 5–7），它不会跟着背景
    # 图变白。所以背景必须是浅色，否则标签直接和背景融成一片看不见。
    # 这条是被用户骂出来的 —— 我之前只量了自己画在背景里的字，
    # 没量 Finder 画的那行标签。
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)],
               fill=(int(250 - 20 * t), int(250 - 20 * t), int(253 - 20 * t)))

    # 中间的箭头，高度对准图标中心（图标在 y=200，窗口高 500 → 0.40）
    #
    # 横向区间必须避开两个图标，否则箭头两端会被图标压住：
    #   App 图标中心 x=170、图标 104px → 右边缘约 222
    #   Applications 中心 x=490          → 左边缘约 438
    # 所以箭头只画在 235…425 之间。
    cy = int(h * 0.40)
    x0, x1 = int(w * 0.356), int(w * 0.644)
    shaft = max(3, int(5 * scale))
    hw, hh = int(20 * scale), int(18 * scale)
    arrow = (58, 124, 222)
    d.rectangle([x0, cy - shaft, x1 - hh, cy + shaft], fill=arrow)
    d.polygon([(x1 - hh, cy - hw), (x1, cy), (x1 - hh, cy + hw)], fill=arrow)

    f1, used = pick_font(27 * scale)
    f2, _ = pick_font(16 * scale)
    font_name_holder.append(used)

    def center(text, y, f, fill):
        bb = d.textbbox((0, 0), text, font=f)
        d.text(((w - (bb[2] - bb[0])) / 2, y), text, font=f, fill=fill)

    # 文字要够亮。深色底上用近白色，副标题也别低于 185 灰阶，
    # 否则在 Finder 窗口里会糊成一片看不清。
    center("把左边的 App 拖进右边的 Applications", int(h * 0.078), f1, (24, 24, 30))
    center("被系统拦截？看下方的说明文件",
           int(h * 0.078) + 44 * scale, f2, (78, 78, 90))

    name = "background@2x.png" if scale == 2 else "background.png"
    os.makedirs(OUT_DIR, exist_ok=True)
    im.save(os.path.join(OUT_DIR, name))
    return name, im.size


def wcag(fg, bg):
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    def lum(c):
        return 0.2126*lin(c[0]) + 0.7152*lin(c[1]) + 0.0722*lin(c[2])
    a, b = lum(fg), lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def main():
    holder = []
    for scale in (1, 2):
        name, size = make(scale, holder)
        print(f"  ✅ {name}  {size[0]}×{size[1]}")
    print(f"  使用字体: {holder[0]}")

    # 自检 1：标称颜色的对比度（WCAG AA 正文要 4.5:1）
    bg_top = (250, 250, 253)
    for label, fg in (("标题", (24, 24, 30)), ("副标题", (78, 78, 90))):
        r = wcag(fg, bg_top)
        print(f"  {'✅' if r >= 4.5 else '❌'} {label} 标称对比度 {r:.1f}:1")

    # 自检 2（更重要）：量**渲染后**的实际峰值亮度。
    # 细笔画小字号经过抗锯齿，峰值会比标称颜色暗一大截 ——
    # 之前标称 188 的副标题，实测峰值只有 130，看着就是糊的。
    im = Image.open(os.path.join(OUT_DIR, "background.png")).convert("L")
    for label, box, need in (("标题", (100, 30, 560, 70), 60),
                             ("副标题", (100, 78, 560, 106), 90)):
        darkest = min(im.crop(box).getdata())
        print(f"  {'✅' if darkest <= need else '❌'} {label} 渲染后最深亮度 {darkest}"
              + ("" if darkest <= need else f"（应 ≤{need}，否则发灰）"))

    # 自检 3（最关键）：Finder 的图标标签是黑的，背景必须够亮，
    # 否则「黑字压深底」直接看不见 —— 这正是之前出过的错。
    bg_bottom = (230, 230, 233)
    r = wcag((5, 5, 5), bg_bottom)
    print(f"  {'✅' if r >= 4.5 else '❌'} Finder 黑色图标标签 vs 最暗处背景 对比度 {r:.1f}:1")


if __name__ == "__main__":
    main()
