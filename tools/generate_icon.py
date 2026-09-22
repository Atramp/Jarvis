#!/usr/bin/env python3
"""生成 AI Quick Ask 应用图标 AppIcon.icns。

设计：蓝紫渐变圆角方块 + 白色 sparkle 四角星（呼应菜单栏 sparkles 符号）。
产物：Resources/AppIcon.icns
"""
import math
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "Resources")
ICONSET = os.path.join(RESOURCES, "AppIcon.iconset")
ICNS = os.path.join(RESOURCES, "AppIcon.icns")

SIZE = 1024
RADIUS = int(SIZE * 0.2237)  # macOS 图标 squircle 圆角比例

# 渐变三色（蓝 → 紫 → 粉），呼应 Siri 光晕
C0 = (59, 130, 246)    # #3B82F6 蓝
C1 = (139, 92, 246)    # #8B5CF6 紫
C2 = (236, 72, 153)    # #EC4899 粉


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def diagonal_gradient(size):
    """对角线性渐变：左上 C0 → 中 C1 → 右下 C2。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))  # 0 左上 → 1 右下
            if t < 0.5:
                c = lerp(C0, C1, t * 2)
            else:
                c = lerp(C1, C2, (t - 0.5) * 2)
            px[x, y] = c
    return img


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def sparkle_points(cx, cy, r_long, r_short):
    """四角星（sparkle）8 顶点：长半径沿四轴，短半径沿对角线。"""
    pts = []
    for i in range(8):
        ang = math.radians(i * 45)
        r = r_long if i % 2 == 0 else r_short
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


def draw_icon(size):
    img = diagonal_gradient(size)

    # 顶部高光（玻璃质感）
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for y in range(int(size * 0.45)):
        a = int(120 * (1 - y / (size * 0.45)))
        od.line([(0, y), (size, y)], fill=(255, 255, 255, a))
    img = Image.alpha_composite(img.convert("RGBA"), overlay)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # 主 sparkle 大四角星（略偏上居中），带柔和外发光
    cx, cy = size * 0.5, size * 0.48
    r_long, r_short = size * 0.30, size * 0.095
    # 外发光：多层半透明白色
    for glow_r, glow_a in [(r_long * 1.18, 36), (r_long * 1.08, 60)]:
        d.polygon(sparkle_points(cx, cy, glow_r, r_short * (glow_r / r_long)),
                  fill=(255, 255, 255, glow_a))
    d.polygon(sparkle_points(cx, cy, r_long, r_short), fill=(255, 255, 255, 255))

    # 右上小 sparkle
    sx, sy = size * 0.70, size * 0.30
    d.polygon(sparkle_points(sx, sy, size * 0.075, size * 0.024),
              fill=(255, 255, 255, 230))

    # 左下小圆点
    dx, dy = size * 0.28, size * 0.72
    d.ellipse([dx - size * 0.024, dy - size * 0.024,
               dx + size * 0.024, dy + size * 0.024],
              fill=(255, 255, 255, 210))

    # 用圆角方块遮罩裁切
    mask = rounded_rect_mask(size, RADIUS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(layer, (0, 0), mask)
    return out


def main():
    os.makedirs(ICONSET, exist_ok=True)
    master = draw_icon(SIZE)

    # macOS iconset 尺寸映射
    specs = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, s in specs.items():
        if s == SIZE:
            master.save(os.path.join(ICONSET, name))
        else:
            master.resize((s, s), Image.LANCZOS).save(os.path.join(ICONSET, name))

    os.system(f'/usr/bin/iconutil -c icns "{ICONSET}" -o "{ICNS}"')
    print(f"✅ 已生成 {ICNS} ({os.path.getsize(ICNS)} bytes)")


if __name__ == "__main__":
    main()
