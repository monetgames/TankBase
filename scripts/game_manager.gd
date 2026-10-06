extends Node
class_name GameManager

const GROUP_NAME := "game_manager"

# ===== 枚举类型 =====

# 游戏循环状态
enum GameLoop {
	WELCOME,	# 欢迎界面
	META,		# Meta 循环（永久成长）
	BUILD,		# 构筑循环（装备准备）
	COMBAT,		# 战斗循环（关卡战斗）
	SUMMARY		# 战役总结
}

# 战斗状态
enum CombatState {
	WAVE_PREPARE,	# 波次准备（15秒倒计时）
	WAVE_ACTIVE,	# 波次进行中
	WAVE_COMPLETE,	# 波次完成
	STAGE_COMPLETE	# 关卡完成
}

# 旧版游戏状态枚举（GameStatus），仍由 start/pause/end_game 与 sig_update_game_status 使用
enum GameStatus{
	START = 0,	# 开始
	OVER = 1,	# 结束
	PAUSE = 2,	# 暂停
	CTN = 3,		# 继续（continue）
}

# 子弹类型标签，用于区分能否破坏某些地形
enum DamageType{
	NORMAL,	# 普通弹，能打穿砖块
	AP,		# 穿甲弹（Armor-piercing ammunition），能打穿砖块、石头
	NB		# 燃烧弹（Napalm bomb），能打穿砖块、燃烧草地、不能打穿石头
}

# XY 坐标轴
enum XYAxis{
	None,	# 无
	X,		# X 坐标
	Y		# Y 坐标
}

# ===== 信号定义 =====

signal stage_changed(stage: int)				# 全局关卡改变（1-30）
signal wave_changed(wave: int)					# 波次改变（1-3）
signal campaign_victory()						# 战役胜利
signal campaign_defeat(reason: String)			# 战役失败
signal loot_gather_started(seconds: float)		# 捡金币阶段开始（波次结束后、商店弹出前）

# 玩家/敌方坦克的运行联动信号：sig_update_game_status 广播游戏状态（start/pause/end_game 时发射），sig_base_pos_changed 广播基地方位
signal sig_update_game_status(int)	# 参数为 GM.GameStatus 类型
signal sig_base_pos_changed(role : String, path : NodePath)
signal sig_player_base_destroyed
signal sig_enemy_base_destroyed
signal sig_enemy_base_count_changed(count: int)   # 敌方基地数量变化
signal sig_enemy_tank_count_changed(count: int)   # 敌方坦克数量变化
signal sig_game_over(winner: String)  # winner: "player" 或 "enemy"

# ===== 单例引用 =====

var map_manager: MapManager = null
var player_bases: Array[Node2D] = []
var enemy_bases: Array[Node2D] = []
var level_info: Dictionary = {}

# ===== 游戏状态数据 =====
var game_state: GameState = null

# ===== 游戏循环状态 =====
var current_loop: GameLoop = GameLoop.WELCOME		# 当前游戏循环
const TOTAL_LEVELS := 30
const LEVELS_PER_CAMPAIGN := 3
const TOTAL_CAMPAIGNS := 10
var current_stage: int = 0							# 当前全局关卡（1-30）
var current_wave: int = 0							# 当前波次（1-3）
var combat_state: CombatState = CombatState.WAVE_PREPARE	# 战斗状态
var _campaign_finalized: bool = false				# 战役结算防重入标志
var campaign_started: bool = false					# 当前战役是否已进入过战斗（战役中构筑循环隐藏"返回 Meta"）

# ===== 旧版游戏状态（GameStatus）=====
var current_game_status: GameStatus = GameStatus.START
var is_game_running: bool = false

# ===== 退出状态 =====
## 是否正在退出游戏：退出过程中节点会陆续脱离 SceneTree，
## 此时必须停止波次推进/场景切换等逻辑（节点脱离后再调用 get_tree() 会报 "Parameter data.tree is null"）
var is_quitting: bool = false


func _notification(what: int) -> void:
	# 关窗口 / 终止进程 / 场景树销毁：标记退出，供波次等系统查询
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		is_quitting = true


## 安全获取 SceneTree：节点已脱离场景树（退出游戏销毁场景树时）返回 null。
func get_tree_safe() -> SceneTree:
	if not is_inside_tree():
		return null
	return get_tree()


func _ready() -> void:
	if not is_in_group(GROUP_NAME):
		add_to_group(GROUP_NAME)
	
	game_state = GameState


