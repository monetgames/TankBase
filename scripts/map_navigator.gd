extends Node
class_name MapNavigator

# MapNavigator - 基于 AStarGrid2D 的导航系统，支持"船"道具
# 职责：管理两套导航网格（有船/无船），提供根据坦克状态寻路的功能

# 两套导航网格：一套用于有船坦克，一套用于无船坦克
var astar_grid_no_boat: AStarGrid2D = AStarGrid2D.new()  # 无船导航网格（水面不可通行）
var astar_grid_with_boat: AStarGrid2D = AStarGrid2D.new()  # 有船导航网格（水面可通行）

# 当前激活的导航网格（根据坦克是否有船选择）
var current_astar_grid: AStarGrid2D

# 配置参数
var nav_grid_size: int = 16 # 导航网格单元格大小（像素）
var origin: Vector2 = Vector2.ZERO
var grid_width: int = 0
var grid_height: int = 0

# 常量
const TANK_GRID: int = 2 # 坦克占据的格子数（2x2）

# === 主要接口 ===

# 从 TileMap 数据构建导航图
func build_from_tilemap(tilemap_layer: TileMapLayer, tilemap_overlay: TileMapLayer, 
					   base_player_positions: Array, base_enemy_positions: Array, 
					   p_grid_size: int = 16, p_origin: Vector2 = Vector2.ZERO,
					   p_map_size: Vector2i = Vector2i.ZERO) -> void:
	# 初始化配置
	_reset_navigator()
	nav_grid_size = p_grid_size
	origin = p_origin
	
	# 导航网格覆盖范围：优先用完整地图尺寸。
	# 空地不铺瓦片，tilemap_layer.get_used_rect() 只覆盖障碍物包围矩形，会导致导航网格偏小、
	# 玩家基地等空地坐标越界。
	var nav_rect: Rect2i
	if p_map_size.x > 0 and p_map_size.y > 0:
		nav_rect = Rect2i(0, 0, p_map_size.x, p_map_size.y)
	else:
		nav_rect = tilemap_layer.get_used_rect()
	grid_width = nav_rect.size.x
	grid_height = nav_rect.size.y
	
	# 配置两套 AStarGrid2D
	var astar_grids = [astar_grid_no_boat, astar_grid_with_boat]
	for astar_grid in astar_grids:
		astar_grid.region = Rect2i(nav_rect.position.x, nav_rect.position.y, grid_width, grid_height)
		astar_grid.cell_size = Vector2(nav_grid_size, nav_grid_size)
		astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER  # 坦克只能上下左右移动
		astar_grid.update()
	
	# 构建导航网格
	_build_navigation_from_tilemaps(tilemap_layer, tilemap_overlay, base_player_positions, base_enemy_positions, nav_rect)
	
	# 默认使用无船导航网格
	current_astar_grid = astar_grid_no_boat

# 获取从起点到终点的路径（根据坦克是否有船选择导航网格）
func get_nav_path(from_pos: Vector2, to_pos: Vector2, has_boat: bool = false) -> PackedVector2Array:
	if grid_width <= 0 or grid_height <= 0:
		return PackedVector2Array()
	
	# 根据是否有船选择导航网格
	var astar_grid = astar_grid_with_boat if has_boat else astar_grid_no_boat
	
	# 起点和终点需要从世界坐标转换为“安全区域左上角”的格子坐标
	# 注意：对于32x32的坦克，它的寻路起点应该是其左上角所在的格子
	var start_cell = world_to_cell(from_pos - Vector2(nav_grid_size, nav_grid_size) / 2.0)
	var end_cell = world_to_cell(to_pos - Vector2(nav_grid_size, nav_grid_size) / 2.0)
	
	# 检查起点和终点是否在边界内
	if not _is_in_bounds(start_cell) or not _is_in_bounds(end_cell):
		return PackedVector2Array()

	# 检查目标单元格是否可通行，如果不可通行则寻找最近的可通行单元格
	if astar_grid.is_point_solid(end_cell):
		end_cell = find_nearest_walkable_cell(end_cell, has_boat)
		if end_cell == Vector2i(-1, -1):
			return PackedVector2Array()
	
	# 获取原始路径（路径点是左上角格子的中心）
	var raw_path = astar_grid.get_point_path(start_cell, end_cell)
	
	# 将路径点转换为2x2区域的中心
	var centered_path = PackedVector2Array()
	var offset_to_center = Vector2(nav_grid_size, nav_grid_size) 
	for point in raw_path:
		centered_path.append(point + offset_to_center)
		
	return centered_path

# 更新单元格的通行状态（同时更新两套导航网格）
func update_cell_passable(cell: Vector2i, passable: bool) -> void:
	if not _is_in_bounds(cell):
		return

	# 同时更新两套导航网格
	astar_grid_no_boat.set_point_solid(cell, not passable)
	astar_grid_with_boat.set_point_solid(cell, not passable)

# 单元格是否可通行（has_boat 决定使用哪套导航网格）
func is_cell_walkable(cell: Vector2i, has_boat: bool = false) -> bool:
	var astar_grid = astar_grid_with_boat if has_boat else astar_grid_no_boat
	return _is_in_bounds(cell) and not astar_grid.is_point_solid(cell)

# 寻找最近的可通行单元格（根据是否有船选择导航网格）
# 使用 BFS（广度优先搜索）
func find_nearest_walkable_cell(center: Vector2i, has_boat: bool = false, max_radius: int = 5) -> Vector2i:
	var astar_grid = astar_grid_with_boat if has_boat else astar_grid_no_boat
	var visited = {}
	var queue = [center]
	visited[center] = true
	while not queue.is_empty():
		var cell = queue.pop_front()
		if _is_in_bounds(cell) and not astar_grid.is_point_solid(cell):
			return cell
		for dir in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			var nb = cell + dir
			if not visited.has(nb) and _is_in_bounds(nb):
				visited[nb] = true
				if center.distance_to(nb) <= max_radius:
					queue.append(nb)
	return Vector2i(-1, -1)

