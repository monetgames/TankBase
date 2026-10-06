extends Node2D
class_name MapManager

# 地图管理器
# 职责：加载关卡、管理瓦片、处理子弹碰撞
# 地形块符号：
# "B"：砖块（brick），所有子弹可破坏；阻挡坦克。
# "S"：石头（stone），特殊子弹（AP，穿甲弹）可破坏，阻挡其他子弹；阻挡坦克。
# "G"：草地（grass），特殊子弹（NB，燃烧弹）可破坏，不阻挡其他子弹；不阻挡坦克。
# "I"：冰面（ice），所有子弹不可破坏；不阻挡坦克。
# "W"：水面（water），所有子弹不可破坏；阻挡未使用道具"船"的坦克。
# "BP"：玩家基地（base_player），所有子弹可破坏；阻挡坦克。
# "BE"：敌方基地（base_enemy），所有子弹可破坏；阻挡坦克。
# "_"或""：空地，不阻挡子弹；不阻挡坦克。

@onready var tilemap_layer: TileMapLayer = $TileMapLayer
@onready var tilemap_overlay: TileMapLayer = $TileMapOverlay

# 相机引用 - 不使用 @onready，改为动态获取
var camera: Camera2D = null

# 背景 ColorRect（动态创建）
var background: ColorRect = null

@export var base_player_scene: PackedScene
@export var base_enemy_scene: PackedScene

# 基础配置
var tile_hp: Dictionary = {}	# 记录每个瓦片的当前 HP，key: Vector2i(cell), value: int(hp)

# 地图网格尺寸（像素）
var grid_size: int = 16

# 默认地图尺寸（格子数）
var map_width: int = 32
var map_height: int = 32

# 地图边界（像素）
var map_bounds: Rect2

# 当前关卡地图 JSON 原始数据（含 base_enemy/base_player 位置配置）
var _level_data: Dictionary = {}

# 玩家坦克引用（用于相机跟随）
var player_tank: CharacterBody2D = null

# 瓦片类型映射
var tile_source_map: Dictionary = {
	"brick": 0, "stone": 1, "grass": 2, "ice": 3, "water": 4
}

# 导航系统
var navigator: MapNavigator = null
var nav_rebuild_interval: float = 3.0  # 导航网络重构时间间隔（秒）
var nav_rebuild_timer: float = 0.0     # 导航网络重构计时器
var is_nav_active: bool = false        # 是否有正在导航的坦克


func _ready() -> void:
	# 创建黑色背景
	background = ColorRect.new()
	background.color = UIPalette.BG_DEEP  # 空地颜色与 UI 最深底色统一
	background.z_index = -100  # 确保在最底层
	background.name = "Background"
	add_child(background)
	move_child(background, 0)  # 移到第一个子节点位置
	background.add_to_group("map_persistent")  # 标记为持久节点
	
	# 获取相机节点
	camera = get_node_or_null("Camera2D")
	if camera == null:
		push_error("[地图错误] 无法找到 Camera2D 节点！")
	else:
		camera.enabled = true
		camera.make_current()
		camera.add_to_group("map_persistent")  # 标记为持久节点
	
	# 标记瓦片层为持久节点
	if tilemap_layer:
		tilemap_layer.add_to_group("map_persistent")
	if tilemap_overlay:
		tilemap_overlay.add_to_group("map_persistent")
	
	# 注册到 GameManager
	if GM.has_method("set_map_manager"):
		GM.set_map_manager(self)
	
	# 初始化导航系统
	navigator = MapNavigator.new()
	add_child(navigator)
	navigator.add_to_group("map_persistent")  # 标记为持久节点
	
	# 加载当前关卡地图（按 GM.current_stage 映射；基地位置由地图 JSON 配置决定）
	load_level_for_stage(GM.current_stage)
	
	# 首次构建导航
	_rebuild_navigation()


## 按关卡号加载对应地图（基地位置由关卡地图 JSON 的 base_enemy/base_player 配置决定）
## @param stage: 全局关卡号（1-30）
func load_level_for_stage(stage: int) -> void:
	var safe_stage := clampi(stage, 1, 30)
	var path := "res://maps/level%d.json" % safe_stage
	print("MapManager: 加载关卡 %d 地图 %s" % [stage, path])
	load_level(path)

func _physics_process(delta: float) -> void:
	# 定时重构导航网络（仅在正在导航时）
	if is_nav_active:
		nav_rebuild_timer += delta
		if nav_rebuild_timer >= nav_rebuild_interval:
			nav_rebuild_timer = 0.0
			_rebuild_navigation()
	
	# 相机跟随玩家坦克
	update_camera_follow()

# === 相机跟随 ===

