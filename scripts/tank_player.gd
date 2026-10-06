extends "res://scripts/tank_parent.gd"
class_name TankPlayer

# 通过 export 在场景/实例中配置该坦克的特性（子类负责在 _ready 应用到父类）
@export var cfg_bullet_scene: PackedScene		# 子弹场景
@export var cfg_move_speed: float = 60.0			# 移动速度
@export var cfg_turret_turn_speed: float = 8.0	# 炮管旋转速度
@export var cfg_max_hp: int = 100				# 最大生命值
@export var cfg_shoot_cooldown: float = 1.0		# 射击冷却时间（秒）
@export var cfg_firepower: int = 50				# 火力
@export var cfg_defense: int = 0				# 防御
@export var cfg_shell_speed: float = 8.0		# 炮弹速度（u/s）
@export var cfg_shell_range: float = 6.0		# 炮弹射程（u）

# 隐身：敌方探测玩家坦克的范围倍率（<1 更难被发现；白 0.80 → 金 0.60）
# 强化不再改变该倍率，改为提供闪避率（dodge_chance）；开炮会短暂暴露（stealth_exposure_duration）
var stealth_multiplier: float = 1.0
var dodge_chance: float = 0.0               # 闪避率（隐身装备强化提供：+1/+2/+3 = 5%/10%/15%）
var stealth_exposure_duration: float = 0.0  # 开炮暴露时长（秒，按隐身装备稀有度）
var _stealth_expose_timer: float = 0.0      # 暴露剩余时间（>0 时敌方视为无隐身）

# 能量护盾（由护盾装备 + 商店护盾共同提供，鼠标右键激发，随时间消耗能量免疫伤害）
var shield_energy: float = 0.0       # 当前护盾能量
var max_shield_energy: float = 0.0   # 最大护盾能量 = 装备基础 + 商店护盾加成（0 表示无护盾）
var _base_shield_energy_max: float = 0.0  # 装备提供的护盾基础最大能量（不含商店加成）
var shield_active := false
var _shield_aura: ShieldAura = null
const SHIELD_DRAIN_DURATION := 10.0

# 道具护盾：按次使用，立即免疫一定秒数（道具格序号键激发）
var _item_shield_remaining := 0.0   # 道具护盾剩余免疫秒数

# ===== 武器槽系统 =====
enum WeaponSlot { MAIN_GUN = 0, MINE = 1, ROCKET = 2 }

## 当前激活的武器槽
var current_weapon_slot: WeaponSlot = WeaponSlot.MAIN_GUN

## 各武器槽的弹药数量（主炮无限，地雷/火箭有限）
var weapon_ammo: Dictionary = {
	WeaponSlot.MAIN_GUN: -1,   # -1 表示无限
	WeaponSlot.MINE: 0,
	WeaponSlot.ROCKET: 0
}

## 武器槽名称（用于UI显示）
const WEAPON_NAMES: Dictionary = {
	WeaponSlot.MAIN_GUN: "主炮",
	WeaponSlot.MINE: "地雷",
	WeaponSlot.ROCKET: "火箭"
}

## 武器槽切换信号（通知UI更新）
signal weapon_slot_changed(slot: WeaponSlot, ammo: int)

## 最近一次鼠标按键时间（左键/右键/中键）- 用于屏蔽按键后的异常滚轮事件
var _last_mouse_button_time_ms: int = 0
const MOUSE_BUTTON_BLOCK_WINDOW_MS: int = 100  # 鼠标按键后屏蔽滚轮的时间窗口（毫秒）- 针对旧鼠标硬件缓存问题

## 滚轮事件计数器 - 用于调试
var _wheel_event_counter: int = 0

## 地雷和火箭场景
var _mine_scene: PackedScene = preload("res://scenes/mine.tscn")
var _rocket_scene: PackedScene = preload("res://scenes/rocket.tscn")

## 尝试在基地范围内维修（每帧调用）
var _repair_cost_accumulator: float = 0.0
var _repair_hp_accumulator: float = 0.0  # 累积治疗量

