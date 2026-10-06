extends Node

## SaveSystem 单例
## 管理游戏数据的持久化存储。
## 存档分两层：
##   1. settings.json —— 音量/全屏等偏好设置（随时落盘，与游戏进度无关）
##   2. save_game.json —— 游戏进度存档（版本 v6）：
##      - 档案数据：黑匣、升级、蓝图、战术背包、生涯统计
##      - 战役进度：下一待玩关卡 + 战役内经济（金币/模组/库存/已装配/耐久/商店强化）
## 存档时机：点击"进入战役"进入战斗时、每通过一关、获得黑匣/蓝图实时、
##           战役胜利结算、从设置窗口返回主菜单。
## 新游戏保护：有旧档时点"新游戏"→ 未通过新战役第一关前不落盘（旧档完好）。

const SAVE_PATH = "user://save_game.json"
const SETTINGS_PATH = "user://settings.json"

## 装备类型字符串 → Equipment.Type 枚举（对齐 config/equipment/equipment_templates.json 的 type 字段）
const TYPE_STR_TO_ENUM: Dictionary = {
	"engine": Equipment.Type.ENGINE,
	"bearing": Equipment.Type.BEARING,
	"main_gun": Equipment.Type.MAIN_GUN,
	"shell": Equipment.Type.SHELL,
	"armor": Equipment.Type.ARMOR,
	"shield": Equipment.Type.SHIELD,
	"diving": Equipment.Type.DIVING,
	"stealth": Equipment.Type.STEALTH,
	"radar": Equipment.Type.RADAR,
	"emp": Equipment.Type.EMP,
	"barrier": Equipment.Type.BARRIER,
	"repair_machine": Equipment.Type.REPAIR_MACHINE,
	"energy_station": Equipment.Type.ENERGY_STATION
}

# ===== 状态 =====
## 读档/初始化进行中（抑制 add_blueprint/add_resource 触发的实时存档）
var _loading: bool = false
## 新游戏保护：未通过新战役第一关前不覆盖磁盘旧存档
var _provisional_new_game: bool = false
## 供自动测试/数值模拟禁用持久化；默认开启，正常游戏行为不受影响。
var _runtime_persistence_enabled: bool = true
## 存档中的"下一待玩关卡"（读档时缓存；0 = 无进行中的战役）
var _saved_next_stage: int = 0
## 上次记录的窗口全屏状态（轮询检测系统级窗口模式变化，如 macOS 原生全屏按钮）
var _last_fullscreen: bool = false
## 窗口模式轮询计时器
var _window_watch_accum: float = 0.0
const WINDOW_WATCH_INTERVAL: float = 1.0
## 真全屏不可用时的回退态：无边框最大化（视觉等同全屏，见 _apply_fullscreen_fallback）
var _fullscreen_fallback_used: bool = false


## 稀有度整数 → Equipment.Rarity 枚举（1-5 与枚举值一致）
func _rarity_from_int(r: int) -> Equipment.Rarity:
	match r:
		2: return Equipment.Rarity.BLUE
		3: return Equipment.Rarity.PURPLE
		4: return Equipment.Rarity.PINK
		5: return Equipment.Rarity.GOLD
		_: return Equipment.Rarity.WHITE

func _ready() -> void:
	# ConfigLoader 在 AutoLoad 顺序中排在 SaveSystem 之前，此处可直接调用
	if has_save():
		var success = load_game()
		if not success:
			GameLog.error("save", "存档加载失败，回退初始数据")
			_initialize_default_data()
	else:
		# 首次启动，初始化默认数据（不落盘：进入战役前不产生存档）
		_initialize_default_data()
	_load_settings()
	# 兜底持久化：macOS 原生全屏按钮等系统级窗口模式变化不经过设置面板按钮，
	# 用轻量轮询检测模式变化后自动写入 settings.json（常驻运行，暂停中也不漏）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_fullscreen = is_fullscreen()


## 读档/初始化进行中（GameState.add_blueprint 等实时存档钩子用）
func is_loading() -> bool:
	return _loading


