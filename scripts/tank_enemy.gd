extends "res://scripts/tank_parent.gd"
class_name TankEnemy

# 移动
@export var cfg_move_speed: float = 60.0
var direction_timer: float = 0.0	# 漫游时朝一个方向直行的剩余时间
var current_direction: Vector2 = Vector2.RIGHT	# 当前漫游方向

# 攻击
@export var cfg_shoot_cooldown: float = 1.0
@export var cfg_fire_range: float = 150.0
var max_fire_interval: float = 3.0	# 最大射击时间间隔，单位：秒
var min_fire_interval: float = 0.5	# 最小射击时间间隔，单位：秒
var shoot_interval_timer: float = 0.0	# 射击间隔计时器

# 炮管
@export var cfg_turret_turn_speed: float = 100.0 # 炮管旋转速度（°/s，初始与玩家裸装持平，enemy_units.json 可覆盖）
var turret_target_direction_timer: float = 0.0 # 炮塔朝一个方向的剩余时间
var random_turret_angle: float= PI/4 # 扇形射击炮塔偏转角度（单边），越小则越专注目标

# 生命
@export var cfg_max_hp: int = 80
@export var cfg_firepower: int = 50
@export var cfg_defense: int = 0

# 目标探测：CHASE/DEFEND 搜索玩家坦克；DETECT 搜索玩家基地，二者保持独立。
@export var cfg_detect_range: float = 160.0 # 默认普通坦克探测范围 8u × 20px
@export var cfg_scout_base_detect_range: float = 300.0 # 默认普通侦察型基地发现半径 15u × 20px
var has_received_target_discovery: bool = false # 是否已接收到目标发现通知
var roam_interval_min := 1.0
var roam_interval_max := 3.0
var chase_range := 160.0

# 出生 AI 角色由生产基地固定编队分配。角色不随临时状态切换改变，广播只影响 detect 角色。
var ai_role: String = "chase"

# ===== AI 状态机 =====
# AI 行为由显式枚举状态机分发，便于扩展与追踪切换条件。
# 状态切换条件：
#   ROAM   → DETECT ：侦察型坦克由生产基地固定编队分配为 DETECT
#   DETECT → 保持     ：发现玩家基地后持续追击（目标失效时漫游并继续探测，不切状态）
#   CHASE  → DEFEND ：目标超出 chase_range（玩家坦克探测范围×2 追击上限），放弃追击回防
#   DEFEND → CHASE  ：玩家坦克离开开火射程，转追击
#   DETECT → DETECT ：收到所属基地"目标发现"广播后，锁定并追击玩家基地
enum State { ROAM, DETECT, CHASE, DEFEND }

# 当前 AI 状态（外部读取用）
var state: State = State.CHASE

# 兼容层：场景/工厂/波次可能直接赋字符串 ai_mode，setter 映射到 state，getter 返回当前字符串。
var _ai_mode: String = "chase"
@export var ai_mode: String:
	set(value):
		_ai_mode = value
		state = _state_from_string(value)
	get:
		return _ai_mode

# AI 智能度，取值范围 [0.0, 1.0]
@export var ai_intelligence: float = 0.8

# ===== BOSS 狂暴 =====
# 每 rage_interval 秒（±5s 抖动）以 rage_chance 概率进入狂暴：
# 射速 ×rage_fire_rate_multiplier（shoot_cooldown 临时缩短为 1/multiplier），
# 持续 rage_duration 秒后恢复。参数由 enemy_units.json boss 节点 boss_rage 配置。
var rage_interval: float = 25.0        # 狂暴判定基准间隔（秒），实际在 ±5s 抖动
var rage_chance: float = 0.3           # 每次判定的进入狂暴概率
var rage_duration: float = 5.0         # 狂暴持续时间（秒）
var rage_fire_rate_multiplier: float = 1.3  # 狂暴期射速倍率
var _rage_timer: float = 0.0           # 距下次狂暴判定剩余时间
var _rage_active_timer: float = 0.0    # 当前狂暴剩余时间
var _is_raging: bool = false           # 是否处于狂暴
var _base_shoot_cooldown: float = 1.5  # 狂暴前的基础射击冷却（恢复用）

# ===== AI 提示动画 =====
# 发现玩家基地 → 头顶"无线电波"（程序化同心圆环；时长与发现警报音效 alert_base 一致）
var _radio_wave_timer: float = 0.0
const RADIO_WAVE_DURATION := 1.2
const RADIO_WAVE_COLOR := Color(0.25, 0.8, 1.0)   # 无线电蓝
# 首次锁定玩家坦克 → 头顶感叹号"!"（程序绘制，约 1.5s 消失）
var _exclamation_timer: float = 0.0
const EXCLAMATION_DURATION := 1.5
const EXCLAMATION_COLOR := Color(1.0, 0.35, 0.2)  # 警示红
# 防守型基地被毁后的"背水一战"是否已触发（确保感叹号/转追击只触发一次）
var _vengeance_triggered: bool = false

# 坦克等级（normal/elite/boss），由生产基地通过工厂设置
var level: String = "normal"

# 各级别贴图
const LEVEL_BODY_SHEETS := {
	"normal": "res://sprites/tank_enemy_body_sheet.png",
	"elite": "res://sprites/tank_enemy_elite_body_sheet.png",
	"boss": "res://sprites/tank_enemy_boss_body_sheet.png",
}
const LEVEL_TURRETS := {
	"normal": "res://sprites/tank_enemy_turret.png",
	"elite": "res://sprites/tank_enemy_elite_turret.png",
	"boss": "res://sprites/tank_enemy_boss_turret.png",
}

