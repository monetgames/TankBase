extends Area2D
class_name BulletParent

@export var speed: float = 400.0
@export var damage: int = 20
@export var max_range: float = 200.0
@export var damage_type: GM.DamageType = GM.DamageType.NB

var start_position: Vector2 = Vector2.ZERO
var launcher: String = ""
var armor_penetration: float = 0.0  # 穿甲率（由发射者写入；精英/BOSS 0.2）
	
func _ready() -> void:
	# 炮弹在坦克/基地（z=5）图层上方穿过，避免从基地下方穿过
	z_index = 6
	start_position = global_position

func _physics_process(delta: float) -> void:
	var dir: Vector2 = Vector2.UP.rotated(rotation)
	var movement: Vector2 = dir * speed * delta
	var next_pos := global_position + movement

	# 对地形块碰撞检测
	var mm = GM.get_map_manager()
	if mm != null:
		var result = mm.bullet_hit(global_position, next_pos, damage, damage_type)
		if result == 1:
			ExplosionEffect.spawn_at(get_parent(), next_pos)
			queue_free()
			return

	# 推进子弹 - 使用全局坐标确保直线飞行
	global_position += movement

	# 射程限制
	if start_position.distance_to(global_position) >= max_range:
		queue_free()

# 设置发射子弹者
func set_launcher(new_launcher: String) -> void:
	launcher = new_launcher

# 处理一般碰撞（坦克、基地）
func _on_body_entered(body: Node2D) -> void:
	if ((body is TankPlayer and launcher == "tank_enemy") or 
		(body is TankEnemy and launcher == "tank_player") or  
		(body is BasePlayer and launcher == "tank_enemy") or 
		(body is BaseEnemy and launcher == "tank_player")):
		# 使用 DamageCalculator 计算并应用伤害（含穿甲率）
		var actual_damage = DamageCalculator.apply_damage(body, damage, armor_penetration)
		
		if body is BaseEnemy:
			print("子弹击中敌方基地: %s | 火力:%d 实际伤害:%d 剩余耐久:%d/%d" % [
				body.name, damage, actual_damage, body.current_hp, body.max_hp])
		elif body is TankEnemy:
			print("子弹击中敌方坦克: %s | 火力:%d 实际伤害:%d 剩余耐久:%d/%d" % [
				body.name, damage, actual_damage, body.current_hp, body.max_hp])
		else:
			print("子弹击中: %s | 火力:%d 实际伤害:%d 剩余耐久:%d" % [
				body.name, damage, actual_damage, body.current_hp])
		
		ExplosionEffect.spawn_at(get_parent(), global_position)
		queue_free()