## 新游戏是否处于保护期（未通过第一关、不覆盖旧档）
func is_provisional() -> bool:
	return _provisional_new_game


## 禁止当前运行进程修改玩家进度或偏好，用于自动测试与数值模拟。
func set_runtime_persistence_enabled(enabled: bool) -> void:
	_runtime_persistence_enabled = enabled


func is_runtime_persistence_enabled() -> bool:
	return _runtime_persistence_enabled


# ===== 游戏存档（进度） =====

## 保存游戏数据
## @param next_stage: 显式指定"下一待玩关卡"（-1 = 按当前游戏循环自动推断）
func save_game(next_stage: int = -1) -> void:
	if not _runtime_persistence_enabled or _provisional_new_game:
		return  # 新游戏未通过第一关：保护旧存档，不落盘
	_write_save(next_stage)


## 实时存档请求（获得黑匣/蓝图时调用；加载中或保护期静默跳过）
func request_save() -> void:
	if not _runtime_persistence_enabled or _loading or _provisional_new_game:
		return
	save_game.call_deferred()


## 通过一关后由 GameManager 调用；新游戏通过战役第一关时正式落盘覆盖旧档
func on_stage_passed(next_stage: int, is_campaign_first_stage: bool) -> void:
	if not _runtime_persistence_enabled:
		return
	if _provisional_new_game:
		if is_campaign_first_stage:
			_provisional_new_game = false
			_write_save(next_stage)
		return
	_write_save(next_stage)


## 存档中的"下一待玩关卡"（0 = 无进行中的战役，继续游戏进 Meta）
func get_saved_next_stage() -> int:
	return _saved_next_stage


## 开始新游戏（全新档案）。有旧档时进入保护期：通过新战役第一关前不落盘。
## @param provisional: 是否保护旧存档（主菜单存在旧档时为 true）
func start_new_game(provisional: bool) -> void:
	_provisional_new_game = provisional
	_saved_next_stage = 0
	_initialize_default_data()


func _write_save(next_stage: int) -> void:
	if not _runtime_persistence_enabled:
		return
	var data = _serialize(next_stage)
	var json_text = JSON.stringify(data, "\t")

	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		GameLog.exception("save", "存档写入失败", {"path": SAVE_PATH, "err": FileAccess.get_open_error()})
		return

	file.store_string(json_text)
	file.close()
	print("SaveSystem: 游戏已保存（下一关 %d）" % _saved_next_stage)
	GameLog.info("save", "存档完成 next_stage=%d" % next_stage)


## 加载游戏数据
## @return: 是否成功加载
func load_game() -> bool:
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		GameLog.warn("save", "存档文件不存在 path=%s" % SAVE_PATH)
		return false

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		GameLog.exception("save", "存档解析失败", {
			"path": SAVE_PATH, "line": json.get_error_line(), "err": json.get_error_message()})
		return false

	_loading = true
	_deserialize(json.data)
	_loading = false
	_provisional_new_game = false  # 显式读档后即以磁盘档为准，退出新游戏保护期
	print("SaveSystem: 游戏已加载（下一关 %d）" % _saved_next_stage)
	GameLog.info("save", "读档完成 next_stage=%d" % _saved_next_stage)
	return true


## 检查是否存在存档
func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


## 删除存档
func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(SAVE_PATH)
		print("SaveSystem: 存档已删除")


## 按当前游戏循环推断"下一待玩关卡"：
## 战斗/构筑循环 = 当前关卡（未通过则下次重开本关）；其余 = 0（无进行中战役）
func _compute_next_stage() -> int:
	if GM == null:
		return 0
	match GM.current_loop:
		GameManager.GameLoop.COMBAT, GameManager.GameLoop.BUILD:
			return GM.current_stage
		_:
			return 0