# === 坐标转换 ===

# 世界坐标转单元格坐标
func world_to_cell(pos: Vector2) -> Vector2i:
	var local_x = int(floor((pos.x - origin.x) / nav_grid_size))
	var local_y = int(floor((pos.y - origin.y) / nav_grid_size))
	return Vector2i(local_x, local_y)

# 单元格坐标转世界坐标（返回单元格中心）
func cell_to_world(cell: Vector2i) -> Vector2:
	return origin + Vector2(
		(cell.x + 0.5) * nav_grid_size,
		(cell.y + 0.5) * nav_grid_size
	)

# === 内部实现 ===

# 重置导航器
func _reset_navigator() -> void:
	astar_grid_no_boat = AStarGrid2D.new()
	astar_grid_with_boat = AStarGrid2D.new()
	grid_width = 0
	grid_height = 0


# 从 TileMap 构建导航网格 (采用“中心线寻路”方案)
func _build_navigation_from_tilemaps(tilemap_layer: TileMapLayer, tilemap_overlay: TileMapLayer, 
								   base_player_positions: Array, base_enemy_positions: Array,
								   nav_rect: Rect2i) -> void:
	# 步骤1: 创建一个临时的障碍物地图，记录所有原始障碍物的位置和类型
	var obstacle_map: Dictionary = {}
	_populate_initial_obstacles(obstacle_map, tilemap_layer)
	_populate_initial_obstacles(obstacle_map, tilemap_overlay)
	_populate_base_obstacles(obstacle_map, base_player_positions)
	_populate_base_obstacles(obstacle_map, base_enemy_positions)

	# 步骤2: 根据障碍物地图和坦克尺寸，构建最终的导航网格
	# 遍历完整地图范围的所有可能坦克“左上角”位置（而非障碍物包围矩形）
	for y in range(nav_rect.position.y, nav_rect.end.y - (TANK_GRID - 1)):
		for x in range(nav_rect.position.x, nav_rect.end.x - (TANK_GRID - 1)):
			var cell = Vector2i(x, y)
			var can_pass_no_boat = true
			var can_pass_with_boat = true
			
			# 检查以当前cell为左上角的 2x2 区域是否完全可通行
			for dy in range(TANK_GRID):
				for dx in range(TANK_GRID):
					var check_cell = Vector2i(x + dx, y + dy)
					if not _is_in_bounds(check_cell):  # 边界检查
						can_pass_no_boat = false
						can_pass_with_boat = false
						break
					var tile_type = obstacle_map.get(check_cell)
					if tile_type != null:
						# 任何障碍物都会阻挡无船坦克
						can_pass_no_boat = false
						# 水域不会阻挡有船坦克
						if tile_type != "water":
							can_pass_with_boat = false
						# 只要发现一个障碍，就可以跳出内层循环
						if not can_pass_no_boat and not can_pass_with_boat:
							break
				if not can_pass_no_boat and not can_pass_with_boat:
					break
			
			# 设置最终的导航点是否为 solid
			astar_grid_no_boat.set_point_solid(cell, not can_pass_no_boat)
			astar_grid_with_boat.set_point_solid(cell, not can_pass_with_boat)

# 填充初始的障碍物类型到字典（只遍历有瓦片的区域）
func _populate_initial_obstacles(obstacle_map: Dictionary, tilemap: TileMapLayer) -> void:
	var used_rect = tilemap.get_used_rect()
	for y in range(used_rect.position.y, used_rect.end.y):
		for x in range(used_rect.position.x, used_rect.end.x):
			var cell = Vector2i(x, y)
			if tilemap.get_cell_source_id(cell) != -1:
				var tile_data = tilemap.get_cell_tile_data(cell)
				if tile_data:
					var tile_type = String(tile_data.get_custom_data("type"))
					# 只记录会产生阻挡的瓦片类型
					match tile_type:
						"brick", "stone", "water":
							obstacle_map[cell] = tile_type

# 填充基地的障碍物
func _populate_base_obstacles(obstacle_map: Dictionary, base_positions: Array) -> void:
	for base_pos in base_positions:
		var cell_x = base_pos[0]
		var cell_y = base_pos[1]
		# 基地占据2x2单元格
		for dy in range(2):
			for dx in range(2):
				var cell = Vector2i(cell_x + dx, cell_y + dy)
				obstacle_map[cell] = "base"

# === 工具函数 ===

# 检查单元格是否在网格范围内
func _is_in_bounds(cell: Vector2i) -> bool:
	var used_rect = Rect2i(0, 0, grid_width, grid_height)  # 假设从(0,0)开始
	return (cell.x >= used_rect.position.x and cell.x < used_rect.end.x and
			cell.y >= used_rect.position.y and cell.y < used_rect.end.y)

# 获取导航网格状态（调试用）
func get_nav_grid_info() -> Dictionary:
	return {
		"grid_size": Vector2i(grid_width, grid_height),
		"nav_grid_size": nav_grid_size,
		"origin": origin,
		"no_boat_grid_points": _count_walkable_points(astar_grid_no_boat),
		"with_boat_grid_points": _count_walkable_points(astar_grid_with_boat)
	}

# 计算可通行点数（调试用）
func _count_walkable_points(astar_grid: AStarGrid2D) -> int:
	var count = 0
	for y in range(grid_height):
		for x in range(grid_width):
			var cell = Vector2i(x, y)
			if not astar_grid.is_point_solid(cell):
				count += 1
	return count
