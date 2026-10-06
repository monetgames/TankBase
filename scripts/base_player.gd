extends "res://scripts/base_parent.gd"
class_name BasePlayer

const EmpBlastEffectScript := preload("res://scripts/emp_blast_effect.gd")
const DamagePopupScript := preload("res://scripts/damage_popup.gd")
const EMP_DOT_COLOR := Color(1.0, 0.84, 0.30)  # EMP 持续伤害数字颜色（亮黄，对齐伤害数字）

@export var player_tank_scene: PackedScene
@export var player_bullet_scene: PackedScene

var player_tank_factory: FactoryTank = null

# 装备提供的基地属性（由装备系统写入）
var repair_speed: float = 0.0         # 维修速度（抢修机）
var repair_discount: float = 0.0      # 维修折扣（抢修机）
var charge_speed: float = 0.0         # 充能速度（能量站）
var max_charge_capacity: float = 0.0  # 最大充能量（能量站）
var emp_range: float = 0.0            # EMP 触发范围（EMP 装备，格）
var emp_stun_duration: float = 3.0    # EMP 瘫痪时长（EMP 装备，秒）
var emp_cooldown_duration: float = 10.0  # EMP 冷却时长（EMP 装备，秒）
var emp_dot_damage: float = 0.0       # EMP 持续伤害总量（EMP 装备）
var emp_disable_movement: bool = true  # EMP 是否瘫痪移动
var emp_disable_shooting: bool = false # EMP 是否瘫痪攻击
var _energy_log_timer := 0.0
var _energy_change_pending := false
var _last_observed_shield_energy := -1.0
var _last_observed_station_energy := -1.0
const ENERGY_LOG_INTERVAL := 1.0

func _ready() -> void:
	# 我方基地血条长期显示
	health_bar_always_visible = true
	# 从配置加载属性
	_load_from_config()
	current_hp = max_hp
	# 恢复上一循环保存的耐久（构筑循环后进入战斗时）
	call_deferred("_restore_stored_hp")
	# 基地帧动画（指挥碉堡 + 旗帜飘动）
	set_base_sprite_frames(load("res://sprites/base_player_sheet.png"))
	# 初始化玩家坦克工厂
	_init_player_tank_factory()
	GM.sig_update_game_status.connect(on_update_game_status)
	GM.sig_base_pos_changed.connect(on_base_pos_changed)
	# 注册到全局管理器
	GM.register_base_player(self)
	
	# 监听装备属性变化信号，实时更新基地属性
	GameState.attribute_changed.connect(_on_attribute_changed)
	
	# 应用当前已装配的基地装备属性
	_apply_all_equipped()

	# 评级统计：本关基地最大耐久计入战役损耗比分母（延迟一帧等装备属性生效，每关只计一次）
	GameState.accumulate_stage_hp_total.call_deferred("base", GM.current_stage, max_hp)


## 应用所有已装配基地装备的属性
func _apply_all_equipped() -> void:
	for slot in GameState.equipped:
		var equipment: Equipment = GameState.equipped[slot]
		if equipment != null:
			_apply_single_equipment(equipment)


## 监听 GameState.attribute_changed 信号，更新基地属性
func _on_attribute_changed(entity: String, attribute: String, value: Variant) -> void:
	if entity != "base":
		return
	match attribute:
		"defense_bonus":
			defense = int(value)
		"repair_speed":
			repair_speed = float(value)
		"repair_discount":
			repair_discount = float(value)
		"charge_speed":
			charge_speed = float(value)
		"max_charge_capacity":
			max_charge_capacity = float(value)
		"emp_range":
			emp_range = float(value)
		"emp_stun_duration":
			emp_stun_duration = float(value)
		"emp_cooldown":
			emp_cooldown_duration = float(value)
		"emp_dot_damage":
			emp_dot_damage = float(value)
		"emp_disable_movement":
			emp_disable_movement = bool(value)
		"emp_disable_shooting":
			emp_disable_shooting = bool(value)

# 重写父类方法：从配置加载基地属性
func _load_from_config() -> void:
	if ConfigLoader:
		var bc = ConfigLoader.base_config
		# 基础耐久 + 黑匣升级加成
		max_hp = bc.get("max_health", 2000) + GameState.base_player_max_health
		defense = bc.get("defense", 0)