## 序列化游戏状态为字典
func _serialize(next_stage: int) -> Dictionary:
	if next_stage < 0:
		next_stage = _compute_next_stage()
	_saved_next_stage = next_stage

	var data = {
		"version": 6,
		"black_boxes": GameState.black_boxes,
		"equipment_card_capacity": GameState.get_equipment_card_capacity(),
		"upgrades": GameState.upgrades.duplicate(),
		"tactical_backpack_capacity": GameState.tactical_backpack_capacity,
		"tutorial_done": GameState.tutorial_done.duplicate(),
		"career": {
			"total_kills": GameState.career_total_kills,
			"victories": GameState.career_victories,
			"campaign_index": GameState.campaign_index,
			"cycle_count": GameState.cycle_count
		},
		"blueprints": [],
		"tactical_backpack": [],
		"campaign_progress": _serialize_campaign_progress(),
	}

	# 序列化蓝图列表
	for bp in GameState.blueprints:
		data["blueprints"].append(_serialize_blueprint(bp))

	# v2 起直接存储九种可选装备的类型 ID
	for equipment_type in GameState.tactical_backpack:
		data["tactical_backpack"].append(equipment_type)

	return data


## 战役内进度与经济（继续游戏时恢复到"重开本关"的构筑循环状态）
func _serialize_campaign_progress() -> Dictionary:
	var equipped_data := {}
	for slot in GameState.equipped:
		var eq: Equipment = GameState.equipped[slot]
		if eq != null:
			equipped_data[str(int(slot))] = _serialize_equipment(eq)
	var inventory_data := []
	for eq in GameState.inventory:
		inventory_data.append(_serialize_equipment(eq))
	return {
		"next_stage": _saved_next_stage,
		"gold": GameState.gold,
		"modules": GameState.modules,
		"inventory": inventory_data,
		"equipped": equipped_data,
		"weapon_ammo": GameState.weapon_ammo.duplicate(),
		"tank_stored_hp": GameState.tank_stored_hp,
		"base_stored_hp": GameState.base_stored_hp,
		"shop_damage_multiplier": GameState.shop_damage_multiplier,
		"shop_fire_rate_multiplier": GameState.shop_fire_rate_multiplier,
		"shop_move_speed_multiplier": GameState.shop_move_speed_multiplier,
		"shop_shield_energy": GameState.shop_shield_energy,
		"shop_repair_count": GameState.shop_repair_count,
		"shop_shield_bought": GameState.shop_shield_bought,
		"equipment_cards_remaining": GameState.equipment_cards_remaining,
		"equipment_card_redeemed_types": GameState.equipment_card_redeemed_types.duplicate(),
	}


## 反序列化字典到游戏状态
func _deserialize(data: Dictionary) -> void:
	# 版本检查
	var version := int(data.get("version", 1))
	if version < 1 or version > 6:
		GameLog.warn("save", "存档版本不匹配（支持 1-6，实际 %d），按兼容模式读取" % version)

	# 恢复黑匣
	GameState.black_boxes = data.get("black_boxes", 0)

	# 恢复升级等级
	GameState._initialize_upgrades()
	var saved_upgrades = data.get("upgrades", {})
	for upgrade_id in saved_upgrades:
		if GameState.upgrades.has(upgrade_id):
			GameState.upgrades[upgrade_id] = int(saved_upgrades[upgrade_id])

	# 恢复新手指引进度（随存档走）；旧存档无此字段时保留启动时从
	# settings.json 迁移来的旧值，避免老玩家指引重播
	var saved_tutorial_done = data.get("tutorial_done", GameState.tutorial_done)
	if saved_tutorial_done is Dictionary:
		GameState.tutorial_done = saved_tutorial_done

	# 恢复生涯统计（旧存档无此字段时回退默认值）
	var career = data.get("career", {})
	GameState.career_total_kills = int(career.get("total_kills", 0))
	GameState.career_victories = int(career.get("victories", 0))
	GameState.campaign_index = clampi(int(career.get("campaign_index", 0)), 0, 9)
	GameState.cycle_count = maxi(0, int(career.get("cycle_count", 0)))
	if version >= 5:
		GameState.equipment_card_capacity = int(data.get("equipment_card_capacity", 2))
	else:
		GameState.derive_equipment_card_capacity_from_campaign()

	# 恢复音量设置（旧存档；settings.json 优先并随后覆盖）
	var settings = data.get("settings", {})
	GameState.music_volume = float(settings.get("music_volume", 1.0))
	GameState.sfx_volume = float(settings.get("sfx_volume", 1.0))

	# v1 的同类型多稀有度蓝图会自动折叠为最高研究等级。
	GameState.blueprints.clear()
	var blueprint_data_list = data.get("blueprints", [])
	var legacy_id_to_type: Dictionary = {}
	for bp_data in blueprint_data_list:
		var bp = _deserialize_blueprint(bp_data)
		if bp:
			legacy_id_to_type[bp.id] = int(bp.equipment_type)
			GameState.add_blueprint(bp)
	GameState.ensure_core_research()

	# v1 保存蓝图 ID，迁移时提取类型；v2 直接保存类型 ID。
	GameState.tactical_backpack.clear()
	var saved_backpack: Array = data.get("tactical_backpack", [])
	for entry in saved_backpack:
		var equipment_type := -1
		if version >= 2 and (entry is int or entry is float):
			equipment_type = int(entry)
		elif legacy_id_to_type.has(str(entry)):
			equipment_type = int(legacy_id_to_type[str(entry)])
		if GameState.OPTIONAL_EQUIPMENT_TYPES.has(equipment_type) and not GameState.tactical_backpack.has(equipment_type):
			GameState.tactical_backpack.append(equipment_type)

	# 按新语义重算容量（初始 2 个可选类型槽）并裁剪溢出项。
	GameState.recalculate_upgrade_bonuses()

	# v4+：恢复战役进度与战役内经济
	_deserialize_campaign_progress(data.get("campaign_progress", {}))
	if version < 6:
		save_game()