# 导航相关变量
var current_path: PackedVector2Array = []  # 当前导航路径
var current_path_index: int = 0            # 当前路径点索引
var path_update_timer: float = 0.0         # 路径更新计时器
var path_update_interval: float = 1.0      # 路径更新间隔（秒）
var is_navigation_complete: bool = false   # 是否导航完成
var last_navigation_destination: Vector2 = Vector2.ZERO  # 上次导航目标位置

# ===== 侦察弹道修正：被不可击毁地形（石头）挡住时换位射击 =====
var _reposition_dest: Vector2 = Vector2.ZERO   # 换位目标点（ZERO 表示无）
var _reposition_timer: float = 0.0             # 换位点重搜间隔计时
var _shell_damage_type = null                  # 缓存的炮弹伤害类型（null=未初始化）
var _base_approach_complete: bool = false      # 是否已走完本次玩家基地导航路径
var _base_approach_target_id: int = 0          # 防止更换目标后沿用旧基地的完成状态
const REPOSITION_SEARCH_INTERVAL := 1.0        # 换位点重搜间隔（秒）

# 调试选项
@export var debug_draw_path: bool = false  # 是否绘制导航路径（战役中默认隐藏，仅调试时开启）
@export var debug_path_color: Color = Color.GREEN  # 路径颜色
@export var debug_current_point_color: Color = Color.YELLOW  # 当前目标点颜色

func _ready() -> void:
	# 从 enemy_units.json 配置加载属性
	_load_from_config()

	# 应用配置到父类变量
	_apply_cfg()

	# 应用等级贴图
	_apply_level_textures()

	# 框定取值为 [0.0, 1.0]
	ai_intelligence = clampf(ai_intelligence, 0.0, 1.0)

	# 尝试初始化目标坦克
	set_target_tank_path(target_tank_path)

	# 连接到基地的"目标发现"信号：
	# 注意工厂是在 add_child（触发 _ready）之后才调用 set_defend_base_path，
	# 因此这里的连接主要是为"场景预置 defend_base_path"的兜底路径；
	# 工厂产出的坦克由重写后的 set_defend_base_path 完成连接（见下）。
	# 只有侦察型才连接生产基地广播，追击型/防守型不会接收。
	if ai_role == "detect" and defend_base_path != NodePath():
		var base = get_node_or_null(defend_base_path)
		if base and base is BaseEnemy:
			base.target_base_discovered.connect(_on_base_target_discovered)


func _physics_process(delta: float) -> void:
	# 防守型基地被摧毁：转入"背水一战"（追击玩家坦克 + 头顶感叹号），仅触发一次。
	# 放在状态分发之前，确保无论当前处于 DEFEND 还是已转 CHASE，基地被毁都会触发。
	if ai_role == "defend" and not _vengeance_triggered and not is_instance_valid(defend_base):
		_vengeance_triggered = true
		_set_state(State.CHASE, "基地被毁，转入追击")
		_trigger_exclamation()

	# 显式状态机分发：按 state 调用对应行为函数
	match state:
		State.ROAM:
			roam_behavior(delta)
		State.DETECT:
			detect_behavior(delta)
		State.CHASE:
			chase_behavior(delta)
		State.DEFEND:
			defend_behavior(delta)

	# BOSS 狂暴计时
	_update_boss_rage(delta)

	# AI 提示动画计时
	_update_indicator_timers(delta)

	# 调用父类处理
	super._physics_process(delta)

	# 绘制导航路径 + AI 提示动画
	queue_redraw()

func _draw() -> void:
	# 调试：绘制导航路径
	if debug_draw_path and current_path.size() > 1:
		# 绘制完整路径
		for i in range(1, current_path.size()):
			var start = to_local(current_path[i-1])
			var end = to_local(current_path[i])
			draw_line(start, end, debug_path_color, 2.0)
		
		# 绘制当前目标点
		if current_path_index < current_path.size():
			var current_target = to_local(current_path[current_path_index])
			draw_circle(current_target, 4.0, debug_current_point_color)
			
			# 绘制从坦克到当前目标点的连线
			var tank_pos = Vector2.ZERO  # 相对于自身的位置
			draw_line(tank_pos, current_target, debug_current_point_color, 1.0)

	# AI 提示动画
	_draw_ai_indicators()

# ===== 状态机辅助 =====

# 字符串 → 状态映射（兼容外部赋值 ai_mode）
func _state_from_string(mode: String) -> State:
	match mode:
		"roam": return State.ROAM
		"detect": return State.DETECT
		"chase": return State.CHASE
		"defend": return State.DEFEND
		_: return State.ROAM  # 未知字符串回退漫游

# 状态切换统一入口：记录切换（reason 仅用于调试日志），便于后续加行为钩子
func _set_state(new_state: State, reason: String = "") -> void:
	if state == new_state:
		return
	if OS.is_debug_build() and reason != "":
		print("TankEnemy %s: %s → %s（%s）" % [name, State.keys()[state], State.keys()[new_state], reason])
	state = new_state


## 由生产基地的固定编队指定角色；非法值回退为追击型。
func assign_ai_role(role: String) -> void:
	ai_role = role if role in ["detect", "chase", "defend"] else "chase"
	ai_mode = ai_role

# ===== AI 提示动画 =====

func _trigger_radio_wave() -> void:
	_radio_wave_timer = RADIO_WAVE_DURATION
	queue_redraw()

func _trigger_exclamation() -> void:
	_exclamation_timer = EXCLAMATION_DURATION
	queue_redraw()
	# 首次锁定玩家坦克：短促提示音
	AudioManager.play_sfx("alert_spot")