## 恢复 GameState 中保存的基地耐久（-1 表示满耐久/新战役）
func _restore_stored_hp() -> void:
	if GameState.base_stored_hp >= 0:
		current_hp = mini(GameState.base_stored_hp, max_hp)
		print("BasePlayer: 恢复耐久 %d/%d" % [current_hp, max_hp])

func _physics_process(delta: float) -> void:
	# super（base_parent）可能在血量归零时触发 queue_free 与场景切换，使本节点离开场景树；
	# 基地被销毁后本函数也可能仍被调用一帧，故前后各检查一次 is_inside_tree。
	if not is_inside_tree():
		return
	super._physics_process(delta)
	if not is_inside_tree():
		return
	# 护盾充能：检测范围内的玩家坦克并充能（速度 = 黑匣升级基础值 + 能量站装备）
	if get_total_charge_speed() > 0.0 and max_charge_capacity > 0.0:
		_charge_nearby_tanks(delta)
	# EMP：检测范围内的敌方坦克并瘫痪
	if emp_range > 0.0:
		_check_emp_trigger()
	_log_energy_changes(delta)


## 实际维修速度 = 黑匣「维修速度强化」加成（基础值）+ 抢修机装备加成
func get_total_repair_speed() -> float:
	return GameState.base_repair_speed_bonus + repair_speed


## 实际充能速度 = 黑匣「充能速度强化」加成（基础值）+ 能量站装备加成
func get_total_charge_speed() -> float:
	return GameState.base_charge_speed_multiplier + charge_speed


## 当前能量站储量
var current_charge: float = 0.0

## 初始化能量站储量（装备能量站时调用）
func _apply_single_equipment(equipment: Equipment) -> void:
	var attrs = equipment.attributes
	match equipment.type:
		Equipment.Type.BARRIER:
			defense = int(attrs.get("defense_bonus", 0))
		Equipment.Type.REPAIR_MACHINE:
			repair_speed = attrs.get("repair_speed", 0.0)
			repair_discount = attrs.get("repair_discount", 0.0)
		Equipment.Type.ENERGY_STATION:
			charge_speed = attrs.get("charge_speed", 0.0)
			max_charge_capacity = attrs.get("max_charge_capacity", 0.0)
			current_charge = max_charge_capacity  # 装备时满充
		Equipment.Type.EMP:
			emp_range = attrs.get("emp_range", 0.0)
			emp_stun_duration = attrs.get("stun_duration", 3.0)
			emp_cooldown_duration = attrs.get("cooldown", 10.0)
			emp_dot_damage = attrs.get("dot_damage", 0.0)
			emp_disable_movement = attrs.get("disable_movement", true)
			emp_disable_shooting = attrs.get("disable_shooting", false)


## 对基地范围内的玩家坦克充能护盾
func _charge_nearby_tanks(delta: float) -> void:
	if current_charge <= 0.0:
		return
	var base_range_px = ConfigLoader.base_config.get("base_range", 3.0) * 16.0 * 2
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if not is_instance_valid(tank):
			continue
		if global_position.distance_to(tank.global_position) > base_range_px:
			continue
		if not "shield_energy" in tank or not "max_shield_energy" in tank:
			continue
		if tank.shield_energy >= tank.max_shield_energy:
			continue
		var charge_amount = get_total_charge_speed() * delta
		charge_amount = minf(charge_amount, tank.max_shield_energy - tank.shield_energy)
		charge_amount = minf(charge_amount, current_charge)
		tank.shield_energy += charge_amount
		current_charge -= charge_amount
		if current_charge <= 0.0:
			break