## 恢复战役进度：无进行中的战役时清空战役内经济
func _deserialize_campaign_progress(prog: Dictionary) -> void:
	_saved_next_stage = int(prog.get("next_stage", 0))
	GameState.tank_stored_hp = int(prog.get("tank_stored_hp", -1))
	GameState.base_stored_hp = int(prog.get("base_stored_hp", -1))
	GameState.shop_damage_multiplier = float(prog.get("shop_damage_multiplier", 1.0))
	GameState.shop_fire_rate_multiplier = float(prog.get("shop_fire_rate_multiplier", 1.0))
	GameState.shop_move_speed_multiplier = float(prog.get("shop_move_speed_multiplier", 1.0))
	GameState.shop_shield_energy = float(prog.get("shop_shield_energy", 0.0))
	GameState.shop_repair_count = int(prog.get("shop_repair_count", 0))
	GameState.shop_shield_bought = int(prog.get("shop_shield_bought", 0))

	if _saved_next_stage <= 0:
		# 无进行中的战役：战役内经济清零
		GameState.gold = 0
		GameState.modules = 0
		GameState.inventory.clear()
		GameState.equipped.clear()
		GameState.item_slots.clear()
		GameState.weapon_ammo.clear()
		GameState.clear_equipment_cards()
		return

	GameState.gold = int(prog.get("gold", 0))
	GameState.modules = int(prog.get("modules", 0))
	if int(prog.get("equipment_cards_remaining", -1)) >= 0:
		GameState.equipment_cards_remaining = int(prog.get("equipment_cards_remaining", 0))
		GameState.equipment_card_redeemed_types.clear()
		for equipment_type in prog.get("equipment_card_redeemed_types", []):
			GameState.equipment_card_redeemed_types.append(int(equipment_type))
	else:
		# v4 及更早的进行中战役在升级后获得一次完整补给。
		GameState.refill_equipment_cards()
	GameState.inventory.clear()
	for eq_data in prog.get("inventory", []):
		var eq = _deserialize_equipment(eq_data)
		if eq != null:
			GameState.inventory.append(eq)
	GameState.equipped.clear()
	var equipped_data: Dictionary = prog.get("equipped", {})
	for slot_str in equipped_data:
		var eq = _deserialize_equipment(equipped_data[slot_str])
		if eq != null:
			GameState.equipped[int(slot_str)] = eq
	GameState.item_slots.clear()
	# 武器弹药：战役内跨关保留（旧存档无此字段时为空，战斗中会落到默认值）
	GameState.weapon_ammo.clear()
	var ammo_data: Dictionary = prog.get("weapon_ammo", {})
	for slot in ammo_data:
		GameState.weapon_ammo[int(slot)] = int(ammo_data[slot])