func _ready() -> void:
	# 我方坦克血条长期显示
	health_bar_always_visible = true
	# 从配置加载属性
	_load_from_config()
	
	# 把配置应用到父类变量
	if cfg_bullet_scene != null:
		bullet_scene = cfg_bullet_scene
	move_speed = cfg_move_speed
	turret_turn_speed = cfg_turret_turn_speed
	max_hp = cfg_max_hp
	shoot_cooldown = cfg_shoot_cooldown
	firepower = cfg_firepower
	defense = cfg_defense
	current_hp = max_hp
	# 恢复上一循环保存的耐久（构筑循环后进入战斗时）
	call_deferred("_restore_stored_hp")

	# 武器弹药：战役内跨关保留（从 GameState 恢复上一关剩余）；战役开始时 GameState 为空给默认值
	if GameState.weapon_ammo.is_empty():
		weapon_ammo[WeaponSlot.MINE] = 10
		weapon_ammo[WeaponSlot.ROCKET] = 10
	else:
		for slot in GameState.weapon_ammo:
			weapon_ammo[slot] = int(GameState.weapon_ammo[slot])
	# 弹药变化时同步回 GameState（跨关/存档保留）
	weapon_slot_changed.connect(_on_weapon_ammo_synced)

	# 把该实例加入 player_tanks 组，供敌方 AI 查找
	add_to_group("player_tanks")
	
	# 注册到 GameManager（用于相机跟随）
	GM.register_player_tank(self)
	
	# 监听装备属性变化信号，实时更新坦克属性
	GameState.attribute_changed.connect(_on_attribute_changed)
	
	# 应用当前已装配的装备属性
	_apply_all_equipped()
	
	# 注册维修按键（F 键）
	if not InputMap.has_action("repair"):
		InputMap.add_action("repair")
		var ev = InputEventKey.new()
		ev.keycode = KEY_F
		InputMap.action_add_event("repair", ev)
	
	# 注册护盾激活（鼠标右键）
	if not InputMap.has_action("shield_activate"):
		InputMap.add_action("shield_activate")
		var ev2 = InputEventMouseButton.new()
		ev2.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("shield_activate", ev2)

	# 评级统计：本关坦克最大耐久计入战役损耗比分母（延迟一帧等装备属性生效，每关只计一次）
	GameState.accumulate_stage_hp_total.call_deferred("tank", GM.current_stage, max_hp)


## 恢复 GameState 中保存的坦克耐久（-1 表示满耐久/新战役）
func _restore_stored_hp() -> void:
	if GameState.tank_stored_hp >= 0:
		current_hp = mini(GameState.tank_stored_hp, max_hp)
		print("TankPlayer: 恢复耐久 %d/%d" % [current_hp, max_hp])
	
	# 注册武器切换（鼠标滚轮）
	if not InputMap.has_action("weapon_next"):
		InputMap.add_action("weapon_next")
		var ev3 = InputEventMouseButton.new()
		ev3.button_index = MOUSE_BUTTON_WHEEL_DOWN
		InputMap.action_add_event("weapon_next", ev3)
	if not InputMap.has_action("weapon_prev"):
		InputMap.add_action("weapon_prev")
		var ev4 = InputEventMouseButton.new()
		ev4.button_index = MOUSE_BUTTON_WHEEL_UP
		InputMap.action_add_event("weapon_prev", ev4)


## 应用所有已装配装备的属性（进入战斗时调用）
func _apply_all_equipped() -> void:
	for slot in GameState.equipped:
		var equipment: Equipment = GameState.equipped[slot]
		if equipment != null:
			_apply_single_equipment(equipment)
	_apply_shop_buffs()


## 应用波间商店购买的战役内临时强化（叠加在装备属性之上）
func _apply_shop_buffs() -> void:
	firepower = int(firepower * GameState.shop_damage_multiplier)
	shoot_cooldown = max(0.1, shoot_cooldown / GameState.shop_fire_rate_multiplier)
	move_speed = move_speed * GameState.shop_move_speed_multiplier


