extends CharacterBody2D
class_name TankParent

const HealthBarScript := preload("res://scripts/health_bar.gd")

## 属性变化信号（供UI监听）
signal stats_changed(current_hp: int, max_hp: int, firepower: int, defense: int, move_speed: float)

# 节点引用
@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var turret: Node2D = $Turret
@onready var muzzle: Marker2D = $Turret/Muzzle

# 射击
var bullet_scene: PackedScene = null         # 子弹场景
var shoot_cooldown: float = 1.0       # 射击冷却（秒），1秒内最多一次
var shoot_cooldown_timer: float = 0.0       # 当前冷却剩余时间（秒）

# 炮身
var target_body_rotation: float = 0.0       # 炮身目标旋转角度
var last_target_body_rotation: float = 0.0	# 上一次炮身朝向(弧度)

# 炮管
var turret_turn_speed: float = 8.0     # 炮管旋转速度
var target_turret_rotation: float = 0.0     # 炮管目标旋转角度

# 生命值
var max_hp: int = 100				   # 最大生命值
var current_hp: int = 100:
	set(value):
		if current_hp != value:
			current_hp = value
			stats_changed.emit(current_hp, max_hp, firepower, defense, move_speed)

# 战斗属性
var firepower: int = 50                # 火力（攻击力）
var defense: int = 0                   # 防御力

# 炮弹属性（由子类从 config 换算后赋值；默认值与 bullet 场景一致）
var shell_speed_px: float = 400.0      # 炮弹速度（像素/秒）
var shell_range_px: float = 200.0      # 炮弹最大射程（像素）

# 地图与移动
var move_speed: float = 100.0          # 移动速度
var last_move_axis: GM.XYAxis = GM.XYAxis.None	# 上次移动坐标轴

# 冰面滑行：坦克在冰面上停止输入后保持惯性滑行
var _ice_slide_velocity: Vector2 = Vector2.ZERO
const ICE_SLIDE_FRICTION_PER_SEC: float = 0.30  # 每秒速度保留比例（帧率无关，越小滑行越短/越大越远）

# 道具/装备
@export var has_boat: bool = false    # 是否拥有“潜渡”能力（可越过水，默认不可，装备潜渡后解锁）
const LAYER_WATER: int = 1 << 7        # 128，对应 TileSet 的 physics_layer_3
var water_speed_penalty: float = 1.0  # 潜渡：水面移速倍率（1.0=无影响；由潜渡稀有度决定，白 0.50 → 金 1.50）
var is_shooting_disabled: bool = false  # EMP：是否瘫痪攻击（与移动瘫痪独立）
var armor_penetration: float = 0.0      # 穿甲率（精英/BOSS 敌方单位 0.2，其余 0）


# 守护的基地
var defend_base_path: NodePath
var defend_base: Node = null

var defend_radius: float = 120.0
var defend_alert_range: float = 200.0

#目标基地
var target_base_path: NodePath
var target_base: Node = null

# 目标坦克
var target_tank_path: NodePath
var target_tank: Node = null

# 冻结状态
var is_frozen: bool = false

# 出生无敌：所有坦克生成后的前三秒免疫伤害，并在不透明与半透明间闪烁。
const SPAWN_INVINCIBILITY_DURATION := 3.0
const INVINCIBILITY_BLINK_INTERVAL := 0.15
var _spawn_invincibility_remaining := 0.0
var _manual_invincible := false

# 出生宽限：新坦克出生后短暂关闭碰撞形状（可重叠），宽限期结束后在 _physics_process 同步恢复。
# 由坦克自身管理，而非工厂用 await timer 恢复，避免异步竞态导致碰撞形状永久关闭。
const SPAWN_GRACE_DURATION := 0.25
var _spawn_grace_remaining := 0.0

# 耐久血条：我方长期显示，敌方受击后显示 5 秒
var health_bar: Node2D = null
var health_bar_always_visible := false