func _update_indicator_timers(delta: float) -> void:
	if _radio_wave_timer > 0.0:
		_radio_wave_timer = max(_radio_wave_timer - delta, 0.0)
	if _exclamation_timer > 0.0:
		_exclamation_timer = max(_exclamation_timer - delta, 0.0)

func _draw_ai_indicators() -> void:
	# 无线电波：以头顶为中心扩散的同心圆环（像素风），约 2s 内淡出
	if _radio_wave_timer > 0.0:
		var progress := 1.0 - (_radio_wave_timer / RADIO_WAVE_DURATION)  # 0 → 1
		var center := Vector2(0, -30)  # 坦克头顶（素材 32x32，原点在中心）
		for i in range(3):
			var radius := progress * 12.0 + i * 6.0
			var alpha := (1.0 - progress) * 0.75
			var col := Color(RADIO_WAVE_COLOR.r, RADIO_WAVE_COLOR.g, RADIO_WAVE_COLOR.b, alpha)
			draw_arc(center, radius, 0.0, TAU, 20, col, 1.0)

	# 感叹号：像素风"!"（竖条 + 圆点），轻微闪烁
	if _exclamation_timer > 0.0:
		var blink := 1.0 if int(_exclamation_timer * 8.0) % 2 == 0 else 0.75
		var col := Color(EXCLAMATION_COLOR.r, EXCLAMATION_COLOR.g, EXCLAMATION_COLOR.b, blink)
		draw_rect(Rect2(-2, -38, 4, 11), col)  # 竖条
		draw_rect(Rect2(-2, -24, 4, 4), col)   # 圆点

# 随机开火逻辑
func random_firing(delta: float) -> void:
	# 智能度越高，开火间隔越短，[min_fire_interval, max_fire_interval] 线性插值
	var fire_interval = lerp(max_fire_interval, min_fire_interval, ai_intelligence)
	# 添加shoot_cooldown限制（BOSS 狂暴期 shoot_cooldown 临时缩短，射速提升）
	if shoot_cooldown > 0.0:
		fire_interval = max(fire_interval, shoot_cooldown)
	shoot_interval_timer += delta
	if shoot_interval_timer >= fire_interval:
		shoot_interval_timer = 0.0
		shoot("tank_enemy")

# 随机扫射：随机扇形炮塔朝向
func random_turret_target_direction(delta: float, global_direction: Vector2) -> void:
	# 只在方向改变时设置炮管方向，炮管方向随机偏转角度
	# 	1.解决紧贴地形块时因射击方向太固定而无法击毁地形块问题；
	# 	2.使得开火方向更随机与灵活
	if turret_target_direction_timer > 0:
		turret_target_direction_timer = max(turret_target_direction_timer - delta, 0.0)
	if turret_target_direction_timer == 0.0:
		var random_angle = randf_range(-random_turret_angle, random_turret_angle) * (1.1 - ai_intelligence)  # 智能度越高，偏转越小，更专注目标
		var rotated_direction = global_direction.rotated(random_angle)
		set_turret_target_direction(rotated_direction)
		turret_target_direction_timer = randf_range(1.0, lerp(3.0, 4.0, ai_intelligence))

# 漫游行为（含智能度）：ai_intelligence∈[0,1]
# - 0：完全随机漫游、随机射击
# - 1：直朝目标行驶并对目标射击
# - (0,1)：方向与射击以 ai_intelligence 的概率偏向目标
func roam_behavior(delta: float, target: Node2D = null) -> void:
	# 低/中智商：按计时器选新方向，方向选择对目标有"概率性偏向"
	if direction_timer > 0.0:
		direction_timer = max(direction_timer - delta, 0.0)
	if direction_timer == 0.0:
		var dirs = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
		var chosen = dirs[randi() % dirs.size()]
		if target != null:
			var dir_to_target = to_cardinal(target.global_position - global_position)
			# 以智能度概率选择"指向目标"的方向
			if randf() < ai_intelligence:
				chosen = dir_to_target
		current_direction = chosen
		direction_timer = randf_range(roam_interval_min, roam_interval_max)

	# 持续朝当前方向行驶
	set_move_direction_cardinal(current_direction, move_speed)
	
	# 随机扇形炮塔朝向
	random_turret_target_direction(delta, global_position + current_direction)
	
	# 随机开火
	random_firing(delta)

# 侦察行为（状态：DETECT）
func detect_behavior(delta: float) -> void:
	# 侦察型坦克攻击目标：玩家基地
	detect_base_targets()

	if not is_instance_valid(target_base):
		_base_approach_complete = false
		_base_approach_target_id = 0
		_reposition_dest = Vector2.ZERO
		# 未进入基地发现半径前不持有基地坐标，只进行随机漫游。
		roam_behavior(delta, null)
		return

	var target_id := target_base.get_instance_id()
	if _base_approach_target_id != target_id:
		_base_approach_target_id = target_id
		_base_approach_complete = false
		_reposition_dest = Vector2.ZERO
		last_navigation_destination = Vector2.ZERO
		is_navigation_complete = false

	# 发现基地后必须先走完整条接近路径。不能用“已进入射程”提前结束导航，
	# 否则侦察坦克会停在路径中途，隔着大片地形朝基地开火。
	if not _base_approach_complete:
		move_by_navigation(delta, target_base.global_position)
		if is_navigation_complete and last_navigation_destination == target_base.global_position:
			_base_approach_complete = true
		elif velocity == Vector2.ZERO:
			# 只有确实无路径时才尝试脱困；已有路径时绝不因射程提前停下。
			var dir_to_base: Vector2 = target_base.global_position - global_position
			if dir_to_base.length() > 1.0:
				var d: Vector2 = to_cardinal(dir_to_base)
				if _is_ahead_walkable(d):
					set_move_direction_cardinal(d, move_speed)
		set_turret_target_direction(target_base.global_position)
		if not _base_approach_complete:
			return

	# 到达导航终点后才检查是否具备有效射位。若射程仍不足或石块挡线，
	# 再进入换位阶段；换位途中同样不会开火。
	var dist := global_position.distance_to(target_base.global_position)
	if _reposition_dest != Vector2.ZERO or dist > cfg_fire_range:
		_reposition_for_clear_shot(delta)
		return
	var shot: Dictionary = _check_base_shot()
	if not bool(shot.get("blocked", false)) or bool(shot.get("destructible", false)):
		velocity = Vector2.ZERO
		set_turret_target_direction(target_base.global_position)
		shoot("tank_enemy")
	else:
		_reposition_for_clear_shot(delta)


