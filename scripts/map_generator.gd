extends RefCounted
class_name MapGenerator

# =============================================================
# 地图生成器
# 柏林噪声生成六地形（空地/水面/冰面/砖块/石块/草地）
# 玩家基地固定地图中心；敌方基地随机四周（BOSS 四角）
# 可玩性与死档检测：双方基地必须可达、坦克可驶出基地
# =============================================================

const TILE_EMPTY := ""
const TILE_WATER := "water"
const TILE_ICE := "ice"
const TILE_BRICK := "brick"
const TILE_STONE := "stone"
const TILE_GRASS := "grass"

# 坦克可通行地形（砖块可破坏，视为可通行）
const PASSABLE := ["", "ice", "grass", "brick"]
# 硬障碍：水面（无船不可过）、石块（普通炮弹不可破坏）
const HARD_BLOCK := ["water", "stone"]
# 四方向偏移（BFS 用）
const DIRECTIONS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var width: int = 32
var height: int = 32
var seed_value: int = 0
var generation_style: String = "noise"

# 地形网格 grid[y][x] = 地形类型字符串
var grid: Array = []

# 保留区：基地 2x2 及其周围一圈、走廊，均保持空地
var _reserved: Dictionary = {}  # key: "x,y" -> true

# 基地位置记录（左上角格子坐标）
var _player_base_pos: Vector2i = Vector2i.ZERO
var _enemy_base_positions: Array = []  # Array[Vector2i]
var _enemy_level_list: Array = []      # 与 _enemy_base_positions 对齐的等级列表

# 死档检测：BFS 可达性
var _reachable_cache: Dictionary = {}


# -------------------------------------------------------------
# 公开入口：生成一张地图，返回可直接写入 JSON 的字典结构
# @param seed_value  随机种子
# @param w,h         地图尺寸（格子数）
# @param spec        关卡规格字典 { enemy_count, enemy_levels, ... }
# -------------------------------------------------------------
func generate(seed_val: int, w: int, h: int, spec: Dictionary) -> Dictionary:
	seed_value = seed_val
	width = w
	height = h
	generation_style = str(spec.get("style", "noise"))
	grid = []
	_reserved = {}
	_reachable_cache = {}
	_enemy_base_positions = []
	_enemy_level_list = []

	for y in range(height):
		grid.append([])
		for x in range(width):
			grid[y].append(TILE_EMPTY)

	# 1. 放置基地（玩家中心，敌方四周）
	_place_bases(spec)

	# 2. 规划走廊（保证基地间可达），并纳入保留区
	_plan_corridors()

	# 3. 噪声生成地形（避开保留区）
	_generate_terrain()

	# 4. 过滤孤立小地形块（水域/障碍去噪，让地图更自然）
	_filter_small_patches()

	# 5. 生成地图边界（大图用石头围边，避免坦克越界观感）
	if width >= 48:
		_add_border()

	return _build_result(spec)


# -------------------------------------------------------------
# 生成结果：组装为 map_manager.load_level 可解析的 JSON 结构
# -------------------------------------------------------------
func _build_result(spec: Dictionary) -> Dictionary:
	var map_data: Dictionary = {}
	for y in range(height):
		for x in range(width):
			var t = grid[y][x]
			if t == TILE_EMPTY:
				continue
			if not map_data.has(t):
				map_data[t] = []
			map_data[t].append([x, y])

	var enemy_bases: Array = []
	for i in range(_enemy_base_positions.size()):
		var pos: Vector2i = _enemy_base_positions[i]
		var lvl: int = int(_enemy_level_list[i])
		enemy_bases.append({
			"pos": [pos.x, pos.y],
			"tank_spawn_pos": _tank_spawns_for(pos, "enemy"),
			"level": lvl,
			"max_hp": lvl,  # 兼容字段，实际数值由 enemy_units.json 读取
			"FactoryTank": {
				"maximum_spawn": 1,
				"spawn_interval": _spawn_interval(lvl),
			},
		})

	var player_base = {
		"pos": [_player_base_pos.x, _player_base_pos.y],
		"tank_spawn_pos": _tank_spawns_for(_player_base_pos, "player"),
		"level": int(spec.get("player_level", 1)),
		"max_hp": 1,  # 兼容字段，实际数值由 player_base.json 读取
	}

	var info := {
		"name": str(spec.get("name", "Generated Level")),
		"author": "MapGenerator",
		"description": str(spec.get("description", "")),
		"version": "1.0",
		"seed": seed_value,
		"style": generation_style,
	}

	return {
		"info": info,
		"size": [width, height],
		"map": map_data,
		"base_enemy": enemy_bases,
		"base_player": [player_base],
	}


