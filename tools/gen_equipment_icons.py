#!/usr/bin/env python3
# 生成 13 装备 × 5 稀有度 = 65 个 32×32 像素图标到 sprites/equipment
# 统一设计语言：军规深色卡底 + 稀有度边框 + 浅色图形 + 左下稀有度星标
import os
from PIL import Image, ImageDraw

# ===== 配色（对齐 UIPalette 军规像素）=====
BG_CARD = (16, 22, 14)      # #10160E 卡片底
BG_PANEL = (24, 34, 22)     # #182216 凹槽线
FG = (216, 224, 200)        # #D8E0C8 主图形（浅绿白）
AMBER = (239, 159, 39)
TEAL = (93, 202, 165)
RED = (226, 75, 74)
YELLOW = (250, 199, 117)

RARITY = {
    "white":  (180, 178, 169),
    "blue":   (93, 156, 236),
    "purple": (181, 127, 221),
    "pink":   (237, 147, 177),
    "gold":   (250, 199, 117),
}
RARITY_ORDER = ["white", "blue", "purple", "pink", "gold"]
SIZE = 32


def new_canvas(rarity_color):
    img = Image.new("RGB", (SIZE, SIZE), BG_CARD)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, SIZE - 1, SIZE - 1], outline=rarity_color, width=2)  # 稀有度边框
    d.rectangle([2, 2, SIZE - 3, SIZE - 3], outline=BG_PANEL, width=1)        # 内凹槽
    return img, d


def draw_stars(d, rarity_color, n):
    # 左下角竖排稀有度点（数量 = 稀有度 1-5）
    for i in range(n):
        y = 26 - i * 3
        d.rectangle([4, y, 5, y + 1], fill=rarity_color)


# ===== 各装备图形（安全区约 x6-26, y6-26）=====
def icon_engine(d, c):          # 引擎：推进器喷焰
    d.rectangle([13, 7, 18, 14], fill=FG)
    d.rectangle([14, 8, 17, 11], fill=BG_CARD)
    d.polygon([(11, 16), (20, 16), (15, 25)], fill=AMBER)
    d.polygon([(13, 16), (18, 16), (15, 21)], fill=YELLOW)


def icon_bearing(d, c):         # 轴承：齿轮
    for (x, y) in [(15, 6), (15, 24), (6, 15), (24, 15), (9, 9), (21, 9), (9, 21), (21, 21)]:
        d.rectangle([x - 1, y - 1, x + 1, y + 1], fill=FG)
    d.ellipse([11, 11, 20, 20], outline=FG, width=2)
    d.ellipse([14, 14, 17, 17], fill=BG_CARD)


def icon_main_gun(d, c):        # 主炮：斜炮管 + 炮口
    d.line([9, 23, 22, 10], fill=FG, width=3)
    d.rectangle([21, 8, 24, 11], fill=FG)
    d.rectangle([8, 22, 14, 25], fill=FG)


def icon_shell(d, c):           # 炮弹：尖头弹 + 尾翼
    d.polygon([(13, 11), (18, 11), (15, 5)], fill=FG)
    d.rectangle([13, 11, 18, 21], fill=FG)
    d.rectangle([13, 14, 18, 15], fill=BG_CARD)
    d.rectangle([11, 20, 13, 24], fill=FG)
    d.rectangle([18, 20, 20, 24], fill=FG)


def icon_armor(d, c):           # 装甲：盾牌
    d.polygon([(9, 7), (22, 7), (22, 15), (15, 24), (9, 15)], outline=FG)
    d.line([9, 7, 22, 7], fill=FG, width=2)
    d.line([15, 9, 15, 21], fill=FG)


def icon_shield(d, c):          # 护盾：能量罩 + 闪电
    d.ellipse([9, 8, 22, 21], outline=TEAL, width=2)
    d.polygon([(16, 9), (13, 15), (15, 15), (14, 20), (18, 13), (16, 13)], fill=TEAL)


