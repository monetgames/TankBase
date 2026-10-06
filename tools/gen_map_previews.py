#!/usr/bin/env python3
"""《坦克基地》30 关地图全貌预览生成器
读取 maps/levelN.json，用真实游戏素材（16px 地形瓦片 + 基地/坦克精灵）拼贴渲染：
- 地形：brick/stone/water/grass/ice 瓦片，空地为深底 + 网格线
- 基地：玩家=base_player（绿框高亮），敌方=base_enemy/_elite/_boss（按 level 1/2/3）
- 出生点：base_player/base_enemy + tank_player/tank_enemy 精灵标注 tank_spawn_pos
输出：output/maps_preview/level_01.png ~ level_30.png + index.html（网格画廊预览页）
用法: python3 tools/gen_map_previews.py
"""
import json
import glob
import html
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SP = os.path.join(ROOT, "sprites")
OUT = os.path.join(ROOT, "output", "maps_preview")
TILE = 16  # 地形瓦片 16x16

# UI 色板（scripts/ui/ui_palette.gd 同源）
BG_GROUND = "#0C120A"
GRID_LINE = "#1A2314"
GREEN_HI = "#97C459"
GREEN_TEXT = "#9CCC65"
AMBER = "#EF9F27"
BORDER = "#4A5D3A"
TEXT_MAIN = "#D8E0C8"
TEXT_MUTED = "#7A8570"

ENEMY_BASE_SPRITE = {1: "base_enemy.png", 2: "base_enemy_elite.png", 3: "base_enemy_boss.png"}
ENEMY_LEVEL_NAME = {1: "普通", 2: "精英", 3: "BOSS"}

_cache = {}


def load(rel):
    if rel not in _cache:
        _cache[rel] = Image.open(os.path.join(SP, rel)).convert("RGBA")
    return _cache[rel]


def stamp(canvas, rel, x, y, w=None, h=None):
    """把精灵贴到画布 (x,y) 像素左上角；w/h 可选缩放（NEAREST）。"""
    im = load(rel)
    if w and (im.width != w or im.height != h):
        im = im.resize((w, h), Image.NEAREST)
    canvas.alpha_composite(im, (x, y))