func _spawn_interval(level: int) -> float:
	match level:
		3: return 2.0   # boss 更快
		2: return 2.5   # elite
		_: return 3.0   # normal


# -------------------------------------------------------------
# 基地放置：玩家中心，敌方四周
# -------------------------------------------------------------
func _place_bases(spec: Dictionary) -> void:
	# 玩家基地：地图中心（2x2）
	_player_base_pos = Vector2i(width / 2 - 1, height / 2 - 1)
	_reserve_base_area(_player_base_pos)

	var enemy_count: int = int(spec.get("enemy_count", 2))
	var enemy_levels: Array = spec.get("enemy_levels", [1])

	# 拆分等级：BOSS（level 3）与非 BOSS
	var boss_count := 0
	var normal_levels: Array = []
	for i in range(enemy_count):
		var lvl: int = int(enemy_levels[i % enemy_levels.size()])
		if lvl == 3:
			boss_count += 1
		else:
			normal_levels.append(lvl)

	_enemy_base_positions = []
	_enemy_level_list = []

	# BOSS 固定四角
	var boss_corners: Array = _boss_corners()
	for i in range(mini(boss_count, boss_corners.size())):
		var corner: Vector2i = boss_corners[i]
		_enemy_base_positions.append(corner)
		_enemy_level_list.append(3)
		_reserve_base_area(corner)

	# 非 BOSS 从候选里挑选（远离玩家基地优先）
	for lvl in normal_levels:
		var best := _pick_farthest_candidate(_enemy_base_candidates())
		if best == Vector2i(-1, -1):
			break
		_enemy_base_positions.append(best)
		_enemy_level_list.append(lvl)
		_reserve_base_area(best)


## 敌方基地候选位置：四角 + 四边中点（2x2 左上角坐标）
func _enemy_base_candidates() -> Array[Vector2i]:
	var m := 3  # 距边缘的格数
	return [
		Vector2i(m, m),
		Vector2i(width - m - 2, m),
		Vector2i(m, height - m - 2),
		Vector2i(width - m - 2, height - m - 2),
		Vector2i(width / 2 - 1, m),
		Vector2i(width / 2 - 1, height - m - 2),
		Vector2i(m, height / 2 - 1),
		Vector2i(width - m - 2, height / 2 - 1),
	]


## BOSS 四角（与候选的四角一致）
func _boss_corners() -> Array[Vector2i]:
	var m := 3
	return [
		Vector2i(m, m),
		Vector2i(width - m - 2, m),
		Vector2i(m, height - m - 2),
		Vector2i(width - m - 2, height - m - 2),
	]


## 从候选里选距离玩家基地最远的（未被占用）
func _pick_farthest_candidate(candidates: Array[Vector2i]) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist := -1.0
	for c: Vector2i in candidates:
		if c in _enemy_base_positions:
			continue
		var d: float = c.distance_to(_player_base_pos)
		if d > best_dist:
			best_dist = d
			best = c
	return best


## 基地保留区：基地 2x2 及周围一圈（共 4x4）保持空地，保证坦克可驶出
func _reserve_base_area(base_pos: Vector2i) -> void:
	for dy in range(-1, 3):
		for dx in range(-1, 3):
			_reserve_cell(base_pos.x + dx, base_pos.y + dy)