func _process(delta: float) -> void:
	# 累计战斗时长（供结算统计"总用时"）：玩家坦克可活动时间——
	# 含波次进行（含出生演出/出生无敌）、波次间隔倒计时、捡金币阶段；
	# 不含暂停、波间商店（打开即暂停）、构筑循环（非战斗循环）。
	if current_loop == GameLoop.COMBAT and not get_tree().paused:
		GameState.stats_combat_seconds += delta

# ===== 游戏状态管理 =====

func start_game() -> void:
	if current_game_status != GameStatus.START:
		return
	current_game_status = GameStatus.START
	is_game_running = true
	print("GameManager: start_game() 被调用，发射 sig_update_game_status 信号")
	print("GameManager: 当前玩家基地数量: ", player_bases.size())
	sig_update_game_status.emit(GameStatus.START)
	print("GameManager: sig_update_game_status 信号已发射")

func pause_game() -> void:
	if current_game_status != GameStatus.START:
		return
	current_game_status = GameStatus.PAUSE
	is_game_running = false
	sig_update_game_status.emit(GameStatus.PAUSE)

func continue_game() -> void:
	if current_game_status != GameStatus.PAUSE:
		return
	current_game_status = GameStatus.CTN
	is_game_running = true
	sig_update_game_status.emit(GameStatus.CTN)

func end_game(winner: String = "player") -> void:
	current_game_status = GameStatus.OVER
	is_game_running = false
	sig_update_game_status.emit(GameStatus.OVER)
	sig_game_over.emit(winner)

# 触发失败条件
func trigger_defeat(reason: String = "") -> void:
	print("GameManager: 战役失败 - ", reason)
	GameLog.warn("campaign", "战役失败 stage=%d reason=%s" % [current_stage, reason])
	# 生成统计快照 → 清理战役内资产 → 存档 → 进入结算
	_finalize_campaign(false, reason)


# ===== 基地管理 =====

## 保存玩家坦克/基地当前耐久到 GameState（跨循环持久化）
func _store_unit_hp() -> void:
	var tanks = get_tree().get_nodes_in_group("player_tanks") if get_tree() else []
	if not tanks.is_empty() and is_instance_valid(tanks[0]) and "current_hp" in tanks[0]:
		GameState.tank_stored_hp = int(tanks[0].current_hp)
		GameState.tank_max_hp = int(tanks[0].max_hp)
		print("GameManager: 保存坦克耐久 %d/%d" % [GameState.tank_stored_hp, GameState.tank_max_hp])
	if not player_bases.is_empty() and is_instance_valid(player_bases[0]) and "current_hp" in player_bases[0]:
		GameState.base_stored_hp = int(player_bases[0].current_hp)
		GameState.base_max_hp = int(player_bases[0].max_hp)
		print("GameManager: 保存基地耐久 %d/%d" % [GameState.base_stored_hp, GameState.base_max_hp])

# 注册/移除（仅保存引用）
func register_base_player(node: Node2D) -> void:
	if node != null and not player_bases.has(node):
		player_bases.append(node)

func register_base_enemy(node: Node2D) -> void:
	if node != null and not enemy_bases.has(node):
		enemy_bases.append(node)
		sig_enemy_base_count_changed.emit(enemy_bases.size())

# 注册玩家坦克（用于相机跟随）
func register_player_tank(tank: CharacterBody2D) -> void:
	if map_manager != null:
		map_manager.set_player_tank(tank)

# 获取子弹容器
func get_bullet_container() -> Node2D:
	if map_manager != null:
		return map_manager.get_bullet_container()
	return null

func unregister_base(node: Node) -> void:
	var was_enemy = enemy_bases.has(node)
	player_bases.erase(node)
	enemy_bases.erase(node)
	
	# 发出对应数量变化信号
	if was_enemy:
		sig_enemy_base_count_changed.emit(enemy_bases.size())
	
	# 检查游戏是否结束
	if player_bases.is_empty():
		sig_player_base_destroyed.emit()
		end_game("enemy")
	elif enemy_bases.is_empty():
		sig_enemy_base_destroyed.emit()
		# 在战斗循环中，敌方基地全灭由 WaveManager 负责判断波次完成
		# 不直接调用 end_game，避免绕过波次系统
		if current_loop != GameLoop.COMBAT:
			end_game("player")

# 访问器
func get_player_bases() -> Array[Node2D]:
	return player_bases