## 检查到玩家基地的弹道：{ blocked: 是否被地形阻挡, destructible: 阻挡地形可否被击毁 }
func _check_base_shot() -> Dictionary:
	var mm = GM.get_map_manager()
	if mm == null:
		return {"blocked": false, "destructible": true}
	return mm.check_shot_blocked(global_position, target_base.global_position, _shell_type())


## 读取本坦克炮弹的伤害类型（从子弹场景实例化一次并缓存）
func _shell_type() -> GM.DamageType:
	if _shell_damage_type == null:
		_shell_damage_type = GM.DamageType.NORMAL
		if bullet_scene != null:
			var sample = bullet_scene.instantiate()
			if "damage_type" in sample:
				_shell_damage_type = sample.damage_type
			sample.free()
	return _shell_damage_type


## 视线被不可击毁地形挡住：搜索一个弹道通畅的射击位并导航过去
func _reposition_for_clear_shot(delta: float) -> void:
	# 已持有换位点：沿导航前往；到达（或导航失败）后仍被挡则放弃该点重选
	if _reposition_dest != Vector2.ZERO:
		move_by_navigation(delta, _reposition_dest)
		if velocity == Vector2.ZERO:
			if is_navigation_complete or _reposition_dest.distance_to(global_position) <= 4.0:
				_reposition_dest = Vector2.ZERO
			else:
				# 导航失败（自身卡在导航不可走格，如单格窄缝）：
				# 选任意可走方向绕出（含背离方向——窄缝出口可能背离目标），
				# 优先朝换位点；绕出后导航自然恢复
				var dir: Vector2 = _pick_escape_direction(_reposition_dest)
				if dir != Vector2.ZERO:
					set_move_direction_cardinal(dir, move_speed)
				else:
					_reposition_dest = Vector2.ZERO
		set_turret_target_direction(target_base.global_position)
		return

	# 未到重搜间隔：继续朝玩家基地逼近，避免原地发呆
	_reposition_timer -= delta
	if _reposition_timer > 0.0:
		move_by_navigation(delta, target_base.global_position)
		if velocity == Vector2.ZERO and not is_navigation_complete:
			# 导航失败兜底：选可走方向绕出（含背离方向）
			var dir: Vector2 = _pick_escape_direction(target_base.global_position)
			if dir != Vector2.ZERO:
				set_move_direction_cardinal(dir, move_speed)
		set_turret_target_direction(target_base.global_position)
		return
	_reposition_timer = REPOSITION_SEARCH_INTERVAL

	_reposition_dest = _find_clear_shot_position()
	var dest: Vector2 = _reposition_dest if _reposition_dest != Vector2.ZERO else target_base.global_position
	# 置空上次导航目的地，强制立即重算路径
	last_navigation_destination = Vector2.ZERO
	move_by_navigation(delta, dest)
	set_turret_target_direction(target_base.global_position)


## 沿方向 d 走一格后，目标格物理上是否可进入（与坦克单格碰撞体一致）：
## 空地/冰面可走，水面需船，砖/石/基地不可走。
## 注意不能用导航的 2x2 语义判断——坦克能物理进出单格窄缝，2x2 会把缝口误判为不可走。
func _is_ahead_walkable(d: Vector2) -> bool:
	var mm = GM.get_map_manager()
	if mm == null:
		return true  # 无地图信息时不额外限制，保持原行为
	var ahead: Vector2 = global_position + d * float(mm.grid_size)
	match mm.get_tile_type_at(ahead):
		"", "ice":
			return true
		"water":
			return has_boat
		_:
			return false


## 导航失败（卡死）时的绕出方向：四方向按"朝目标程度"降序，取第一个前方格可走的；
## 全部朝目标方向不可走时允许背离方向（窄缝出口可能背离目标）
func _pick_escape_direction(dest: Vector2) -> Vector2:
	var to_dest: Vector2 = dest - global_position
	var dirs: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	dirs.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.dot(to_dest) > b.dot(to_dest))
	for d in dirs:
		if _is_ahead_walkable(d):
			return d
	return Vector2.ZERO