# 设置玩家坦克引用
func set_player_tank(tank: CharacterBody2D) -> void:
	player_tank = tank
	
	print("=== MapManager.set_player_tank 被调用 ===")
	print("玩家坦克位置: ", tank.global_position if tank else "null")
	print("相机有效: ", is_instance_valid(camera))
	print("地图边界: ", map_bounds)
	
	# 立即将相机移动到玩家坦克位置（不使用平滑过渡）
	if is_instance_valid(camera) and is_instance_valid(player_tank):
		var target_pos = player_tank.global_position
		
		# 获取视口大小
		var viewport_size = get_viewport_rect().size
		var camera_half_width = viewport_size.x / 2.0
		var camera_half_height = viewport_size.y / 2.0
		
		print("视口大小: ", viewport_size)
		
		# 计算相机边界
		var camera_min_x = map_bounds.position.x + camera_half_width
		var camera_max_x = map_bounds.position.x + map_bounds.size.x - camera_half_width
		var camera_min_y = map_bounds.position.y + camera_half_height
		var camera_max_y = map_bounds.position.y + map_bounds.size.y - camera_half_height
		
		# 如果地图小于视口，相机居中
		if map_bounds.size.x < viewport_size.x:
			camera_min_x = map_bounds.position.x + map_bounds.size.x / 2.0
			camera_max_x = camera_min_x
		if map_bounds.size.y < viewport_size.y:
			camera_min_y = map_bounds.position.y + map_bounds.size.y / 2.0
			camera_max_y = camera_min_y
		
		print("相机边界: min_x=", camera_min_x, " max_x=", camera_max_x, " min_y=", camera_min_y, " max_y=", camera_max_y)
		
		# 限制相机位置并立即设置
		target_pos.x = clamp(target_pos.x, camera_min_x, camera_max_x)
		target_pos.y = clamp(target_pos.y, camera_min_y, camera_max_y)
		
		print("目标相机位置: ", target_pos)
		print("相机当前位置(设置前): ", camera.global_position)
		
		camera.global_position = target_pos
		
		print("相机当前位置(设置后): ", camera.global_position)
		print("=== set_player_tank 完成 ===")
	else:
		print("ERROR: 相机或玩家坦克无效！")
		print("=== set_player_tank 失败 ===")

# 更新相机跟随
func update_camera_follow() -> void:
	# 验证玩家坦克有效性
	if not is_instance_valid(player_tank):
		return
	
	# 验证相机有效性
	if not is_instance_valid(camera):
		push_error("[相机错误] 相机引用失效！这不应该发生。")
		return
	
	# 获取视口大小（相机可见区域）
	var viewport_size = get_viewport_rect().size
	
	# 计算相机可移动的边界
	# 相机中心不能超出地图边界，否则会显示地图外的空白
	var camera_half_width = viewport_size.x / 2.0
	var camera_half_height = viewport_size.y / 2.0
	
	var camera_min_x = map_bounds.position.x + camera_half_width
	var camera_max_x = map_bounds.position.x + map_bounds.size.x - camera_half_width
	var camera_min_y = map_bounds.position.y + camera_half_height
	var camera_max_y = map_bounds.position.y + map_bounds.size.y - camera_half_height
	
	# 如果地图小于视口，相机居中不移动
	if map_bounds.size.x < viewport_size.x:
		camera_min_x = map_bounds.position.x + map_bounds.size.x / 2.0
		camera_max_x = camera_min_x
	if map_bounds.size.y < viewport_size.y:
		camera_min_y = map_bounds.position.y + map_bounds.size.y / 2.0
		camera_max_y = camera_min_y
	
	# 平滑跟随玩家坦克
	var target_pos = player_tank.global_position
	var new_camera_pos = camera.global_position.lerp(target_pos, 0.1)
	
	# 限制相机位置在边界内
	new_camera_pos.x = clamp(new_camera_pos.x, camera_min_x, camera_max_x)
	new_camera_pos.y = clamp(new_camera_pos.y, camera_min_y, camera_max_y)
	
	camera.global_position = new_camera_pos

# 将相机聚焦到指定位置（带边界限制）
func focus_camera_on_position(target_position: Vector2) -> void:
	if not is_instance_valid(camera):
		push_error("[相机错误] 相机引用失效！")
		return
	
	# 获取视口大小
	var viewport_size = get_viewport_rect().size
	var camera_half_width = viewport_size.x / 2.0
	var camera_half_height = viewport_size.y / 2.0
	
	# 计算相机边界
	var camera_min_x = map_bounds.position.x + camera_half_width
	var camera_max_x = map_bounds.position.x + map_bounds.size.x - camera_half_width
	var camera_min_y = map_bounds.position.y + camera_half_height
	var camera_max_y = map_bounds.position.y + map_bounds.size.y - camera_half_height
	
	# 如果地图小于视口，相机居中
	if map_bounds.size.x < viewport_size.x:
		camera_min_x = map_bounds.position.x + map_bounds.size.x / 2.0
		camera_max_x = camera_min_x
	if map_bounds.size.y < viewport_size.y:
		camera_min_y = map_bounds.position.y + map_bounds.size.y / 2.0
		camera_max_y = camera_min_y
	
	# 限制相机位置并立即设置
	var clamped_pos = Vector2(
		clamp(target_position.x, camera_min_x, camera_max_x),
		clamp(target_position.y, camera_min_y, camera_max_y)
	)
	camera.global_position = clamped_pos
	print("MapManager: Camera focused on position: ", clamped_pos)

# 检查位置是否在地图边界内
func is_position_in_bounds(pos: Vector2) -> bool:
	return map_bounds.has_point(pos)