## 根据装备属性更新坦克变量
func _apply_single_equipment(equipment: Equipment) -> void:
	var attrs = equipment.attributes
	match equipment.type:
		Equipment.Type.ENGINE:
			move_speed = cfg_move_speed + attrs.get("move_speed_bonus", 0.0) * 20.0
		Equipment.Type.BEARING:
			turret_turn_speed = cfg_turret_turn_speed + attrs.get("turret_rotation_bonus", 0.0)
		Equipment.Type.MAIN_GUN:
			shoot_cooldown = max(0.1, cfg_shoot_cooldown - attrs.get("shoot_cooldown_reduction", 0.0))
			shell_speed_px = attrs.get("shell_speed", cfg_shell_speed) * 20.0
		Equipment.Type.SHELL:
			firepower = cfg_firepower + int(attrs.get("shell_damage_bonus", 0.0))
			shell_range_px = attrs.get("shell_range_bonus", cfg_shell_range) * 20.0
		Equipment.Type.ARMOR:
			defense = cfg_defense + int(attrs.get("defense_bonus", 0))
		Equipment.Type.SHIELD:
			var new_base = attrs.get("shield_energy_max", 0.0)
			if new_base != _base_shield_energy_max:
				# 装配/更换护盾装备：更新基础能量并满充（含商店加成）
				_base_shield_energy_max = new_base
				_recompute_shield_max()
				shield_energy = max_shield_energy
		Equipment.Type.DIVING:
			set_has_boat(true)  # 潜渡：解锁水面通行
			water_speed_penalty = attrs.get("water_speed_penalty", 1.0)
		Equipment.Type.STEALTH:
			stealth_multiplier = attrs.get("detection_range_multiplier", 1.0)
			dodge_chance = attrs.get("dodge_chance", 0.0)
			stealth_exposure_duration = attrs.get("exposure_duration", 0.0)


## 监听 GameState.attribute_changed 信号，更新坦克属性
func _on_attribute_changed(entity: String, attribute: String, value: Variant) -> void:
	if entity != "tank":
		return
	match attribute:
		"move_speed_bonus":
			move_speed = cfg_move_speed + float(value) * 20.0
		"turret_rotation_bonus":
			turret_turn_speed = cfg_turret_turn_speed + float(value)
		"shell_speed":
			shell_speed_px = (float(value) if float(value) > 0.0 else cfg_shell_speed) * 20.0
		"shell_range_bonus":
			shell_range_px = (float(value) if float(value) > 0.0 else cfg_shell_range) * 20.0
		"stealth_multiplier":
			stealth_multiplier = float(value)
		"dodge_chance":
			dodge_chance = float(value)
		"stealth_exposure_duration":
			stealth_exposure_duration = float(value)
		"shoot_cooldown_reduction":
			shoot_cooldown = max(0.1, cfg_shoot_cooldown - float(value))
		"shell_damage_bonus":
			firepower = cfg_firepower + int(value)
		"defense_bonus":
			defense = cfg_defense + int(value)
		"shield_energy_max":
			_base_shield_energy_max = float(value)
			_recompute_shield_max()
			# 装配/更换护盾装备时满充（含商店加成）
			if _base_shield_energy_max > 0.0:
				shield_energy = max_shield_energy
			else:
				_set_shield_active(false)
		"can_cross_water":
			set_has_boat(bool(value))  # 潜渡装备装卸实时生效
		"water_speed_penalty":
			water_speed_penalty = float(value)  # 潜渡水面移速倍率实时生效