## 每秒最多输出一次。主动护盾耗能、受击吸收和能量站充能都会触发同一条状态日志。
func _log_energy_changes(delta: float) -> void:
	if not is_inside_tree():
		return
	_energy_log_timer = maxf(_energy_log_timer - delta, 0.0)
	var tanks := get_tree().get_nodes_in_group("player_tanks")
	if tanks.is_empty():
		return
	var tank = tanks[0]
	if not is_instance_valid(tank) or not "shield_energy" in tank or not "max_shield_energy" in tank:
		return
	var shield_energy: float = float(tank.shield_energy)
	if _last_observed_shield_energy < 0.0:
		_last_observed_shield_energy = shield_energy
		_last_observed_station_energy = current_charge
		return
	if absf(shield_energy - _last_observed_shield_energy) > 0.001 or absf(current_charge - _last_observed_station_energy) > 0.001:
		_energy_change_pending = true
	_last_observed_shield_energy = shield_energy
	_last_observed_station_energy = current_charge
	if _energy_change_pending and _energy_log_timer <= 0.0:
		print("BasePlayer: 能量状态 | 坦克护盾 %.1f/%.1f | 能量站 %.1f/%.1f" % [
			shield_energy, float(tank.max_shield_energy), current_charge, max_charge_capacity])
		_energy_log_timer = ENERGY_LOG_INTERVAL
		_energy_change_pending = false


## EMP 冷却计时（秒）
var _emp_cooldown: float = 0.0

## 检测并触发 EMP
func _check_emp_trigger() -> void:
	if _emp_cooldown > 0.0:
		_emp_cooldown -= get_physics_process_delta_time()
		return
	var emp_range_px = emp_range * 16.0
	for tank in get_tree().get_nodes_in_group("enemy_tanks"):
		if not is_instance_valid(tank):
			continue
		if global_position.distance_to(tank.global_position) <= emp_range_px:
			_trigger_emp()
			return


## 触发 EMP，瘫痪范围内所有敌方坦克，并按稀有度施加瘫痪时长/冷却/持续伤害差异
func _trigger_emp() -> void:
	_emp_cooldown = emp_cooldown_duration
	var emp_range_px = emp_range * 16.0
	# EMP 扩散特效
	EmpBlastEffectScript.spawn_at(get_parent(), global_position, emp_range_px)
	var stun := maxf(0.1, emp_stun_duration)
	var frozen_count := 0
	for tank in get_tree().get_nodes_in_group("enemy_tanks"):
		if not is_instance_valid(tank):
			continue
		if global_position.distance_to(tank.global_position) > emp_range_px:
			continue
		# 瘫痪移动 / 瘫痪攻击按配置区分
		if emp_disable_movement and tank.has_method("set_frozen"):
			tank.set_frozen(true)
		if emp_disable_shooting and tank.has_method("set_shooting_disabled"):
			tank.set_shooting_disabled(true)
		frozen_count += 1
		# 定时解除瘫痪
		get_tree().create_timer(stun).timeout.connect(func():
			if is_instance_valid(tank):
				if tank.has_method("set_frozen"):
					tank.set_frozen(false)
				if tank.has_method("set_shooting_disabled"):
					tank.set_shooting_disabled(false)
		)
		# 持续伤害（电磁伤害，走防御公式）
		_apply_emp_dot(tank, emp_dot_damage, stun)
	print("BasePlayer: EMP 触发，瘫痪 %d 个敌方坦克（冷却 %.1fs）" % [frozen_count, emp_cooldown_duration])


## EMP 持续伤害：瘫痪期间每秒一跳，每跳 dot_damage/ticks 走防御公式减免
func _apply_emp_dot(tank: Node, total_damage: float, duration: float) -> void:
	if total_damage <= 0.0 or duration <= 0.0:
		return
	var ticks: int = max(1, int(ceil(duration)))
	var per_tick: float = total_damage / float(ticks)
	var state: Dictionary = {"applied": 0}
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(func():
		if not is_instance_valid(tank) or not tank.is_inside_tree() or int(tank.current_hp) <= 0:
			timer.queue_free()
			return
		state.applied += 1
		# DoT 走防御公式（电磁伤害按目标防御减免）
		var dmg := DamageCalculator.calculate_damage(int(round(per_tick)), int(tank.defense)) if "defense" in tank else int(round(per_tick))
		if dmg > 0:
			tank.current_hp -= dmg
			if tank.has_method("_on_damaged"):
				tank._on_damaged()
			_spawn_emp_damage_popup(tank, dmg)
		if state.applied >= ticks:
			timer.queue_free()
	)
	add_child(timer)


## 在目标头顶弹出 EMP 持续伤害数字
func _spawn_emp_damage_popup(tank: Node, dmg: int) -> void:
	var parent: Node = GM.get_map_manager()
	if parent == null:
		parent = tank.get_parent()
	if parent == null:
		return
	var pos: Vector2 = tank.global_position
	if tank.has_method("get_head_world_position"):
		pos = tank.get_head_world_position()
	DamagePopupScript.spawn_at(parent, pos, str(dmg), EMP_DOT_COLOR)

