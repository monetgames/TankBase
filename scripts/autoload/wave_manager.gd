extends Node

## WaveManager 单例
## 管理战斗循环中的波次生成和进度

# ===== 信号 =====
signal wave_started(stage: int, wave: int)
signal wave_completed(stage: int, wave: int)
signal map_loaded()  # 地图加载完成信号

# ===== 状态 =====
var current_wave_enemies: Array[Node] = []  # 当前波次的敌方单位
var _interval_timer: Timer = null           # 波次间隔计时器

# ===== 配置 =====
var wave_interval: float = 3.0  # 波次间隔秒数（从配置加载）

# ===== 退出状态 =====
var _shutting_down: bool = false  # 场景树销毁中（退出游戏）：敌方单位批量移除不判定为波次完成


func _ready() -> void:
	# 创建波次间隔计时器
	_interval_timer = Timer.new()
	_interval_timer.one_shot = true
	_interval_timer.timeout.connect(_on_interval_timer_timeout)
	add_child(_interval_timer)
	
	# 从配置加载波次间隔
	if ConfigLoader.wave_configs.size() > 0:
		var first_wave = ConfigLoader.wave_configs[0]
		wave_interval = first_wave.get("wave_interval", 3.0)


## 开始新波次
## @param stage: 全局关卡编号（1-30）
## @param wave: 波次编号（1-3）
func start_wave(stage: int, wave: int) -> void:
	print("WaveManager: 开始关卡 %d 波次 %d" % [stage, wave])
	current_wave_enemies.clear()
	
	# 我方基地和坦克立即开始战斗；敌方仍在其后进行出生光标演出。
	call_deferred("_emit_map_loaded")

	# 生成敌方单位（内部可能 await 地图就绪，必须等它完成再继续）
	await _spawn_enemies(stage, wave)
	
	# 波次开始警报音效
	if AudioManager:
		AudioManager.play_sfx("wave_start")

	wave_started.emit(stage, wave)

## 延迟发出地图加载完成信号
func _emit_map_loaded() -> void:
	print("WaveManager: 地图加载完成，发出 map_loaded 信号")
	map_loaded.emit()


## 注册敌方单位到当前波次
## @param enemy: 敌方单位节点
func register_enemy(enemy: Node) -> void:
	if not current_wave_enemies.has(enemy):
		current_wave_enemies.append(enemy)
		# 监听敌方单位的销毁信号
		if not enemy.tree_exited.is_connected(_on_enemy_removed.bind(enemy)):
			enemy.tree_exited.connect(_on_enemy_removed.bind(enemy))
		# 通知UI更新敌方坦克数量（只统计坦克，不含基地）
		var tank_count = current_wave_enemies.filter(func(e): return is_instance_valid(e) and e.is_in_group("enemy_tanks")).size()
		GM.sig_enemy_tank_count_changed.emit(tank_count)


## 敌方单位被移除时的回调
func _on_enemy_removed(enemy: Node) -> void:
	# 退出游戏时场景树销毁会批量移除敌方单位，不视为波次完成
	if _is_shutting_down():
		return
	current_wave_enemies.erase(enemy)
	# 通知UI更新敌方坦克数量
	var tank_count = current_wave_enemies.filter(func(e): return is_instance_valid(e) and e.is_in_group("enemy_tanks")).size()
	GM.sig_enemy_tank_count_changed.emit(tank_count)
	_check_wave_completion()


## 检查波次是否完成
func _check_wave_completion() -> void:
	if _is_shutting_down():
		return
	# 过滤掉已销毁的节点
	current_wave_enemies = current_wave_enemies.filter(func(e): return is_instance_valid(e))
	
	if current_wave_enemies.is_empty():
		print("WaveManager: 所有敌方单位已消灭，波次完成")
		wave_completed.emit(GM.current_stage, GM.current_wave)


## 是否处于退出游戏/场景树销毁流程（自身或 GameManager 已脱离场景树）
func _is_shutting_down() -> bool:
	return _shutting_down or not is_inside_tree() or GM.is_quitting


func _exit_tree() -> void:
	# 退出游戏：标记销毁并清空波次单位，避免后续批量移除触发波次完成
	_shutting_down = true
	stop_interval_timer()
	current_wave_enemies.clear()