func get_enemy_bases() -> Array[Node2D]:
	return enemy_bases

func set_level_info(info: Dictionary) -> void:
	level_info = info

func get_level_info() -> Dictionary:
	return level_info

# ===== 地图 =====

# MapManager 相关方法
func set_map_manager(manager: MapManager) -> void:
	map_manager = manager

func get_map_manager() -> MapManager:
	return map_manager

# ===== 导航器 =====

# 获取导航器
func get_navigator() -> MapNavigator:
	if map_manager and map_manager.has_method("get_navigator"):
		return map_manager.get_navigator()
	return null

# ===== 工具方法 =====

func is_game_paused() -> bool:
	return current_game_status == GameStatus.PAUSE

func is_game_over() -> bool:
	return current_game_status == GameStatus.OVER

func reset() -> void:
	player_bases.clear()
	enemy_bases.clear()
	current_game_status = GameStatus.START
	is_game_running = false

# ===== 游戏状态访问 =====

func get_game_state() -> GameState:
	return game_state

# ===== 游戏循环管理方法 =====

## 开始新战役
func start_new_campaign() -> void:
	print("GameManager: 开始新战役")
	# 每次战役包含三个连续全局关卡；失败时保留当前战役组以便重试。
	current_stage = get_campaign_start_stage(GameState.campaign_index)
	current_wave = 1
	combat_state = CombatState.WAVE_PREPARE
	_campaign_finalized = false  # 重置结算防重入标志，允许新战役正常结算
	campaign_started = false  # 新战役尚未进入战斗，构筑循环允许返回 Meta
	GameLog.info("campaign", "战役开始 stage=%d campaign=%d" % [current_stage, GameState.campaign_index + 1])
	
	# 重置战役内资源（金币、模组等）
	GameState.reset_campaign_resources()
	GameState.refill_equipment_cards()
	# 重置战役统计（击杀/时长/获得记录）
	GameState.reset_campaign_stats()
	
	# 从配置读取并给予初始资源
	var initial_gold = GameState.get_initial_campaign_gold()
	var initial_modules = ConfigLoader.initial_resources_config.get("initial_modules", 0)
	EconomySystem.add_resource("gold", initial_gold)
	if initial_modules > 0:
		EconomySystem.add_resource("module", initial_modules)
	
	# 直接进入第一关的构筑循环
	transition_to_loop(GameLoop.BUILD)

## 切换游戏循环
func transition_to_loop(loop: GameLoop) -> void:
	print("GameManager: 切换游戏循环到 ", _get_loop_name(loop))
	# 防重入：已在目标循环时不重复执行场景切换（避免结算界面被重复加载/闪走）
	if current_loop == loop:
		return
	# 离开战斗循环时，保存坦克/基地耐久（供构筑循环维修与下次战斗恢复）
	if current_loop == GameLoop.COMBAT and loop != GameLoop.COMBAT:
		_store_unit_hp()
	current_loop = loop

	# 根据循环类型执行相应的初始化
	match loop:
		GameLoop.WELCOME:
			_on_enter_welcome()
		GameLoop.META:
			_on_enter_meta()
		GameLoop.BUILD:
			_on_enter_build()
		GameLoop.COMBAT:
			_on_enter_combat()
		GameLoop.SUMMARY:
			_on_enter_summary()

	# 背景音乐只在战场播放：离开战斗循环（商店/构筑/结算/主菜单）即暂停，
	# 回到战斗循环恢复（保留播放进度，play_music 的防重启逻辑与之兼容）
	if AudioManager:
		AudioManager.set_music_paused(loop != GameLoop.COMBAT)


## 从存档继续游戏（由主菜单"继续游戏"调用；SaveSystem.load_game 已先行）
## 存档下一关 == 当前战役组首关 → Meta 循环（未通过本战役第一关）；
## 否则 → 构筑循环，重开该关（通过了第一关或第二关）
func continue_game_from_save() -> void:
	var next_stage: int = SaveSystem.get_saved_next_stage()
	_campaign_finalized = false
	GameState.reset_campaign_stats()
	if next_stage <= 0 or next_stage == get_campaign_start_stage(GameState.campaign_index):
		# 无进行中的战役 / 未通过本战役第一关 → 指挥部
		campaign_started = false
		current_stage = maxi(next_stage, get_campaign_start_stage(GameState.campaign_index))
		transition_to_loop(GameLoop.META)
	else:
		# 战役进行中（已通过第一关或第二关）→ 基地，重开本关
		campaign_started = true
		current_stage = next_stage
		current_wave = 1
		combat_state = CombatState.WAVE_PREPARE
		transition_to_loop(GameLoop.BUILD)
	print("GameManager: 从存档继续（下一关 %d，战役组 %d）" % [next_stage, GameState.campaign_index])