# 重写父类方法：从配置加载坦克属性（config/tank/player_tank.json 为单一事实来源）
func _load_from_config() -> void:
	if ConfigLoader:
		var tc = ConfigLoader.tank_config
		# 基础耐久 + 黑匣升级加成
		cfg_max_hp = tc.get("max_health", 1000) + GameState.base_tank_max_health
		max_hp = cfg_max_hp  # 确保 max_hp 也更新
		
		# 直接从配置读取，避免场景默认值覆盖配置
		cfg_firepower = tc.get("shell_damage", 50)
		cfg_defense = tc.get("defense", 0)
		# 移动速度：裸装基准 u/s + 黑匣升级加成（+0.1 u/s/级），×20 换算像素
		cfg_move_speed = (tc.get("move_speed", 3.0) + GameState.base_tank_speed_multiplier) * 20.0
		# 炮台旋转：裸装基准 °/s + 黑匣升级加成（+5°/s/级），真角速度驱动
		cfg_turret_turn_speed = tc.get("turret_rotation_speed", 100) + GameState.base_turret_rotation_multiplier
		# 射击冷却必须从配置读取，否则改 config 射速不生效
		cfg_shoot_cooldown = tc.get("shoot_cooldown", 1.0)
		# 炮弹速度/射程基线：u 单位 → 像素（×20），主炮/炮弹装备可覆盖
		cfg_shell_speed = float(tc.get("shell_speed", 8.0))
		cfg_shell_range = float(tc.get("shell_range", 6.0))
		shell_speed_px = cfg_shell_speed * 20.0
		shell_range_px = cfg_shell_range * 20.0

func _exit_tree() -> void:
	# 从组中移除，防止已销毁实例残留在组内
	remove_from_group("player_tanks")

# 使用 _input 处理所有离散输入事件（滚轮、点击、按键）
# _input 在 GUI 之前处理，适合游戏输入；_unhandled_input 会被 GUI 拦截
func _input(event: InputEvent) -> void:
	# 处理鼠标按钮事件
	if event is InputEventMouseButton:
		var current_time_ms = Time.get_ticks_msec()
		
		# 只处理按下事件
		if not event.pressed:
			return
		
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 左键射击 - 记录按键时间
				_last_mouse_button_time_ms = current_time_ms
				_fire_current_weapon()
				get_viewport().set_input_as_handled()
			
			MOUSE_BUTTON_RIGHT:
				# 右键护盾 - 记录按键时间
				_last_mouse_button_time_ms = current_time_ms
				_toggle_shield()
				get_viewport().set_input_as_handled()
			
			MOUSE_BUTTON_MIDDLE:
				# 中键 - 记录按键时间（预留，当前无功能）
				_last_mouse_button_time_ms = current_time_ms
				get_viewport().set_input_as_handled()
			
			MOUSE_BUTTON_WHEEL_DOWN:
				_wheel_event_counter += 1
				var time_since_button = current_time_ms - _last_mouse_button_time_ms
				
				# 检查是否在鼠标按键的屏蔽窗口内（针对旧鼠标硬件缓存问题）
				if _last_mouse_button_time_ms > 0 and time_since_button < MOUSE_BUTTON_BLOCK_WINDOW_MS:
					print("TankPlayer: [滚轮下#%d] 屏蔽（距按键%dms < %dms）" % [_wheel_event_counter, time_since_button, MOUSE_BUTTON_BLOCK_WINDOW_MS])
					get_viewport().set_input_as_handled()
					return
				
				# 执行切换
				_switch_weapon(1)
				get_viewport().set_input_as_handled()
			
			MOUSE_BUTTON_WHEEL_UP:
				_wheel_event_counter += 1
				var time_since_button = current_time_ms - _last_mouse_button_time_ms
				
				# 检查是否在鼠标按键的屏蔽窗口内（针对旧鼠标硬件缓存问题）
				if _last_mouse_button_time_ms > 0 and time_since_button < MOUSE_BUTTON_BLOCK_WINDOW_MS:
					print("TankPlayer: [滚轮上#%d] 屏蔽（距按键%dms < %dms）" % [_wheel_event_counter, time_since_button, MOUSE_BUTTON_BLOCK_WINDOW_MS])
					get_viewport().set_input_as_handled()
					return
				
				# 执行切换
				_switch_weapon(-1)
				get_viewport().set_input_as_handled()
	
	# 处理键盘事件
	elif event is InputEventKey and event.pressed and not event.is_echo():
		match event.keycode:
			KEY_SPACE:
				# 空格键射击
				print("TankPlayer: [空格键射击]")
				_fire_current_weapon()
				get_viewport().set_input_as_handled()
			
			KEY_F:
				# F键维修
				if GM.current_loop == GameManager.GameLoop.COMBAT:
					_toggle_repair()
					get_viewport().set_input_as_handled()
			
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				# 数字键使用道具
				var item_index = event.keycode - KEY_1
				if ItemSystem and item_index >= 0 and item_index < 6:
					ItemSystem.use_item(item_index)
					get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	# 隐身开火暴露计时：暴露期间敌方探测倍率视为 1.0
	if _stealth_expose_timer > 0.0:
		_stealth_expose_timer = maxf(0.0, _stealth_expose_timer - delta)
	# 移动向量
	var iv := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)
	set_move_direction_cardinal(to_cardinal(iv), get_effective_move_speed())

	# 炮塔朝向
	set_turret_target_direction(get_global_mouse_position())

	# 如果正在维修，持续执行维修逻辑
	if _is_repairing:
		_try_repair(delta)
	
	# 非激活状态不消耗能量；能量站会在基地范围内自动补充未满的护盾。
	_update_shield(delta)

	super._physics_process(delta)


