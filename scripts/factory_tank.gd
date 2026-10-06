extends "res://scripts/factory_parent.gd"
class_name FactoryTank

# FactoryTank（通用坦克工厂）
# 职责：
# - 按固定时间间隔生产坦克实例（玩家或敌人均可）
# - 累计产出次数不超过 maximum_spawn（<=0 表示无限产出）
# - 在基地附近的固定出生点（spawn_offsets）循环出生
# - 出生瞬间允许重叠（出生宽限由坦克自身管理：tank_parent._enter_tree 关闭碰撞，_physics_process 同步恢复）
# - 产出与存活数变化通过信号对外通知
#
# 使用方式：
# - 将本节点作为“基地”的子节点，设置 product_scene（坦克预制体）
# - 可选设置 group_name（如 "enemy_tanks"/"player_tanks"）
# - 可在 Inspector 中配置 maximum_spawn、spawn_interval、spawn_offsets 等

var product_scene: PackedScene              # 要生产的坦克场景（玩家或敌人）
var bullet_scene: PackedScene              # 坦克装载的子弹
var maximum_spawn: int = 1                 # 最大生产坦克数（累计上限；<=0 表示无限）
var maximum_boss_spawn: int = 0            # BOSS 累计生产上限（0=该工厂不额外限制）
var spawn_interval: float = 3.0             # 出生间隔（秒）
var initial_spawn_delay: float = 0.0        # 首辆敌方坦克生产前延迟，用于首关留出接敌准备时间
var tank_spawn_positions: PackedVector2Array = []  # 坦克出生点（全局坐标）
var overlap_grace: float = 0.25             # [已废弃] 出生宽限已迁移到 tank_parent 自身管理，此字段保留兼容
var group_name: String = ""                 # 产出后加入的分组（如 "enemy_tanks" 或 "player_tanks"）
var product_levels: Array = []              # 生产坦克等级队列（按出生顺序循环），空则全部 normal
var enemy_ai_role_sequence: Array = []      # 敌方固定编队（chase/detect/defend），按出生顺序循环

var _alive_count: int = 0            # 当前场景中由本工厂产出的存活坦克数量
var _spawn_idx: int = 0              # 出生点轮转索引
var _spawned_total: int = 0          # 已累计生产数量
var _spawned_boss_total: int = 0     # 已累计生产的 BOSS 坦克数量
var _cooldown: float = 0.0           # 产出冷却计时（<=0 时触发一次产出）

var target_base_path: NodePath = NodePath()	# 攻击目标的路径
var defend_path: NodePath = NodePath()	# 防御位置的路径
const ENEMY_SPAWN_FLASH_DURATION := 2.0

func _process(delta: float) -> void:
	# 未运行时不处理
	if not is_running():
		return
	
	# 1) 未配置产物则不工作
	if product_scene == null:
		return
	# 2) 达到最大生产数则停止（maximum_spawn<=0 表示无限产）
	if maximum_spawn > 0 and _spawned_total >= maximum_spawn:
		return
	# 3) 冷却计时，时间到则产出并重置冷却
	_cooldown -= delta
	if _cooldown <= 0.0:
		_spawn_one()
		_cooldown = max(0.01, spawn_interval)


# —— 工厂状态回调实现 ——
func _on_factory_start() -> void:
	# 重置所有计数和计时
	_spawned_total = 0
	_alive_count = 0
	_spawn_idx = 0
	_cooldown = maxf(initial_spawn_delay, 0.0)
	_spawned_boss_total = 0

func _on_factory_pause() -> void:
	# 暂停时保持所有计数，仅暂停生产
	pass

func _on_factory_continue() -> void:
	# 继续时恢复生产，延续原有计数
	_cooldown = 0.0  # 立即生产一个

func _on_factory_over() -> void:
	_spawned_total = 0
	_alive_count = 0
	_spawn_idx = 0
	_spawned_boss_total = 0

# Immediately produce one tank (no cooldown)
func produce_immediately() -> void:
	_spawn_one()
	_cooldown = max(0.01, spawn_interval)

# 生产队列信息（供雷达 show_production_queue 预警）
# @return: running 生产中 / cooldown_left 下次生产剩余秒 / spawn_interval 间隔 / spawned_total 已产 / maximum_spawn 上限
func get_production_info() -> Dictionary:
	return {
		"running": is_running(),
		"cooldown_left": maxf(_cooldown, 0.0),
		"spawn_interval": spawn_interval,
		"spawned_total": _spawned_total,
		"maximum_spawn": maximum_spawn,
		"maximum_boss_spawn": maximum_boss_spawn,
		"spawned_boss_total": _spawned_boss_total,
	}