func _reserve_cell(x: int, y: int) -> void:
	if x < 0 or y < 0 or x >= width or y >= height:
		return
	_reserved["%d,%d" % [x, y]] = true


func _is_reserved(x: int, y: int) -> bool:
	return _reserved.has("%d,%d" % [x, y])


# -------------------------------------------------------------
# 可达性保障：规划玩家基地到每个敌方基地的走廊（2 格宽）
# -------------------------------------------------------------
func _plan_corridors() -> void:
	for target in _enemy_base_positions:
		_plan_corridor(_player_base_pos, target)


## 从 a 到 b 规划一条带随机折线的走廊（曼哈顿 + 随机中间转折点），宽度 2 格
func _plan_corridor(a: Vector2i, b: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + a.x * 31 + b.y * 17

	# 随机决定先水平还是先垂直，并加入一个中间转折点让走廊更自然
	var mid: Vector2i
	if rng.randf() < 0.5:
		mid = Vector2i(a.x + int(rng.randi_range(0, b.x - a.x)) if b.x != a.x else a.x, b.y)
	else:
		mid = Vector2i(b.x, a.y + int(rng.randi_range(0, b.y - a.y)) if b.y != a.y else a.y)

	_carve_line(a, mid)
	_carve_line(mid, b)


## 沿曼哈顿路径雕刻 2 格宽走廊（纳入保留区）
func _carve_line(p0: Vector2i, p1: Vector2i) -> void:
	var cur := p0
	while cur != p1:
		_reserve_cell(cur.x, cur.y)
		_reserve_cell(cur.x + 1, cur.y)
		_reserve_cell(cur.x, cur.y + 1)
		_reserve_cell(cur.x + 1, cur.y + 1)
		if cur.x != p1.x:
			cur.x += 1 if p1.x > cur.x else -1
		elif cur.y != p1.y:
			cur.y += 1 if p1.y > cur.y else -1
	_reserve_cell(p1.x, p1.y)
	_reserve_cell(p1.x + 1, p1.y)
	_reserve_cell(p1.x, p1.y + 1)
	_reserve_cell(p1.x + 1, p1.y + 1)


# -------------------------------------------------------------
# 柏林噪声生成地形（避开保留区）
# -------------------------------------------------------------
func _generate_terrain() -> void:
	var water_noise := FastNoiseLite.new()
	water_noise.seed = seed_value
	water_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	water_noise.frequency = 0.035
	water_noise.fractal_octaves = 3

	var obstacle_noise := FastNoiseLite.new()
	obstacle_noise.seed = seed_value + 777
	obstacle_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	obstacle_noise.frequency = 0.09
	obstacle_noise.fractal_octaves = 2

	var deco_noise := FastNoiseLite.new()
	deco_noise.seed = seed_value + 12345
	deco_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	deco_noise.frequency = 0.07
	deco_noise.fractal_octaves = 2

	for y in range(height):
		for x in range(width):
			if _is_reserved(x, y):
				continue
			var n_water := water_noise.get_noise_2d(x, y)
			var n_obs := obstacle_noise.get_noise_2d(x, y)
			var n_deco := deco_noise.get_noise_2d(x, y)
			var water_threshold := -0.52
			var stone_threshold := 0.62
			var brick_threshold := 0.34
			var grass_threshold := 0.55
			var ice_threshold := -0.5
			match generation_style:
				"open":
					water_threshold = -0.82
					stone_threshold = 0.76
					brick_threshold = 0.48
					grass_threshold = 0.72
				"water":
					water_threshold = -0.28
					stone_threshold = 0.72
					brick_threshold = 0.44
					grass_threshold = 0.80
				"grass":
					water_threshold = -0.90
					stone_threshold = 0.72
					brick_threshold = 0.46
					grass_threshold = 0.12
				"ruins":
					water_threshold = -0.82
					stone_threshold = 0.70
					brick_threshold = 0.12
					grass_threshold = 0.80
				"ice":
					water_threshold = -0.82
					stone_threshold = 0.76
					brick_threshold = 0.50
					grass_threshold = 0.82
					ice_threshold = 0.10
				"marsh":
					water_threshold = -0.18
					stone_threshold = 0.80
					brick_threshold = 0.55
					grass_threshold = 0.20
				"fortress":
					water_threshold = -0.90
					stone_threshold = 0.48
					brick_threshold = 0.10
					grass_threshold = 0.90
				"mixed":
					water_threshold = -0.45
					stone_threshold = 0.65
					brick_threshold = 0.28
					grass_threshold = 0.45
				"finale":
					water_threshold = -0.35
					stone_threshold = 0.55
					brick_threshold = 0.18
					grass_threshold = 0.25

			# 水域（连片，低频噪声）
			if n_water < water_threshold:
				grid[y][x] = TILE_WATER
			# 障碍：石块 / 砖块
			elif n_obs > stone_threshold:
				grid[y][x] = TILE_STONE
			elif n_obs > brick_threshold:
				grid[y][x] = TILE_BRICK
			# 装饰：冰面 / 草地
			elif n_deco < ice_threshold:
				grid[y][x] = TILE_ICE
			elif n_deco > grass_threshold:
				grid[y][x] = TILE_GRASS


# -------------------------------------------------------------
# 过滤孤立小地块：小于阈值的连通块填平，让地图更自然、避免碎屑
# -------------------------------------------------------------
func _filter_small_patches() -> void:
	for tile_type in [TILE_WATER, TILE_STONE, TILE_BRICK, TILE_ICE, TILE_GRASS]:
		var min_size := 4
		if tile_type == TILE_WATER:
			min_size = 6  # 水域要求更大块才保留
		_filter_patch_of_type(tile_type, min_size)


func _filter_patch_of_type(tile_type: String, min_size: int) -> void:
	var visited: Dictionary = {}
	for y in range(height):
		for x in range(width):
			if grid[y][x] != tile_type or visited.has("%d,%d" % [x, y]):
				continue
			# BFS 找连通块
			var cells: Array = []
			var queue: Array = [Vector2i(x, y)]
			visited["%d,%d" % [x, y]] = true
			while not queue.is_empty():
				var c: Vector2i = queue.pop_front()
				cells.append(c)
				for d: Vector2i in DIRECTIONS:
					var nx := c.x + d.x
					var ny := c.y + d.y
					if nx < 0 or ny < 0 or nx >= width or ny >= height:
						continue
					var key := "%d,%d" % [nx, ny]
					if visited.has(key):
						continue
					if grid[ny][nx] == tile_type:
						visited[key] = true
						queue.append(Vector2i(nx, ny))
			# 小块填平为空地
			if cells.size() < min_size:
				for c in cells:
					grid[c.y][c.x] = TILE_EMPTY


# -------------------------------------------------------------
# 大图边界：石头围一圈，避免视野外地形割裂
# -------------------------------------------------------------
func _add_border() -> void:
	for x in range(width):
		grid[0][x] = TILE_STONE
		grid[height - 1][x] = TILE_STONE
	for y in range(height):
		grid[y][0] = TILE_STONE
		grid[y][width - 1] = TILE_STONE


# -------------------------------------------------------------
# 坦克出生点：基地朝地图中心一侧 + 左右/上下各一个（确保空地）
# -------------------------------------------------------------
func _tank_spawns_for(base_pos: Vector2i, _side: String = "") -> Array:
	var spawns: Array = []
	var center := Vector2i(width / 2, height / 2)
	var dir := center - base_pos  # 基地指向地图中心的方向

	# 主要方向（朝中心）
	var primary := Vector2i.ZERO
	if abs(dir.x) >= abs(dir.y):
		primary = Vector2i(1 if dir.x > 0 else -1, 0)
	else:
		primary = Vector2i(0, 1 if dir.y > 0 else -1)

	# 候选偏移：朝中心方向 4 格，及两侧
	var offsets: Array[Vector2i] = [
		primary * 4,
		primary * -2,  # 反方向（坦克可绕出）
	]

	for off: Vector2i in offsets:
		var sp: Vector2i = base_pos + off
		# 落在基地左右/上下的空地上
		if _valid_spawn(sp):
			spawns.append([sp.x, sp.y])

	# 兜底：至少 1 个出生点（紧邻基地）
	if spawns.is_empty():
		spawns.append([base_pos.x, base_pos.y - 2] if base_pos.y >= 2 else [base_pos.x, base_pos.y + 2])
	return spawns


func _valid_spawn(sp: Vector2i) -> bool:
	if sp.x < 1 or sp.y < 1 or sp.x >= width - 2 or sp.y >= height - 2:
		return false
	# 出生点 2x2 区域内无硬障碍
	for dy in range(2):
		for dx in range(2):
			var t := _tile_at(sp.x + dx, sp.y + dy)
			if t in HARD_BLOCK:
				return false
	return true


func _tile_at(x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= width or y >= height:
		return TILE_STONE  # 界外视为硬障碍
	return grid[y][x]


# -------------------------------------------------------------
# 死档检测：BFS 验证玩家基地到所有敌方基地可达
# 硬障碍（水面/石块）不可通过；砖块/冰面/草地/空地可通行
# -------------------------------------------------------------
func validate_reachability() -> Dictionary:
	var result := {"reachable": true, "details": []}
	for target in _enemy_base_positions:
		if not _bfs_reachable(_player_base_pos, target):
			result["reachable"] = false
			result["details"].append({"player": [_player_base_pos.x, _player_base_pos.y], "enemy": [target.x, target.y]})
	for base in [_player_base_pos] + _enemy_base_positions:
		for dy in range(2):
			for dx in range(2):
				if _tile_at(base.x + dx, base.y + dy) in HARD_BLOCK:
					result["reachable"] = false
					result["details"].append({"blocked_base": [base.x, base.y]})
		for spawn in _tank_spawns_for(base):
			var spawn_pos := Vector2i(int(spawn[0]), int(spawn[1]))
			if not _valid_spawn(spawn_pos) or not _bfs_reachable(base, spawn_pos):
				result["reachable"] = false
				result["details"].append({"blocked_spawn": [spawn_pos.x, spawn_pos.y], "base": [base.x, base.y]})
	return result


## 单格 BFS（障碍 = 水面/石块）。基地 2x2 实际取左上角作为起点/终点。
func _bfs_reachable(start: Vector2i, target: Vector2i) -> bool:
	var key := "%d,%d->%d,%d" % [start.x, start.y, target.x, target.y]
	if _reachable_cache.has(key):
		return _reachable_cache[key]

	var visited: Dictionary = {}
	var queue: Array = [start]
	visited["%d,%d" % [start.x, start.y]] = true

	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		if c == target:
			_reachable_cache[key] = true
			return true
		for d: Vector2i in DIRECTIONS:
			var nx := c.x + d.x
			var ny := c.y + d.y
			if nx < 0 or ny < 0 or nx >= width or ny >= height:
				continue
			if visited.has("%d,%d" % [nx, ny]):
				continue
			if _tile_at(nx, ny) in HARD_BLOCK:
				continue
			visited["%d,%d" % [nx, ny]] = true
			queue.append(Vector2i(nx, ny))

	_reachable_cache[key] = false
	return false


# -------------------------------------------------------------
# 生成并保证可达：死档则换种子重试
# -------------------------------------------------------------
func generate_reachable(seed_val: int, w: int, h: int, spec: Dictionary, max_retries: int = 100) -> Dictionary:
	for attempt in range(max_retries):
		var data := generate(seed_val + attempt, w, h, spec)
		if not validate_reachability()["reachable"]:
			continue
		return data
	# 理论上不会到（走廊已保证可达），兜底返回最后一次
	push_warning("MapGenerator: 可达性校验未通过，返回最后生成结果")
	return generate(seed_val, w, h, spec)
