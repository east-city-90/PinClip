#!/usr/bin/env python3
"""PinClip 图标生成：App 图标（靛蓝圆角方块 + 白色图钉）+ 菜单栏模板图标。仅用标准库。"""
import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "Resources")


def write_png(path, width, height, pixel_fn):
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter: none
        for x in range(width):
            r, g, b, a = pixel_fn(x, y)
            rows += bytes((r, g, b, a))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def smoothstep(edge0, edge1, v):
    t = max(0.0, min(1.0, (v - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def rounded_rect_sdf(px, py, w, h, radius):
    """正距离近似（外正内负）"""
    cx = min(max(px, radius), w - radius)
    cy = min(max(py, radius), h - radius)
    return math.hypot(px - cx, py - cy) - radius


def app_icon(size):
    def fn(x, y):
        s = size
        # 背景：圆角方块（macOS 圆角约 22.4%）
        radius = s * 0.224
        d = rounded_rect_sdf(x + 0.5, y + 0.5, s, s, radius)
        bg_alpha = 1.0 - smoothstep(-0.7, 0.7, d)
        if bg_alpha <= 0:
            return (0, 0, 0, 0)
        # 垂直渐变 #6366f1 → #4338ca
        t = y / s
        r = round(99 + (67 - 99) * t)
        g = round(102 + (56 - 102) * t)
        b = round(241 + (202 - 241) * t)

        # 白色图钉（头部圆 + 锥形针身）
        u, v = (x + 0.5) / s, (y + 0.5) / s
        head_d = math.hypot(u - 0.5, v - 0.365) - 0.135
        head = 1.0 - smoothstep(-1.5 / s, 1.5 / s, head_d)
        # 针身：梯形从 (0.42,0.44) 收窄到 (0.5,0.83)
        if 0.44 <= v <= 0.83:
            half_width = 0.09 * (0.83 - v) / 0.39
            needle_d = abs(u - 0.5) - half_width
            needle = 1.0 - smoothstep(-1.5 / s, 1.5 / s, needle_d)
        else:
            needle = 0.0
        pin = max(head, needle)
        # 头部高光
        hl = 1.0 - smoothstep(-1.5 / s, 1.5 / s, math.hypot(u - 0.45, v - 0.32) - 0.045)
        rr = round(255 * (1 - (1 - 255 / 255) * 0))  # 白
        out_r = round(r * (1 - pin) + rr * pin)
        out_g = round(g * (1 - pin) + rr * pin)
        out_b = round(b * (1 - pin) + rr * pin)
        return (out_r, out_g, out_b, round(bg_alpha * 255))

    return fn


def tray_icon(size):
    """黑色图钉（模板图）"""
    def fn(x, y):
        u, v = (x + 0.5) / size, (y + 0.5) / size
        head_d = math.hypot(u - 0.5, v - 0.32) - 0.16
        head = 1.0 - smoothstep(-1.5 / size, 1.5 / size, head_d)
        if 0.40 <= v <= 0.88:
            half_width = 0.11 * (0.88 - v) / 0.48
            needle_d = abs(u - 0.5) - half_width
            needle = 1.0 - smoothstep(-1.5 / size, 1.5 / size, needle_d)
        else:
            needle = 0.0
        pin = max(head, needle)
        alpha = round(pin * 255)
        return (0, 0, 0, alpha)

    return fn


def main():
    os.makedirs(OUT, exist_ok=True)
    # App 图标源 + iconset（标准命名组合，iconutil 可直接转 icns）
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    write_png(os.path.join(OUT, "icon_1024.png"), 1024, 1024, app_icon(1024))
    for w, names in {
        16: ["icon_16x16.png"],
        32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"],
        128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: ["icon_512x512@2x.png"],
    }.items():
        for name in names:
            write_png(os.path.join(iconset, name), w, w, app_icon(w))
    # 菜单栏模板图标
    write_png(os.path.join(OUT, "tray.png"), 36, 36, tray_icon(36))
    print("icons generated at", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