## 在玩家基地周边射程范围内找一个：弹道通畅、可通行、离自己最近的格子
func _find_clear_shot_position() -> Vector2:
	var mm = GM.get_map_manager()
	if mm == null:
		return Vector2.ZERO
	var navigator = mm.get_navigator()
	if navigator == null:
		return Vector2.ZERO
	var grid: int = mm.grid_size
	var base_pos: Vector2 = target_base.global_position
	var base_cell: Vector2i = mm.world_to_grid(base_pos)
	var search_radius := int(ceil(cfg_fire_range / float(grid)))
	var best_dest := Vector2.ZERO
	var best_dist := INF
	for dy in range(-search_radius, search_radius + 1):
		for dx in range(-search_radius, search_radius + 1):
			var cell := base_cell + Vector2i(dx, dy)
			var world := mm.grid_to_world(cell)
			# 候选必须在射程内，且离自己不太远（避免横穿地图）
			if world.distance_to(base_pos) > cfg_fire_range:
				continue
			if world.distance_to(global_position) > cfg_fire_range * 2.0:
				continue
			# 弹道必须通畅
			if mm.check_shot_blocked(world, base_pos, _shell_type()).blocked:
				continue
			# 格子必须可通行（坦克能开过去）
			if not navigator.is_cell_walkable(cell, has_boat):
				continue
			var d := world.distance_to(global_position)
			if d < best_dist:
				best_dist = d
				best_dest = world
	return best_dest


# 追击行为（状态：CHASE）
func chase_behavior(delta: float) -> void:
	# 追击型坦克攻击目标：玩家坦克
	detect_tank_targets()

	if is_instance_valid(target_tank):
		# CHASE → DEFEND：返回防守条件按角色区分（见 _should_return_to_defend）。
		if is_instance_valid(defend_base) and _should_return_to_defend():
			_set_state(State.DEFEND, "返回基地防守")
			return
		# 向目标移动
		move_by_navigation(delta, target_tank.global_position)
		# 如果发现则对准并在可开火时射击
		set_turret_target_direction(target_tank.global_position)
		var to_target: Vector2 = target_tank.global_position - global_position
		var dist: float = to_target.length()
		if dist <= cfg_fire_range:
			shoot("tank_enemy")
		else:
			# 随机开火
			random_firing(delta)
	else:
		# 目标玩家坦克失效/未发现：保持 CHASE 漫游并持续探测（同 DETECT，不切状态）
		target_tank = null
		roam_behavior(delta, null)


## 判断追击中是否应返回防守（按角色区分返回阈值）
## - 防守型（ai_role=defend）：追击出基地周边 2 倍防守半径即返回；
## - 追击型（ai_role=chase）及其他：目标超出追击上限（探测范围×2）才返回。
## 基地被摧毁（引用失效）后：所有角色都不再返回防守，持续追击（背水一战）。
func _should_return_to_defend() -> bool:
	if not is_instance_valid(defend_base):
		return false
	if ai_role == "defend":
		return global_position.distance_to(defend_base.global_position) > defend_radius * 2.0
	return global_position.distance_to(target_tank.global_position) > chase_range


# 防守行为（状态：DEFEND）
# 防守型坦克在敌方基地周边防守：炮塔随机转向和发射；
# 玩家坦克进入射程内 → 静止并炮管直指（不偏移）攻击；
# 玩家坦克离开射程 → 转追击（返回条件见 chase_behavior 的 _should_return_to_defend）。
# 基地被摧毁后 → 转追击玩家坦克（背水一战，头顶感叹号，永不返回防守）。
func defend_behavior(delta: float) -> void:
	# 先检测目标
	detect_tank_targets()

	# 发现玩家坦克
	if is_instance_valid(target_tank):
		var distance_to_tank := global_position.distance_to(target_tank.global_position)
		if distance_to_tank <= cfg_fire_range:
			# 射程内：静止，炮管直指（不偏移）攻击
			velocity = Vector2.ZERO
			set_turret_target_direction(target_tank.global_position)
			shoot("tank_enemy")
		else:
			# 射程外：转追击（DEFEND → CHASE）
			_set_state(State.CHASE, "玩家坦克离开射程")
		return

	# 未发现玩家：在基地周边防守
	var to_center: Vector2 = defend_base.global_position - global_position
	var dist_to_base = to_center.length()
	if dist_to_base > defend_radius:
		# 离基地太远，导航返回基地
		move_by_navigation(delta, defend_base.global_position)
	else:
		# 在防守半径内：随机转向 + 压制射击
		velocity = Vector2.ZERO
		random_turret_target_direction(delta, global_position + current_direction)
		random_firing(delta)
		

# 使用导航系统移动到目标位置
func move_by_navigation(delta: float, target_position: Vector2) -> void:
	var mm = GM.get_map_manager()
	if mm == null:
		push_error("move_by_navigation: 无法获取 MapManager 单例")
		return
	
	# 如果导航已经完成，并且目标没变，则停止移动
	if is_navigation_complete and last_navigation_destination == target_position:
		velocity = Vector2.ZERO
		# 通知 MapManager 导航已停止
		mm.set_navigation_active(false)
		return

	# 通知 MapManager 导航正在进行
	mm.set_navigation_active(true)

	# 如果目标改变，重置导航状态
	if last_navigation_destination != target_position:
		last_navigation_destination = target_position
		is_navigation_complete = false
		path_update_timer = path_update_interval # 立即更新路径

	# 使用导航系统寻路
	_update_path_to_target(delta, target_position)
	
	# 如果路径为空或已到达终点，停止移动
	if current_path.size() == 0 or current_path_index >= current_path.size():
		velocity = Vector2.ZERO
		# 通知 MapManager 导航已停止
		mm.set_navigation_active(false)
		return

	# 路径点为 2x2 区域的中心
	var next_point = current_path[current_path_index]
	var to_next = next_point - global_position

	# 检测是否已经超过当前路径点
	if current_path_index + 1 < current_path.size():
		var next_next_point = current_path[current_path_index + 1]
		var to_next_next = next_next_point - global_position
		if to_next.dot(to_next_next) < 0:
			current_path_index += 1
			next_point = current_path[current_path_index]
			to_next = next_point - global_position

	# 如果接近中心点，推进到下一个路径点
	var grid_size = mm.grid_size
	var snap_tolerance = grid_size * 0.5 
	if to_next.length() <= snap_tolerance:
		current_path_index += 1
		if current_path_index >= current_path.size():
			velocity = Vector2.ZERO
			is_navigation_complete = true
			# 通知 MapManager 导航已停止
			mm.set_navigation_active(false)
			return

	# 朝向下一个路径点的中心移动
	set_move_direction_cardinal(to_cardinal(to_next), move_speed)