## 序列化单个蓝图
func _serialize_blueprint(bp: Blueprint) -> Dictionary:
	return {
		"id": bp.id,
		"equipment_type": bp.equipment_type,
		"rarity": bp.rarity,
		"base_attributes": bp.base_attributes.duplicate()
	}


## 反序列化单个蓝图
func _deserialize_blueprint(data: Dictionary) -> Blueprint:
	var bp = Blueprint.new()
	bp.id = data.get("id", "")
	bp.equipment_type = data.get("equipment_type", Equipment.Type.ENGINE)
	bp.rarity = data.get("rarity", Equipment.Rarity.WHITE)
	bp.base_attributes = data.get("base_attributes", {})
	# 如果存档里 base_attributes 为空，从 ConfigLoader 补充
	if bp.base_attributes.is_empty():
		var template = ConfigLoader.get_equipment_template(bp.equipment_type, bp.rarity)
		bp.base_attributes = template.get("attributes", {}).duplicate()
	return bp


## 序列化单个装备（战役内库存/已装配）
func _serialize_equipment(eq: Equipment) -> Dictionary:
	return {
		"id": eq.id,
		"type": int(eq.type),
		"rarity": int(eq.rarity),
		"enhancement_level": int(eq.enhancement_level),
		"origin": int(eq.origin),
		"base_attributes": eq.base_attributes.duplicate(),
	}


## 反序列化单个装备：按强化等级重算实际属性
func _deserialize_equipment(data: Dictionary) -> Equipment:
	var eq = Equipment.new()
	eq.id = data.get("id", "")
	eq.type = int(data.get("type", Equipment.Type.ENGINE))
	eq.rarity = int(data.get("rarity", Equipment.Rarity.WHITE))
	eq.enhancement_level = int(data.get("enhancement_level", 0))
	eq.origin = int(data.get("origin", Equipment.Origin.GOLD_CRAFT))
	eq.base_attributes = data.get("base_attributes", {}).duplicate()
	if eq.base_attributes.is_empty():
		var template = ConfigLoader.get_equipment_template(eq.type, eq.rarity)
		eq.base_attributes = template.get("attributes", {}).duplicate()
	# 以基础属性为底、按强化等级叠倍率（与 EquipmentSystem 强化同规则）
	eq.attributes = eq.base_attributes.duplicate()
	if eq.enhancement_level > 0:
		EquipmentSystem._apply_enhancement(eq)
	return eq


## 初始化默认数据（首次启动 / 新游戏；不落盘）
func _initialize_default_data() -> void:
	_loading = true
	print("SaveSystem: 初始化默认游戏数据")
	GameState.black_boxes = 0
	GameState.campaign_index = 0
	GameState.cycle_count = 0
	GameState.equipment_card_capacity = int(ConfigLoader.initial_resources_config.get("initial_equipment_card_capacity", 2))
	GameState.clear_equipment_cards()
	# 新游戏重玩全部新手指引：清空完成标记（开启状态下进入后会重新经历）
	GameState.tutorial_done = {}
	GameState._initialize_upgrades()
	GameState.blueprints.clear()
	GameState.tactical_backpack.clear()
	GameState.tactical_backpack_capacity = int(ConfigLoader.initial_resources_config.get("initial_backpack_capacity", 2))

	# 创建初始类型研究等级（引擎/轴承/主炮/炮弹/抢修机，均为白色）
	var initial_blueprint_cfgs: Array = ConfigLoader.initial_resources_config.get("initial_blueprints", [])
	if initial_blueprint_cfgs.is_empty():
		# 兜底默认（配置缺失时）
		initial_blueprint_cfgs = [
			{"type": "engine"}, {"type": "bearing"}, {"type": "main_gun"},
			{"type": "shell"}, {"type": "repair_machine"}
		]

	for i in range(initial_blueprint_cfgs.size()):
		var bp_cfg: Dictionary = initial_blueprint_cfgs[i]
		var type_str: String = str(bp_cfg.get("type", "engine"))
		var bp = Blueprint.new()
		bp.id = "initial_bp_%d" % i
		bp.equipment_type = TYPE_STR_TO_ENUM.get(type_str, Equipment.Type.ENGINE)
		bp.rarity = _rarity_from_int(int(bp_cfg.get("rarity", 1)))
		var template = ConfigLoader.get_equipment_template(bp.equipment_type, bp.rarity)
		bp.base_attributes = template.get("attributes", {})
		GameState.add_blueprint(bp)

	print("SaveSystem: 已创建 %d 个初始蓝图" % GameState.blueprints.size())
	GameState.ensure_core_research()
	GameState.recalculate_upgrade_bonuses()

	# 战役内状态清零（新游戏从零开始）
	GameState.reset_campaign_stats()
	_saved_next_stage = 0
	_deserialize_campaign_progress({})
	_loading = false