## 生成敌方单位
## @param stage: 关卡编号
## @param wave: 波次编号
func _spawn_enemies(stage: int, wave: int) -> void:
	var wave_config = get_wave_config(stage, wave)
	
	if wave_config.is_empty():
		GameLog.warn("wave", "波次配置为空 stage=%d wave=%d，使用默认配置" % [stage, wave])
		wave_config = _get_default_wave_config(stage, wave)
	
	# 获取地图管理器
	var map_mgr = GM.get_map_manager()
	if map_mgr == null:
		GameLog.error("wave", "获取 MapManager 失败，无法生成敌方单位 stage=%d wave=%d" % [stage, wave])
		return
	
	# 生成敌方基地（位置来自关卡地图 JSON 的 base_enemy 配置，每波随机取用）
	var enemy_bases: Array = _sanitize_wave_bases(stage, wave, wave_config.get("enemy_bases", []))
	var base_pos_configs: Array = map_mgr.get_base_enemy_configs() if map_mgr.has_method("get_base_enemy_configs") else []
	# 时序防御：战斗场景 node_added 信号可能先于 map_manager 加载完地图数据触发，
	# 此时 base_enemy 配置为空——等待地图数据就绪后再取（轮询最多 30 帧）
	if base_pos_configs.is_empty() and map_mgr.has_method("get_base_enemy_configs"):
		for _i in range(30):
			if not map_mgr.is_node_ready():
				await map_mgr.ready
			base_pos_configs = map_mgr.get_base_enemy_configs()
			if not base_pos_configs.is_empty():
				break
			await get_tree().process_frame
	if base_pos_configs.is_empty():
		GameLog.error("wave", "关卡地图未配置敌方基地位置（base_enemy），跳过基地生成 stage=%d wave=%d" % [stage, wave])
		return
	# 可出现点位有多个时，敌方基地每波随机分布（打乱副本后按需取用，
	# 波内不重复；基地数超过点位数时循环使用，一般每关配置 >= 单波最大基地数）
	var base_pos_pool: Array = base_pos_configs.duplicate()
	base_pos_pool.shuffle()
	if is_campaign_first_stage(stage):
		# 首关把高阶基地优先放到离玩家基地更远的位置，避免开局围攻。
		var player_pos := _get_player_base_position()
		base_pos_pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _base_position_distance(a, player_pos, map_mgr.grid_size) > _base_position_distance(b, player_pos, map_mgr.grid_size))
		enemy_bases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _base_level_rank(str(a.get("level", "normal"))) > _base_level_rank(str(b.get("level", "normal"))))
	# 所有敌方基地先共同显示 2 秒出生光标，避免基地和首批坦克一开局立即出现。
	var pending_enemy_bases: Array[Dictionary] = []
	for i in range(enemy_bases.size()):
		var pos_config: Dictionary = base_pos_pool[i % base_pos_pool.size()]
		if not pos_config.has("pos") or (pos_config["pos"] as Array).size() != 2:
			push_error("WaveManager: 基地位置配置缺少 pos 字段（关卡地图不兼容）")
			continue
		if map_mgr.has_method("clear_base_area"):
			map_mgr.clear_base_area(pos_config["pos"], pos_config.get("tank_spawn_pos", []))
		var gs: int = map_mgr.grid_size
		var base_position := gs * Vector2(pos_config["pos"][0], pos_config["pos"][1])
		SpawnFlashEffect.spawn_at(map_mgr, base_position + Vector2(gs, gs), 2.0)
		pending_enemy_bases.append({"config": enemy_bases[i], "pos_config": pos_config})

	if not pending_enemy_bases.is_empty():
		await get_tree().create_timer(2.0).timeout
	for pending in pending_enemy_bases:
		_spawn_enemy_base(pending["config"], map_mgr, pending["pos_config"], true)