func _toggle_shield() -> void:
	# 能量护盾已激活 → 关闭
	if shield_active:
		_set_shield_active(false)
		print("TankPlayer: 护盾已关闭")
		return
	# 能量护盾（装备护盾或商店护盾加成后，尚有能量即可右键激发）
	if max_shield_energy > 0.0 and shield_energy > 0.0:
		_set_shield_active(true)
		print("TankPlayer: 护盾已激活，当前能量 %.1f/%.1f" % [shield_energy, max_shield_energy])
		return
	print("TankPlayer: 无可用护盾（未装备且无商店护盾/能量耗尽）")


func _set_shield_active(active: bool) -> void:
	if shield_active == active:
		return
	shield_active = active
	_sync_shield_aura()


## 道具护盾：立即免疫 duration 秒（由 item_system 的道具格序号键激发调用）
func grant_item_shield(duration: float) -> void:
	_item_shield_remaining += duration
	_sync_shield_aura()
	print("TankPlayer: 道具护盾免疫 %.1f 秒" % duration)


## 商店护盾：当前能量与最大能量同时增加 x（本次战役有效）
## 由波间商店购买护盾时调用；即使未装备护盾也可获得独立能量护盾额度
func add_shop_shield_energy(x: float) -> void:
	shield_energy += x
	_recompute_shield_max()
	print("TankPlayer: 商店护盾能量 +%.0f，当前 %.1f/%.1f" % [x, shield_energy, max_shield_energy])


## 重算最大护盾能量 = 装备基础 + 商店加成；超出部分截断
func _recompute_shield_max() -> void:
	max_shield_energy = _base_shield_energy_max + GameState.shop_shield_energy
	if shield_energy > max_shield_energy:
		shield_energy = max_shield_energy
	if max_shield_energy <= 0.0:
		shield_active = false
		shield_energy = 0.0


## 每帧统一更新护盾：按优先级逐个消耗（道具护盾 > 能量护盾）
func _update_shield(delta: float) -> void:
	if _item_shield_remaining > 0.0:
		_item_shield_remaining = maxf(_item_shield_remaining - delta, 0.0)
	elif shield_active:
		var drain_rate := max_shield_energy / SHIELD_DRAIN_DURATION
		shield_energy = maxf(shield_energy - drain_rate * delta, 0.0)
		if shield_energy <= 0.0:
			shield_active = false
			print("TankPlayer: 护盾能量耗尽，护盾已关闭")
	_sync_shield_aura()


## 统一护盾激活状态：道具护盾或能量护盾任一激活即视为免疫中
func is_shield_active() -> bool:
	return _item_shield_remaining > 0.0 or shield_active


## 同步护盾特效：任一护盾激活时显示 shield_aura，全部失效时隐藏
func _sync_shield_aura() -> void:
	var active := is_shield_active()
	if active and not is_instance_valid(_shield_aura):
		_shield_aura = ShieldAura.new()
		add_child(_shield_aura)
	elif not active and is_instance_valid(_shield_aura):
		_shield_aura.queue_free()
		_shield_aura = null