def render_level(path):
    d = json.load(open(path))
    gw, gh = d["size"]
    W, H = gw * TILE, gh * TILE
    cv = Image.new("RGBA", (W, H))
    px = cv.load()

    # 空地底色 + 16px 网格
    bg = tuple(int(BG_GROUND[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
    grid = tuple(int(GRID_LINE[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
    for y in range(H):
        for x in range(W):
            px[x, y] = grid if (x % TILE == 0 or y % TILE == 0) else bg

    # 地形瓦片（每个 key 一层，坐标 [gx, gy]）
    for terrain, sprite in [("brick", "brick.png"), ("stone", "stone.png"),
                            ("water", "water.png"), ("grass", "grass.png"),
                            ("ice", "ice.png")]:
        for pos in d["map"].get(terrain, []):
            stamp(cv, sprite, pos[0] * TILE, pos[1] * TILE)

    # 玩家基地（绿框高亮 2x2）+ 玩家坦克出生点
    # 玩家坦克全场唯一：数据里即使配置了多个生成点位，也只标注第一个
    player_tank_drawn = False
    for bp in d.get("base_player", []):
        bx, by = bp["pos"][0] * TILE, bp["pos"][1] * TILE
        frame(cv, bx - 3, by - 3, 38, 38, GREEN_HI)
        stamp(cv, "base_player.png", bx, by)
        spawn_points = bp.get("tank_spawn_pos", [])
        if not player_tank_drawn and spawn_points:
            stamp_tank(cv, "player", spawn_points[0][0] * TILE, spawn_points[0][1] * TILE)
            player_tank_drawn = True

    # 敌方基地（按等级用不同基地精灵）+ 敌方坦克出生点
    for be in d.get("base_enemy", []):
        bx, by = be["pos"][0] * TILE, be["pos"][1] * TILE
        frame(cv, bx - 2, by - 2, 36, 36, (int(BORDER[1:3], 16), int(BORDER[3:5], 16), int(BORDER[5:7], 16), 255))
        stamp(cv, ENEMY_BASE_SPRITE.get(be.get("level", 1), "base_enemy.png"), bx, by)
        for sp in be.get("tank_spawn_pos", []):
            stamp_tank(cv, "enemy", sp[0] * TILE, sp[1] * TILE)

    return cv, d


def hex_rgba(s):
    return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5)) + (255,)


def frame(cv, x, y, w, h, color):
    color = hex_rgba(color) if isinstance(color, str) else color
    px = cv.load()
    W, H = cv.size
    for i in range(max(0, x), min(W, x + w)):
        for yy in (y, y + h - 1):
            if 0 <= yy < H:
                px[i, yy] = color
    for j in range(max(0, y), min(H, y + h)):
        for xx in (x, x + w - 1):
            if 0 <= xx < W:
                px[xx, j] = color


def stamp_tank(cv, side, x, y):
    """坦克精灵标注出生点：对齐游戏内原点——
    wave_manager 以 gs*(sp+1)（2x2 块中心）为坦克原点，精灵覆盖标记格及其右下邻格，
    故精灵左上角 = 标记格左上角 (gx*16, gy*16)。"""
    if side == "player":
        body = load("tank_player_body_sheet.png").crop((0, 0, 32, 32))
        turret = load("tank_player_turret.png")
    else:
        body = load("tank_enemy.png")
        turret = load("tank_enemy_turret.png")
    cv.alpha_composite(body, (x, y))
    cv.alpha_composite(turret, (x, y))


def short_title(d, idx):
    """优先用 info.name（中文命名），拼上风格名"""
    desc = d.get("info", {}).get("description", "")
    style = desc.split("：")[1].split("地图")[0].split("；")[0] if "：" in desc else ""
    name = d.get("info", {}).get("name", "第 %d 关" % idx)
    return "%s · %s" % (name, style) if style else name


def main():
    os.makedirs(OUT, exist_ok=True)
    files = sorted(glob.glob(os.path.join(ROOT, "maps", "level*.json")),
                   key=lambda p: int("".join(c for c in os.path.basename(p) if c.isdigit())))
    cards = []
    for idx, path in enumerate(files, 1):
        cv, d = render_level(path)
        png_name = "level_%02d.png" % idx
        cv.save(os.path.join(OUT, png_name))
        cards.append((idx, png_name, short_title(d, idx), cv.size))
        print("生成", png_name, cv.size[0], "x", cv.size[1])

    # ---- 静态预览页 ----
    legend = """
    <div class="legend">
      <span class="chip"><img src="../sprites_ref/base_player.png" onerror="this.style.display='none'"><b class="g">绿框</b> 我方基地 · <b class="g">绿坦克</b> 玩家出生点</span>
      <span class="chip">灰/棕/红框 = 敌方基地（<b>普通 / 精英 / BOSS</b>）· 灰坦克 = 敌方出兵位</span>
      <span class="chip">砖墙 · 石块 · 水 · 草 · 冰</span>
    </div>"""
    items = []
    for idx, png, title, (w, h) in cards:
        items.append(
            '<div class="card"><a href="%s" target="_blank"><img src="%s" alt="%s"></a>'
            '<div class="meta"><span class="no">%02d</span><span class="title">%s</span>'
            '<span class="size">%d×%d</span></div></div>'
            % (png, png, html.escape(title), idx, html.escape(title), w // TILE, h // TILE))
    page = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>坦克基地 · 30 关地图全貌</title>
<style>
  body {{ background:#0C120A; color:{TEXT_MAIN}; font-family:-apple-system,"PingFang SC",sans-serif; margin:24px; }}
  h1 {{ color:{GREEN_TEXT}; font-size:22px; margin:0 0 6px; }}
  .sub {{ color:{TEXT_MUTED}; font-size:13px; margin-bottom:14px; }}
  .legend {{ display:flex; gap:16px; flex-wrap:wrap; color:{TEXT_MUTED}; font-size:13px; margin-bottom:20px; }}
  .legend b {{ color:{AMBER}; }}
  .legend .g {{ color:{GREEN_TEXT}; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(420px,1fr)); gap:16px; }}
  .card {{ background:#10160E; border:1px solid {BORDER}; border-radius:6px; overflow:hidden;
           transition: transform 0.25s ease, border-color 0.25s ease; }}
  .card:hover {{ transform: translateY(-4px); border-color:#4a7a3a; }}
  .card img {{ width:100%; display:block; image-rendering:pixelated; }}
  .meta {{ display:flex; align-items:center; gap:10px; padding:8px 12px; }}
  .no {{ color:{AMBER}; font-weight:700; }}
  .title {{ flex:1; color:{GREEN_TEXT}; font-size:14px; }}
  .size {{ color:{TEXT_MUTED}; font-size:12px; }}
</style></head><body>
<h1>坦克基地 · 30 关地图全貌</h1>
<div class="sub">地形块 + 基地/坦克出生点标注（真实游戏素材渲染）· 点击图片查看原始大图</div>
{legend}
<div class="grid">
{items}
</div></body></html>""".format(
        TEXT_MAIN=TEXT_MAIN, GREEN_TEXT=GREEN_TEXT, TEXT_MUTED=TEXT_MUTED,
        AMBER=AMBER, BORDER=BORDER, legend=legend, items="\n".join(items))
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)
    print("预览页:", os.path.join(OUT, "index.html"))


if __name__ == "__main__":
    main()