# ===== 偏好设置（settings.json，随时落盘） =====

## 保存偏好设置（音量/全屏/简报已读），独立于游戏进度存档
func save_settings() -> void:
	if not _runtime_persistence_enabled:
		return
	var data = {
		"music_volume": GameState.music_volume,
		"sfx_volume": GameState.sfx_volume,
		"fullscreen": is_fullscreen(),
		"story_intro_seen": GameState.story_intro_seen,
		"tutorial_enabled": GameState.tutorial_enabled,
	}
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		GameLog.exception("save", "设置写入失败", {"path": SETTINGS_PATH, "err": FileAccess.get_open_error()})
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


## 启动时加载偏好设置（覆盖存档内的旧 settings 段）
func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		GameLog.exception("save", "设置解析失败，使用默认设置", {
			"path": SETTINGS_PATH, "line": json.get_error_line(), "err": json.get_error_message()})
		file.close()
		return
	file.close()
	var data: Dictionary = json.data
	GameState.music_volume = clampf(float(data.get("music_volume", 1.0)), 0.0, 1.0)
	GameState.sfx_volume = clampf(float(data.get("sfx_volume", 1.0)), 0.0, 1.0)
	# 作战简报已读标记（旧档/无记录默认未读，首次新游戏会播放剧情）
	GameState.story_intro_seen = bool(data.get("story_intro_seen", false))
	# 新手指引开关（settings.json 全局偏好）与完成标记迁移种子：
	# 标记现已随游戏存档持久化；此处读取旧版 settings.json 中的标记仅作
	# 老玩家迁移（旧存档无 tutorial_done 字段时以该值兜底，避免指引重播）
	GameState.tutorial_enabled = bool(data.get("tutorial_enabled", true))
	var tutorial_done: Dictionary = data.get("tutorial_done", {})
	GameState.tutorial_done = tutorial_done if tutorial_done is Dictionary else {}
	# 有偏好记录时严格应用上次的窗口/全屏模式；
	# 无记录（首次启动）不强制设置，保持 Godot 默认的窗口模式
	var want_fullscreen := bool(data.get("fullscreen", false))
	set_fullscreen(want_fullscreen, false)


# ===== 窗口/全屏模式 =====

## 窗口模式实际生效后发出（设置面板据此刷新按钮文案；回退逻辑延后一帧，不能同步读取）
signal window_mode_changed(is_fullscreen: bool)

## 当前是否处于全屏（含无边框最大化的回退态）
func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		return true
	# 回退态：无边框 + 最大化
	return mode == DisplayServer.WINDOW_MODE_MAXIMIZED and DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS)