# 限制位置在地图边界内
func clamp_position_to_bounds(pos: Vector2) -> Vector2:
	return Vector2(
		clamp(pos.x, map_bounds.position.x, map_bounds.position.x + map_bounds.size.x),
		clamp(pos.y, map_bounds.position.y, map_bounds.position.y + map_bounds.size.y)
	)

# 检查坦克位置是否在地图边界内（考虑坦克尺寸）
func is_tank_position_in_bounds(pos: Vector2, tank_size: float = 32.0) -> bool:
	var half_size = tank_size / 2.0
	var tank_bounds = Rect2(
		map_bounds.position.x + half_size,
		map_bounds.position.y + half_size,
		map_bounds.size.x - tank_size,
		map_bounds.size.y - tank_size
	)
	return tank_bounds.has_point(pos)

# 限制坦克位置在地图边界内（考虑坦克尺寸）
func clamp_tank_position_to_bounds(pos: Vector2, tank_size: float = 32.0) -> Vector2:
	var half_size = tank_size / 2.0
	return Vector2(
		clamp(pos.x, map_bounds.position.x + half_size, map_bounds.position.x + map_bounds.size.x - half_size),
		clamp(pos.y, map_bounds.position.y + half_size, map_bounds.position.y + map_bounds.size.y - half_size)
	)

# === 子弹管理 ===

# 添加子弹到正确的容器中
func add_bullet(bullet: Node2D) -> void:
	add_child(bullet)

# 获取子弹容器（确保子弹在正确的坐标系统中）
func get_bullet_container() -> Node2D:
	return self

# 添加获取导航器的方法
func get_navigator() -> MapNavigator:
	return navigator

# 标记导航状态
func set_navigation_active(active: bool) -> void:
	is_nav_active = active

## 获取关卡地图配置的敌方基地位置列表（由关卡设计决定）
## @return: base_enemy 配置数组（每项含 pos/tank_spawn_pos/level）
func get_base_enemy_configs() -> Array:
	return _level_data.get("base_enemy", [])


## 清理基地占用的瓦片（基地 2×2 格 + 坦克出生点），供 WaveManager 生成基地前调用
## @param base_pos: 基地左上角格子坐标（[x,y] 数组 或 Vector2）
## @param tank_spawns: 坦克出生点格子坐标数组（可为空）
func clear_base_area(base_pos: Variant, tank_spawns: Array = []) -> void:
	var gx: int = int(base_pos[0])
	var gy: int = int(base_pos[1])
	for dy in range(2):
		for dx in range(2):
			_clear_tile(Vector2i(gx + dx, gy + dy))
	for sp in tank_spawns:
		if (sp as Array).size() == 2:
			for dy in range(2):
				for dx in range(2):
					_clear_tile(Vector2i(int(sp[0]) + dx, int(sp[1]) + dy))


func get_enemy_spawn_position() -> Vector2:
	var margin := 3  # 距地图边缘的最小格子数
	var base_size := 2  # 基地占 2x2 格
	# 限制在地图上半部分（前 40% 行）
	var max_row := int(map_height * 0.4)
	var blocked_types := ["stone", "water", "brick"]
	
	# 随机尝试最多 200 次，找到合适的空地
	for _i in range(200):
		var gx := randi_range(margin, map_width - margin - base_size)
		var gy := randi_range(margin, max_row - base_size)
		if _is_area_clear(gx, gy, base_size, base_size, blocked_types):
			return Vector2(gx * grid_size, gy * grid_size)
	
	# 找不到合适位置时，回退到地图上方中央
	push_warning("MapManager: 无法找到合适的敌方基地生成位置，使用默认位置")
	return Vector2(map_width / 2 * grid_size, margin * grid_size)

## 检查指定区域（格子坐标）是否全部为空地
func _is_area_clear(gx: int, gy: int, w: int, h: int, blocked_types: Array) -> bool:
	for dy in range(h):
		for dx in range(w):
			var cell := Vector2i(gx + dx, gy + dy)
			var tile_info := _get_tile_info(cell)
			if not tile_info.is_empty() and tile_info.type in blocked_types:
				return false
	return true

# 重构导航网络
func _rebuild_navigation() -> void:
	if navigator == null:
		return
	
	print("重构导航网络...")
	navigator.build_from_tilemap(
		tilemap_layer,
		tilemap_overlay,
		get_base_positions("player"),
		get_base_positions("enemy"),
		navigator.nav_grid_size,
		Vector2.ZERO,
		Vector2i(map_width, map_height)
	)

# === 获取基地位置 ===

# 获取指定类型基地的位置数组
func get_base_positions(base_type: String) -> Array:
	var positions = []
	
	match base_type:
		"player":
			# 从 GameManager 获取玩家基地并转换为网格坐标
			for base_node in GM.get_player_bases():
				if is_instance_valid(base_node):
					var grid_pos = world_to_grid(base_node.global_position)
					positions.append([grid_pos.x, grid_pos.y])
		
		"enemy":
			# 从 GameManager 获取敌方基地并转换为网格坐标
			for base_node in GM.get_enemy_bases():
				if is_instance_valid(base_node):
					var grid_pos = world_to_grid(base_node.global_position)
					positions.append([grid_pos.x, grid_pos.y])
		
		_:
			push_warning("未知的基地类型: " + base_type)
	
	return positions

