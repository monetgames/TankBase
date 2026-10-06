extends Area2D
class_name Rocket

## 火箭弹
## 与炮弹相同：从炮管口直线飞行，碰撞地形/敌方单位时停止
## 碰撞后对48×48像素（3×3格，网格吸附）范围内所有目标造成爆炸伤害
## 包括：敌方坦克、敌方基地、可破坏地形（砖块/草地等）

@export var speed: float = 400.0
@export var max_range: float = 400.0

const TILE_SIZE: int = 16
const EXPLOSION_HALF: float = 24.0   # 48×48 的一半（1.5格）
const TANK_MARGIN: float = 8.0       # 敌方坦克半宽（伤害盒按目标体型外扩）
const BASE_MARGIN: float = 16.0      # 敌方基地半宽
## 爆炸伤害（由 tank_player 根据炮弹伤害×配置倍数设置）
var explosion_damage: int = 100

var start_position: Vector2 = Vector2.ZERO
var launcher: String = ""
var _exploded: bool = false

func _ready() -> void:
	# 火箭在坦克/基地（z=5）图层上方穿过，避免从基地下方穿过
	# body_entered 已在 rocket.tscn 中声明连接，此处不可重复连接（重复会报 "already connected"）
	z_index = 6
	start_position = global_position


func set_launcher(new_launcher: String) -> void:
	launcher = new_launcher


func _physics_process(delta: float) -> void:
	if _exploded:
		return
	
	var dir = Vector2.UP.rotated(rotation)
	var next_pos = global_position + dir * speed * delta
	
	# 地形碰撞检测
	var mm = GM.get_map_manager()
	if mm != null:
		var result = mm.bullet_hit(global_position, next_pos, 0, GM.DamageType.NB)
		if result == 1:
			_explode()
			return
	
	global_position = next_pos
	
	if start_position.distance_to(global_position) >= max_range:
		# 射程耗尽属于自然销毁，不产生爆炸效果或范围伤害。
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if _exploded:
		return
	if (body is TankEnemy and launcher == "tank_player") or \
	   (body is BaseEnemy and launcher == "tank_player"):
		_explode()


## 爆炸：对48×48范围内所有目标（单位+地形）造成伤害
func _explode() -> void:
	_exploded = true
	# 爆炸中心吸附到格子中心
	var snap_pos = _snap_to_grid(global_position)
	ExplosionEffect.spawn_at(get_parent(), snap_pos)
	
	# 1. 对范围内敌方坦克造成伤害
	for tank in get_tree().get_nodes_in_group("enemy_tanks"):
		if not is_instance_valid(tank):
			continue
		if _in_explosion_range(snap_pos, tank.global_position, TANK_MARGIN):
			DamageCalculator.apply_damage(tank, explosion_damage)
			print("Rocket: 爆炸命中敌方坦克 %s，伤害 %d" % [tank.name, explosion_damage])
	
	# 2. 对范围内敌方基地造成伤害
	for base in get_tree().get_nodes_in_group("enemy_bases"):
		if not is_instance_valid(base):
			continue
		if _in_explosion_range(snap_pos, base.global_position, BASE_MARGIN):
			DamageCalculator.apply_damage(base, explosion_damage)
			print("Rocket: 爆炸命中敌方基地 %s，伤害 %d" % [base.name, explosion_damage])
	
	# 3. 对3×3范围内每个地形格子造成伤害
	var mm = GM.get_map_manager()
	if mm != null:
		# 遍历以爆炸中心为中心的3×3格（-1,0,+1 偏移）
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var cell_center = snap_pos + Vector2(dx * TILE_SIZE, dy * TILE_SIZE)
				# 用极短射线触发 bullet_hit 对该格子造成伤害
				var from = cell_center - Vector2(0.1, 0.1)
				var to   = cell_center + Vector2(0.1, 0.1)
				mm.bullet_hit(from, to, explosion_damage, GM.DamageType.NB)
	
	print("Rocket: 火箭爆炸于 %s" % str(snap_pos))
	queue_free()


func _in_explosion_range(center: Vector2, target: Vector2, margin: float = 0.0) -> bool:
	var half := EXPLOSION_HALF + margin
	return abs(target.x - center.x) <= half and abs(target.y - center.y) <= half


func _snap_to_grid(pos: Vector2) -> Vector2:
	return Vector2(
		round(pos.x / TILE_SIZE) * TILE_SIZE,
		round(pos.y / TILE_SIZE) * TILE_SIZE
	)
