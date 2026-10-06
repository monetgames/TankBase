extends "res://scripts/base_parent.gd"
class_name BaseEnemy

# 信号：发现玩家基地
signal target_base_discovered(target: Node2D)  # 发现玩家基地时发射
var discovered_target_base: Node2D = null  # 已发现的目标基地

# 敌方坦克与子弹场景
@export var enemy_tank_scene: PackedScene
@export var enemy_bullet_scene: PackedScene

# ===== 基地炮塔 =====
# 参数由 config/enemy/enemy_units.json bases 节点 turret_* 字段配置，_load_from_config 接入。
var turret_damage: int = 15                 # 炮塔单发伤害
var turret_detect_range: float = 8.0        # 炮塔探测范围（单位，×20 → 像素）
var turret_range: float = 8.0               # 炮塔开火射程（单位，×20 → 像素）
var turret_cooldown: float = 3.0            # 炮塔射击冷却（秒）
var turret_cooldown_timer: float = 0.0      # 当前冷却剩余时间
var _current_turret_target: Node2D = null   # 当前炮塔目标（仅用于可选项绘制/调试）
var _turret_enabled: bool = false           # 是否可开火（跟随游戏状态 START/CTN）
const TURRET_BULLET_SPEED_PX := 280.0       # 炮塔炮弹速度（像素/秒，对齐普通坦克炮弹 14u×20）
const TURRET_BULLET_OFFSET_PX := 18.0       # 炮口从基地中心偏移量（像素）

# 敌方坦克工厂
var enemy_tank_factory: FactoryTank = null

# 基地等级（normal/elite/boss），决定生产的坦克等级组合
var level: String = "normal"

# 各级基地生产的坦克等级队列（按出生顺序循环）
const LEVEL_TANK_MIX := {
	"normal": ["normal"],
	"elite": ["elite", "normal"],
	"boss": ["boss", "elite", "normal"],
}

# 各级基地帧动画贴图
const LEVEL_SHEETS := {
	"normal": "res://sprites/base_enemy_sheet.png",
	"elite": "res://sprites/base_enemy_elite_sheet.png",
	"boss": "res://sprites/base_enemy_boss_sheet.png",
}

## 设置基地等级（WaveManager 生成时调用，可能早于 _ready）
func set_level(lv: String) -> void:
	level = lv
	_load_from_config()
	_apply_level_to_factory()
	_apply_level_frames()


## 应用动态难度缩放（生成时由波次管理器调用）。
## 与敌方坦克共用配置曲线，基地炮塔伤害独立按伤害曲线成长。
## @param stage: 全局关卡（1-30）
## @param wave: 当前波次（1-3）
func apply_scaling(stage: int, wave: int) -> void:
	var scaling: Dictionary = ConfigLoader.enemy_configs.get("scaling", {})
	var stage_index := maxi(stage - 1, 0)
	var wave_index := maxi(wave - 1, 0)
	var is_boss := level == "boss"
	var hp_stage := float(scaling.get("boss_stage_hp_multiplier" if is_boss else "stage_hp_multiplier", 1.065 if is_boss else 1.08))
	var damage_stage := float(scaling.get("boss_stage_damage_multiplier" if is_boss else "stage_damage_multiplier", 1.04 if is_boss else 1.05))
	var defense_stage := float(scaling.get("boss_stage_defense_multiplier" if is_boss else "stage_defense_multiplier", 1.02 if is_boss else 1.03))
	# 循环挑战：通关第 10 战役后每轮敌方耐久/炮塔伤害 +10%
	var cycle_mult := 1.0 + 0.1 * float(GameState.cycle_count)
	var hp_mult := pow(hp_stage, stage_index) * pow(float(scaling.get("wave_hp_multiplier", 1.0)), wave_index) * cycle_mult
	var damage_mult := pow(damage_stage, stage_index) * pow(float(scaling.get("wave_damage_multiplier", 1.0)), wave_index) * cycle_mult
	var defense_mult := pow(defense_stage, stage_index) * pow(float(scaling.get("wave_defense_multiplier", 1.01)), wave_index)
	max_hp = int(round(max_hp * hp_mult))
	var defense_caps: Dictionary = scaling.get("defense_cap_by_level", {})
	defense = mini(int(round(defense * defense_mult)), int(defense_caps.get(level, 170)))
	turret_damage = int(round(turret_damage * damage_mult))
	current_hp = max_hp  # 缩放后满耐久
	print("BaseEnemy: 等级 %s 应用缩放 HPx%.2f 火力x%.2f 防御x%.2f 循环x%.2f → HP %d 炮塔 %d 防御 %d" % [level, hp_mult, damage_mult, defense_mult, cycle_mult, max_hp, turret_damage, defense])