## 当前坦克状态文本（用于右侧 UI "状态" 显示）
## 可能同时存在多个状态，用顿号连接；无状态时显示"正常"
func get_status_text() -> String:
	var parts: Array[String] = []
	if is_shield_active():
		parts.append("护盾")
	if ItemSystem.active_effects.has(ItemData.ItemType.FIREPOWER_BOOST):
		parts.append("火力")
	if ItemSystem.active_effects.has(ItemData.ItemType.SPEED_BOOST):
		parts.append("加速")
	if _is_repairing:
		parts.append("维修")
	if parts.is_empty():
		return "正常"
	return "、".join(parts)


# ===== 武器槽方法 =====

## 切换武器槽（direction: +1 下一个，-1 上一个）
func _switch_weapon(direction: int) -> void:
	var slots = [WeaponSlot.MAIN_GUN, WeaponSlot.MINE, WeaponSlot.ROCKET]
	var current_idx = slots.find(current_weapon_slot)
	var new_idx = (current_idx + direction + slots.size()) % slots.size()
	current_weapon_slot = slots[new_idx]
	var ammo = weapon_ammo.get(current_weapon_slot, 0)
	print("TankPlayer: 切换武器槽 -> %s（弹药：%s）" % [
		WEAPON_NAMES[current_weapon_slot],
		"无限" if ammo < 0 else str(ammo)
	])
	weapon_slot_changed.emit(current_weapon_slot, ammo)


## 根据当前武器槽执行射击
func _fire_current_weapon() -> void:
	match current_weapon_slot:
		WeaponSlot.MAIN_GUN:
			shoot("tank_player")
		WeaponSlot.MINE:
			_place_mine()
		WeaponSlot.ROCKET:
			_fire_rocket()


## 敌方探测使用的有效隐身倍率：开火暴露窗口内视为 1.0
func get_effective_stealth_multiplier() -> float:
	if _stealth_expose_timer > 0.0:
		return 1.0
	return stealth_multiplier


## 闪避率读取（供 DamageCalculator 判定，类似免疫但不掉耐久）
func get_dodge_chance() -> float:
	return dodge_chance


## 开火成功钩子（父类 shoot 发射成功后调用）：主炮开火触发隐身暴露
func _on_shell_fired(_launcher: String) -> void:
	if stealth_exposure_duration > 0.0:
		_stealth_expose_timer = stealth_exposure_duration


## 弹药变化同步到 GameState（战役内跨关保留；战役结束由 reset_campaign_resources 清空）
func _on_weapon_ammo_synced(_slot: WeaponSlot, _ammo: int) -> void:
	GameState.weapon_ammo = weapon_ammo.duplicate()