# 世界坐标转网格坐标
func world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / grid_size)),
		int(floor(world_pos.y / grid_size))
	)

# 网格坐标转世界坐标
func grid_to_world(grid_pos: Vector2i) -> Vector2:
	return Vector2(
		(grid_pos.x + 0.5) * grid_size,
		(grid_pos.y + 0.5) * grid_size
	)

# === 关卡加载 ===

func load_level(path: String) -> void:
	# 清空地图（注意：延迟到文件解析与配置校验通过后再执行，避免坏地图清掉当前关卡）
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("无法打开关卡文件: " + path)
		return
	
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("JSON解析错误: " + json.get_error_message())
		return
	file.close()
	
	var result = json.get_data()
	if typeof(result) != TYPE_DICTIONARY:
		push_error("关卡数据格式错误，预期为字典")
		return
	
	# 校验基地位置配置：关卡地图必须声明 base_enemy 与 base_player 位置（关卡设计决定）
	if typeof(result.get("base_enemy")) != TYPE_ARRAY or (result.get("base_enemy") as Array).is_empty():
		push_error("关卡配置文件错误（不兼容）：缺少 base_enemy 位置设定，请在地图 JSON 中配置敌方基地位置")
		return
	if typeof(result.get("base_player")) != TYPE_ARRAY or (result.get("base_player") as Array).is_empty():
		push_error("关卡配置文件错误（不兼容）：缺少 base_player 位置设定，请在地图 JSON 中配置我方基地位置")
		return
	
	# 校验通过后才存储地图原始数据（含基地位置配置）
	_level_data = result	

	# 读取地图尺寸
	var size_data = result.get("size")
	if typeof(size_data) == TYPE_ARRAY and size_data.size() == 2:
		map_width = size_data[0]
		map_height = size_data[1]
		# 计算地图边界（像素）
		map_bounds = Rect2(0, 0, map_width * grid_size, map_height * grid_size)
		print("地图尺寸: %dx%d 格子, %dx%d 像素" % [map_width, map_height, map_bounds.size.x, map_bounds.size.y])
	else:
		# 使用默认尺寸
		map_width = 32
		map_height = 32
		map_bounds = Rect2(0, 0, map_width * grid_size, map_height * grid_size)
		print("使用默认地图尺寸: %dx%d" % [map_width, map_height])
	
	# 更新背景大小以匹配地图
	if background:
		background.position = map_bounds.position
		background.size = map_bounds.size

	# 加载地图数据
	var level_map = result.get("map") 
	# 遍历level_data字典
	if typeof(level_map) != TYPE_DICTIONARY:
		push_error("关卡地图数据格式错误，预期为字典")
		return
	
	# 配置校验全部通过，此时才清空旧地图与旧引用（避免坏地图/坏数据清掉当前关卡）
	clear_map()
	GM.reset()

	# 优先加载瓦片类型
	for tile_type in tile_source_map.keys():
		if level_map.has(tile_type) and typeof(level_map[tile_type]) == TYPE_ARRAY:
			for pos in level_map[tile_type]:
				if typeof(pos) == TYPE_ARRAY and pos.size() == 2:
					create_tile(pos[0], pos[1], tile_type)
				else:
					push_error("无效的坐标格式: " + str(pos))
	
	# 加载玩家基地（常驻，位置由地图配置决定）
	# 注意：敌方基地不在此创建——由 WaveManager 按波次从 base_enemy 位置配置生成，避免双份
	var level_base_player = result.get("base_player")
	if typeof(level_base_player) == TYPE_ARRAY:
		for base_info in level_base_player:
			if typeof(base_info) == TYPE_DICTIONARY:
				var bp := create_base_player(base_info)
				if bp != null:
					GM.register_base_player(bp)
				else:
					push_error("创建玩家基地失败: " + str(base_info))
			else:
				push_error("无效的基地信息格式: " + str(base_info))

	print("成功加载关卡: " + path)
	
	# 额外输出关卡信息
	var level_info = result.get("info", {})
	if typeof(level_info) == TYPE_DICTIONARY and not level_info.is_empty():
		GM.set_level_info(level_info)
		print("关卡名称: " + level_info.get("name", ""))
		print("关卡作者: " + level_info.get("author", ""))
		print("关卡描述: " + level_info.get("description", ""))
		print("关卡版本: " + level_info.get("version", ""))