# —— 生产实例 ——
# 实际产出一个坦克实例并完成初始化放置
func _spawn_one() -> void:
	var next_level := _get_next_product_level()
	if not _can_spawn_level(next_level):
		return
	# 出生容器：优先使用“基地（本节点父级）”的父节点，保证与基地同层
	var base := get_parent() as Node2D
	var container := base.get_parent() if base != null else get_tree().current_scene
	if container == null:
		container = self

	# 选择一个出生偏移（循环使用）
	var tank_pos = tank_spawn_positions[_spawn_idx % max(1, tank_spawn_positions.size())] if tank_spawn_positions.size() > 0 else Vector2.ZERO
	_spawn_idx += 1
	if group_name == "enemy_tanks":
		SpawnFlashEffect.spawn_at(container, tank_pos, ENEMY_SPAWN_FLASH_DURATION)
		await get_tree().create_timer(ENEMY_SPAWN_FLASH_DURATION).timeout
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if not _can_spawn_level(next_level):
			return
	_spawn_tank_at(container, tank_pos)


func _spawn_tank_at(container: Node, tank_pos: Vector2) -> void:

	var tank := product_scene.instantiate()
	if not (tank is Node2D):
		push_warning("FactoryTank: product_scene 不是 Node2D")
		return

	container.add_child(tank)

	(tank as Node2D).global_position = tank_pos

	# 将子弹场景下发给坦克
	tank.set_bullet_scene(bullet_scene)

	# 按等级队列设置坦克等级（贴图与属性）
	var lv := _get_next_product_level()
	if tank.has_method("set_level"):
		tank.set_level(lv)

	# 敌方基地按固定编队分配角色，避免以概率随机生成侦察型坦克。
	if group_name == "enemy_tanks" and tank.has_method("assign_ai_role"):
		var role := "chase"
		if not enemy_ai_role_sequence.is_empty():
			role = str(enemy_ai_role_sequence[_spawned_total % enemy_ai_role_sequence.size()])
		tank.assign_ai_role(role)

	# 应用动态难度缩放（敌方单位：属性 × 1.08^(全局关卡-1) × 1.03^(波-1)；默认曲线，可被 config scaling 覆盖）
	if group_name == "enemy_tanks" and tank.has_method("apply_scaling"):
		tank.apply_scaling(GM.current_stage, GM.current_wave)

	# 设置防御点和目标点
	tank.set_defend_base_path(defend_path)
	tank.set_target_base_path(target_base_path)

	# 加入坦克分组，便于统一检索/管理
	if group_name != "":
		tank.add_to_group(group_name)
		
		# 如果是玩家坦克，注册到GameManager用于相机跟随
		if group_name == "player_tanks" and tank is CharacterBody2D:
			GM.register_player_tank(tank as CharacterBody2D)
		
		# 如果是敌方坦克，注册到WaveManager用于波次完成检测
		if group_name == "enemy_tanks":
			WaveManager.register_enemy(tank)

	# 更新计数与事件
	_alive_count += 1
	_spawned_total += 1
	if lv == "boss":
		_spawned_boss_total += 1
	alive_count_changed.emit(_alive_count)

	# 新手指引：敌方第一辆坦克实际产出后讲解战场（非暂停卡片，自动去重只弹一次）
	if group_name == "enemy_tanks":
		Tutorial.fire("combat_intro")
	spawned.emit(tank)

	# 当该坦克离开场景树（被销毁）时，更新存活计数
	tank.tree_exited.connect(func ():
		_alive_count = max(0, _alive_count - 1)
		alive_count_changed.emit(_alive_count)
	)


func _get_next_product_level() -> String:
	if product_levels.is_empty():
		return "normal"
	return str(product_levels[_spawned_total % product_levels.size()])


func _can_spawn_level(level: String) -> bool:
	if group_name != "enemy_tanks":
		return true
	if level == "boss" and maximum_boss_spawn > 0 and _spawned_boss_total >= maximum_boss_spawn:
		return false
	return WaveManager == null or WaveManager.can_spawn_enemy_tank(level)