func _enter_tree() -> void:
	# 先于 _ready 调用，只按位增删水层位，不影响其它地形碰撞位
	_sync_boat_collision_mask(true)
	_spawn_invincibility_remaining = SPAWN_INVINCIBILITY_DURATION
	# 出生宽限：关闭自身碰撞形状（可重叠），由 _physics_process 同步恢复
	_spawn_grace_remaining = SPAWN_GRACE_DURATION
	_set_own_collision_enabled(false)
	
func _ready() -> void:
	# 从配置加载属性（子类可重写）
	_load_from_config()
	current_hp = max_hp
	# 初始化：让目标炮身、炮管旋转方向与当前旋转方向一致
	target_body_rotation = body_sprite.rotation
	target_turret_rotation = turret.rotation
	last_target_body_rotation = target_body_rotation

# 从配置文件加载坦克属性（子类重写以加载特定配置）
func _load_from_config() -> void:
	pass

func set_bullet_scene(bullet: PackedScene) -> void:
	if bullet != null:
		bullet_scene = bullet

func set_defend_base_path(path: NodePath) -> void:
	if path != NodePath():
		defend_base_path = path
		defend_base = get_node_or_null(defend_base_path)

func set_target_base_path(path: NodePath) -> void:
	if path != NodePath():
		target_base_path = path
		target_base = get_node_or_null(target_base_path)

func set_target_tank_path(path: NodePath) -> void:
	if path != NodePath():
		target_tank_path = path
		target_tank = get_node_or_null(target_tank_path)

func _physics_process(delta: float) -> void:
	_ensure_health_bar()
	_update_spawn_invincibility(delta)
	_update_spawn_grace(delta)

	# 死亡必须优先于冻结处理：冻结只暂停行动，不能阻塞销毁与掉落。
	if current_hp <= 0:
		_on_tank_destroyed()
		queue_free()
		return

	# 检查是否被冻结
	if is_frozen:
		velocity = Vector2.ZERO
		body_sprite.stop()
		return
	
	# 更新射击冷却计时器
	if shoot_cooldown_timer > 0.0:
		shoot_cooldown_timer = max(shoot_cooldown_timer - delta, 0.0)

	# 更新 GameState 中的坦克血量
	_update_game_state_health()

	# 冰面滑行：在冰面上停止输入时保持惯性滑行
	_apply_ice_slide_velocity()
	
	# 是否有移动速度（速度由子类负责设置 velocity）
	if velocity == Vector2.ZERO:
		body_sprite.stop()
	else:
		body_sprite.play()
		# 移动时，炮身加 90° 校正素材（默认素材朝上）
		target_body_rotation = velocity.angle() + PI / 2
		
	# 瞬时旋转炮身（接近90度拐弯才转，直线前后行驶不转）
	if is_nearly_90_degree_rotation(target_body_rotation, last_target_body_rotation):
		body_sprite.rotation = target_body_rotation
		last_target_body_rotation = target_body_rotation
	
	# 真角速度旋转炮管（°/s）：朝目标角度以 turret_turn_speed 转动
	turret.rotation = rotate_toward(turret.rotation, target_turret_rotation, deg_to_rad(turret_turn_speed) * delta)

	# 先尝试移动并处理第一次碰撞，若碰撞则沿法线滑动一次，减少粘连
	var motion = velocity * delta
	if motion != Vector2.ZERO:
		# 检查坦克边界（考虑坦克尺寸）
		var new_position = global_position + motion
		if GM.map_manager != null and not GM.map_manager.is_tank_position_in_bounds(new_position):
			# 如果超出边界，限制位置
			new_position = GM.map_manager.clamp_tank_position_to_bounds(new_position)
			motion = new_position - global_position
		
		var col = move_and_collide(motion)
		if col != null:
			var slid_motion = velocity.slide(col.get_normal()) * delta
			# 对滑动运动也进行坦克边界检查
			var slid_new_position = global_position + slid_motion
			if GM.map_manager != null and not GM.map_manager.is_tank_position_in_bounds(slid_new_position):
				slid_new_position = GM.map_manager.clamp_tank_position_to_bounds(slid_new_position)
				slid_motion = slid_new_position - global_position
			move_and_collide(slid_motion)
	# 若 motion == Vector2.ZERO 则什么也不做

	# 移动后衰减冰面滑行速度
	_decay_ice_slide(delta)