# 保持关卡到JSON文件
func save_level(path: String) -> void:
	var level_map: Dictionary = {}

	# 瓦片
	var used_cells = tilemap_layer.get_used_cells() + tilemap_overlay.get_used_cells()
	for cell in used_cells:
		var tile_info = _get_tile_info(cell)
		if tile_info.is_empty():
			continue
		var tile_type = tile_info.type
		if not tile_source_map.has(tile_type):
			continue
		if not level_map.has(tile_type):
			level_map[tile_type] = []
		level_map[tile_type].append([cell.x, cell.y])

	var level_data: Dictionary = { "map": level_map }

	# 基地：从 GameManager 汇总为顶层字段（与 load 对齐）
	var bases_enemy: Array = []
	for be in GM.get_enemy_bases():
		if is_instance_valid(be):
			var gx := int(round((be.position.x) / float(grid_size)))
			var gy := int(round((be.position.y) / float(grid_size)))
			var rec := { "pos": [gx, gy] }
			var tank_spawn_pos: Array = []
			for tank_spawn in be.enemy_tank_factory.tank_spawn_positions:
				var sx = int(round((tank_spawn.x) / float(grid_size))) - 1
				var sy = int(round((tank_spawn.y) / float(grid_size))) - 1
				tank_spawn_pos.append([sx, sy])
			if tank_spawn_pos.size() > 0:
				rec["tank_spawn_pos"] = tank_spawn_pos
			if "level" in be: rec["level"] = be.level
			if "cfg_max_hp" in be: rec["max_hp"] = be.cfg_max_hp
			# 工厂配置
			var enemy_tank_factory = {
				"maximum_spawn": be.enemy_tank_factory.maximum_spawn ,
				"spawn_interval": be.enemy_tank_factory.spawn_interval
			}
			rec["FactoryTank"] = enemy_tank_factory
			bases_enemy.append(rec)
	var bases_player: Array = []
	for bp in GM.get_player_bases():
		if is_instance_valid(bp):
			var gx2 := int(round((bp.position.x) / float(grid_size)))
			var gy2 := int(round((bp.position.y) / float(grid_size)))
			var rec2 := { "pos": [gx2, gy2] }
			var tank_spawn_pos2: Array = []
			for tank_spawn in bp.player_tank_factory.tank_spawn_positions:
				var sx2 = int(round((tank_spawn.x) / float(grid_size))) - 1
				var sy2 = int(round((tank_spawn.y) / float(grid_size))) - 1
				tank_spawn_pos2.append([sx2, sy2])
			if tank_spawn_pos2.size() > 0:
				rec2["tank_spawn_pos"] = tank_spawn_pos2
			if "level" in bp: rec2["level"] = bp.level
			if "cfg_max_hp" in bp: rec2["max_hp"] = bp.cfg_max_hp
			bases_player.append(rec2)
	
	if bases_enemy.size() > 0:
		level_data["base_enemy"] = bases_enemy
	if bases_player.size() > 0:
		level_data["base_player"] = bases_player

	var info = GM.get_level_info()
	if info.size() > 0:
		level_data["info"] = info

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法打开文件进行写入: " + path)
		return
	file.store_string(JSON.stringify(level_data))
	file.close()
	print("成功保存关卡到: " + path)

# 创建瓦片
func create_tile(x: int, y: int, symbol: String) -> void:
	if symbol == "grass":
		_set_tile(tilemap_overlay, Vector2i(x, y), symbol)  # 草地在覆盖层
	else:
		_set_tile(tilemap_layer, Vector2i(x, y), symbol)

# 创建玩家基地
func create_base_player(base_info: Dictionary) -> Node2D:
	# 清除基地（32*32）位置的瓦片（占用2x2格）
	for dy in range(2):
		for dx in range(2):
			_clear_tile(Vector2i(base_info["pos"][0] + dx, base_info["pos"][1] + dy))
			for tank_spawn in base_info.get("tank_spawn_pos", []):
				_clear_tile(Vector2i(tank_spawn[0] + dx, tank_spawn[1] + dy))
	var base_position := grid_size * Vector2(base_info["pos"][0], base_info["pos"][1])
	var base_player = base_player_scene.instantiate()
	add_child(base_player)
	base_player.set_base_pos("player", base_position)
	if base_info.has("level"):
		base_player.base_level = int(base_info["level"])
	# 注意：max_hp 从 player_base.json 配置读取，地图文件的 max_hp 字段已废弃，忽略
	# 基地工厂：坦克工厂
	if is_instance_valid(base_player.player_tank_factory):
		for tank_spawn in base_info.get("tank_spawn_pos", []):
			base_player.player_tank_factory.tank_spawn_positions.append(grid_size * Vector2(tank_spawn[0] + 1, tank_spawn[1] + 1))
	return base_player

# 创建敌方基地
func create_base_enemy(base_info: Dictionary) -> Node2D:
	# 清除基地、坦克（32*32）位置的瓦片（占用2x2格）
	for dy in range(2):
		for dx in range(2):
			_clear_tile(Vector2i(base_info["pos"][0] + dx, base_info["pos"][1] + dy))
			for tank_spawn in base_info.get("tank_spawn_pos", []):
				_clear_tile(Vector2i(tank_spawn[0] + dx, tank_spawn[1] + dy))
	# 实例化敌方基地前显示出生光标（基地本体的原点在左上角）。
	var base_position := grid_size * Vector2(base_info["pos"][0], base_info["pos"][1])
	SpawnFlashEffect.spawn_at(self, base_position + Vector2(grid_size, grid_size))
	var base_enemy = base_enemy_scene.instantiate()
	add_child(base_enemy)
	base_enemy.set_base_pos("enemy", base_position)
	# 按地图标注的等级（int 1/2/3）设置基地，数值统一由 base_enemy 从 enemy_units.json 读取
	if base_info.has("level"):
		var level_key := "normal"
		match int(base_info["level"]):
			2: level_key = "elite"
			3: level_key = "boss"
		base_enemy.set_level(level_key)
	# 基地坦克工厂：仅设置出生点（布局信息），生产间隔/最大在场数由 base_enemy 从配置读取
	if is_instance_valid(base_enemy.enemy_tank_factory):
		for tank_spawn in base_info.get("tank_spawn_pos", []):
			base_enemy.enemy_tank_factory.tank_spawn_positions.append(grid_size * Vector2(tank_spawn[0] + 1, tank_spawn[1] + 1))
	return base_enemy

