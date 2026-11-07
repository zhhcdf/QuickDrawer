"""B 方案 + 黄色右条：出几档黄色对比，顺便验证 16px 可辨认度。

黄色在深色底上的难点：
- 太亮（#FFD400）会刺眼且在浅色任务栏上消失
- 太暗（#A87600）会显得脏、像"警告"
- 饱和度低（#C9A94E）会发灰、像褪色
所以在 HSL 里固定色相约 45°（金黄），扫明度 52%~64%、饱和度 82%~100% 共 6 档。
"""
import colorsys
import os

from PIL import Image, ImageDraw

S = 1024
OUT = os.path.join(os.environ["TEMP"], "qd_icons3")
os.makedirs(OUT, exist_ok=True)

BG_TOP = (43, 48, 64)
BG_BOT = (26, 30, 42)
INK = (247, 249, 252)
DIM = (150, 160, 180)


def hx(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h / 360.0, l / 100.0, s / 100.0)
    return (int(r * 255), int(g * 255), int(b * 255))


def name_of(c):
    return "#%02X%02X%02X" % c


def canvas():
    img = Image.new("RGB", (S, S), BG_TOP)
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    return img


MASK = Image.new("L", (S, S), 0)
ImageDraw.Draw(MASK).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * .225), fill=255)


def icon_b(barcolor):
    """B 方案：右侧竖条 + 三条白线（第三条灰）。"""
    img = canvas()
    d = ImageDraw.Draw(img)
    x0 = int(S * .665)
    d.rectangle([x0, 0, S, S], fill=barcolor)
    for i, (y, w) in enumerate(((.315, .40), (.475, .40), (.635, .24))):
        h = int(S * .105)
        yy = int(S * y)
        d.rounded_rectangle([int(S * .125), yy, int(S * .125) + int(S * w), yy + h],
                            radius=h // 2, fill=INK if i < 2 else DIM)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), MASK)
    return out


# 6 档黄色候选（色相 45°，金黄）
YELLOWS = [
    ("Y1_琥珀_52_90", hx(45, 90, 52)),
    ("Y2_金黄_56_95", hx(45, 95, 56)),
    ("Y3_亮金_60_96", hx(46, 96, 60)),
    ("Y4_柠檬_62_100", hx(50, 100, 62)),
    ("Y5_橙金_50_88", hx(40, 88, 50)),
    ("Y6_淡金_66_90", hx(48, 90, 66)),
]


def luminance(c):
    def f(v):
        v = v / 255.0
        return v / 12.92 if v <= .03928 else ((v + .055) / 1.055) ** 2.4
    return .2126 * f(c[0]) + .7152 * f(c[1]) + .0722 * f(c[2])


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + .05) / (lo + .05)


def main():
    tiles = []
    print(f"{'name':<18} {'hex':<9} {'vs白线':<7} {'vs深底':<7} {'vs浅底#F2F3F6'}")
    for nm, col in YELLOWS:
        im = icon_b(col)
        im.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, nm + ".png"))
        tiles.append((nm, col, im))
        print(f"{nm:<18} {name_of(col):<9} "
              f"{contrast(col, INK):<7.2f} {contrast(col, BG_BOT):<7.2f} "
              f"{contrast(col, (242, 243, 246)):.2f}")

    # 对照表
    CW, CH = 300, 400
    cols = 3
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (CW * cols, CH * rows), (248, 249, 252))
    d = ImageDraw.Draw(sheet)
    for i, (nm, col, im) in enumerate(tiles):
        x = (i % cols) * CW + 20
        y = (i // cols) * CH + 16
        big = im.resize((200, 200), Image.LANCZOS)
        sheet.paste(big, (x, y), big)
        d.text((x, y + 208), nm, fill=(60, 64, 78))
        d.text((x, y + 228), name_of(col), fill=(60, 64, 78))
        cx = x + 210
        for j, s in enumerate((64, 32)):
            sm = im.resize((s, s), Image.LANCZOS)
            sheet.paste(sm, (cx, y + j * 76), sm)
        s16 = im.resize((16, 16), Image.LANCZOS)
        sheet.paste(s16.resize((80, 80), Image.NEAREST), (cx, y + 160), s16.resize((80, 80), Image.NEAREST))
        sheet.paste(s16, (cx, y + 250), s16)
    sheet.save(os.path.join(OUT, "sheet.png"))
    print("\nsheet:", os.path.join(OUT, "sheet.png"))


if __name__ == "__main__":
    main()