func _update_spawn_invincibility(delta: float) -> void:
	if _spawn_invincibility_remaining <= 0.0:
		return
	_spawn_invincibility_remaining = maxf(_spawn_invincibility_remaining - delta, 0.0)
	var visible_alpha := 0.45 if fmod(_spawn_invincibility_remaining, INVINCIBILITY_BLINK_INTERVAL * 2.0) < INVINCIBILITY_BLINK_INTERVAL else 1.0
	body_sprite.modulate.a = visible_alpha
	turret.modulate.a = visible_alpha
	if _spawn_invincibility_remaining <= 0.0:
		body_sprite.modulate.a = 1.0
		turret.modulate.a = 1.0


## 出生宽限恢复：每物理帧同步检查，宽限期结束后恢复碰撞形状。
## 与 _enter_tree 里的关闭配对，每帧同步恢复，避免异步竞态导致碰撞形状永久关闭。
func _update_spawn_grace(delta: float) -> void:
	if _spawn_grace_remaining <= 0.0:
		return
	_spawn_grace_remaining -= delta
	if _spawn_grace_remaining <= 0.0:
		_set_own_collision_enabled(true)


## 递归启/停自身所有碰撞形状（坦克通常只有一个根级 CollisionShape2D）
func _set_own_collision_enabled(enabled: bool) -> void:
	_set_collision_enabled_recursive(self, enabled)


func _set_collision_enabled_recursive(node: Node, enabled: bool) -> void:
	if node is CollisionShape2D:
		(node as CollisionShape2D).disabled = not enabled
	elif node is CollisionPolygon2D:
		(node as CollisionPolygon2D).disabled = not enabled
	for c in node.get_children():
		_set_collision_enabled_recursive(c, enabled)


## 供临时道具兼容调用；出生无敌与手动无敌均阻止伤害结算。
func set_invincible(value: bool) -> void:
	_manual_invincible = value


func is_damage_immune() -> bool:
	return _manual_invincible or _spawn_invincibility_remaining > 0.0 or is_shield_active()


func is_shield_active() -> bool:
	return false


# ------------ 耐久血条 ------------
# 惰性创建血条（子类 _ready 未调用 super，故放在 _physics_process 首次执行时创建）
func _ensure_health_bar() -> void:
	if health_bar != null:
		return
	health_bar = HealthBarScript.new()
	add_child(health_bar)
	health_bar.setup(self, health_bar_always_visible, Vector2(0, -26))


# 受击通知：敌方血条临时显示（由 DamageCalculator 调用）
func _on_damaged() -> void:
	if health_bar != null:
		health_bar.on_damaged()
	# 新手指引：玩家坦克首次受击 → 暂停并教 F 维修（框架自动去重，只弹一次）
	if is_in_group("player_tanks"):
		Tutorial.fire("combat_damage")


# 头顶世界坐标（用于浮动伤害数字定位；坦克原点在中心）
func get_head_world_position() -> Vector2:
	return global_position + Vector2(0, -24)


# ------------ 冰面滑行 ------------ 
# 移动前：在冰面上时，主动移动记录滑行速度；停止输入但有滑行惯性则用惯性继续滑行
func _apply_ice_slide_velocity() -> void:
	if not _is_on_ice():
		_ice_slide_velocity = Vector2.ZERO
		return
	if velocity != Vector2.ZERO:
		_ice_slide_velocity = velocity
	elif _ice_slide_velocity != Vector2.ZERO:
		velocity = _ice_slide_velocity

# 移动后：冰面滑行速度按时间指数衰减（帧率无关），低于阈值时清零
func _decay_ice_slide(delta: float) -> void:
	if _ice_slide_velocity == Vector2.ZERO:
		return
	_ice_slide_velocity *= pow(ICE_SLIDE_FRICTION_PER_SEC, delta)
	if _ice_slide_velocity.length() < 1.0:
		_ice_slide_velocity = Vector2.ZERO

