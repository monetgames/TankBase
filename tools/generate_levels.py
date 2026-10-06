#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 30 个预设关卡到 maps/ 文件夹。
算法与 scripts/map_generator.gd 保持一致：
  玩家基地中心、敌方基地四周（BOSS 四角）、走廊保证可达、死档检测（BFS）。
运行：python3 tools/generate_levels.py
"""
import json
import random
import sys
from collections import deque

EMPTY, WATER, ICE, BRICK, STONE, GRASS = "", "water", "ice", "brick", "stone", "grass"
HARD_BLOCK = {WATER, STONE}
PASSABLE = {EMPTY, ICE, GRASS, BRICK}


def make_noise(seed, size):
    """确定性 2D value-noise，返回 callable(x, y) -> [-1, 1]。
    基于随机格点 + 双线性插值，近似柏林噪声的连续渐变。"""
    rng = random.Random(seed)
    gx = size * 2
    gy = size * 2
    lattice = [[rng.uniform(-1, 1) for _ in range(gx + 1)] for _ in range(gy + 1)]

    def smooth(t):
        return t * t * (3 - 2 * t)

    def noise(x, y, freq=1.0):
        fx = x * freq
        fy = y * freq
        x0 = int(fx) % gx
        y0 = int(fy) % gy
        x1 = (x0 + 1) % gx
        y1 = (y0 + 1) % gy
        tx = smooth(fx - int(fx))
        ty = smooth(fy - int(fy))
        a = lattice[y0][x0]
        b = lattice[y0][x1]
        c = lattice[y1][x0]
        d = lattice[y1][x1]
        return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty

    return noise


class Generator:
    def __init__(self, seed, w, h, spec):
        self.seed = seed
        self.w = w
        self.h = h
        self.spec = spec
        self.grid = [[EMPTY for _ in range(w)] for _ in range(h)]
        self.reserved = set()
        self.player_base = (w // 2 - 1, h // 2 - 1)
        self.enemy_bases = []       # [(x, y), ...]
        self.enemy_levels = []      # 与 enemy_bases 对齐

    def reserve(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.reserved.add((x, y))

    def is_reserved(self, x, y):
        return (x, y) in self.reserved

    def reserve_base(self, bx, by):
        for dy in range(-1, 3):
            for dx in range(-1, 3):
                self.reserve(bx + dx, by + dy)

    def place_bases(self):
        self.reserve_base(*self.player_base)
        enemy_count = self.spec["enemy_count"]
        enemy_levels = self.spec["enemy_levels"]
        boss_count = 0
        normal_levels = []
        for i in range(enemy_count):
            lvl = enemy_levels[i % len(enemy_levels)]
            if lvl == 3:
                boss_count += 1
            else:
                normal_levels.append(lvl)

        m = 3
        corners = [
            (m, m), (self.w - m - 2, m),
            (m, self.h - m - 2), (self.w - m - 2, self.h - m - 2),
        ]
        candidates = corners + [
            (self.w // 2 - 1, m), (self.w // 2 - 1, self.h - m - 2),
            (m, self.h // 2 - 1), (self.w - m - 2, self.h // 2 - 1),
        ]

        # BOSS 四角
        for i in range(min(boss_count, len(corners))):
            self.enemy_bases.append(corners[i])
            self.enemy_levels.append(3)
            self.reserve_base(*corners[i])

        # 非 BOSS 从候选挑最远的
        for lvl in normal_levels:
            best, bd = None, -1
            for c in candidates:
                if c in self.enemy_bases:
                    continue
                d = (c[0] - self.player_base[0]) ** 2 + (c[1] - self.player_base[1]) ** 2
                if d > bd:
                    bd, best = d, c
            if best is None:
                break
            self.enemy_bases.append(best)
            self.enemy_levels.append(lvl)
            self.reserve_base(*best)

    def carve_line(self, p0, p1):
        cx, cy = p0
        while (cx, cy) != p1:
            for dy in range(2):
                for dx in range(2):
                    self.reserve(cx + dx, cy + dy)
            if cx != p1[0]:
                cx += 1 if p1[0] > cx else -1
            elif cy != p1[1]:
                cy += 1 if p1[1] > cy else -1
        for dy in range(2):
            for dx in range(2):
                self.reserve(p1[0] + dx, p1[1] + dy)

    def plan_corridors(self):
        rng = random.Random(self.seed * 7919)
        for target in self.enemy_bases:
            a = self.player_base
            b = target
            if rng.random() < 0.5:
                mid = (a[0] + rng.randint(0, abs(b[0] - a[0])) if b[0] != a[0] else a[0], b[1])
            else:
                mid = (b[0], a[1] + rng.randint(0, abs(b[1] - a[1])) if b[1] != a[1] else a[1])
            self.carve_line(a, mid)
            self.carve_line(mid, b)

    def generate_terrain(self):
        n_water = make_noise(self.seed, self.w)
        n_obs = make_noise(self.seed + 777, self.w)
        n_deco = make_noise(self.seed + 12345, self.w)
        style = self.spec.get("style", "noise")
        for y in range(self.h):
            for x in range(self.w):
                if self.is_reserved(x, y):
                    continue
                vw = n_water(x, y, 0.035)
                vo = n_obs(x, y, 0.09)
                vd = n_deco(x, y, 0.07)
                # 风格只改变地形权重；所有基地之间的走廊已在前一步保留为空地。
                ice_threshold = -0.5
                if style == "open":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.82, 0.76, 0.48, 0.72
                elif style == "water":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.28, 0.72, 0.44, 0.80
                elif style == "grass":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.90, 0.72, 0.46, 0.12
                elif style == "ruins":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.82, 0.70, 0.12, 0.80
                elif style == "ice":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.82, 0.76, 0.50, 0.82
                    ice_threshold = 0.10
                elif style == "marsh":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.18, 0.80, 0.55, 0.20
                elif style == "fortress":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.90, 0.48, 0.10, 0.90
                elif style == "mixed":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.45, 0.65, 0.28, 0.45
                elif style == "finale":
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.35, 0.55, 0.18, 0.25
                else:
                    water_threshold, stone_threshold, brick_threshold, grass_threshold = -0.52, 0.62, 0.34, 0.55

                if vw < water_threshold:
                    self.grid[y][x] = WATER
                elif vo > stone_threshold:
                    self.grid[y][x] = STONE
                elif vo > brick_threshold:
                    self.grid[y][x] = BRICK
                elif vd < ice_threshold:
                    self.grid[y][x] = ICE
                elif vd > grass_threshold:
                    self.grid[y][x] = GRASS

    def filter_small_patches(self):
        for tile, min_size in [(WATER, 6), (STONE, 4), (BRICK, 4), (ICE, 4), (GRASS, 4)]:
            visited = set()
            for y in range(self.h):
                for x in range(self.w):
                    if self.grid[y][x] != tile or (x, y) in visited:
                        continue
                    cells, q = [], deque([(x, y)])
                    visited.add((x, y))
                    while q:
                        cx, cy = q.popleft()
                        cells.append((cx, cy))
                        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                            nx, ny = cx + dx, cy + dy
                            if 0 <= nx < self.w and 0 <= ny < self.h and (nx, ny) not in visited and self.grid[ny][nx] == tile:
                                visited.add((nx, ny))
                                q.append((nx, ny))
                    if len(cells) < min_size:
                        for cx, cy in cells:
                            self.grid[cy][cx] = EMPTY

    def add_border(self):
        if self.w < 48:
            return
        for x in range(self.w):
            self.grid[0][x] = STONE
            self.grid[self.h - 1][x] = STONE
        for y in range(self.h):
            self.grid[y][0] = STONE
            self.grid[y][self.w - 1] = STONE

    def tile_at(self, x, y):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return STONE
        return self.grid[y][x]

    def bfs_reachable(self, start, target):
        visited = {start}
        q = deque([start])
        while q:
            cx, cy = q.popleft()
            if (cx, cy) == target:
                return True
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = cx + dx, cy + dy
                if not (0 <= nx < self.w and 0 <= ny < self.h):
                    continue
                if (nx, ny) in visited:
                    continue
                if self.tile_at(nx, ny) in HARD_BLOCK:
                    continue
                visited.add((nx, ny))
                q.append((nx, ny))
        return False

    def validate(self):
        details = []
        for e in self.enemy_bases:
            if not self.bfs_reachable(self.player_base, e):
                details.append({"player": list(self.player_base), "enemy": list(e)})
        # 基地及其坦克出生点必须处于可通行区域，避免基地压在水/石中或坦克出生即困死。
        for base in [self.player_base] + self.enemy_bases:
            for dy in range(2):
                for dx in range(2):
                    if self.tile_at(base[0] + dx, base[1] + dy) in HARD_BLOCK:
                        details.append({"blocked_base": list(base)})
            for spawn in self.tank_spawns(base, ""):
                sx, sy = spawn
                if not self.valid_spawn((sx, sy)) or not self.bfs_reachable(base, (sx, sy)):
                    details.append({"blocked_spawn": list(spawn), "base": list(base)})
        return details

    def tank_spawns(self, base, side):
        spawns = []
        cx, cy = self.w // 2, self.h // 2
        dx = 1 if cx > base[0] else -1 if cx < base[0] else 0
        dy = 1 if cy > base[1] else -1 if cy < base[1] else 0
        if abs(base[0] - cx) >= abs(base[1] - cy):
            primary = (dx, 0)
        else:
            primary = (0, dy)
        for off in (primary, (-primary[0], -primary[1])):
            sp = (base[0] + off[0] * 4, base[1] + off[1] * 4)
            if self.valid_spawn(sp):
                spawns.append(list(sp))
        if not spawns:
            fallback = [base[0], max(0, base[1] - 2)]
            spawns.append(fallback)
        return spawns

    def valid_spawn(self, sp):
        if not (1 <= sp[0] < self.w - 2 and 1 <= sp[1] < self.h - 2):
            return False
        for dy in range(2):
            for dx in range(2):
                if self.tile_at(sp[0] + dx, sp[1] + dy) in HARD_BLOCK:
                    return False
        return True

    def build(self):
        map_data = {}
        for y in range(self.h):
            for x in range(self.w):
                t = self.grid[y][x]
                if t == EMPTY:
                    continue
                map_data.setdefault(t, []).append([x, y])

        def spawn_interval(lvl):
            return {3: 2.0, 2: 2.5}.get(lvl, 3.0)

        enemy_bases = []
        for i, pos in enumerate(self.enemy_bases):
            lvl = self.enemy_levels[i]
            enemy_bases.append({
                "pos": list(pos),
                "tank_spawn_pos": self.tank_spawns(pos, "enemy"),
                "level": lvl,
                "max_hp": lvl,
                "FactoryTank": {"maximum_spawn": 1, "spawn_interval": spawn_interval(lvl)},
            })

        player_base = {
            "pos": list(self.player_base),
            "tank_spawn_pos": self.tank_spawns(self.player_base, "player"),
            "level": int(self.spec.get("player_level", 1)),
            "max_hp": 1,
        }

        return {
            "info": {
                "name": self.spec["name"],
                "author": "MapGenerator",
                "description": self.spec["description"],
                "version": "1.0",
                "seed": self.seed,
                "style": self.spec.get("style", "noise"),
            },
            "size": [self.w, self.h],
            "map": map_data,
            "base_enemy": enemy_bases,
            "base_player": [player_base],
        }


STYLE_NAMES = ["open", "water", "grass", "noise", "ruins", "ice", "marsh", "fortress", "mixed", "finale"]


def wave_composition(level_no, wave_no):
    """返回一个全局关卡波次的基地等级列表。
    前三关控制在 1/1/2、1/2/3、1/2/3 个基地，之后通过战役组和关卡递增，最多 6 个。
    敌方属性还会按全局关卡缩放，因此不会因战役组切换而降低难度。
    """
    if level_no <= 3:
        first_campaign = {
            1: [["normal"], ["normal"], ["normal", "normal"]],
            2: [["normal"], ["normal", "normal"], ["normal", "normal", "normal"]],
            3: [["normal"], ["normal", "elite"], ["normal", "normal", "elite"]],
        }
        return first_campaign[level_no][wave_no - 1]

    campaign = (level_no - 1) // 3
    local_stage = (level_no - 1) % 3
    campaign_bonus = (campaign + 1) // 2
    wave_bonus = 1 if wave_no == 3 else 0
    count = min(6, 1 + campaign_bonus + local_stage + wave_bonus)

    elite_count = 0
    if level_no >= 3:
        elite_count = max(1, (level_no - 1) // 6 + (1 if local_stage >= 1 else 0))
        if wave_no < 3:
            elite_count = max(0, elite_count - 1)
    boss_count = 0
    if level_no >= 7 and wave_no == 3:
        boss_count = 1
    if level_no >= 25 and wave_no == 3:
        boss_count = 2
    boss_count = min(max(0, count - 1), boss_count)
    elite_count = min(max(0, count - boss_count - 1), elite_count)

    return (["boss"] * boss_count + ["elite"] * elite_count +
            ["normal"] * (count - boss_count - elite_count))


def build_level_specs():
    specs = []
    for level_no in range(1, 31):
        campaign = (level_no - 1) // 3
        local_stage = (level_no - 1) % 3
        if level_no in (1, 11, 21):
            size = (32, 32)
        elif level_no in (10, 20, 30):
            size = (64, 64)
        else:
            size = (48, 48)
        waves = [wave_composition(level_no, wave) for wave in (1, 2, 3)]
        max_levels = waves[-1]
        max_count = len(max_levels)
        style = STYLE_NAMES[campaign]
        style_label = {
            "open": "开阔空地", "water": "连片水域", "grass": "草地平原", "noise": "柏林噪声",
            "ruins": "砖墙遗迹", "ice": "冰原", "marsh": "水草沼泽", "fortress": "石墙要塞",
            "mixed": "复合地形", "finale": "终局混合战场",
        }[style]
        specs.append({
            "name": "Level %d" % level_no,
            "size": size,
            "seed": 100000 + level_no * 7919,
            "enemy_count": max_count,
            "enemy_levels": [1 if lv == "normal" else 2 if lv == "elite" else 3 for lv in max_levels],
            "style": style,
            "description": "第 %d 战役第 %d 关：%s地图；基地数量与波次递增并通过 BFS 死档检测。" % (campaign + 1, local_stage + 1, style_label),
        })
    return specs


LEVEL_SPECS = build_level_specs()


def main():
    ok_all = True
    for i, spec in enumerate(LEVEL_SPECS):
        level_no = i + 1
        w, h = spec["size"]
        seed = spec["seed"]
        # 死档则换种子重试（走廊已保证可达，这里兜底）
        data = None
        for attempt in range(100):
            g = Generator(seed + attempt, w, h, spec)
            g.place_bases()
            g.plan_corridors()
            g.generate_terrain()
            g.filter_small_patches()
            g.add_border()
            if not g.validate():
                data = g.build()
                break
        if data is None:
            print("关卡 %d 死档检测失败！" % level_no)
            ok_all = False
            continue

        path = "maps/level%d.json" % level_no
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent="\t")
        print("关卡 %2d: %dx%d, 敌方基地 %d 个, 可达性 OK -> %s" % (level_no, w, h, len(data["base_enemy"]), path))

    waves = []
    for level_no in range(1, 31):
        for wave_no in range(1, 4):
            waves.append({
                "_stage": "第%d关-第%d波" % (level_no, wave_no),
                "enemy_bases": [{"level": lv} for lv in wave_composition(level_no, wave_no)],
                "wave_interval": 3,
            })
    with open("config/wave/wave_configs.json", "w", encoding="utf-8") as f:
        json.dump({
            "_comment": "30 个全局关卡，每关 3 波；每三关为一次战役。基地数量前期保守，随战役和关卡递增，地图基地位置由对应 levelN.json 提供。",
            "max_stages": 30,
            "max_waves_per_stage": 3,
            "waves": waves,
            "loot_gather_interval": 3,
        }, f, ensure_ascii=False, indent="\t")
    print("波次配置：30 关 × 3 波 = %d 波" % len(waves))

    print("========== 生成完成 %s ==========" % ("全部成功" if ok_all else "存在失败"))
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