# 更新到目标的路径 - 通过 GameManager 获取导航器
func _update_path_to_target(delta: float, target_position: Vector2) -> void:
	# 如果导航已经完成，不再更新路径
	if is_navigation_complete:
		return

	# 定期更新路径，避免每帧都计算
	path_update_timer += delta
	if path_update_timer >= path_update_interval:
		path_update_timer = 0.0
		
		# 通过 GameManager 获取导航器
		if GM.has_method("get_navigator"):
			var navigator = GM.get_navigator()
			if navigator:
				# 根据是否有船获取路径
				var new_path = navigator.get_nav_path(global_position, target_position, has_boat)
				current_path = new_path
				current_path_index = 0  # 重置路径索引

# ===== 基地通信 =====

## 重写父类：设置守卫基地后连接其"目标发现"信号。
## 时序说明：FactoryTank._spawn_one 先 add_child（触发 _ready）再调用 set_defend_base_path，
## 若只在 _ready 连接会因 defend_base_path 尚为空而错过广播。改为路径设置时连接。
## 仅侦察型连接其生产基地的 target_base_discovered 信号。
## 广播不会影响同基地追击型/防守型，也不会影响其它基地坦克。
func set_defend_base_path(path: NodePath) -> void:
	super.set_defend_base_path(path)
	if ai_role != "detect":
		return
	if defend_base_path == NodePath():
		return
	var base = get_node_or_null(defend_base_path)
	if base and base is BaseEnemy:
		if not base.target_base_discovered.is_connected(_on_base_target_discovered):
			base.target_base_discovered.connect(_on_base_target_discovered)

# 信号回调 - 当守卫基地广播发现玩家基地时调用
func _on_base_target_discovered(target: Node2D) -> void:
	if ai_role != "detect":
		return
	if not is_instance_valid(target):
		return
	target_base = target
	has_received_target_discovery = true
	# 强制切换为侦察模式追击玩家基地
	_set_state(State.DETECT, "收到基地广播：目标玩家基地已发现")
	# 提示：发现玩家基地 → 头顶无线电波
	_trigger_radio_wave()
	print("坦克 %s 收到基地信号，目标基地已发现: %s" % [name, target.name])

# 检测基地：侦察模式
func detect_base_targets() -> void:
	# 如果已收到基地的目标发现信号，则直接使用该目标（不重复触发提示）
	if has_received_target_discovery and is_instance_valid(target_base):
		return
	
	# 否则尝试从守卫基地获取已经广播的发现结果。
	if defend_base_path != NodePath():
		var base = get_node_or_null(defend_base_path)
		if base and base is BaseEnemy:
			var discovered = base.get_discovered_target_base()
			if is_instance_valid(discovered):
				_acquire_target_base(discovered)
				return

	# 未经发现的显式目标路径不得绕过半径；只保留本地范围检测结果。
	target_base = null
	var found = _find_player_base_in_range(cfg_scout_base_detect_range)
	if is_instance_valid(found):
		_acquire_target_base(found)
		# 通知守卫基地，由基地广播给旗下坦克
		if defend_base_path != NodePath():
			var base = get_node_or_null(defend_base_path)
			if base and base is BaseEnemy:
				base.notify_target_base_discovered(found)

# 记录目标玩家基地并触发"发现"提示
func _acquire_target_base(base: Node2D) -> void:
	if target_base == base:
		return
	target_base = base
	has_received_target_discovery = true
	_trigger_radio_wave()
	# 发现玩家基地：强警报（仅本地首次发现的坦克播放；广播同伴不重复响）
	AudioManager.play_sfx("alert_base")

# 检测坦克：追击、防守模式
func detect_tank_targets() -> void:
	# 如果已有显式目标，先检查距离是否超出范围
	if is_instance_valid(target_tank):
		# 防守型基地被毁后的"背水一战"：一旦锁定玩家坦克，不受探测范围限制，持续追击不可甩开
		if ai_role == "defend" and not is_instance_valid(defend_base):
			return
		var dist_to_target: float = (target_tank.global_position - global_position).length()
		var keep_range := cfg_detect_range
		# 玩家隐身：优先取有效倍率（开火暴露窗口内视为 1.0）
		if target_tank.has_method("get_effective_stealth_multiplier"):
			keep_range = cfg_detect_range * float(target_tank.get_effective_stealth_multiplier())
		elif "stealth_multiplier" in target_tank:
			keep_range = cfg_detect_range * float(target_tank.stealth_multiplier)
		if dist_to_target > keep_range:
			target_tank = null  # 目标超出检测范围（含玩家隐身缩放），失去目标
			return
		return  # 目标仍在范围内，保持不变

	# 如果有显式路径，尝试获取目标
	if target_tank_path != NodePath():
		var path_target = get_node_or_null(target_tank_path)
		if is_instance_valid(path_target):
			target_tank = path_target
			# 首次锁定玩家坦克 → 头顶感叹号
			_trigger_exclamation()
		return

	# 否则自动检测最近的目标
	var found = detect_nearest_target("player_tanks", cfg_detect_range)
	if is_instance_valid(found):
		target_tank = found
		# 首次锁定玩家坦克 → 头顶感叹号
		_trigger_exclamation()