# 设置瓦片
func _set_tile(layer: TileMapLayer, cell: Vector2i, tile_type: String) -> void:
	var source_id = tile_source_map.get(tile_type, -1)
	if source_id >= 0:
		layer.set_cell(cell, source_id, Vector2i(0, 0), 0)

# 清理 tilemap 的某个瓦片
func _clear_tile(cell: Vector2i) -> void:
	tilemap_layer.set_cell(cell)
	tilemap_overlay.set_cell(cell)

# 清空整个地图
func clear_map() -> void:
	for child in get_children():
		# 只删除不在 "map_persistent" 组中的节点
		# 持久节点包括：相机、瓦片层、导航器、背景等
		if not child.is_in_group("map_persistent"):
			child.queue_free()
	
	tilemap_layer.clear()
	tilemap_overlay.clear()
	tile_hp.clear()


# === 子弹碰撞检测 ===
# 返回值：
#	0：没碰撞，不阻挡子弹
#	1：阻挡子弹
func bullet_hit(start_pos: Vector2, end_pos: Vector2, damage: int, bullet_type: GM.DamageType, algorithm: String = "Bresenham") -> int:
	var local_start = tilemap_layer.to_local(start_pos)
	var local_end = tilemap_layer.to_local(end_pos)
	var hit_result = {}
	
	# 瓦片碰撞检测
	# 根据选择的算法进行碰撞检测
	if algorithm == "DDA":
		# 使用 DDA 算法
		hit_result = _raycast_dda_with_corner_handling(local_start, local_end, bullet_type)
	else:
		# 默认使用 Bresenham 算法
		hit_result = _raycast_bresenham_with_corner(local_start, local_end, bullet_type)
	if hit_result.is_empty():
		return 0  # 没有碰撞

	# 获取命中瓦片信息
	var tile_info = _get_tile_info(hit_result.cell)
	if tile_info.is_empty():
		return 0  # 没查找到瓦片

	# 检查子弹是否能击中这种瓦片
	var can_hit_and_damage = _can_hit_and_damage_tiles(tile_info.type, bullet_type)
	if can_hit_and_damage.is_empty() or not can_hit_and_damage.hit:
		return 0  # 不能击中该类型瓦片

	# 检查子弹是否能伤害该瓦片
	if can_hit_and_damage.damage:
		# 处理伤害
		_damage_tile(hit_result.cell, tile_info, damage)
	
	return 1  # 瓦片阻挡子弹

# Bresenham 算法，保持对拐角处理能力
func _raycast_bresenham_with_corner(start_local: Vector2, end_local: Vector2, bullet_type: GM.DamageType) -> Dictionary:
	var start_cell: Vector2i = tilemap_layer.local_to_map(start_local)
	var end_cell: Vector2i   = tilemap_layer.local_to_map(end_local)
	
	var cur: Vector2i = start_cell
	var dx: int = end_cell.x - start_cell.x
	var dy: int = end_cell.y - start_cell.y
	var sx: int = (1 if dx > 0 else (-1 if dx < 0 else 0))
	var sy: int = (1 if dy > 0 else (-1 if dy < 0 else 0))
	dx = abs(dx)
	dy = abs(dy)
	
	# 起始格若可阻挡直接返回
	if _can_hit_tiles(cur, bullet_type):
		return {"cell": cur}
	
	var err: int = dx - dy
	
	# 遍历
	while cur != end_cell:
		var step_x := false
		var step_y := false
		var e2: int = err * 2
		
		if e2 > -dy:
			err -= dy
			step_x = true
		if e2 < dx:
			err += dx
			step_y = true
		
		# 同时跨格 => 角落（对角）情况，需要挑选
		if step_x and step_y:
			var cand_x := Vector2i(cur.x + sx, cur.y)
			var cand_y := Vector2i(cur.x, cur.y + sy)
			
			var block_x := _can_hit_tiles(cand_x, bullet_type)
			var block_y := _can_hit_tiles(cand_y, bullet_type)
			
			if block_x and not block_y:
				cur = cand_x
			elif block_y and not block_x:
				cur = cand_y
			elif not block_x and not block_y:
				# 两个都不阻挡 => 真正对角前进
				cur.x += sx
				cur.y += sy
			else:
				# 两个都阻挡 => 选更贴近射线方向的
				cur = _pick_corner_block(cand_x, cand_y, start_local, end_local)
		elif step_x:
			cur.x += sx
		elif step_y:
			cur.y += sy
		else:
			break  # 理论不会发生
		
		if _can_hit_tiles(cur, bullet_type):
			return {"cell": cur}
	
	return {}

