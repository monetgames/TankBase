extends Area2D
class_name Mine

## 地雷
## 只能放置在空地、冰面、草地；落在水面/砖块/石块上时放置取消并提示（不消耗弹药）
## 地形校验入口：placement_block_reason()，由 tank_player 在扣除弹药前调用
## 层级：z=2，位于坦克/基地（z=5）之下
## 触发范围：48×48像素（3×3格），仅被敌方坦克或敌方基地触发
## 爆炸范围：48×48像素，对范围内所有敌方单位造成伤害

const TILE_SIZE: int = 16
const EXPLOSION_HALF: float = 24.0   # 48×48 的一半
# 伤害盒外扩量：按目标体型取半宽，使伤害判定覆盖"能触发地雷的最大距离"。
# 触发盒 48×48（半宽 24）叠加坦克碰撞盒 26×22（半宽 13）→ 最大触发距离 37，
# 故坦克取 13 才能把擦边触发的目标也纳入伤害范围（此前 8 会漏伤害）。
const TANK_MARGIN: float = 13.0      # 敌方坦克半宽（伤害盒按目标体型外扩）
const BASE_MARGIN: float = 16.0      # 敌方基地半宽
## 爆炸伤害（由 tank_player 根据炮弹伤害×配置倍数设置）
var explosion_damage: int = 150

## 可放置的地形类型（空地/冰面/草地）
const PLACEABLE_TYPES: Array = ["", "ice", "grass"]

## 地形中文名（放置失败提示用）
const TILE_NAMES: Dictionary = {
	"": "空地",
	"water": "水面",
	"ice": "冰面",
	"brick": "砖块",
	"stone": "石块",
	"grass": "草地",
}

var _triggered: bool = false

func _ready() -> void:
	# 层级：地雷位于坦克/基地之下
	# body_entered 已在 mine.tscn 中声明连接，此处不可重复连接（重复会报 "already connected"）
	z_index = 2


## 检查 pos（格子中心）能否放置地雷：仅空地/冰面/草地可放置。
## @param mm: MapManager 引用；为 null 时返回 ""（无法检测地形，沿用"允许放置"的兜底行为）
## @return 阻断原因：可放置返回 ""；不可放置返回地形中文名（如"水面"/"砖块"/"石块"）。
##   由 tank_player 在扣除弹药前调用，据此提示玩家并取消放置。
static func placement_block_reason(mm: Node2D, pos: Vector2) -> String:
	if mm == null:
		return ""
	var tile = mm.get_tile_type_at(pos)
	if tile in PLACEABLE_TYPES:
		return ""
	return TILE_NAMES.get(tile, str(tile))


func _on_body_entered(body: Node2D) -> void:
	if _triggered:
		return
	# 仅被敌方坦克或敌方基地触发
	if not (body is TankEnemy or body is BaseEnemy):
		return
	_triggered = true
	_explode(body)


## 爆炸：对48×48范围内所有敌方单位造成伤害
## @param trigger: 触发本次爆炸的单位；无论是否落在伤害盒内都必定吃到伤害
##   （触发距离 = 触发盒 + 目标体型，略大于伤害盒，避免"擦边引爆却不掉血"）
func _explode(trigger: Node = null) -> void:
	var snap_pos = _snap_to_grid(global_position)
	ExplosionEffect.spawn_at(get_parent(), snap_pos)
	var hit_ids: Dictionary = {}
	
	for tank in get_tree().get_nodes_in_group("enemy_tanks"):
		if not is_instance_valid(tank):
			continue
		if _in_explosion_range(snap_pos, tank.global_position, TANK_MARGIN):
			hit_ids[tank.get_instance_id()] = true
			DamageCalculator.apply_damage(tank, explosion_damage)
			print("Mine: 爆炸命中敌方坦克 %s，伤害 %d" % [tank.name, explosion_damage])
	
	for base in get_tree().get_nodes_in_group("enemy_bases"):
		if not is_instance_valid(base):
			continue
		if _in_explosion_range(snap_pos, base.global_position, BASE_MARGIN):
			hit_ids[base.get_instance_id()] = true
			DamageCalculator.apply_damage(base, explosion_damage)
			print("Mine: 爆炸命中敌方基地 %s，伤害 %d" % [base.name, explosion_damage])
	
	# 触发者兜底：坦克沿边擦过触发盒时中心可能已在伤害盒外，但仍应吃到伤害
	if trigger != null and is_instance_valid(trigger) and not hit_ids.has(trigger.get_instance_id()):
		if trigger is TankEnemy or trigger is BaseEnemy:
			hit_ids[trigger.get_instance_id()] = true
			DamageCalculator.apply_damage(trigger, explosion_damage)
			print("Mine: 爆炸命中触发单位 %s，伤害 %d" % [trigger.name, explosion_damage])
	
	print("Mine: 地雷爆炸于 %s" % str(snap_pos))
	queue_free()


func _in_explosion_range(center: Vector2, target: Vector2, margin: float = 0.0) -> bool:
	var half := EXPLOSION_HALF + margin
	return abs(target.x - center.x) <= half and abs(target.y - center.y) <= half


## 将任意世界坐标吸附到最近的格子中心（(gx+0.5)*16, (gy+0.5)*16）
func _snap_to_grid(pos: Vector2) -> Vector2:
	var cell := Vector2i(
		round(pos.x / TILE_SIZE - 0.5),
		round(pos.y / TILE_SIZE - 0.5)
	)
	return Vector2(
		(cell.x + 0.5) * TILE_SIZE,
		(cell.y + 0.5) * TILE_SIZE
	)