## 进入下一关卡
func advance_to_next_stage() -> void:
	# 第 3/6/…/30 关完成后结束本次三关战役。
	if is_campaign_final_stage(current_stage):
		print("GameManager: 已完成所有关卡，触发战役胜利")
		trigger_victory()
		return

	var was_campaign_first_stage: bool = current_stage == get_campaign_start_stage(GameState.campaign_index)
	current_stage += 1
	current_wave = 1
	combat_state = CombatState.WAVE_PREPARE
	# 道具每关结束清空，不跨关保留（武器弹药走 GameState.weapon_ammo 跨关保留）
	GameState.item_slots.clear()

	print("GameManager: 进入关卡 ", current_stage)
	stage_changed.emit(current_stage)

	# 一关存档一次（通过本关 → 记录下一关进度；新游戏通过第一关时正式落盘覆盖旧档）
	if SaveSystem:
		SaveSystem.on_stage_passed(current_stage, was_campaign_first_stage)

	# 进入构筑循环准备新关卡
	transition_to_loop(GameLoop.BUILD)


func get_campaign_start_stage(campaign_index: int) -> int:
	return clampi(campaign_index * LEVELS_PER_CAMPAIGN + 1, 1, TOTAL_LEVELS)


func is_campaign_final_stage(stage: int) -> bool:
	return stage >= ConfigLoader.max_stages or stage % LEVELS_PER_CAMPAIGN == 0

## 进入下一波次
func advance_to_next_wave() -> void:
	# 退出游戏时不再推进波次
	if is_quitting or not is_inside_tree():
		return
	if current_wave >= ConfigLoader.max_waves_per_stage:
		print("GameManager: 关卡 ", current_stage, " 完成")
		combat_state = CombatState.STAGE_COMPLETE
		# 关卡通关后：非最终关 → 先捡金币（掉落金币/模组）再进下一关；最终关 → 直接胜利结算
		if current_stage < ConfigLoader.max_stages:
			_start_stage_loot_gather_phase()
		else:
			advance_to_next_stage()
		return
	
	# 捡金币阶段：先给玩家 loot_gather_interval 秒自由移动捡取掉落金币，
	# 结束后才弹波间商店（同关内波次之间）
	_start_loot_gather_phase()


## 关卡通关后的捡金币阶段（不弹商店，捡完后进下一关构筑循环）
func _start_stage_loot_gather_phase() -> void:
	# 退出游戏时节点已脱离 SceneTree，不能再创建计时器
	var tree := get_tree_safe()
	if tree == null:
		return
	var duration: float = ConfigLoader.loot_gather_interval
	print("GameManager: 关卡通关，捡金币阶段 %.1f 秒" % duration)
	loot_gather_started.emit(duration)
	await tree.create_timer(duration).timeout
	# 阶段结束后进入下一关（若期间未触发其他流程；已离开战斗循环如切到结算界面则不继续）
	if combat_state == CombatState.STAGE_COMPLETE and current_loop == GameLoop.COMBAT and is_inside_tree() and is_instance_valid(tree.current_scene):
		advance_to_next_stage()


## 启动捡金币阶段（不暂停游戏，坦克可自由移动）
func _start_loot_gather_phase() -> void:
	# 退出游戏时节点已脱离 SceneTree，不能再创建计时器
	var tree := get_tree_safe()
	if tree == null:
		return
	combat_state = CombatState.WAVE_COMPLETE
	var duration: float = ConfigLoader.loot_gather_interval
	print("GameManager: 捡金币阶段 %.1f 秒" % duration)
	loot_gather_started.emit(duration)
	# 用单次计时器在阶段结束后弹商店
	await tree.create_timer(duration).timeout
	# 阶段结束后如果仍在战斗场景且未进入新波次，弹商店
	# （已离开战斗循环如切到结算界面则不弹，防止从结算界面自动跳回战斗）
	if combat_state == CombatState.WAVE_COMPLETE and current_loop == GameLoop.COMBAT and is_inside_tree() and is_instance_valid(tree.current_scene):
		_open_wave_shop()


