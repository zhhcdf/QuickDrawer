# -*- coding: utf-8 -*-
"""生成 QuickDrawer 应用图标（src/QuickDrawer/assets/QuickDrawer.ico）。

设计与 TrayIcon.CreateTrayHIcon() 一致：圆角深色方块 + 三条抽屉线条。

**手工拼 ICO 容器**，不用 PIL 的 ICO 写出器：Pillow 在同时给 `sizes=` 和
`append_images=` 时只写第一帧（实测 9 帧只落 1 帧，493 字节），
而 ICO 的每个目录项必须对应一份独立的 PNG 数据。

尺寸 16/20/24/32/40/48/64/128/256 覆盖资源管理器各视图、任务栏、
Alt+Tab、属性对话框与高 DPI 缩放。
"""
import io
import os
import struct

from PIL import Image, ImageDraw

OUT_DIR = 'src/QuickDrawer/assets'
OUT = os.path.join(OUT_DIR, 'QuickDrawer.ico')

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

BG = (0x2D, 0x2D, 0x38, 0xFF)      # 与 TrayIcon.cs:113 Color.FromRgb(0x2D,0x2D,0x38) 一致
FG = (0xFF, 0xFF, 0xFF, 0xFF)

SS = 8  # 超采样倍数，画大再缩小得到抗锯齿


def render(size: int) -> Image.Image:
    s = size * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 圆角方块。半径按 TrayIcon 的 3/16 比例。
    radius = max(1, round(s * 3 / 16))
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=radius, fill=BG)

    # 三条抽屉线条，y 与 TrayIcon 一致：0.35 / 0.55 / 0.75。
    # 线宽随尺寸缩放（TrayIcon 固定 1.4px 只适合 16px；256px 下要跟着放大）。
    lw = max(1.4, s * 0.08)
    left = s * 3 / 16
    right = s - left
    mid_right = right - s * 3 / 16   # 中间那条右边多缩，对应 TrayIcon 的 (size-6)

    for y_ratio, x2 in ((0.35, right), (0.55, mid_right), (0.75, right)):
        y = s * y_ratio
        d.line([(left, y), (x2, y)], fill=FG, width=int(round(lw)))

    return img.resize((size, size), Image.LANCZOS)


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    return buf.getvalue()


def build_ico(frames) -> bytes:
    """frames: [(size, png_bytes), ...]"""
    count = len(frames)
    header = struct.pack('<HHH', 0, 1, count)   # reserved=0, type=1(icon), count
    entries = b''
    payload = b''
    offset = 6 + 16 * count
    for size, data in frames:
        # ICO 目录项里 256 必须写成 0（单字节放不下 256）
        dim = 0 if size >= 256 else size
        entries += struct.pack(
            '<BBBBHHII',
            dim, dim,          # width, height
            0,                 # color count (0 = truecolor)
            0,                 # reserved
            1,                 # planes
            32,                # bit count
            len(data),         # bytes in resource
            offset + len(payload),
        )
        payload += data
    return header + entries + payload


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    frames = [(n, png_bytes(render(n))) for n in SIZES]
    blob = build_ico(frames)
    with open(OUT, 'wb') as f:
        f.write(blob)
    print(f'written {OUT} ({len(blob)} bytes, {len(SIZES)} frames)')

    # 自检：重新解析，确认目录项数量与尺寸都对
    with open(OUT, 'rb') as f:
        d = f.read()
    _, typ, count = struct.unpack('<HHH', d[:6])
    assert typ == 1 and count == len(SIZES), (typ, count)
    for i in range(count):
        off = 6 + i * 16
        w, h, _, _, _, bpp, size, dataoff = struct.unpack('<BBBBHHII', d[off:off + 16])
        w = w or 256
        h = h or 256
        assert bpp == 32, bpp
        assert d[dataoff:dataoff + 8] == b'\x89PNG\r\n\x1a\n', f'frame {i} not PNG'
        print(f'  frame {i}: {w}x{h} bpp={bpp} {size} bytes')
    print('self-check OK')


if __name__ == '__main__':
    main()