# 检测坦克是否在冰面上：坦克 2x2 格（32px），中心在网格线交点，
# 检测覆盖的 4 个格中心是否有冰面，骑在冰面边缘也能触发滑行
func _is_on_ice() -> bool:
	var mm = GM.get_map_manager()
	if mm == null:
		return false
	for dy in [-8.0, 8.0]:
		for dx in [-8.0, 8.0]:
			if mm.get_tile_type_at(global_position + Vector2(dx, dy)) == "ice":
				return true
	return false


# ------------ 潜渡：水面移速倍率 ------------
# 检测坦克是否在水面上（与冰面检测同理，覆盖 2x2 格的 4 个中心点）
func _is_on_water() -> bool:
	var mm = GM.get_map_manager()
	if mm == null:
		return false
	for dy in [-8.0, 8.0]:
		for dx in [-8.0, 8.0]:
			if mm.get_tile_type_at(global_position + Vector2(dx, dy)) == "water":
				return true
	return false

# 计算实际移动速度：装配潜渡且位于水面时应用水速倍率，否则返回基础移速
func get_effective_move_speed() -> float:
	if has_boat and _is_on_water():
		return move_speed * water_speed_penalty
	return move_speed


# ------------ 炮塔/炮管 ------------ 
# 检查角度差是否接近±π/2（±90度）。tolerance需大于0（0度）、小于1.5（接近90度）；tolerance越大则素材旋转越“敏感”
func is_nearly_90_degree_rotation(angle1: float, angle2: float, tolerance: float = 0.8) -> bool:
	return abs(abs(angle_difference(angle1, angle2)) - PI/2) < tolerance
	
func set_turret_target_direction(world_position: Vector2) -> void:
	# 设置炮管旋转目标角度（玩家用鼠标，敌人用AI目标）
	var dir = world_position - turret.global_position
	if dir.length() > 0.1:
		# 默认炮管素材朝上，加 90° 校正
		target_turret_rotation = dir.angle() + PI / 2


# ------------ 炮身/移动 ------------ 
# 将任意方向量化为上下左右之一（单位向量或 ZERO）
func to_cardinal(vec: Vector2) -> Vector2:
	if vec == Vector2.ZERO:
		return Vector2.ZERO
	var ax: float = absf(vec.x)
	var ay: float = absf(vec.y)
	if ax > ay:
		return Vector2(signf(vec.x), 0)
	elif ay > ax:
		return Vector2(0, signf(vec.y))
	else:
		# 保持当前主轴，若没有则默认竖直优先
		return Vector2(0, signf(vec.y)) if last_move_axis != GM.XYAxis.X else Vector2(signf(vec.x), 0)

# 设定移动方向（仅四方向），如发生轴变化则沿正交轴吸附成网格像素（16）的倍数
func set_move_direction_cardinal(dir: Vector2, speed: float) -> void:
	var axis_now := GM.XYAxis.None if dir == Vector2.ZERO else (GM.XYAxis.X if dir.x != 0 else GM.XYAxis.Y)
	if axis_now != GM.XYAxis.None and axis_now != last_move_axis:
		_snap_to_grid_for_dir(dir) # 轴变化时吸附
	last_move_axis = axis_now
	velocity = dir * speed

# 沿正交轴吸附到最近的网格像素倍数
func _snap_to_grid_for_dir(dir: Vector2) -> void:
	if dir.x != 0:
		_snap_axis_to_grid(GM.XYAxis.Y)	# x 方向行驶，则吸附 y 坐标
	elif dir.y != 0:
		_snap_axis_to_grid(GM.XYAxis.X)	# y 方向行驶，则吸附 x 坐标