## 打开波间商店（由捡金币阶段结束后调用）
func _open_wave_shop() -> void:
	combat_state = CombatState.WAVE_COMPLETE
	var shop_node = get_tree().current_scene.get_node_or_null("WaveShop")
	if shop_node == null:
		# 商店节点缺失时直接进入下一波（容错）
		_proceed_after_shop()
		return
	shop_node.open(current_stage, current_wave)


## 商店关闭后继续波次流程（由 WaveShop.close 回调）
func on_shop_closed() -> void:
	current_wave += 1
	combat_state = CombatState.WAVE_PREPARE
	
	print("GameManager: 进入波次 ", current_wave)
	wave_changed.emit(current_wave)
	
	# 启动波次间隔计时器，计时结束后 WaveManager 自动开始新波次
	WaveManager.start_interval_timer()


## 商店缺失时的降级路径：直接进入下一波
func _proceed_after_shop() -> void:
	current_wave += 1
	combat_state = CombatState.WAVE_PREPARE
	print("GameManager: 波间商店不可用，直接进入波次 ", current_wave)
	wave_changed.emit(current_wave)
	WaveManager.start_interval_timer()

## 触发战役胜利
func trigger_victory() -> void:
	print("GameManager: 战役胜利！")
	var completed_campaign := GameState.campaign_index + 1
	GameLog.info("campaign", "战役胜利 campaign=%d stage=%d" % [completed_campaign, current_stage])
	# 每次战役固定完成 3 个全局关卡，避免奖励随全局关卡编号膨胀。
	var reward = LEVELS_PER_CAMPAIGN
	EconomySystem.add_resource("black_box", reward)
	GameState.stats_black_boxes_earned += reward
	# 发放关卡蓝图奖励（稀有度随关卡提升，进入蓝图库）
	if DropSystem:
		var bp_rewards: Array = DropSystem.generate_blueprint_rewards()
		for bp in bp_rewards:
			if is_instance_valid(bp) and get_tree().current_scene and get_tree().current_scene.has_method("show_blueprint_toast"):
				get_tree().current_scene.show_blueprint_toast(bp)
	# 生涯胜利计数
	GameState.career_victories += 1
	GameState.award_equipment_card_capacity(completed_campaign)
	# 胜利后进入下一组三关；完成第 30 关后保留最终战役组循环挑战。
	if completed_campaign >= TOTAL_CAMPAIGNS:
		GameState.cycle_count += 1
	GameState.campaign_index = mini(GameState.campaign_index + 1, TOTAL_CAMPAIGNS - 1)
	# 生成统计快照 → 清理战役内资产 → 存档 → 进入结算
	_finalize_campaign(true, "")

## @deprecated 别名：仅转发 trigger_defeat()
func trigger_defeat_new(reason: String = "未知原因") -> void:
	trigger_defeat(reason)

## 战役结算收尾（胜利/失败共用）：生成统计快照、清理战役内资产、保存存档、发信号并切到结算界面
func _finalize_campaign(victory: bool, reason: String) -> void:
	# 防重入：坦克与基地同时被摧毁等会重复触发结算，避免结算界面被重复加载/闪走
	if _campaign_finalized:
		GameLog.warn("campaign", "结算重复触发已忽略 victory=%s" % str(victory))
		return
	_campaign_finalized = true
	# 1. 生成统计快照（在战斗场景释放前读取单位耐久）
	GameState.stats_snapshot = _build_campaign_stats(victory, reason)
	# 2. 清理战役内资产（保留黑匣/蓝图/升级）
	GameState.reset_campaign_resources()
	# 3. 存档策略（新存档系统）：
	#    胜利 → 战役内资产已清零，进度 = 下一战役组首关（继续游戏进 Meta）；
	#    失败 → 进度 = 当前战役组首关：战役失败整场重打，游戏内重试与退出后
	#           "继续游戏"行为一致（campaign_index 未推进，同一表达式即本组首关）；
	#           战役内经济已在上方重置，与 start_new_campaign 的初始发放一致。
	#    战役未结束就退出游戏 → 不经过此处，保留最后检查点（继续游戏续打未完成关）。
	#    新游戏保护期内失败 → save_game 内部直接跳过，磁盘旧档完好。
	if SaveSystem:
		SaveSystem.save_game(get_campaign_start_stage(GameState.campaign_index))
	# 3.5 结算音效
	if AudioManager:
		AudioManager.play_sfx("victory" if victory else "defeat")
	# 4. 切换到结算场景
	transition_to_loop(GameLoop.SUMMARY)
	# 5. 场景切换后发出结果信号（延迟到新场景 _ready 之后，避免信号早于连接而丢失；
	#    兜底：campaign_summary._ready 也会直接读取 stats_snapshot 显示）
	if victory:
		call_deferred("_emit_campaign_victory")
	else:
		call_deferred("_emit_campaign_defeat", reason)


