extends Control
class_name RadarUI
## 军规像素风雷达小地图：按地图比例绘制我方/敌方单位与视野框。

const REFRESH_INTERVAL := 0.15

var _map_manager: Node = null
var _camera: Camera2D = null
var _timer: float = 0.0

# 雷达探测范围（像素）。无雷达=0（不显示敌方单位）；白 8 格=128px → 金全图
var _radar_range_px: float = 0.0
var _show_enemy_health := false       # 蓝+：雷达范围内敌方血条常显
var _show_production_queue := false   # 紫+：雷达范围内敌方基地生产预警
var _show_full_map := false           # 金：全图显示（无视探测范围）
var _show_base_intel := false         # 粉/金：敌方基地等级标识 + 炮塔射程环
const PRODUCTION_WARN_SECONDS := 5.0  # 生产队列预警提前秒数
var _intel_font: Font = load("res://fonts/fusion-pixel-12px-monospaced-zh_hans.ttf.woff2") as Font

func _ready() -> void:
	custom_minimum_size = Vector2(96, 96)
	GameState.attribute_changed.connect(_on_attribute_changed)
	_init_radar_from_equipped()


func _on_attribute_changed(entity: String, attribute: String, value: Variant) -> void:
	if entity != "tank":
		return
	match attribute:
		"radar_range":
			# 探测范围单位是格，×16 换算像素（地图 grid_size=16）
			_radar_range_px = float(value) * 16.0
		"radar_show_enemy_health":
			_show_enemy_health = bool(value)
		"radar_show_production_queue":
			_show_production_queue = bool(value)
		"radar_show_full_map":
			_show_full_map = bool(value)
		"radar_show_base_intel":
			_show_base_intel = bool(value)


## 战斗开始时从已装配装备初始化雷达探测范围。
## 雷达在构筑循环装配时通过 attribute_changed 广播，但此时战斗 HUD 的 RadarUI 尚未实例化，信号已丢失；
## 故进入战斗后需主动读取已装配雷达，否则 radar_range 恒为 0，敌方单位永不显示。
func _init_radar_from_equipped() -> void:
	for slot in GameState.equipped:
		var equipment: Equipment = GameState.equipped[slot]
		if equipment != null and equipment.type == Equipment.Type.RADAR:
			var attrs = equipment.attributes
			_radar_range_px = float(attrs.get("detection_range", 0.0)) * 16.0
			_show_enemy_health = bool(attrs.get("show_enemy_health", false))
			_show_production_queue = bool(attrs.get("show_production_queue", false))
			_show_full_map = bool(attrs.get("show_full_map", false))
			_show_base_intel = bool(attrs.get("show_base_intel", false))
			return


## 判定某世界坐标是否在雷达探测范围内（以玩家坦克为中心）
func _within_radar(pos: Vector2) -> bool:
	if _radar_range_px <= 0.0:
		return false  # 无雷达：不显示敌方单位
	if _show_full_map or _radar_range_px >= 999.0 * 16.0:
		return true  # 金色/全图：全域显示
	for t in get_tree().get_nodes_in_group("player_tanks"):
		if t is Node2D:
			return t.global_position.distance_to(pos) <= _radar_range_px
	return true  # 无玩家坦克时兜底显示


## show_enemy_health：让雷达范围内的敌方坦克血条常显
func _update_enemy_health_visibility() -> void:
	for t in get_tree().get_nodes_in_group("enemy_tanks"):
		if t is Node2D and t.has_method("set_radar_health_visible"):
			t.set_radar_health_visible(_show_enemy_health and _within_radar(t.global_position))


## 粉/金雷达：绘制敌方基地炮塔射程环与等级标识（N 普通 / E 精英 / B BOSS）
func _draw_base_intel(base: Node, radar_pos: Vector2, bounds: Rect2) -> void:
	# 炮塔射程环：射程(u)×20 px，按雷达缩放换算半径
	var turret_range_u: float = float(base.get("turret_range")) if base.get("turret_range") != null else 0.0
	if turret_range_u > 0.0 and bounds.size.x > 0.0:
		var scale_avg := (size.x / bounds.size.x + size.y / bounds.size.y) * 0.5
		var ring_r := turret_range_u * 20.0 * scale_avg
		draw_arc(radar_pos, ring_r, 0.0, TAU, 24, UIPalette.BORDER_HI, 1.0)
	# 等级标识：normal=N(琥珀) / elite=E(暗珀) / boss=B(红)
	var lv := str(base.get("level")) if base.get("level") != null else ""
	var mark := "N"
	var mark_color := UIPalette.AMBER
	if lv == "elite":
		mark = "E"
		mark_color = UIPalette.AMBER_DARK
	elif lv == "boss":
		mark = "B"
		mark_color = UIPalette.RED
	if _intel_font != null:
		draw_string(_intel_font, radar_pos + Vector2(4, -4), mark, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, mark_color)