def icon_diving(d, c):          # 潜渡：潜艇 + 水波
    d.rectangle([8, 17, 23, 21], fill=FG)
    d.rectangle([13, 12, 18, 17], fill=FG)
    d.rectangle([15, 8, 16, 12], fill=FG)
    d.rectangle([15, 8, 19, 9], fill=FG)
    d.line([7, 24, 11, 24], fill=TEAL)
    d.line([13, 25, 18, 25], fill=TEAL)
    d.line([20, 24, 24, 24], fill=TEAL)


def icon_stealth(d, c):         # 隐身：幽灵
    d.ellipse([10, 7, 21, 16], fill=FG)
    d.rectangle([10, 12, 21, 20], fill=FG)
    d.polygon([(10, 20), (13, 20), (11, 23)], fill=FG)
    d.polygon([(14, 20), (17, 20), (15, 23)], fill=FG)
    d.polygon([(18, 20), (21, 20), (19, 23)], fill=FG)
    d.rectangle([13, 11, 14, 12], fill=BG_CARD)
    d.rectangle([17, 11, 18, 12], fill=BG_CARD)


def icon_radar(d, c):           # 雷达：天线锅 + 波纹
    d.rectangle([11, 22, 20, 24], fill=FG)
    d.line([15, 22, 15, 14], fill=FG, width=2)
    d.polygon([(9, 15), (20, 8), (23, 13), (12, 18)], outline=FG)
    d.arc([15, 4, 25, 14], 0, 90, fill=FG)
    d.arc([18, 7, 25, 14], 0, 90, fill=FG)


def icon_emp(d, c):             # EMP：扩散环 + 闪电
    d.ellipse([8, 8, 23, 23], outline=FG, width=1)
    d.polygon([(16, 6), (12, 15), (15, 15), (13, 24), (20, 12), (16, 12)], fill=AMBER)


def icon_barrier(d, c):         # 壁垒：城墙 + 雉堞
    d.rectangle([8, 14, 23, 23], fill=FG)
    for x in (8, 14, 20):
        d.rectangle([x, 10, x + 3, 14], fill=FG)
    d.line([8, 18, 23, 18], fill=BG_CARD)
    d.line([13, 14, 13, 18], fill=BG_CARD)
    d.line([18, 18, 18, 23], fill=BG_CARD)


def icon_repair_machine(d, c):  # 抢修机：扳手
    d.line([10, 23, 19, 14], fill=FG, width=3)
    d.rectangle([19, 9, 22, 13], fill=FG)
    d.rectangle([22, 12, 24, 15], fill=FG)
    d.rectangle([20, 11, 22, 13], fill=BG_CARD)


def icon_energy_station(d, c):  # 能量站：电池 + 闪电
    d.rectangle([10, 9, 21, 23], outline=FG, width=2)
    d.rectangle([14, 6, 17, 9], fill=FG)
    d.rectangle([12, 16, 19, 21], fill=TEAL)
    d.polygon([(15, 11), (13, 15), (15, 15), (14, 18), (17, 14), (15, 14)], fill=YELLOW)


ICONS = {
    "engine": icon_engine, "bearing": icon_bearing, "main_gun": icon_main_gun,
    "shell": icon_shell, "armor": icon_armor, "shield": icon_shield,
    "diving": icon_diving, "stealth": icon_stealth, "radar": icon_radar,
    "emp": icon_emp, "barrier": icon_barrier,
    "repair_machine": icon_repair_machine, "energy_station": icon_energy_station,
}

OUT = "sprites/equipment"
os.makedirs(OUT, exist_ok=True)
count = 0
for name, fn in ICONS.items():
    for ri, rname in enumerate(RARITY_ORDER, start=1):
        rc = RARITY[rname]
        img, d = new_canvas(rc)
        fn(d, rc)
        draw_stars(d, rc, ri)
        img.save(os.path.join(OUT, f"{name}_{rname}.png"))
        count += 1
print(f"generated {count} icons -> {OUT}")