func _emit_campaign_victory() -> void:
	campaign_victory.emit()


func _emit_campaign_defeat(reason: String) -> void:
	campaign_defeat.emit(reason)

## 构建战役统计快照（SUMMARY 界面数据来源）
func _build_campaign_stats(victory: bool, reason: String) -> Dictionary:
	var tanks_killed: int = 0
	var tanks_by_level: Dictionary = {}
	for lv in GameState.stats_tanks_killed:
		tanks_by_level[lv] = GameState.stats_tanks_killed[lv]
		tanks_killed += int(GameState.stats_tanks_killed[lv])
	var bases_killed: int = 0
	var bases_by_level: Dictionary = {}
	for lv in GameState.stats_bases_killed:
		bases_by_level[lv] = GameState.stats_bases_killed[lv]
		bases_killed += int(GameState.stats_bases_killed[lv])
	# 耐久损耗比（基于离开战斗时保存的剩余/最大耐久）
	var tank_hp_loss: float = 0.0
	if GameState.tank_max_hp > 0:
		var tank_left: float = float(GameState.tank_stored_hp) if GameState.tank_stored_hp >= 0 else float(GameState.tank_max_hp)
		tank_hp_loss = clampf((1.0 - tank_left / GameState.tank_max_hp) * 100.0, 0.0, 100.0)
	var base_hp_loss: float = 0.0
	if GameState.base_max_hp > 0:
		var base_left: float = float(GameState.base_stored_hp) if GameState.base_stored_hp >= 0 else float(GameState.base_max_hp)
		base_hp_loss = clampf((1.0 - base_left / GameState.base_max_hp) * 100.0, 0.0, 100.0)
	return {
		"victory": victory,
		"reason": reason,
		"stage": current_stage,
		"wave": current_wave,
		"tanks_killed": tanks_killed,
		"tank_kills_by_level": tanks_by_level,
		"bases_killed": bases_killed,
		"base_kills_by_level": bases_by_level,
		"combat_seconds": GameState.stats_combat_seconds,
		"tank_hp_loss_pct": tank_hp_loss,
		"base_hp_loss_pct": base_hp_loss,
		"black_boxes_earned": GameState.stats_black_boxes_earned,
		"blueprints_earned": GameState.stats_blueprints_earned.duplicate(),
		"equipment_card_capacity_gained": GameState.stats_equipment_card_capacity_gained,
		"next_equipment_card_capacity": GameState.get_equipment_card_capacity(),
		"equipment_cards_remaining": GameState.equipment_cards_remaining,
		"equipment_card_redeemed_types": GameState.equipment_card_redeemed_types.duplicate(),
		"gold_crafted_count": GameState.stats_gold_crafted_count,
		"gold_remaining": GameState.gold,
		# 评级用战役级累计（损耗=各关实际掉血之和，分母=各关最大耐久之和，回复不计）
		"tank_dmg_taken": GameState.stats_tank_dmg_taken,
		"tank_hp_total": GameState.stats_tank_hp_total,
		"base_dmg_taken": GameState.stats_base_dmg_taken,
		"base_hp_total": GameState.stats_base_hp_total,
		"enemy_tanks_planned": GameState.stats_enemy_tanks_planned,
	}

# ===== 场景路径常量 =====
const SCENE_WELCOME  = "res://scenes/game_welcome.tscn"
const SCENE_META     = "res://scenes/meta_loop.tscn"
const SCENE_BUILD    = "res://scenes/build_loop.tscn"
const SCENE_COMBAT   = "res://scenes/game_ui.tscn"
const SCENE_SUMMARY  = "res://scenes/campaign_summary.tscn"

# ===== 循环进入回调 =====

func _on_enter_welcome() -> void:
	print("GameManager: 进入欢迎界面")
	# 返回主菜单一律恢复运行态：战斗暂停（波间商店/暂停式指引）不得带进主菜单，
	# 否则主菜单按钮会被冻结
	get_tree().paused = false
	# 未点「知道了」就离开 → 收起卡片且不计完成，下次遇到继续教
	if Tutorial:
		Tutorial.dismiss_without_completing()
	get_tree().change_scene_to_file(SCENE_WELCOME)