## show_production_queue：判断敌方基地是否即将生产（剩余 ≤ 预警秒且未达上限）
func _is_base_producing_soon(base: Node) -> bool:
	if base == null or not ("enemy_tank_factory" in base):
		return false
	var factory = base.enemy_tank_factory
	if factory == null or not factory.is_running():
		return false
	var info: Dictionary = factory.get_production_info()
	var maximum: int = int(info.get("maximum_spawn", 0))
	var spawned: int = int(info.get("spawned_total", 0))
	if maximum > 0 and spawned >= maximum:
		return false
	return float(info.get("cooldown_left", 999.0)) <= PRODUCTION_WARN_SECONDS

func _process(delta: float) -> void:
	# 保持正方形：高度跟随实际宽度
	if size.x > 0.0 and not is_equal_approx(custom_minimum_size.y, size.x):
		custom_minimum_size.y = size.x
	_timer += delta
	if _timer >= REFRESH_INTERVAL:
		_timer = 0.0
		_cache_nodes()
		queue_redraw()
	# show_enemy_health：每帧同步敌方血条常显状态
	_update_enemy_health_visibility()

func _cache_nodes() -> void:
	if not is_instance_valid(_map_manager):
		var scene := get_tree().current_scene
		if scene:
			_map_manager = scene.find_child("MapManager", true, false)
	if not is_instance_valid(_camera):
		for n in get_tree().get_nodes_in_group("map_persistent"):
			if n is Camera2D:
				_camera = n
				break

func _world_bounds() -> Rect2:
	if is_instance_valid(_map_manager) and "map_bounds" in _map_manager:
		var b: Rect2 = _map_manager.map_bounds
		if b.size.x > 0.0 and b.size.y > 0.0:
			return b
	return Rect2(0, 0, 512, 512)

func _to_radar(pos: Vector2, bounds: Rect2) -> Vector2:
	var sx := size.x / bounds.size.x
	var sy := size.y / bounds.size.y
	var p := Vector2((pos.x - bounds.position.x) * sx, (pos.y - bounds.position.y) * sy)
	return p.clamp(Vector2(2, 2), size - Vector2(2, 2))

func _draw() -> void:
	# 底色与边框
	draw_rect(Rect2(Vector2.ZERO, size), UIPalette.BG_DEEP, true)
	var bounds := _world_bounds()
	# 十字网格
	var mid := size * 0.5
	draw_line(Vector2(mid.x, 1), Vector2(mid.x, size.y - 1), UIPalette.BORDER_DIM, 1.0)
	draw_line(Vector2(1, mid.y), Vector2(size.x - 1, mid.y), UIPalette.BORDER_DIM, 1.0)

	# 敌方基地（琥珀 4px 方块，仅在雷达探测范围内显示；生产预警时高亮；粉/金加等级标识与射程环）
	for b in GM.get_enemy_bases():
		if b is Node2D and _within_radar(b.global_position):
			var radar_pos := _to_radar(b.global_position, bounds)
			var base_color := UIPalette.AMBER_DARK
			if _show_production_queue and _is_base_producing_soon(b):
				base_color = UIPalette.AMBER
			_square(radar_pos, base_color, 4.0)
			if _show_base_intel:
				_draw_base_intel(b, radar_pos, bounds)
	# 敌方坦克（红点，仅在雷达探测范围内显示）
	for t in get_tree().get_nodes_in_group("enemy_tanks"):
		if t is Node2D and _within_radar(t.global_position):
			_dot(_to_radar(t.global_position, bounds), UIPalette.RED, 2.0)
	# 我方基地（绿色 5px 方块）
	for b in GM.get_player_bases():
		if b is Node2D:
			_square(_to_radar(b.global_position, bounds), UIPalette.GREEN, 5.0)
	# 我方坦克（亮绿点）
	for t in get_tree().get_nodes_in_group("player_tanks"):
		if t is Node2D:
			_dot(_to_radar(t.global_position, bounds), UIPalette.GREEN_TEXT, 2.0)

	# 相机视野框
	if is_instance_valid(_camera):
		var view_size := get_viewport_rect().size
		var top_left := _camera.get_screen_center_position() - view_size * 0.5
		var tl := _to_radar(top_left, bounds)
		var br := _to_radar(top_left + view_size, bounds)
		draw_rect(Rect2(tl, br - tl), UIPalette.BORDER_HI, false, 1.0)

	draw_rect(Rect2(Vector2.ZERO, size), UIPalette.BORDER, false, 1.0)

func _dot(center: Vector2, color: Color, radius: float) -> void:
	var r := maxf(radius, 1.0)
	draw_rect(Rect2(center - Vector2(r, r) * 0.5, Vector2(r, r)), color, true)

func _square(center: Vector2, color: Color, side: float) -> void:
	draw_rect(Rect2(center - Vector2(side, side) * 0.5, Vector2(side, side)), color, true)