# 位置吸附成网格像素（16）的倍数
func _snap_axis_to_grid(axis: GM.XYAxis = GM.XYAxis.None) -> void:
	var mm = GM.get_map_manager()
	if mm == null:
		push_error("_snap_axis_to_grid: 无法获取 MapManager 单例")
		return

	if axis == GM.XYAxis.X:
		global_position.x = round(global_position.x / float(mm.grid_size)) * float(mm.grid_size)
	elif axis == GM.XYAxis.Y:
		global_position.y = round(global_position.y / float(mm.grid_size)) * float(mm.grid_size)

# ------------ 射击 ------------ 
func shoot(launcher : String) -> void:
	# EMP 瘫痪攻击时禁止射击
	if is_shooting_disabled:
		return
	# 射击冷却检查
	if bullet_scene == null:
		return
	if shoot_cooldown_timer > 0.0:
		return
	# 成功射击，重置冷却计时器
	shoot_cooldown_timer = shoot_cooldown

	# 射击音效
	if AudioManager:
		AudioManager.play_sfx("shoot")

	# 实例化子弹场景
	var bullet = bullet_scene.instantiate()
	bullet.set_launcher(launcher)
	
	# 设置子弹伤害为发射者的火力值
	if "damage" in bullet:
		bullet.damage = firepower

	# 穿甲率（精英/BOSS 敌方单位 0.2，其余 0）
	if "armor_penetration" in bullet:
		bullet.armor_penetration = armor_penetration

	# 设置子弹速度/射程（由发射者属性决定，覆盖子弹场景硬编码默认值）
	if "speed" in bullet:
		bullet.speed = shell_speed_px
	if "max_range" in bullet:
		bullet.max_range = shell_range_px
	
	# 使用GameManager获取正确的子弹容器
	var bullet_container = GM.get_bullet_container()
	if bullet_container != null:
		bullet_container.add_child(bullet)
	else:
		# 备用方案：添加到当前场景
		get_tree().current_scene.add_child(bullet)
	
	# 设置子弹的世界变换到 muzzle（位置+旋转）
	bullet.global_transform = muzzle.global_transform

	# 立即记录正确的起始全局位置，避免 bullet._ready() 记录到错误位置导致射程计算异常
	if "start_position" in bullet:
		bullet.start_position = bullet.global_position

	# 开火成功钩子：子类可覆盖（玩家坦克用于隐身开火暴露）
	_on_shell_fired(launcher)


## 开火成功后的钩子（默认空实现，子类可覆盖）
func _on_shell_fired(_launcher: String) -> void:
	pass


# ------------ 道具：船 ------------ 
func set_has_boat(value: bool) -> void:
	if has_boat == value:
		return
	has_boat = value
	_sync_boat_collision_mask()  # 仅在状态变化时同步

# 仅按位增删水层位，保留其它地形碰撞位
func _sync_boat_collision_mask(immediate: bool = false) -> void:
	var need_water := not has_boat
	var curr := collision_mask
	var has_water := (curr & LAYER_WATER) != 0
	var target := curr
	if need_water and not has_water:
		target = curr | LAYER_WATER
	elif not need_water and has_water:
		target = curr & ~LAYER_WATER
	else:
		return
	if immediate:
		collision_mask = target
	else:
		set_deferred("collision_mask", target)

# 更新 GameState 中的坦克血量（由子类重写）
func _update_game_state_health() -> void:
	pass

# 坦克被摧毁时的处理（由子类重写）
func _on_tank_destroyed() -> void:
	pass

# 获取防御值（供伤害计算使用）
func get_defense() -> int:
	return defense

# 设置冻结状态
func set_frozen(frozen: bool) -> void:
	is_frozen = frozen
	if is_frozen:
		velocity = Vector2.ZERO
		body_sprite.stop()
		modulate = Color(0.5, 0.5, 1.0)
	else:
		modulate = Color(1.0, 1.0, 1.0)

# EMP：设置射击禁用状态（与移动瘫痪独立）
func set_shooting_disabled(disabled: bool) -> void:
	is_shooting_disabled = disabled

# 雷达 show_enemy_health：让血条在雷达探测范围内常显（由 RadarUI 每帧调用）
func set_radar_health_visible(v: bool) -> void:
	if health_bar != null:
		health_bar.set_forced_visible(v)