## 检测最近的目标（target_group_name：玩家坦克分组 "player_tanks"）
func detect_nearest_target(target_group_name: String, max_range: float) -> Node2D:
	if target_group_name == "":
		return null

	# 在 group 中查找最近目标（需把对应目标加入该组）
	var candidates = get_tree().get_nodes_in_group(target_group_name)
	if candidates.size() == 0:
		return null

	var nearest: Node2D = null
	var nearest_dist := INF
	for c in candidates:
		if not (c is Node2D):
			continue
		# 玩家隐身：缩小该目标的可探测范围（含开火暴露窗口）
		var eff_range := max_range
		if c.has_method("get_effective_stealth_multiplier"):
			eff_range = max_range * float(c.get_effective_stealth_multiplier())
		elif "stealth_multiplier" in c:
			eff_range = max_range * float(c.stealth_multiplier)
		var d: float = (c.global_position - global_position).length()
		if d <= eff_range and d < nearest_dist:
			nearest_dist = d
			nearest = c

	return nearest


## 侦察模式专用：基地不进入敌方扫描分组，仅在本次范围检测时从全局注册表获取候选。
func _find_player_base_in_range(max_range: float) -> Node2D:
	var nearest: Node2D = null
	var nearest_dist := max_range
	for base in GM.get_player_bases():
		if not is_instance_valid(base):
			continue
		var distance := global_position.distance_to(base.global_position)
		if distance < nearest_dist:
			nearest_dist = distance
			nearest = base
	return nearest

# 接收来自基地的信号
func rev_msg_from_base(msg: String) -> void:
	print("TankEnemy received message from base: %s" % msg)

# 发送信号给基地
func send_msg_to_base(msg: String) -> void:
	var defend_base = get_node_or_null(defend_base_path)
	if defend_base != null and defend_base.has_method("rev_msg_from_tank"):
		defend_base.rev_msg_from_tank(msg)

# 坦克被摧毁时的处理
func _on_tank_destroyed() -> void:
	print("TankEnemy: Tank destroyed at position: ", global_position)
	# 记录战役击杀统计（按等级）
	if GameState:
		GameState.register_tank_killed(level)
	# 生成掉落物
	if DropSystem:
		print("TankEnemy: Calling DropSystem.spawn_drop_from_enemy_tank")
		DropSystem.spawn_drop_from_enemy_tank(global_position, level)
	else:
		print("TankEnemy: ERROR - DropSystem not found!")


# 从 enemy_units.json 加载坦克属性
func _load_from_config() -> void:
	var template = ConfigLoader.get_enemy_template("tank", level)
	if template.is_empty():
		return

	cfg_max_hp = int(template.get("max_health", cfg_max_hp))
	cfg_firepower = int(template.get("shell_damage", cfg_firepower))
	cfg_defense = int(template.get("defense", cfg_defense))
	var speed_tiles = float(template.get("move_speed", 2.0))
	cfg_move_speed = speed_tiles * 20.0  # 与 tank_player 相同的换算
	# 炮弹速度/射程：u 单位 → 像素（×20 与移动速度换算一致），随强度梯次增大
	shell_speed_px = float(template.get("shell_speed", 14.0)) * 20.0
	shell_range_px = float(template.get("shell_range", 8.0)) * 20.0
	# 射击冷却（普通 2.5s / 精英 2.0s / BOSS 1.5s）
	cfg_shoot_cooldown = float(template.get("shoot_cooldown", 2.5))
	# 炮塔转速（°/s）：普通与玩家裸装持平 100，精英 110 / BOSS 120 拉开梯度
	cfg_turret_turn_speed = float(template.get("turret_turn_speed", cfg_turret_turn_speed))
	# CHASE/DEFEND 探测、DETECT 基地发现和开火范围：u 单位 → 像素（×20）。
	cfg_detect_range = float(template.get("detect_range", 8.0)) * 20.0
	cfg_scout_base_detect_range = float(template.get("scout_base_detect_range", 15.0)) * 20.0
	cfg_fire_range = float(template.get("fire_range", 6.0)) * 20.0
	roam_interval_min = float(template.get("roam_interval_min", 1.0))
	roam_interval_max = float(template.get("roam_interval_max", 3.0))
	chase_range = cfg_detect_range * float(template.get("chase_range_multiplier", 2.0))
	defend_radius = float(template.get("defend_radius", 3.0)) * 20.0
	defend_alert_range = float(template.get("return_threshold", 8.0)) * 20.0
	# AI 智能度
	ai_intelligence = float(template.get("ai_intelligence", ai_intelligence))
	# BOSS 狂暴参数：仅 boss 等级配置包含 boss_rage 节点
	var rage_cfg: Dictionary = template.get("boss_rage", {})
	if not rage_cfg.is_empty():
		rage_interval = float(rage_cfg.get("rage_interval", rage_interval))
		rage_chance = float(rage_cfg.get("rage_chance", rage_chance))
		rage_duration = float(rage_cfg.get("rage_duration", rage_duration))
		rage_fire_rate_multiplier = float(rage_cfg.get("rage_fire_rate_multiplier", rage_fire_rate_multiplier))
		# 首次狂暴判定随机化，避免同帧齐狂暴
		_rage_timer = randf_range(rage_interval - 5.0, rage_interval + 5.0)