## 生成单个敌方基地
## @param config: 波次配置中的基地等级（"normal"/"elite"/"boss"）
## @param map_mgr: 地图管理器
## @param pos_config: 关卡地图 base_enemy 位置配置（含 pos/tank_spawn_pos/level）
func _spawn_enemy_base(config: Dictionary, map_mgr: Node, pos_config: Dictionary = {}, area_already_cleared: bool = false) -> void:
	var base_scene = load("res://scenes/base_enemy.tscn")
	if base_scene == null:
		push_error("WaveManager: 无法加载敌方基地场景")
		return
	
	var base_node = base_scene.instantiate()
	
	# 设置等级（波次配置优先，缺失时用地图标注等级）
	var level = config.get("level", "")
	if level.is_empty() and pos_config.has("level"):
		var lv_num: int = int(pos_config["level"])
		level = "normal"
		match lv_num:
			2: level = "elite"
			3: level = "boss"
	if base_node.has_method("set_level"):
		base_node.set_level(level)
	
	# 位置来自关卡地图配置（格子坐标 → 像素），不再随机生成
	var gs: int = map_mgr.grid_size
	if pos_config.has("pos") and (pos_config["pos"] as Array).size() == 2:
		base_node.position = gs * Vector2(pos_config["pos"][0], pos_config["pos"][1])
		# 清理基地占地瓦片（基地 2×2 + 坦克出生点），避免基地压在障碍物上
		if not area_already_cleared and map_mgr.has_method("clear_base_area"):
			map_mgr.clear_base_area(pos_config["pos"], pos_config.get("tank_spawn_pos", []))
	else:
		push_error("WaveManager: 基地位置配置缺少 pos 字段（关卡地图不兼容）")
		base_node.queue_free()
		return
	
	map_mgr.add_child(base_node)
	if is_campaign_first_stage(GM.current_stage) and base_node.enemy_tank_factory != null:
		base_node.enemy_tank_factory.initial_spawn_delay = get_first_stage_pressure(GM.current_stage, GM.current_wave).get("spawn_delay", 2.0)
		# 基地 _ready 已在本帧启动工厂，覆盖其首轮冷却以保证延迟真正生效。
		base_node.enemy_tank_factory._cooldown = base_node.enemy_tank_factory.initial_spawn_delay
	
	# 坦克出生点：优先使用地图配置的 tank_spawn_pos，缺失时回退基地四周
	if pos_config.has("tank_spawn_pos") and (pos_config["tank_spawn_pos"] as Array).size() > 0:
		var spawns := PackedVector2Array()
		for sp in pos_config["tank_spawn_pos"]:
			if (sp as Array).size() == 2:
				spawns.append(gs * Vector2(sp[0] + 1, sp[1] + 1))
		if base_node.enemy_tank_factory != null and spawns.size() > 0:
			base_node.enemy_tank_factory.tank_spawn_positions = spawns
	elif base_node.enemy_tank_factory != null:
		base_node.enemy_tank_factory.tank_spawn_positions = PackedVector2Array([
			base_node.position + Vector2(-gs * 2, 0),
			base_node.position + Vector2(gs * 4, 0),
			base_node.position + Vector2(0, gs * 4),
		])
	
	# 应用动态难度缩放（属性 × 1.08^(全局关-1) × 1.03^(波-1)）
	if base_node.has_method("apply_scaling"):
		base_node.apply_scaling(GM.current_stage, GM.current_wave)

	register_enemy(base_node)

	# 评级统计：该基地的预计坦克产量计入战役预计总生产（击败前就摧毁基地也不会拉低比值分母）
	if base_node.enemy_tank_factory != null:
		GameState.accumulate_enemy_tanks_planned(base_node.enemy_tank_factory.maximum_spawn)

	print("WaveManager: 生成敌方基地 [%s] 于 %s（地图配置位置）" % [level, base_node.position])


## 任意三关战役的第一关都启用低压力保护。
func is_campaign_first_stage(stage: int) -> bool:
	return stage >= 1 and (stage - 1) % ConfigLoader.max_waves_per_stage == 0


## 返回首关全局基地/坦克上限。非首关返回 0（不额外限制）。
func get_first_stage_pressure(stage: int, wave: int) -> Dictionary:
	if not is_campaign_first_stage(stage):
		return {"base_limit": 0, "tank_limit": 0, "spawn_delay": 0.0}
	var campaign := clampi(int(ceil(float(stage) / float(ConfigLoader.max_waves_per_stage))), 1, 10)
	var band := "1_3" if campaign <= 3 else ("4_6" if campaign <= 6 else "7_10")
	var cfg: Dictionary = ConfigLoader.wave_pressure_config
	var base_tables: Dictionary = cfg.get("base_limits_by_campaign_band", {})
	var tank_tables: Dictionary = cfg.get("tank_limits_by_campaign_band", {})
	var fallback_base := [2, 2, 3] if campaign <= 3 else ([3, 3, 4] if campaign <= 6 else [3, 4, 5])
	var fallback_tank := [6, 8, 10] if campaign <= 3 else ([8, 10, 12] if campaign <= 6 else [10, 12, 14])
	var base_limits: Array = base_tables.get(band, fallback_base)
	var tank_limits: Array = tank_tables.get(band, fallback_tank)
	var index := clampi(wave - 1, 0, ConfigLoader.max_waves_per_stage - 1)
	return {
		"base_limit": int(base_limits[index]),
		"tank_limit": int(tank_limits[index]),
		"spawn_delay": float(cfg.get("first_spawn_delay_seconds", 2.0)),
	}