func _on_enter_meta() -> void:
	print("GameManager: 进入 Meta 循环")
	get_tree().change_scene_to_file(SCENE_META)

func _on_enter_build() -> void:
	print("GameManager: 进入构筑循环 - 关卡 ", current_stage)
	get_tree().change_scene_to_file(SCENE_BUILD)

func _on_enter_combat() -> void:
	campaign_started = true  # 战役正式开始，此后构筑循环不再显示"返回 Meta"
	AudioManager.play_music("battle_music")  # 战斗循环低音 BGM（循环中重复进入不重启）
	print("GameManager: 进入战斗循环 - 关卡 ", current_stage, " 波次 ", current_wave)
	# 进入战役（点击"进入战斗"）即开始存档：记录本关进度与当前战役内经济
	if SaveSystem:
		SaveSystem.save_game(current_stage)
	print("GameManager: 进入战斗前 equipped 数量=%d" % GameState.equipped.size())
	# 重置战斗相关状态
	reset()
	# 连接波次完成信号
	if not WaveManager.wave_completed.is_connected(_on_wave_completed):
		WaveManager.wave_completed.connect(_on_wave_completed)
	# 连接地图加载完成信号
	if not WaveManager.map_loaded.is_connected(_on_map_loaded):
		WaveManager.map_loaded.connect(_on_map_loaded)
	
	# 连接场景切换完成信号（一次性连接）
	if not get_tree().node_added.is_connected(_on_combat_scene_loaded):
		get_tree().node_added.connect(_on_combat_scene_loaded, CONNECT_ONE_SHOT)
	
	get_tree().change_scene_to_file(SCENE_COMBAT)

## 战斗场景加载完成回调（通过 node_added 信号触发）
func _on_combat_scene_loaded(node: Node) -> void:
	# 检查是否是战斗场景的根节点
	if node.name == "GameUI" or node.name == "GameView":
		print("GameManager: 战斗场景已加载，启动波次")
		combat_state = CombatState.WAVE_ACTIVE
		# 等一帧：确保场景树内所有节点 _ready 完成（含 map_manager 加载地图数据），
		# 避免 start_wave 时地图 base_enemy 配置尚未就绪导致敌方基地不生成
		await get_tree().process_frame
		# 启动波次（生成敌方基地，完成后会发出 map_loaded 信号）
		WaveManager.start_wave(current_stage, current_wave)

## 地图加载完成回调（通过信号触发）
func _on_map_loaded() -> void:
	# 退出游戏时不再启动战斗
	if is_quitting or not is_inside_tree():
		return
	print("GameManager: 收到地图加载完成信号，当前玩家基地数量: ", player_bases.size())
	print("GameManager: 地图加载时 equipped 数量=%d" % GameState.equipped.size())
	# 让所有玩家基地重新应用装备属性（确保在场景完全加载后生效）
	for base in player_bases:
		if is_instance_valid(base) and base.has_method("_apply_all_equipped"):
			base._apply_all_equipped()
	# 让所有玩家坦克重新应用装备属性
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if is_instance_valid(tank) and tank.has_method("_apply_all_equipped"):
			tank._apply_all_equipped()
	# 启动游戏（触发玩家坦克工厂开始生产坦克）
	start_game()


## 波次完成回调
func _on_wave_completed(_stage: int, _wave: int) -> void:
	# 退出游戏时场景树正在销毁
	if is_quitting or not is_inside_tree():
		return
	combat_state = CombatState.WAVE_COMPLETE
	advance_to_next_wave()

func _on_enter_summary() -> void:
	print("GameManager: 进入战役总结")
	# 停止波次计时器，防止遗留的波次间隔在结算界面触发新波次/切场景
	if WaveManager:
		WaveManager.stop_interval_timer()
	get_tree().change_scene_to_file(SCENE_SUMMARY)

# ===== 辅助方法 =====

func _get_loop_name(loop: GameLoop) -> String:
	match loop:
		GameLoop.WELCOME: return "欢迎界面"
		GameLoop.META: return "Meta循环"
		GameLoop.BUILD: return "构筑循环"
		GameLoop.COMBAT: return "战斗循环"
		GameLoop.SUMMARY: return "战役总结"
	return "未知"