## 放置地雷
func _place_mine() -> void:
	var ammo = weapon_ammo.get(WeaponSlot.MINE, 0)
	if ammo <= 0:
		print("TankPlayer: 地雷弹药不足")
		return
	if _mine_scene == null:
		push_error("TankPlayer: 地雷场景未加载")
		return
	# 放置在炮管出口指向的格子中心（16×16轮廓恰好落于单个格子内）
	const TILE_SIZE = 16
	var muzzle_pos = muzzle.global_position
	var mm = GM.get_map_manager()
	var place_pos
	if mm != null:
		var cell = mm.world_to_grid(muzzle_pos)
		place_pos = mm.grid_to_world(cell)
	else:
		# 无地图管理器时的兜底：手动吸附到最近格子中心
		place_pos = Vector2(
			round(muzzle_pos.x / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2.0,
			round(muzzle_pos.y / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2.0
		)

	# 地形校验：仅空地/冰面/草地可放置；落在水面/砖块/石块上则提示并取消（不消耗弹药）
	var block_reason: String = Mine.placement_block_reason(mm, place_pos)
	if block_reason != "":
		print("TankPlayer: %s不可放置地雷，取消放置" % block_reason)
		var scene = get_tree().current_scene
		if scene and scene.has_method("show_toast"):
			scene.show_toast("%s不可放置地雷！" % block_reason, UIPalette.RED)
		return

	weapon_ammo[WeaponSlot.MINE] -= 1
	weapon_slot_changed.emit(WeaponSlot.MINE, weapon_ammo[WeaponSlot.MINE])

	var mine = _mine_scene.instantiate()
	mine.global_position = place_pos
	# 伤害 = 当前炮弹伤害 × 配置倍数
	var multiplier = ConfigLoader.items_config.get("mine", {}).get("damage_multiplier", 3.0)
	mine.explosion_damage = int(firepower * multiplier)
	var container = GM.get_bullet_container()
	if container:
		container.add_child(mine)
	else:
		get_tree().current_scene.add_child(mine)
	print("TankPlayer: 放置地雷于格子 %s，剩余 %d 枚" % [str(place_pos), weapon_ammo[WeaponSlot.MINE]])
	
	# 如果地雷耗尽，自动切回主炮
	if weapon_ammo[WeaponSlot.MINE] <= 0:
		current_weapon_slot = WeaponSlot.MAIN_GUN
		weapon_slot_changed.emit(current_weapon_slot, weapon_ammo[WeaponSlot.MAIN_GUN])
		print("TankPlayer: 地雷已耗尽，自动切回主炮")


## 发射火箭
func _fire_rocket() -> void:
	var ammo = weapon_ammo.get(WeaponSlot.ROCKET, 0)
	if ammo <= 0:
		print("TankPlayer: 火箭弹药不足")
		return
	if _rocket_scene == null:
		push_error("TankPlayer: 火箭场景未加载")
		return
	weapon_ammo[WeaponSlot.ROCKET] -= 1
	weapon_slot_changed.emit(WeaponSlot.ROCKET, weapon_ammo[WeaponSlot.ROCKET])
	# 从炮口位置向炮台方向发射火箭
	var rocket = _rocket_scene.instantiate()
	rocket.global_transform = muzzle.global_transform
	rocket.start_position = muzzle.global_position
	rocket.set_launcher("tank_player")
	# 火箭速度/射程始终与当前炮弹一致（覆盖 rocket 场景硬编码）
	rocket.speed = shell_speed_px
	rocket.max_range = shell_range_px
	# 伤害 = 当前炮弹伤害 × 配置倍数
	var multiplier = ConfigLoader.items_config.get("rocket", {}).get("damage_multiplier", 2.0)
	rocket.explosion_damage = int(firepower * multiplier)
	var container = GM.get_bullet_container()
	if container:
		container.add_child(rocket)
	else:
		get_tree().current_scene.add_child(rocket)
	print("TankPlayer: 发射火箭，剩余 %d 枚" % weapon_ammo[WeaponSlot.ROCKET])
	# 火箭同样触发隐身暴露
	if stealth_exposure_duration > 0.0:
		_stealth_expose_timer = stealth_exposure_duration
	
	# 如果火箭耗尽，自动切回主炮
	if weapon_ammo[WeaponSlot.ROCKET] <= 0:
		current_weapon_slot = WeaponSlot.MAIN_GUN
		weapon_slot_changed.emit(current_weapon_slot, weapon_ammo[WeaponSlot.MAIN_GUN])
		print("TankPlayer: 火箭已耗尽，自动切回主炮")


## 添加弹药（拾取道具时调用）
## @param slot: 武器槽
## @param amount: 数量
func add_ammo(slot: WeaponSlot, amount: int) -> void:
	if slot == WeaponSlot.MAIN_GUN:
		return  # 主炮无限弹药
	weapon_ammo[slot] = weapon_ammo.get(slot, 0) + amount
	print("TankPlayer: 获得 %s x%d，当前 %d 枚" % [WEAPON_NAMES[slot], amount, weapon_ammo[slot]])
	weapon_slot_changed.emit(slot, weapon_ammo[slot])

## 维修状态
var _is_repairing: bool = false

## 切换维修状态
func _toggle_repair() -> void:
	if _is_repairing:
		# 停止维修
		_is_repairing = false
		print("TankPlayer: 停止维修")
	else:
		# 开始维修前检查条件
		var base = _get_nearby_player_base()
		if base == null:
			print("TankPlayer: 无法开始维修 - 不在基地范围内")
			return
		var base_repair_speed: float = base.get_total_repair_speed() if base.has_method("get_total_repair_speed") else 0.0
		if base_repair_speed <= 0.0:
			print("TankPlayer: 无法开始维修 - 基地维修速度为 0（未装备抢修机且未点黑匣维修升级）")
			return
		if current_hp >= max_hp:
			print("TankPlayer: 无法开始维修 - 耐久已满")
			return
		# 开始维修
		_is_repairing = true
		print("TankPlayer: 开始维修（按F键停止）")

# 维修
func _try_repair(delta: float) -> void:
	# 检查是否还在基地范围内
	var base = _get_nearby_player_base()
	if base == null:
		_is_repairing = false
		_repair_cost_accumulator = 0.0
		_repair_hp_accumulator = 0.0
		print("TankPlayer: 离开基地范围，停止维修")
		return
	
	# 检查基地维修速度是否仍有效（黑匣升级 + 抢修机装备）
	var base_repair_speed: float = base.get_total_repair_speed() if base.has_method("get_total_repair_speed") else 0.0
	if base_repair_speed <= 0.0:
		_is_repairing = false
		_repair_cost_accumulator = 0.0
		_repair_hp_accumulator = 0.0
		print("TankPlayer: 基地维修速度归零，停止维修")
		return
	
	# 检查是否已满耐久
	if current_hp >= max_hp:
		_is_repairing = false
		_repair_cost_accumulator = 0.0
		_repair_hp_accumulator = 0.0
		print("TankPlayer: 耐久已满，停止维修")
		return
	
	# 维修费用：每 100 HP 消耗 repair_cost_per_100hp 金币，抢修机折扣减免
	var cost_per_100hp = ConfigLoader.base_config.get("repair_cost_per_100hp", 5)
	var heal_per_sec = base_repair_speed
	var discount: float = float(base.get("repair_discount")) if base.get("repair_discount") != null else 0.0
	var cost_per_sec = heal_per_sec * cost_per_100hp / 100.0 * (1.0 - discount)
	
	# 累积治疗量和费用
	_repair_hp_accumulator += heal_per_sec * delta
	_repair_cost_accumulator += cost_per_sec * delta
	
	# 当累积治疗量 >= 1 时才应用治疗
	var healed = int(_repair_hp_accumulator)
	if healed > 0:
		_repair_hp_accumulator -= healed
		current_hp = min(current_hp + healed, max_hp)
	
	# 当累积费用 >= 1 时才扣除金币
	var gold_to_spend = int(_repair_cost_accumulator)
	if gold_to_spend > 0:
		if EconomySystem.spend_resource("gold", gold_to_spend):
			_repair_cost_accumulator -= gold_to_spend
			if healed > 0:
				print("TankPlayer: 维修中 +%d HP，当前 %d/%d，消耗 %d 金币" % [healed, current_hp, max_hp, gold_to_spend])
		else:
			_is_repairing = false
			_repair_cost_accumulator = 0.0
			_repair_hp_accumulator = 0.0
			print("TankPlayer: 金币不足，停止维修")


## 获取附近的玩家基地（在基地作用范围内）
func _get_nearby_player_base() -> Node:
	var base_range_px = ConfigLoader.base_config.get("base_range", 3.0) * 16.0 * 2
	for base in GM.get_player_bases():
		if is_instance_valid(base) and global_position.distance_to(base.global_position) <= base_range_px:
			return base
	return null

# 重写父类方法：更新 GameState 中的玩家坦克血量
func _update_game_state_health() -> void:
	pass  # 坦克血量由自身变量管理，不覆盖 GameState

# 重写父类方法：玩家坦克被摧毁时的处理
func _on_tank_destroyed() -> void:
	print("TankPlayer: 玩家坦克被摧毁")
	# 玩家坦克只有一条命：被毁即战役失败，无重生系统。
	GM.trigger_defeat("player_tank_destroyed")