# 角落同时两个候选格都阻挡时，选与射线路径更贴近的那个
func _pick_corner_block(cand_x: Vector2i, cand_y: Vector2i, start_local: Vector2, end_local: Vector2) -> Vector2i:
	var ray_dir: Vector2 = (end_local - start_local).normalized()
	var center_x: Vector2 = tilemap_layer.map_to_local(cand_x)
	var center_y: Vector2 = tilemap_layer.map_to_local(cand_y)
	var to_x: Vector2 = (center_x - start_local).normalized()
	var to_y: Vector2 = (center_y - start_local).normalized()
	var angle_x: float = absf(ray_dir.angle_to(to_x))
	var angle_y: float = absf(ray_dir.angle_to(to_y))
	return cand_x if angle_x <= angle_y else cand_y


# 改进的DDA算法，专门处理对角碰撞
func _raycast_dda_with_corner_handling(start_local: Vector2, end_local: Vector2, bullet_type: GM.DamageType) -> Dictionary:
	var dx = end_local.x - start_local.x
	var dy = end_local.y - start_local.y
	
	# 当前格子坐标
	var current_cell = tilemap_layer.local_to_map(start_local)
	var target_cell = tilemap_layer.local_to_map(end_local)
	
	# 如果起点和终点在同一格子，直接检查该格子
	if current_cell == target_cell:
		if _can_hit_tiles(current_cell, bullet_type):
			return {"cell": current_cell}
		return {}
	
	# DDA参数
	var abs_dx = abs(dx)
	var abs_dy = abs(dy)
	var step_x = 1 if dx > 0 else -1
	var step_y = 1 if dy > 0 else -1
	
	# 到下一个格子边界的距离
	var next_x = current_cell.x + (0.5 if step_x > 0 else -0.5)
	var next_y = current_cell.y + (0.5 if step_y > 0 else -0.5)
	
	# 计算t值（射线参数）
	var t_max_x = INF if abs_dx < 0.0001 else (next_x * grid_size - start_local.x) / dx
	var t_max_y = INF if abs_dy < 0.0001 else (next_y * grid_size - start_local.y) / dy
	var t_delta_x = INF if abs_dx < 0.0001 else abs(grid_size / dx)
	var t_delta_y = INF if abs_dy < 0.0001 else abs(grid_size / dy)
	
	# 遍历格子
	var max_steps = abs(target_cell.x - current_cell.x) + abs(target_cell.y - current_cell.y) + 2
	
	for i in range(max_steps):
		# 检查当前格子
		if _can_hit_tiles(current_cell, bullet_type):
			return {"cell": current_cell}
		
		# 如果到达目标，结束
		if current_cell == target_cell:
			break
		
		# 关键：对角碰撞处理
		var epsilon = 0.0001
		if abs(t_max_x - t_max_y) < epsilon:
			# 几乎同时到达X和Y边界（对角情况）
			var corner_result = _handle_corner_collision(current_cell, step_x, step_y, bullet_type, start_local, dx, dy)
			if not corner_result.is_empty():
				return corner_result
			
			# 两个方向都前进
			current_cell.x += step_x
			current_cell.y += step_y
			t_max_x += t_delta_x
			t_max_y += t_delta_y
		elif t_max_x < t_max_y:
			# X方向先到达边界
			current_cell.x += step_x
			t_max_x += t_delta_x
		else:
			# Y方向先到达边界
			current_cell.y += step_y
			t_max_y += t_delta_y
	
	return {}

# 处理对角碰撞：选择夹角更小的格子
func _handle_corner_collision(current_cell: Vector2i, step_x: int, step_y: int, bullet_type: GM.DamageType, start_local: Vector2, dx: float, dy: float) -> Dictionary:
	# 候选格子：X方向和Y方向的相邻格子
	var candidate_x = Vector2i(current_cell.x + step_x, current_cell.y)
	var candidate_y = Vector2i(current_cell.x, current_cell.y + step_y)
	
	# 检查哪些候选格子会阻挡子弹
	var blocks_x = _can_hit_tiles(candidate_x, bullet_type)
	var blocks_y = _can_hit_tiles(candidate_y, bullet_type)
	
	# 如果只有一个阻挡，选择它
	if blocks_x and not blocks_y:
		return {"cell": candidate_x}
	elif blocks_y and not blocks_x:
		return {"cell": candidate_y}
	elif not blocks_x and not blocks_y:
		return {}  # 都不阻挡，继续
	
	# 两个都阻挡：计算夹角，选择更小的
	var ray_dir = Vector2(dx, dy).normalized()
	
	# 计算到格子中心的方向向量
	var center_x = tilemap_layer.map_to_local(candidate_x)
	var center_y = tilemap_layer.map_to_local(candidate_y)
	
	var to_x = (center_x - start_local).normalized()
	var to_y = (center_y - start_local).normalized()
	
	# 计算夹角
	var angle_x = abs(ray_dir.angle_to(to_x))
	var angle_y = abs(ray_dir.angle_to(to_y))
	
	# 选择夹角更小的（更接近射线方向的）
	if angle_x < angle_y:
		return {"cell": candidate_x}
	elif angle_y < angle_x:
		return {"cell": candidate_y}
	else:
		# 夹角相等（45度），选择X方向（或可以随机选择）
		return {"cell": candidate_x}