## 重写父类：从 config/enemy/enemy_units.json 按等级加载数值（单一事实来源）
func _load_from_config() -> void:
	if ConfigLoader == null:
		return
	var template = ConfigLoader.get_enemy_template("base", level)
	if template.is_empty():
		push_warning("BaseEnemy: 未找到基地模板 " + level + "，使用默认值")
		return
	max_hp = int(template.get("max_health", 300))
	defense = int(template.get("defense", 0))
	current_hp = max_hp  # 新生成基地满耐久
	# 炮塔参数：伤害/射程/冷却按等级写入配置
	turret_damage = int(template.get("turret_damage", turret_damage))
	turret_detect_range = float(template.get("turret_detect_range", turret_range))
	turret_range = float(template.get("turret_range", turret_range))
	turret_cooldown = float(template.get("turret_cooldown", turret_cooldown))
	# 工厂参数（若工厂已创建，同步应用）
	_apply_factory_config(template)

## 将基地模板中的工厂参数应用到坦克工厂（生产间隔/最大在场数/可产坦克类型）
func _apply_factory_config(template: Dictionary = {}) -> void:
	if enemy_tank_factory == null:
		return
	if template.is_empty():
		template = ConfigLoader.get_enemy_template("base", level) if ConfigLoader else {}
	if template.is_empty():
		return
	enemy_tank_factory.maximum_spawn = int(template.get("max_tanks", 4))
	enemy_tank_factory.maximum_boss_spawn = int(template.get("boss_tank_max_per_base", 0))
	enemy_tank_factory.spawn_interval = float(template.get("production_interval", 10.0))
	# 可产坦克类型：配置优先，缺失时回退到等级常量
	var tank_types: Array = template.get("tank_types", [])
	if tank_types.size() > 0:
		enemy_tank_factory.product_levels = tank_types.duplicate()
	else:
		enemy_tank_factory.product_levels = LEVEL_TANK_MIX.get(level, ["normal"]).duplicate()
	var ai_roles: Array = template.get("ai_role_sequence", [])
	enemy_tank_factory.enemy_ai_role_sequence = ai_roles.duplicate() if not ai_roles.is_empty() else ["chase", "chase", "detect", "defend"]

func _apply_level_to_factory() -> void:
	if enemy_tank_factory != null:
		# 优先使用配置的 tank_types（_load_from_config 已通过 _apply_factory_config 设置），
		# 配置缺失时才回退到等级常量 LEVEL_TANK_MIX
		if enemy_tank_factory.product_levels.is_empty():
			enemy_tank_factory.product_levels = LEVEL_TANK_MIX.get(level, ["normal"]).duplicate()

## 按等级应用基地帧动画
func _apply_level_frames() -> void:
	set_base_sprite_frames(load(LEVEL_SHEETS.get(level, LEVEL_SHEETS["normal"])))

func _ready() -> void:
	# 初始基地参数
	current_hp = max_hp
	# 加入敌方基地分组（火箭/地雷范围伤害、雷达等按组检索）
	add_to_group("enemy_bases")
	# 初始化敌方坦克工厂
	_init_enemy_tank_factory()
	# 工厂创建后重新加载配置（set_level 可能早于 _ready，工厂未建时配置未真正应用）
	_load_from_config()
	# 应用基地等级到工厂（配置的 tank_types 优先）
	_apply_level_to_factory()
	# 应用等级帧动画
	_apply_level_frames()
	# 信号槽
	GM.sig_update_game_status.connect(on_update_game_status)
	GM.sig_base_pos_changed.connect(on_base_pos_changed)
	# 注册到全局管理器
	GM.register_base_enemy(self)
	# 敌方基地在出生动画后才进入场景时，补领已经发出的开局状态。
	if GM.is_game_running and GM.current_game_status == GM.GameStatus.START:
		on_update_game_status(GM.GameStatus.START)

# 初始化敌方坦克工厂
func _init_enemy_tank_factory() -> void:
	# 如果enemy_tank_factory非空，则回收enemy_tank_factory对象
	if enemy_tank_factory != null and is_instance_valid(enemy_tank_factory):
		enemy_tank_factory.queue_free()
		enemy_tank_factory = null

	# 创建敌方坦克工厂
	enemy_tank_factory = FactoryTank.new()
	if enemy_tank_factory == null:
		push_error("Failed to create FactoryTank instance in BaseEnemy.")
		return

	enemy_tank_factory.defend_path = get_path()
	enemy_tank_factory.product_scene = enemy_tank_scene
	enemy_tank_factory.bullet_scene = enemy_bullet_scene
	enemy_tank_factory.group_name = "enemy_tanks"
	add_child(enemy_tank_factory)
	# 工厂参数从配置读取（生产间隔/最大在场数，不依赖地图 JSON）
	_apply_factory_config()

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	# 基地炮塔攻击：向探测范围内最近的玩家坦克开火
	_update_turret(delta)

# ===== 基地炮塔攻击 =====