## 将 cfg_* 配置应用到父类变量
func _apply_cfg() -> void:
	move_speed = cfg_move_speed
	turret_turn_speed = cfg_turret_turn_speed
	max_hp = cfg_max_hp
	shoot_cooldown = cfg_shoot_cooldown
	firepower = cfg_firepower
	defense = cfg_defense
	current_hp = max_hp
	# 精英/BOSS 20% 穿甲（普通 0）
	armor_penetration = 0.2 if level in ["elite", "boss"] else 0.0


## 设置坦克等级（由工厂调用），切换贴图并重载属性
func set_level(lv: String) -> void:
	level = lv
	_load_from_config()
	_apply_cfg()
	_apply_level_textures()


## 应用动态难度缩放（生成时由工厂/波次管理器调用）。
## 耐久、火力、防御分别读取同一配置曲线，防御仅轻微受波次影响并按等级封顶。
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
	# 循环挑战：通关第 10 战役后每轮敌方耐久/火力 +10%
	var cycle_mult := 1.0 + 0.1 * float(GameState.cycle_count)
	var hp_mult := pow(hp_stage, stage_index) * pow(float(scaling.get("wave_hp_multiplier", 1.0)), wave_index) * cycle_mult
	var firepower_mult := pow(damage_stage, stage_index) * pow(float(scaling.get("wave_damage_multiplier", 1.0)), wave_index) * cycle_mult
	var defense_mult := pow(defense_stage, stage_index) * pow(float(scaling.get("wave_defense_multiplier", 1.01)), wave_index)
	cfg_max_hp = int(round(cfg_max_hp * hp_mult))
	cfg_firepower = int(round(cfg_firepower * firepower_mult))
	var defense_caps: Dictionary = scaling.get("defense_cap_by_level", {})
	cfg_defense = mini(int(round(cfg_defense * defense_mult)), int(defense_caps.get(level, 170)))
	# 炮塔转速：不用指数缩放（30 关会涨到 9×，转塔瞬间锁人体验崩坏），
	# 改用温和线性增长并封顶 +50%（每关 +2%，第 26 关到顶）；波次不参与，避免波内突变。
	# 封顶后普通 150 / 精英 165 / BOSS 180，仍低于玩家满配轴承 175+黑匣升级的成长上限。
	var turret_speed_mult: float = 1.0 + min(0.5, 0.02 * float(stage - 1))
	cfg_turret_turn_speed = cfg_turret_turn_speed * turret_speed_mult
	_apply_cfg()
	print("TankEnemy: 等级 %s 应用缩放 HPx%.2f 火力x%.2f 防御x%.2f 转速x%.2f 循环x%.2f → HP %d 火力 %d 防御 %d 转速 %.0f°/s" % [level, hp_mult, firepower_mult, defense_mult, turret_speed_mult, cycle_mult, max_hp, firepower, defense, turret_turn_speed])


## 按等级应用车体贴图与炮塔贴图
func _apply_level_textures() -> void:
	var sheet: Texture2D = load(LEVEL_BODY_SHEETS.get(level, LEVEL_BODY_SHEETS["normal"]))
	if sheet and body_sprite:
		var frames := SpriteFrames.new()
		frames.add_animation("idle")
		frames.set_animation_speed("idle", 8.0)
		frames.set_animation_loop("idle", true)
		for i in range(2):
			var at := AtlasTexture.new()
			at.atlas = sheet
			at.region = Rect2(i * 32, 0, 32, 32)
			frames.add_frame("idle", at)
		body_sprite.sprite_frames = frames
		body_sprite.animation = &"idle"
		body_sprite.play()
	var tur: Texture2D = load(LEVEL_TURRETS.get(level, LEVEL_TURRETS["normal"]))
	if tur:
		var ts := get_node_or_null("Turret/TurretSprite") as Sprite2D
		if ts:
			ts.texture = tur

# ===== BOSS 狂暴逻辑 =====

func _update_boss_rage(delta: float) -> void:
	# 仅 BOSS 等级有狂暴
	if level != "boss":
		return
	if _is_raging:
		# 狂暴持续中
		_rage_active_timer -= delta
		if _rage_active_timer <= 0.0:
			_end_rage()
		return
	# 非狂暴：每 20-30s 判定一次进入狂暴的概率
	_rage_timer -= delta
	if _rage_timer <= 0.0:
		_rage_timer = randf_range(rage_interval - 5.0, rage_interval + 5.0)  # rage_interval=25 → 20~30s
		if randf() < rage_chance:
			_start_rage()

func _start_rage() -> void:
	_is_raging = true
	_rage_active_timer = rage_duration
	_base_shoot_cooldown = shoot_cooldown
	# 狂暴：射速 ×rage_fire_rate_multiplier → 冷却临时缩短为 1/multiplier
	shoot_cooldown = shoot_cooldown / rage_fire_rate_multiplier
	# 可选视觉：炮塔闪红提示狂暴
	var turret_node := get_node_or_null("Turret") as Node2D
	if turret_node:
		turret_node.modulate = Color(1.0, 0.35, 0.35)
	print("TankEnemy %s: BOSS 进入狂暴！射速 x%.1f，持续 %.1fs" % [name, rage_fire_rate_multiplier, rage_duration])

func _end_rage() -> void:
	_is_raging = false
	shoot_cooldown = _base_shoot_cooldown
	var turret_node := get_node_or_null("Turret") as Node2D
	if turret_node:
		turret_node.modulate = Color(1.0, 1.0, 1.0)
	print("TankEnemy %s: 狂暴结束，射速恢复" % name)