# 是否可以攻击（子弹在该瓦片处被阻挡并销毁）瓦片或物理对象
func _can_hit_tiles(cell: Vector2i, bullet_type: GM.DamageType) -> bool:
	var tile_info = _get_tile_info(cell)
	if tile_info.is_empty():
		return false

	var can_hit_and_damage = _can_hit_and_damage_tiles(tile_info.type, bullet_type)
	if can_hit_and_damage.is_empty():
		return false

	return can_hit_and_damage.hit


## 检查射线弹道是否被地形阻挡（只查询，不造成伤害，供 AI 选射击位用）
## 返回 { "blocked": bool, "type": String, "destructible": bool }
## type/destructible 仅在 blocked=true 时有意义；destructible=阻挡地形能否被该子弹类型击毁
func check_shot_blocked(from_pos: Vector2, to_pos: Vector2, bullet_type: GM.DamageType = GM.DamageType.NORMAL) -> Dictionary:
	var no_hit := {"blocked": false, "type": "", "destructible": false}
	var local_start = tilemap_layer.to_local(from_pos)
	var local_end = tilemap_layer.to_local(to_pos)
	var hit_result = _raycast_bresenham_with_corner(local_start, local_end, bullet_type)
	if hit_result.is_empty():
		return no_hit
	var tile_info = _get_tile_info(hit_result.cell)
	if tile_info.is_empty():
		return no_hit
	var can = _can_hit_and_damage_tiles(tile_info.type, bullet_type)
	if can.is_empty() or not can.hit:
		return no_hit
	return {"blocked": true, "type": tile_info.type, "destructible": bool(can.damage)}

# 获取瓦片信息
# 返回字典，包含：
#	"layer": TileMapLayer
#	"type": String
#	"tile_data": TileData
# 如果没有瓦片，返回空字典
func _get_tile_info(cell: Vector2i) -> Dictionary:
	# 先检查覆盖层（草地）
	var overlay_id = tilemap_overlay.get_cell_source_id(cell)
	if overlay_id != -1:
		var tile_data = tilemap_overlay.get_cell_tile_data(cell)
		if tile_data:
			return {
				"layer": tilemap_overlay,
				"type": String(tile_data.get_custom_data("type")),
				"tile_data": tile_data
			}
	
	# 再检查基础层
	var base_id = tilemap_layer.get_cell_source_id(cell)
	if base_id != -1:
		var tile_data = tilemap_layer.get_cell_tile_data(cell)
		if tile_data:
			return {
				"layer": tilemap_layer,
				"type": String(tile_data.get_custom_data("type")),
				"tile_data": tile_data
			}
	
	return {}


## 获取世界坐标处的地形类型字符串（空地返回 ""）
func get_tile_type_at(world_pos: Vector2) -> String:
	var local_pos = tilemap_layer.to_local(world_pos)
	var cell = tilemap_layer.local_to_map(local_pos)
	var info = _get_tile_info(cell)
	return info.get("type", "")
# 返回字典：
# { "hit": bool, "damage": bool }
# 含义：
#   hit=true     可攻击，子弹在该瓦片处被阻挡并销毁
#   damage=true  可伤害，子弹类型可对该瓦片造成伤害
func _can_hit_and_damage_tiles(tile_type: String, bullet_type: GM.DamageType) -> Dictionary:
	match tile_type:
		"brick", "base_player", "base_enemy":
			return {"hit": true, "damage": true}
		"stone":
			# 所有子弹被阻挡；只有 AP 子弹能造成伤害
			return {"hit": true, "damage": bullet_type == GM.DamageType.AP}
		"grass":
			# 只有 NB 子弹会被草拦下并能烧毁
			var nb = bullet_type == GM.DamageType.NB
			return {"hit": nb, "damage": nb}
		"water", "ice":
			return {"hit": false, "damage": false}
		_:
			return {"hit": false, "damage": false}

# 处理瓦片受损
func _damage_tile(cell: Vector2i, tile_info: Dictionary, damage: int) -> void:
	var layer = tile_info.layer
	var tile_data = tile_info.tile_data
	
	# 初始化HP
	if not tile_hp.has(cell):
		var initial_hp = tile_data.get_custom_data("hp")
		if initial_hp == null:
			push_error(tile_info.layer.name + " 的 " + tile_info.type +" 瓦片缺少 hp 自定义数据")
			tile_hp[cell] = 1 # 默认1点血
		else:
			tile_hp[cell] = int(initial_hp)
	
	# 扣血
	tile_hp[cell] -= damage
	
	if tile_hp[cell] <= 0:
		# 销毁瓦片
		_destroy_tile(cell, layer)
	else:
		# 备用：显示受损状态
		_show_damaged_tile(cell, layer, tile_data)

# 销毁瓦片
func _destroy_tile(cell: Vector2i, layer: TileMapLayer) -> void:
	layer.set_cell(cell)  # 清空瓦片
	tile_hp.erase(cell)

# 备用：显示受损瓦片（更换为受损瓦片ID）
func _show_damaged_tile(cell: Vector2i, layer: TileMapLayer, tile_data: TileData) -> void:
	var damaged_id = tile_data.get_custom_data("damaged_tile_id")
	if damaged_id != null and int(damaged_id) != -1:
		layer.set_cell(cell, int(damaged_id), Vector2i(0, 0), 0)