# Windows 上从 Godot 编辑器"内嵌运行"（Embedded Game View）时，DisplayServer 只支持
# 窗口模式，调用 window_set_mode(FULLSCREEN) 会被忽略并输出
# "Embedded window only supports Windowed mode."，表现为设置里点"全屏"毫无反应。
# 因此统一走 set_fullscreen()：先尝试真全屏，一帧后确认未生效则回退为无边框最大化窗口
# （视觉上等同全屏），并把该状态同样记为"全屏"，保证按钮文案与持久化一致。
## 设置全屏/窗口模式
## @param want: true 请求全屏（不支持真全屏时自动回退无边框最大化）；false 恢复窗口
## @param persist: 是否立即落盘 settings.json（设置面板点击时用 true）
func set_fullscreen(want: bool, persist: bool = true) -> void:
	if not want:
		_fullscreen_fallback_used = false
		# 已是窗口模式且无边框关闭时不重复设置：内嵌窗口对 window_set_mode 有模式限制，
		# 无谓调用只会刷错误日志（如启动时恢复窗口模式）
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED or DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS):
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_last_fullscreen = false
		if persist:
			save_settings()
		window_mode_changed.emit(false)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_confirm_fullscreen_applied(persist)


## 真全屏是否生效要等一帧（窗口模式切换由 DisplayServer 异步落地），
## 未生效才回退，避免把"还没生效"误判成"不支持"。
func _confirm_fullscreen_applied(persist: bool) -> void:
	var tree := get_tree()
	if tree != null:
		await tree.process_frame
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		_fullscreen_fallback_used = false
		_last_fullscreen = true
		if persist:
			save_settings()
		window_mode_changed.emit(true)
		return
	_apply_fullscreen_fallback(persist)


## 回退：无边框 + 最大化窗口（内嵌窗口等不支持真全屏的运行环境）
func _apply_fullscreen_fallback(persist: bool) -> void:
	_fullscreen_fallback_used = true
	print("SaveSystem: 当前运行环境不支持真全屏（如编辑器内嵌窗口），尝试回退为无边框最大化窗口")
	# 先确认最大化可用再去边框，否则会留下"无标题栏的普通窗口"（无法拖动/关闭）
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	var tree := get_tree()
	if tree != null:
		await tree.process_frame
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	else:
		print("SaveSystem: 该环境也不支持最大化窗口，保持窗口模式（设置面板将显示「全屏（不可用）」）")
	_last_fullscreen = is_fullscreen()
	if persist:
		save_settings()
	window_mode_changed.emit(true)


## 真全屏不可用、当前是无边框最大化的回退态
func is_using_fullscreen_fallback() -> bool:
	return _fullscreen_fallback_used


## 作战简报（新手指引剧情）是否已看过
func is_story_intro_seen() -> bool:
	return GameState.story_intro_seen


## 标记作战简报已读并立即落盘（首次播完剧情时调用）
func mark_story_intro_seen() -> void:
	GameState.story_intro_seen = true
	save_settings()


# ===== 新手指引（TutorialManager 使用） =====

func is_tutorial_enabled() -> bool:
	return GameState.tutorial_enabled


## 设置全局开关并立即落盘；关闭不清除完成记录，重新开启后未完成的指引下次遇到仍会弹出
func set_tutorial_enabled(enabled: bool) -> void:
	GameState.tutorial_enabled = enabled
	save_settings()


func is_tutorial_done(id: String) -> bool:
	return GameState.tutorial_done.get(id, false)


## 标记单条指引完成。不立即落盘——随游戏存档点（过关/实时存档请求）持久化；
## 新游戏开始时标记清空（重玩全部），读档时恢复存档内进度
func mark_tutorial_done(id: String) -> void:
	GameState.tutorial_done[id] = true
	request_save()


func _process(delta: float) -> void:
	# 轻量轮询：捕获系统级窗口模式变化（macOS 原生全屏按钮 / 系统手势等，
	# 它们不经过设置面板的"屏幕模式"按钮），变化后自动落盘 settings.json
	_window_watch_accum += delta
	if _window_watch_accum < WINDOW_WATCH_INTERVAL:
		return
	_window_watch_accum = 0.0
	var cur_fullscreen := is_fullscreen()
	if cur_fullscreen != _last_fullscreen:
		_last_fullscreen = cur_fullscreen
		save_settings()