## 炮塔逻辑：冷却计时 → 查找射程内最近目标 → 开火
func _update_turret(delta: float) -> void:
	if enemy_bullet_scene == null:
		return
	if not _turret_enabled:
		return
	if turret_cooldown_timer > 0.0:
		turret_cooldown_timer = max(turret_cooldown_timer - delta, 0.0)

	# 每帧查找探测范围内最近的玩家坦克
	var target := _find_turret_target()
	_current_turret_target = target

	if target == null:
		return
	if turret_cooldown_timer <= 0.0:
		_fire_turret(target)
		turret_cooldown_timer = turret_cooldown

## 查找探测范围内最近的玩家坦克。基地炮塔不会主动获取玩家基地坐标。
func _find_turret_target() -> Node2D:
	var range_px: float = turret_detect_range * 20.0
	var nearest: Node2D = null
	var nearest_dist: float = range_px

	# 先遍历玩家坦克，距离相同时坦克优先
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if not is_instance_valid(tank) or not (tank is Node2D):
			continue
		var d: float = global_position.distance_to(tank.global_position)
		if d <= nearest_dist:
			nearest_dist = d
			nearest = tank

	return nearest

## 发射一枚炮塔炮弹（复用子弹机制，launcher=tank_enemy 可命中玩家坦克与玩家基地）
func _fire_turret(target: Node2D) -> void:
	# 基地炮塔射击音效（与坦克开火一致）
	if AudioManager:
		AudioManager.play_sfx("shoot")
	var bullet = enemy_bullet_scene.instantiate()
	bullet.set_launcher("tank_enemy")

	if "damage" in bullet:
		bullet.damage = turret_damage
	if "speed" in bullet:
		bullet.speed = TURRET_BULLET_SPEED_PX
	if "max_range" in bullet:
		bullet.max_range = turret_range * 20.0

	var dir: Vector2 = (target.global_position - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.DOWN

	# 加入子弹容器后设置世界变换（与 tank_parent.shoot 一致）
	var container = GM.get_bullet_container()
	if container != null:
		container.add_child(bullet)
	else:
		get_tree().current_scene.add_child(bullet)

	# 炮口位置：基地中心 + 朝目标偏移；旋转：bullet 移动方向 = Vector2.UP.rotated(rotation)
	var muzzle_pos: Vector2 = global_position + dir * TURRET_BULLET_OFFSET_PX
	bullet.global_transform = Transform2D(atan2(dir.x, -dir.y), muzzle_pos)

	# 立即记录正确的起始全局位置，避免射程计算异常
	if "start_position" in bullet:
		bullet.start_position = bullet.global_position

# 游戏状态更新通知槽
func on_update_game_status(status: GM.GameStatus) -> void:
	match status:
		GM.GameStatus.START:
			_turret_enabled = true  # 战斗开始，炮塔可开火
			if enemy_tank_factory != null:
				enemy_tank_factory.start()       # 开始生产
		GM.GameStatus.PAUSE:
			_turret_enabled = false  # 暂停时炮塔停火
			if enemy_tank_factory != null:
				enemy_tank_factory.pause()    # 暂停
		GM.GameStatus.CTN:
			_turret_enabled = true  # 继续，炮塔恢复开火
			if enemy_tank_factory != null:
				enemy_tank_factory.continue_work()  # 继续
		GM.GameStatus.OVER:
			_turret_enabled = false  # 结束停火
			if enemy_tank_factory != null:
				enemy_tank_factory.over()     # 结束并清理

# 基地位置改变通知槽
func on_base_pos_changed(role : String, path : NodePath) -> void:
	# 当基地位置改变时，通知敌方坦克工厂更新出生位置
	if role == "player" and enemy_tank_factory != null:
		# 故意不设置 target_base_path：否则敌方坦克的探测模式会立即发现玩家基地
		pass

# ===== 目标基地发现通知机制 =====

# 侦察坦克调用此方法，通知基地发现了目标
func notify_target_base_discovered(target: Node2D) -> void:
	if discovered_target_base == null:
		discovered_target_base = target
		target_base_discovered.emit(target)  # 发射信号，仅通知本基地的侦察型坦克
		print("敌方基地发现玩家基地: %s，通知本基地侦察型坦克进攻" % target.name)

# 获取已发现的目标基地
func get_discovered_target_base() -> Node2D:
	return discovered_target_base

func _exit_tree() -> void:
	pass  # 基地计数由 GM.unregister_base 管理

# 基地被摧毁时的处理
func _on_base_destroyed() -> void:
	print("BaseEnemy: Base destroyed at position: ", global_position)
	# 记录战役击杀统计（按等级）
	if GameState:
		GameState.register_base_killed(level)
	# 停止坦克工厂，不再生产新坦克
	if enemy_tank_factory != null and is_instance_valid(enemy_tank_factory):
		enemy_tank_factory.over()
	# 生成掉落物
	if DropSystem:
		print("BaseEnemy: Calling DropSystem.spawn_drop_from_enemy_base")
		DropSystem.spawn_drop_from_enemy_base(global_position, level)
	else:
		print("BaseEnemy: ERROR - DropSystem not found!")
	# 调用父类处理
	super._on_base_destroyed()