## 敌方工厂在真正生成前查询：首关限制总坦克数，BOSS 额外限制全场同时存在数。
func can_spawn_enemy_tank(level: String) -> bool:
	var all_enemy_tanks := get_tree().get_nodes_in_group("enemy_tanks")
	var pressure := get_first_stage_pressure(GM.current_stage, GM.current_wave)
	if int(pressure.get("tank_limit", 0)) > 0 and all_enemy_tanks.size() >= int(pressure["tank_limit"]):
		return false
	if level != "boss":
		return true
	var boss_limit := get_boss_tank_limit(GM.current_stage, GM.current_wave)
	if boss_limit <= 0:
		return false
	var active_bosses := 0
	for tank in all_enemy_tanks:
		if is_instance_valid(tank) and str(tank.get("level")) == "boss":
			active_bosses += 1
	return active_bosses < boss_limit


## BOSS 基地只能出现在指定第三波；第 11-24 关每波至多一座，后期按关卡放宽。
func get_boss_base_limit(stage: int, wave: int) -> int:
	if stage <= 9 or is_campaign_first_stage(stage) or wave != 3:
		return 0
	if stage >= 11 and stage <= 24:
		return 1
	if stage in [26, 29]:
		return 1
	if stage in [27, 30]:
		return 2
	return 0


## 战役 4-8 全场仅一辆 BOSS 坦克；两辆仅允许最终关第三波。
func get_boss_tank_limit(stage: int, wave: int) -> int:
	var campaign := clampi(int(ceil(float(stage) / float(ConfigLoader.max_waves_per_stage))), 1, 10)
	if campaign <= 3 or is_campaign_first_stage(stage):
		return 0
	if stage == 30 and wave == 3:
		return 2
	return 1


func _sanitize_wave_bases(stage: int, wave: int, raw_bases: Array) -> Array:
	var result: Array = []
	var boss_remaining := get_boss_base_limit(stage, wave)
	for entry in raw_bases:
		if not (entry is Dictionary):
			continue
		var base: Dictionary = entry.duplicate()
		if str(base.get("level", "normal")) == "boss":
			if boss_remaining <= 0:
				base["level"] = "elite"
			else:
				boss_remaining -= 1
		result.append(base)
	var pressure := get_first_stage_pressure(stage, wave)
	var base_limit: int = pressure.get("base_limit", 0)
	if base_limit > 0 and result.size() > base_limit:
		result.resize(base_limit)
	return result


func _base_level_rank(level: String) -> int:
	match level:
		"boss": return 3
		"elite": return 2
	return 1


func _get_player_base_position() -> Vector2:
	var bases := GM.get_player_bases()
	if not bases.is_empty() and is_instance_valid(bases[0]):
		return bases[0].global_position
	return Vector2.ZERO


func _base_position_distance(config: Dictionary, player_pos: Vector2, grid_size: int) -> float:
	var pos: Array = config.get("pos", [])
	if pos.size() != 2:
		return 0.0
	return player_pos.distance_squared_to(Vector2(pos[0], pos[1]) * grid_size)

## 获取波次配置
## @param stage: 关卡编号
## @param wave: 波次编号
## @return: 波次配置字典
func get_wave_config(stage: int, wave: int) -> Dictionary:
	# 波次配置索引：(stage-1)*每关波次 + (wave-1)
	var index = (stage - 1) * ConfigLoader.max_waves_per_stage + (wave - 1)
	
	if index < ConfigLoader.wave_configs.size():
		return ConfigLoader.wave_configs[index]
	
	return {}


## 默认波次配置（配置文件缺失时使用）
func _get_default_wave_config(stage: int, wave: int) -> Dictionary:
	# 随关卡和波次增加敌方基地数量
	var base_count = 1 + (stage - 1)
	var level = "normal"
	if stage >= 3:
		level = "elite"
	if stage >= 5 and wave == 3:
		level = "boss"
	
	var bases = []
	for i in range(base_count):
		bases.append({"level": level})
	
	return {
		"enemy_bases": bases,
		"wave_interval": wave_interval
	}


## 波次间隔计时器结束回调
func _on_interval_timer_timeout() -> void:
	print("WaveManager: 波次间隔结束，开始新波次")
	start_wave(GM.current_stage, GM.current_wave)


## 启动波次间隔计时器
## @param seconds: 间隔秒数
func start_interval_timer(seconds: float = -1.0) -> void:
	var interval = seconds if seconds > 0 else wave_interval
	print("WaveManager: 波次间隔 %.1f 秒" % interval)
	_interval_timer.start(interval)


## 停止波次间隔计时器
func stop_interval_timer() -> void:
	_interval_timer.stop()


## 获取波次间隔剩余时间
func get_interval_remaining() -> float:
	return _interval_timer.time_left


## 清空当前波次状态
func clear_wave() -> void:
	current_wave_enemies.clear()
	_interval_timer.stop()
