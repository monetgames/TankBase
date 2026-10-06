#!/usr/bin/env python3
"""《坦克基地》新手指引剧情插画生成器
逐像素程序化生成 6 幕 256x128 像素插画。
策略：真实游戏 sprite 作"图章"合成 + 程序化绘制场景，
色板严格取自 UIPalette（military_theme）与现有素材采样值，
保证插画与游戏内视觉 100% 同源。
用法: python tools/gen_story_art.py
输出: sprites/story/intro_01.png ~ intro_06.png (256x128)
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SP = os.path.join(ROOT, "sprites")
OUT = os.path.join(SP, "story")
W, H = 256, 128

# ===== 色板：UIPalette（scripts/ui/ui_palette.gd）=====
BG_DEEP = "#0C120A"
BG_PANEL = "#182216"
BG_CARD = "#10160E"
BG_PRESSED = "#2E3D28"
BORDER = "#4A5D3A"
BORDER_HI = "#6B8A55"
BORDER_DIM = "#2E3D28"
GREEN = "#97C459"
GREEN_DARK = "#3B6D11"
AMBER = "#EF9F27"
AMBER_DARK = "#BA7517"
TEAL = "#5DCAA5"
RED = "#E24B4A"
YELLOW = "#FAC775"
TEXT_MAIN = "#D8E0C8"
TEXT_MUTED = "#7A8570"
# 稀有度
RAR = ["#B4B2A9", "#5D9CEC", "#B57FDD", "#ED93B1", "#FAC775"]  # 白蓝紫粉金

# ===== 色板：素材采样（见下采样脚本输出）=====
# 地形
BRICK_D, BRICK_M, BRICK_L = "#301810", "#8A442E", "#AC6244"
STONE_D, STONE_M, STONE_L, STONE_H = "#42403A", "#5C5A52", "#828076", "#A09E94"
WATER_D, WATER_M, WATER_L = "#173A56", "#2E6088", "#6AA8C8"
GRASS_D, GRASS_M, GRASS_2, GRASS_L = "#14260E", "#284216", "#50742C", "#709840"
ICE_D, ICE_M, ICE_L = "#96BECE", "#ACD2DE", "#CAE6F0"

_cache = {}


def rgb(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), 255)


def dim(color, f):
    r, g, b, a = color
    return (int(r * f), int(g * f), int(b * f), a)


def load(rel, gray_tint=None):
    """加载 sprite 并缓存；gray_tint 可将彩色 icon 染成指定灰度色。"""
    key = (rel, gray_tint)
    if key in _cache:
        return _cache[key]
    im = Image.open(os.path.join(SP, rel)).convert("RGBA")
    if gray_tint is not None:
        px = im.load()
        t = rgb(gray_tint)
        for y in range(im.height):
            for x in range(im.width):
                r, g, b, a = px[x, y]
                lum = (r * 30 + g * 59 + b * 11) // 100
                px[x, y] = (t[0] * lum // 255, t[1] * lum // 255, t[2] * lum // 255, a)
    _cache[key] = im
    return im


def sprite(rel, tint=None):
    return load(rel, tint)


class Art:
    def __init__(self):
        self.im = Image.new("RGBA", (W, H), rgb(BG_DEEP))
        self.px = self.im.load()

    # ---- 基础 ----
    def p(self, x, y, c):
        if 0 <= x < W and 0 <= y < H:
            self.px[x, y] = c

    def rect(self, x, y, w, h, c):
        for j in range(h):
            for i in range(w):
                self.p(x + i, y + j, c)

    def frame(self, x, y, w, h, c):
        for i in range(w):
            self.p(x + i, y, c)
            self.p(x + i, y + h - 1, c)
        for j in range(h):
            self.p(x, y + j, c)
            self.p(x + w - 1, y + j, c)

    def dash_frame(self, x, y, w, h, c, on=3, off=2):
        for i in range(w):
            if (i // off) % 2 == 0:
                self.p(x + i, y, c)
                self.p(x + i, y + h - 1, c)
        for j in range(h):
            if (j // off) % 2 == 0:
                self.p(x, y + j, c)
                self.p(x + w - 1, y + j, c)

    def dash_line(self, x0, y0, x1, y1, c, on=3, off=2):
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        i = 0
        while True:
            if (i // off) % 2 == 0:
                self.p(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x0 += sx
            if e2 < dx:
                err += dx
                y0 += sy
            i += 1

    def disc(self, cx, cy, r, c):
        for j in range(-r, r + 1):
            for i in range(-r, r + 1):
                if i * i + j * j <= r * r:
                    self.p(cx + i, cy + j, c)

    def stamp(self, rel, x, y, scale=1, dimf=1.0, tint=None):
        """把游戏 sprite 图章到画布 (x,y) 左上角；dimf<1 整体压暗。"""
        s = sprite(rel, tint)
        if scale != 1:
            s = s.resize((s.width * scale, s.height * scale), Image.NEAREST)
        if dimf != 1.0:
            s = s.copy()
            p2 = s.load()
            for j in range(s.height):
                for i in range(s.width):
                    r, g, b, a = p2[i, j]
                    p2[i, j] = (int(r * dimf), int(g * dimf), int(b * dimf), a)
        self.im.alpha_composite(s, (x, y))

    # ---- 复合元素 ----
    def tank(self, x, y, body_rel, turret_rel, rot=0, t_rot=0, scale=1, dimf=1.0):
        """车体 + 炮塔合成坦克；rot 为 90 的倍数（车体四向）。"""
        body = sprite(body_rel).crop((0, 0, 32, 32))  # sheet 取第 0 帧
        if rot:
            body = body.rotate(rot, resample=Image.NEAREST)
        tur = sprite(turret_rel)
        if t_rot:
            tur = tur.rotate(t_rot, resample=Image.NEAREST, expand=True)
        bx, by = x, y  # x,y 即最终画布坐标（scale 只作用于 sprite 尺寸）
        self.im.alpha_composite(body.resize((32 * scale,) * 2, Image.NEAREST), (bx, by))
        if scale != 1:
            tur = tur.resize((tur.width * scale, tur.height * scale), Image.NEAREST)
        ox = (32 * scale - tur.width) // 2
        oy = (32 * scale - tur.height) // 2
        self.im.alpha_composite(tur, (bx + ox, by + oy))

    def tile_brick(self, x, y, s=16):
        self.rect(x, y, s, s, rgb(BRICK_D))
        self.rect(x, y, s, 2, rgb(BRICK_L))
        self.rect(x, y + 2, s, 2, rgb(BRICK_M))
        self.rect(x + 3, y + 4, s - 6, 3, rgb(BRICK_D))
        self.rect(x, y + 7, s, 2, rgb(BRICK_L))
        self.rect(x, y + 9, s, 2, rgb(BRICK_M))
        self.rect(x + 8, y + 11, s - 8, 3, rgb(BRICK_D))
        self.rect(x, y + 11, 8, 3, rgb(BRICK_M))

    def tile_stone(self, x, y, s=16):
        self.rect(x, y, s, s, rgb(STONE_M))
        self.rect(x, y, s, 3, rgb(STONE_H))
        self.rect(x, y, 3, s, rgb(STONE_H))
        self.rect(x, y + s - 3, s, 3, rgb(STONE_D))
        self.rect(x + s - 3, y, 3, s, rgb(STONE_D))
        self.rect(x + 5, y + 5, 6, 4, rgb(STONE_D))

    def tile_water(self, x, y, s=16):
        self.rect(x, y, s, s, rgb(WATER_D))
        for j in range(0, s, 4):
            self.rect(x, y + j + 1, s // 2, 1, rgb(WATER_M))
            self.rect(x + s // 2, y + j + 3, s // 2, 1, rgb(WATER_M))

    def tile_grass(self, x, y, s=16):
        self.rect(x, y, s, s, rgb(GRASS_M))
        for j in range(0, s, 2):
            for i in range(0, s, 2):
                v = (i * 7 + j * 13 + x * 3 + y * 5) % 4
                if v == 0:
                    self.p(x + i, y + j, rgb(GRASS_D))
                elif v == 1:
                    self.p(x + i, y + j, rgb(GRASS_2))
                elif v == 2:
                    self.p(x + i, y + j + 1, rgb(GRASS_D))

    def tile_ice(self, x, y, s=16):
        self.rect(x, y, s, s, rgb(ICE_M))
        self.rect(x, y, s // 2, s // 2, rgb(ICE_L))
        self.rect(x + s // 2, y + s // 2, s // 2, s // 2, rgb(ICE_D))
        self.p(x + 3, y + 3, (255, 255, 255, 255))
        self.p(x + 11, y + 11, (255, 255, 255, 255))

    def arrow(self, x, y, dx, dy, c, head=4):
        """从 (x,y) 沿 (dx,dy) 单位向量画虚线箭头，长度 len_px。"""
        pass

    def arrow_to(self, x0, y0, x1, y1, c, on=4, off=3, head=4):
        self.dash_line(x0, y0, x1, y1, c, on, off)
        # 箭头头（根据方向画 V 形）
        dx, dy = x1 - x0, y1 - y0
        ln = max(1, (dx * dx + dy * dy) ** 0.5)
        ux, uy = dx / ln, dy / ln
        for k in range(head):
            self.p(x1 - int(ux * k) - int(-uy * k * 0.9), y1 - int(uy * k) - int(ux * k * 0.9), c)
            self.p(x1 - int(ux * k) - int(uy * k * 0.9), y1 - int(uy * k) - int(-ux * k * 0.9), c)

    def boom(self, cx, cy, r, main=rgb(YELLOW)):
        """爆炸星形：中心白 -> 主色 -> 暗色尖刺。"""
        self.disc(cx, cy, max(2, r - 3), (255, 255, 255, 255))
        self.disc(cx, cy, r, main)
        for ang in range(0, 360, 45):
            dx = [1, 1, 0, -1, -1, -1, 0, 1][ang // 45]
            dy = [0, 1, 1, 1, 0, -1, -1, -1][ang // 45]
            for k in range(r, r + 4):
                self.p(cx + dx * k, cy + dy * k, dim(main, 0.55))

    def scanlines(self, strength=0.82):
        """CRT 军用显示屏扫描线：每 3 行压暗。"""
        p = self.im.load()
        dk = (0, 0, 0)
        for y in range(0, H, 3):
            for x in range(W):
                r, g, b, a = p[x, y]
                p[x, y] = (int(r * strength), int(g * strength), int(b * strength), a)

    def grid(self, step=16, c=BORDER_DIM):
        for x in range(0, W, step):
            for y in range(H):
                self.p(x, y, rgb(c))
        for y in range(0, H, step):
            for x in range(W):
                self.p(x, y, rgb(c))

    def save(self, name):
        os.makedirs(OUT, exist_ok=True)
        path = os.path.join(OUT, name)
        self.im.save(path)
        print("生成", os.path.relpath(path, ROOT))


# ============ 01 战区态势 ============
def scene_01():
    a = Art()
    a.grid(16)
    # 地形散布（避开中心区）
    a.tile_brick(24, 56)
    a.tile_brick(40, 76)
    a.tile_stone(64, 24)
    a.tile_stone(176, 96)
    a.tile_water(48, 96)
    a.tile_water(64, 96)
    a.tile_grass(96, 16)
    a.tile_grass(136, 96)
    a.tile_grass(208, 64)
    # 敌方基地四角（普通灰 x2 / 精英琥珀 / BOSS 红）
    a.stamp("base_enemy.png", 8, 8)
    a.stamp("base_enemy_elite.png", 216, 8)
    a.stamp("base_enemy.png", 8, 88)
    a.stamp("base_enemy_boss.png", 216, 88)
    # 红色进军箭头 -> 中心
    ctr = (127, 63)
    a.arrow_to(44, 28, ctr[0] - 18, ctr[1] - 18, rgb(RED))
    a.arrow_to(212, 28, ctr[0] + 18, ctr[1] - 18, rgb(RED))
    a.arrow_to(44, 96, ctr[0] - 18, ctr[1] + 18, rgb(RED))
    a.arrow_to(212, 96, ctr[0] + 18, ctr[1] + 18, rgb(RED))
    # 我方基地：绿光 2 圈同心框 + 基地
    a.frame(104, 40, 48, 48, dim(rgb(GREEN), 0.55))
    a.frame(108, 44, 40, 40, dim(rgb(GREEN), 0.85))
    a.stamp("base_player.png", 112, 48)
    a.scanlines()
    a.save("intro_01.png")


# ============ 02 你的岗位 ============
def scene_02():
    a = Art()
    a.rect(0, 0, W, H, rgb(BG_CARD))
    # 中央车间平台
    a.rect(80, 12, 96, 88, rgb(BG_PRESSED))
    a.frame(80, 12, 96, 88, rgb(BORDER))
    a.frame(82, 14, 92, 84, rgb(BORDER_DIM))
    # 坦克 2x 特写（车体朝上）
    a.tank(96, 26, "tank_player_body_sheet.png", "tank_player_turret.png", scale=2)
    # 8 个装备槽虚框（左 4 右 4）
    for j, sy in enumerate([14, 36, 58, 80]):
        for sx, side in [(36, -1), (204, 1)]:
            a.dash_frame(sx, sy, 16, 16, rgb(BORDER_HI))
            a.p(sx + 8, sy + 8, rgb(BORDER))
            # 连接线
            ex = 96 if side < 0 else 160
            a.dash_line(sx + 16, sy + 8, ex, sy + 8, rgb(BORDER), on=2, off=3)
    # 底部：1 实 + 3 幽灵（无备用车）
    ghost = sprite("tank_player_body_sheet.png").crop((0, 0, 32, 32)).resize((16, 16), Image.NEAREST)
    for i in range(4):
        gx = 88 + i * 22
        gy = 104
        g = ghost.copy()
        if i > 0:
            p2 = g.load()
            for yy in range(16):
                for xx in range(16):
                    r, gg, b, aa = p2[xx, yy]
                    p2[xx, yy] = (r // 4, gg // 4, b // 4, aa)
        a.im.alpha_composite(g, (gx, gy))
        if i > 0:
            a.dash_line(gx, gy, gx + 15, gy + 15, dim(rgb(RED), 0.9), on=1, off=1)
            a.dash_line(gx + 15, gy, gx, gy + 15, dim(rgb(RED), 0.9), on=1, off=1)
    # 实车下方绿色三角（选中标记）
    a.p(95, 101, rgb(GREEN))
    a.p(96, 101, rgb(GREEN))
    a.p(94, 100, rgb(GREEN))
    a.p(97, 100, rgb(GREEN))
    a.p(96, 99, rgb(GREEN))
    a.scanlines(0.88)
    a.save("intro_02.png")


# ============ 03 交战规则 ============
def scene_03():
    a = Art()
    # 地面
    a.rect(0, 0, W, H, rgb(BG_DEEP))
    # 战场地形
    a.tile_brick(0, 112)
    a.tile_brick(16, 112)
    a.tile_brick(32, 112)
    a.tile_grass(200, 48)
    a.tile_grass(216, 48)
    a.tile_stone(96, 112)
    a.tile_stone(112, 112)
    # 敌方基地（右上）+ 出生光标
    a.dash_frame(195, 4, 42, 42, rgb(AMBER))
    a.stamp("base_enemy.png", 198, 8)
    # 产兵队列：3 辆敌坦克沿对角线推进
    a.tank(152, 36, "tank_enemy.png", "tank_enemy_turret.png", t_rot=-135)
    a.tank(108, 58, "tank_enemy.png", "tank_enemy_turret.png", t_rot=-135)
    a.tank(64, 80, "tank_enemy.png", "tank_enemy_turret.png", t_rot=-90)
    # 玩家坦克（左下）炮塔朝右平射
    a.tank(16, 80, "tank_player_body_sheet.png", "tank_player_turret.png", t_rot=-90)
    # 炮弹轨迹 + 命中爆炸（同一水平线）
    for k in range(5):
        a.p(52 + k * 3, 95, rgb(YELLOW if k % 2 else TEXT_MAIN))
    a.boom(68, 95, 5)
    # 地面金币（3 枚 16x16）
    for cx, cy in [(28, 36), (52, 20), (124, 96)]:
        c = sprite("coin.png").resize((16, 16), Image.NEAREST)
        a.im.alpha_composite(c, (cx, cy))
    a.scanlines()
    a.save("intro_03.png")


# ============ 04 后勤：构筑 ============
def scene_04():
    a = Art()
    a.rect(0, 0, W, H, rgb(BG_PANEL))
    # 车间台面
    a.rect(0, 108, W, 20, rgb(BG_CARD))
    for x in range(0, W, 16):
        a.p(x, 108, rgb(BORDER_DIM))
        a.p(x + 1, 108, rgb(BORDER))
    a.rect(0, 107, W, 1, rgb(BORDER))
    # 左：坦克 32x32
    a.rect(8, 32, 52, 52, rgb(BG_CARD))
    a.frame(8, 32, 52, 52, rgb(BORDER))
    a.tank(18, 42, "tank_player_body_sheet.png", "tank_player_turret.png")
    # 分隔
    for y in range(8, 104, 4):
        a.p(76, y, rgb(BORDER_DIM))
    # 上：4 件必装装备图标
    must = ["engine_white.png", "bearing_white.png", "main_gun_white.png", "shell_white.png"]
    for i, n in enumerate(must):
        a.dash_frame(88 + i * 30, 10, 24, 24, rgb(BORDER_HI))
        ic = sprite("equipment/" + n).resize((24, 24), Image.NEAREST)
        a.im.alpha_composite(ic, (88 + i * 30, 10))
    # 中：稀有度色阶（白->金）
    for i, c in enumerate(RAR):
        a.rect(88 + i * 26, 48, 18, 18, dim(rgb(c), 0.92))
        a.frame(88 + i * 26, 48, 18, 18, dim(rgb(c), 0.5))
        # 高亮当前档
        if i == 2:
            a.frame(87 + i * 26, 47, 20, 20, rgb(TEXT_MAIN))
    # 下：强化 +0..+3 pips
    for i in range(4):
        filled = i < 2
        c = rgb(GREEN) if filled else rgb(BORDER)
        a.rect(88 + i * 22, 84, 12, 12, c)
        a.frame(88 + i * 22, 84, 12, 12, dim(c, 0.6))
    # 右侧：向上大箭头（升阶）
    for k in range(28):
        a.p(232, 92 - k, rgb(AMBER))
    a.p(229, 96, rgb(AMBER)); a.p(230, 95, rgb(AMBER)); a.p(231, 94, rgb(AMBER))
    a.p(235, 96, rgb(AMBER)); a.p(234, 95, rgb(AMBER)); a.p(233, 94, rgb(AMBER))
    a.scanlines(0.9)
    a.save("intro_04.png")


# ============ 05 长期战争 ============
def scene_05():
    a = Art()
    a.rect(0, 0, W, H, rgb(BG_CARD))
    # 竖向分隔
    for y in range(8, 120, 4):
        a.p(128, y, rgb(BORDER_DIM))
    # 左区：战役结束清零（金币 + 装备 + 模组，暗化 + 红斜杠）
    for cx, cy, n in [(24, 20, "coin.png"), (76, 20, "equipment/armor_white.png"),
                      (24, 72, "module.png"), (76, 72, "coin.png")]:
        ic = sprite(n).resize((32, 32), Image.NEAREST)
        p2 = ic.load()
        for yy in range(32):
            for xx in range(32):
                r, g, b, aa = p2[xx, yy]
                p2[xx, yy] = (r // 3, g // 3, b // 3, aa)
        a.im.alpha_composite(ic, (cx, cy))
        a.dash_line(cx, cy, cx + 31, cy + 31, dim(rgb(RED), 0.8), on=2, off=2)
        a.dash_line(cx + 31, cy, cx, cy + 31, dim(rgb(RED), 0.8), on=2, off=2)
    # 右区：永久保留（黑匣 + 蓝图卷轴，高亮 + 绿光框）
    a.frame(146, 16, 40, 40, dim(rgb(GREEN), 0.7))
    a.stamp("black_box.png", 150, 20)
    # 蓝图卷轴（手绘 32x32）
    bx, by = 200, 20
    a.rect(bx, by, 32, 32, rgb("#5D9CEC"))
    a.rect(bx, by, 32, 4, rgb("#3D6EA8"))
    a.rect(bx, by + 28, 32, 4, rgb("#3D6EA8"))
    a.frame(bx, by, 32, 32, rgb("#2C4E78"))
    for k, (lx, ly, lw) in enumerate([(5, 9, 18), (5, 14, 22), (5, 19, 14)]):
        a.rect(bx + lx, by + ly, lw, 2, rgb("#B8D4F0"))
    a.rect(bx + 5, by + 24, 10, 2, rgb("#8FB8E0"))
    # 右区下方：8 项黑匣升级格（全部点亮）
    for i in range(8):
        a.rect(146 + i * 14, 76, 10, 10, rgb(GREEN_DARK))
        a.frame(146 + i * 14, 76, 10, 10, rgb(GREEN))
        a.p(150 + i * 14, 80, rgb(GREEN))
    # 底部：循环箭头（跨战役成长）
    for k in range(40):
        a.p(108 + k, 108, rgb(BORDER_HI))
        a.p(148 - k, 116, rgb(BORDER_HI))
    a.p(104, 104, rgb(GREEN)); a.p(105, 104, rgb(GREEN)); a.p(104, 108, rgb(GREEN))
    a.p(106, 103, rgb(GREEN)); a.p(105, 107, rgb(GREEN))
    a.p(152, 112, rgb(GREEN)); a.p(151, 112, rgb(GREEN)); a.p(152, 116, rgb(GREEN))
    a.p(150, 113, rgb(GREEN)); a.p(151, 117, rgb(GREEN))
    a.scanlines(0.88)
    a.save("intro_05.png")


# ============ 06 出征 ============
def scene_06():
    a = Art()
    # 天空：3 段渐变带
    a.rect(0, 0, W, 44, rgb("#0C120A"))
    a.rect(0, 44, W, 18, rgb("#1A1E14"))
    a.rect(0, 62, W, 14, rgb("#33291A"))
    # 太阳
    a.disc(196, 52, 14, dim(rgb(AMBER), 0.45))
    a.disc(196, 52, 11, rgb(AMBER))
    a.disc(196, 52, 8, rgb(YELLOW))
    # 地平线
    a.rect(0, 76, W, 2, rgb(AMBER_DARK))
    # 地面
    a.rect(0, 78, W, 50, rgb("#10160E"))
    for x in range(0, W, 3):
        if (x * 7) % 11 < 3:
            a.p(x, 84 + (x * 13) % 40, rgb(GRASS_D))
    # 远处敌方基地剪影（16x16，底边贴地平线 y=76）
    for ex, n in [(148, "base_enemy.png"), (168, "base_enemy_elite.png"),
                  (190, "base_enemy.png"), (210, "base_enemy_boss.png")]:
        s = sprite(n).resize((16, 16), Image.NEAREST)
        s = s.copy()
        p2 = s.load()
        for yy in range(16):
            for xx in range(16):
                rr, gg, bb, aa = p2[xx, yy]
                p2[xx, yy] = (rr // 3, gg // 3, bb // 3, aa)
        a.im.alpha_composite(s, (ex, 60))
    # 我方基地 + 坦克（出征位）
    a.stamp("base_player.png", 24, 44)
    a.tank(72, 46, "tank_player_body_sheet.png", "tank_player_turret.png")
    # 尾迹（地面履带印）
    for k in range(10):
        a.p(64 - k, 70, dim(rgb(GRASS_2), 0.8))
        a.p(64 - k, 74, dim(rgb(GRASS_2), 0.8))
    # 关卡刻度：30 格，前 3 亮绿
    a.rect(16, 102, 210, 1, rgb(BORDER))
    for i in range(30):
        x = 18 + i * 7
        c = rgb(GREEN) if i < 3 else (rgb(BORDER_HI) if i < 10 else rgb(BORDER_DIM))
        a.rect(x, 104, 2, 12 if i < 3 else 9, c)
    # 刻度下：战役组分隔（每 3 格一条竖线）
    a.scanlines(0.9)
    a.save("intro_06.png")


if __name__ == "__main__":
    scene_01()
    scene_02()
    scene_03()
    scene_04()
    scene_05()
    scene_06()
    # 预览拼图 2x
    sheet = Image.new("RGBA", (256 * 2 + 8 * 3, 128 * 3 + 8 * 4), (40, 40, 40, 255))
    for i in range(6):
        im = Image.open(os.path.join(OUT, f"intro_0{i+1}.png"))
        sheet.alpha_composite(im, (8 + (i % 2) * (256 + 8), 8 + (i // 2) * (128 + 8)))
    sheet.save("/tmp/story_preview.png")
    print("预览: /tmp/story_preview.png")