# 初始化玩家坦克工厂
func _init_player_tank_factory() -> void:
	# 如果player_tank_factory非空，则回收player_tank_factory对象
	if player_tank_factory != null and is_instance_valid(player_tank_factory):
		player_tank_factory.queue_free()
		player_tank_factory = null

	# 创建玩家坦克工厂
	player_tank_factory = FactoryTank.new()
	if player_tank_factory == null:
		push_error("Failed to create FactoryTank instance in BasePlayer.")
		return

	player_tank_factory.defend_path = get_path()
	player_tank_factory.product_scene = player_tank_scene
	player_tank_factory.bullet_scene = player_bullet_scene
	player_tank_factory.group_name = "player_tanks"
	add_child(player_tank_factory)

func on_update_game_status(status: GameManager.GameStatus) -> void:
	print("BasePlayer: 收到游戏状态更新信号: ", status)
	match status:
		GameManager.GameStatus.START:
			print("BasePlayer: 启动玩家坦克工厂")
			if player_tank_factory != null:
				player_tank_factory.start()
				print("BasePlayer: 玩家坦克工厂已启动")
			else:
				print("BasePlayer: ERROR - 玩家坦克工厂为 null！")
		GameManager.GameStatus.PAUSE:
			if player_tank_factory != null:
				player_tank_factory.pause()
		GameManager.GameStatus.CTN:
			if player_tank_factory != null:
				player_tank_factory.continue_work()
		GameManager.GameStatus.OVER:
			if player_tank_factory != null:
				player_tank_factory.over()

# 基地位置改变通知槽
func on_base_pos_changed(role : String, path : NodePath) -> void:
	# 当基地位置改变时，通知敌方坦克工厂更新出生位置
	if role == "enemy" and player_tank_factory != null:
		player_tank_factory.target_base_path = path

# 重写父类方法：更新 GameState 中的基地血量
func _update_game_state_health() -> void:
	pass  # 基地血量通过信号系统更新


## 当前基地状态文本（用于右侧 UI "状态" 显示）
## 可能同时存在多个状态，用顿号连接；无状态时显示"正常"
func get_status_text() -> String:
	if not is_inside_tree():
		return "正常"
	var parts: Array[String] = []
	if emp_range > 0.0 and _emp_cooldown > 0.0:
		parts.append("EMP冷却")
	if _is_charging_tank():
		parts.append("充能")
	if repair_speed > 0.0 and _has_repairing_tank():
		parts.append("维修")
	if parts.is_empty():
		return "正常"
	return "、".join(parts)


## 基地范围内是否存在正在维修的玩家坦克
func _has_repairing_tank() -> bool:
	if not is_inside_tree():
		return false
	var base_range_px = ConfigLoader.base_config.get("base_range", 3.0) * 16.0 * 2
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if not is_instance_valid(tank):
			continue
		if tank.get("_is_repairing") == true and global_position.distance_to(tank.global_position) <= base_range_px:
			return true
	return false


## 是否正在为坦克充能：能量站有储量、范围内有护盾未满的坦克时才为真
func _is_charging_tank() -> bool:
	if get_total_charge_speed() <= 0.0 or max_charge_capacity <= 0.0 or current_charge <= 0.0:
		return false
	if not is_inside_tree():
		return false
	var base_range_px = ConfigLoader.base_config.get("base_range", 3.0) * 16.0 * 2
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if not is_instance_valid(tank):
			continue
		if global_position.distance_to(tank.global_position) > base_range_px:
			continue
		if not ("shield_energy" in tank) or not ("max_shield_energy" in tank):
			continue
		if float(tank.shield_energy) < float(tank.max_shield_energy):
			return true
	return false


# 重写父类方法：玩家基地被摧毁时触发战役失败
func _on_base_destroyed() -> void:
	print("BasePlayer: 玩家基地被摧毁，触发战役失败")
	GM.unregister_base(self)
	# 仅在战斗循环中触发失败
	if GM.current_loop == GameManager.GameLoop.COMBAT:
		GM.trigger_defeat("player_base_destroyed")
	queue_free()
