extends Node

## GameState 单例
## 管理全局游戏状态数据，包括资源、装备、升级和战役进度

## 资源数据（永久）
var black_boxes: int = 0  # 黑匣数量
var blueprints: Array[Blueprint] = []  # 类型研究记录：每种装备仅保留最高已解锁稀有度
var equipment_card_capacity: int = 2  # 每次新战役补满的永久装备卡上限

## 资源数据（战役内）
var gold: int = 0  # 金币
var modules: int = 0  # 模组
var equipment_cards_remaining: int = 0  # 本战役剩余装备卡
var equipment_card_redeemed_types: Array[int] = []  # 本战役已用装备卡兑换的类型

## 装备数据
var equipped: Dictionary = {}  # 已装配装备 (EquipmentSlot -> Equipment)
var inventory: Array[Equipment] = []  # 装备库存

## 道具数据
var item_slots: Array = []  # 道具槽位（每关结束清空，不跨关保留）

## 武器弹药（地雷/火箭；战役内跨关保留，战役结束重置；键 = TankPlayer.WeaponSlot 枚举值）
var weapon_ammo: Dictionary = {}

## 升级数据
var upgrades: Dictionary = {}  # 黑匣升级等级 (upgrade_id -> level)

## 黑匣升级带来的基础属性加成（永久，跨战役保留）
var base_tank_max_health: int = 0          # 坦克最大耐久加成（累加值，HP）
var base_tank_speed_multiplier: float = 0.0  # 坦克移动速度加成（累加值，u/s；语义为绝对增量）
var base_turret_rotation_multiplier: float = 0.0  # 炮台旋转速度加成（累加值，°/s）
var base_player_max_health: int = 0        # 基地最大耐久加成（累加值，HP）
var base_repair_speed_bonus: float = 0.0   # 基地维修速度加成（HP/s，当前未接入运行时）
var base_charge_speed_multiplier: float = 0.0  # 基地充能速度加成（能量/s，当前未接入运行时）

## 四种核心装备始终拥有制造许可，不占战术背包
const CORE_EQUIPMENT_TYPES: Array[int] = [
	Equipment.Type.ENGINE,
	Equipment.Type.BEARING,
	Equipment.Type.MAIN_GUN,
	Equipment.Type.SHELL,
]

## 战术背包仅保存九种可选装备的类型 ID
const OPTIONAL_EQUIPMENT_TYPES: Array[int] = [
	Equipment.Type.ARMOR,
	Equipment.Type.SHIELD,
	Equipment.Type.DIVING,
	Equipment.Type.STEALTH,
	Equipment.Type.RADAR,
	Equipment.Type.EMP,
	Equipment.Type.BARRIER,
	Equipment.Type.REPAIR_MACHINE,
	Equipment.Type.ENERGY_STATION,
]
var tactical_backpack: Array[int] = []
var tactical_backpack_capacity: int = 2  # 初始 2 个可选类型，黑匣扩容后最多 8 个

## 战役内临时强化（波间商店购买，跨波次保留，战役结束重置）
## 伤害倍率 / 射速倍率 / 移速倍率（如 1.3 = +30%），护盾次数
var shop_damage_multiplier: float = 1.0
var shop_fire_rate_multiplier: float = 1.0
var shop_move_speed_multiplier: float = 1.0
var shop_shield_energy: float = 0.0  # 商店护盾增加的能量护盾额度（当前+最大同时增加，本次战役有效）
var shop_repair_count: int = 0      # 战场维修已购次数（价格递增档位）
var shop_shield_bought: int = 0     # 护盾已购次数（价格递增档位）

## 战役统计（当前战役内累计，结算时生成快照供 SUMMARY 界面读取）
var stats_tanks_killed: Dictionary = {}      # 坦克击杀计数 {"normal": n, "elite": n, "boss": n}
var stats_bases_killed: Dictionary = {}      # 基地击杀计数 {"normal": n, "elite": n, "boss": n}
var stats_combat_seconds: float = 0.0        # 战斗总时长（波次进行中累计）
var stats_black_boxes_earned: int = 0        # 本战役获得黑匣（掉落 + 结算奖励）
var stats_blueprints_earned: Array = []      # 本战役获得蓝图（掉落拾取 + 结算奖励）
var stats_equipment_card_capacity_gained: int = 0  # 本次胜利提升的下次战役装备卡上限
var stats_gold_crafted_count: int = 0        # 本战役金币制造装备件数
var stats_snapshot: Dictionary = {}          # 战役结算统计快照（SUMMARY 界面读取）
var tank_max_hp: int = -1                    # 坦克最大耐久（战役末用于损耗比）
var base_max_hp: int = -1                    # 基地最大耐久（战役末用于损耗比）

## 评级用战役级累计（损耗=各关实际掉血之和，回复不计；分母=各关最大耐久之和）
var stats_tank_dmg_taken: int = 0            # 玩家坦克累计承受耐久伤害（仅实际扣血）
var stats_base_dmg_taken: int = 0            # 玩家基地累计承受耐久伤害（仅实际扣血）
var stats_tank_hp_total: int = 0             # 战役各关坦克最大耐久之和（损耗比分母）
var stats_base_hp_total: int = 0             # 战役各关基地最大耐久之和（损耗比分母）
var stats_enemy_tanks_planned: int = 0       # 战役预计总生产敌方坦克（各敌方基地工厂上限之和）
var _hp_total_counted: Dictionary = {}       # 已计入 HP 分母的关卡 {"tank": 关卡号, "base": 关卡号}

## 生涯统计（跨战役持久化，随存档保存）
var career_total_kills: int = 0              # 生涯累计击杀（坦克+基地）
var career_victories: int = 0                # 生涯战役胜利次数
var campaign_index: int = 0                  # 当前战役组（0-9），每组连续 3 个全局关卡
var cycle_count: int = 0                     # 循环挑战轮次（从 1 起算，= 通关第 10 战役次数）；敌方耐久/火力 ×(1+0.1×cycle_count)


## 记录一次敌方坦克击杀（按等级计数）
func register_tank_killed(level: String) -> void:
	stats_tanks_killed[level] = int(stats_tanks_killed.get(level, 0)) + 1
	career_total_kills += 1


## 记录一次敌方基地击杀（按等级计数）
func register_base_killed(level: String) -> void:
	stats_bases_killed[level] = int(stats_bases_killed.get(level, 0)) + 1
	career_total_kills += 1


## 重置战役统计（新战役开始时调用）
func reset_campaign_stats() -> void:
	stats_tanks_killed.clear()
	stats_bases_killed.clear()
	stats_combat_seconds = 0.0
	stats_black_boxes_earned = 0
	stats_blueprints_earned.clear()
	stats_equipment_card_capacity_gained = 0
	stats_gold_crafted_count = 0
	stats_snapshot.clear()
	tank_max_hp = -1
	base_max_hp = -1
	stats_tank_dmg_taken = 0
	stats_base_dmg_taken = 0
	stats_tank_hp_total = 0
	stats_base_hp_total = 0
	stats_enemy_tanks_planned = 0
	_hp_total_counted.clear()


## 记录玩家单位承受的实际耐久伤害（回复不计入；由 DamageCalculator 在实际扣血时调用）
## @param is_player_tank: 目标是否为玩家坦克（否则视为玩家基地）
func register_damage_taken(is_player_tank: bool, hp_damage: int) -> void:
	if hp_damage <= 0:
		return
	if is_player_tank:
		stats_tank_dmg_taken += hp_damage
	else:
		stats_base_dmg_taken += hp_damage


## 累计本关单位最大耐久到战役分母（每关只计一次，同一关重复调用不叠加）
## @param kind: "tank" 或 "base"
## @param stage: 全局关卡编号
## @param unit_max_hp: 本关该单位最大耐久
func accumulate_stage_hp_total(kind: String, stage: int, unit_max_hp: int) -> void:
	if int(_hp_total_counted.get(kind, -1)) == stage:
		return
	_hp_total_counted[kind] = stage
	if unit_max_hp <= 0:
		return
	if kind == "tank":
		stats_tank_hp_total += unit_max_hp
	else:
		stats_base_hp_total += unit_max_hp


## 累计敌方基地的预计坦克产量（基地生成时调用，maximum_spawn<=0 视为不产坦克）
func accumulate_enemy_tanks_planned(maximum_spawn: int) -> void:
	if maximum_spawn > 0:
		stats_enemy_tanks_planned += maximum_spawn


## 添加装备类型到战术背包
## @return: 是否成功添加
func add_to_backpack(equipment_type: int) -> bool:
	if tactical_backpack.size() >= tactical_backpack_capacity:
		return false
	if not OPTIONAL_EQUIPMENT_TYPES.has(equipment_type):
		return false
	if get_blueprint_for_type(equipment_type) == null:
		return false
	if tactical_backpack.has(equipment_type):
		return false
	tactical_backpack.append(equipment_type)
	return true


## 从战术背包移除装备类型
func remove_from_backpack(equipment_type: int) -> void:
	tactical_backpack.erase(equipment_type)


## 添加蓝图研究成果。同类型仅保留最高稀有度；获得更高稀有度会提升研究等级，
## 并自动包含该类型的全部较低稀有度制造权。
## @return: 是否新增类型或提升了研究等级
func add_blueprint(blueprint: Blueprint) -> bool:
	if blueprint == null:
		return false
	var existing := get_blueprint_for_type(blueprint.equipment_type)
	var gained := false
	if existing != null:
		if int(blueprint.rarity) <= int(existing.rarity):
			return false
		existing.rarity = blueprint.rarity
		existing.base_attributes = _get_blueprint_attributes(blueprint.equipment_type, blueprint.rarity, blueprint.base_attributes)
		sort_blueprints_by_type()
		gained = true
	else:
		blueprint.base_attributes = _get_blueprint_attributes(blueprint.equipment_type, blueprint.rarity, blueprint.base_attributes)
		blueprints.append(blueprint)
		sort_blueprints_by_type()
		gained = true
	# 获得蓝图实时存档（读档/初始化期间由 SaveSystem 的 _loading 守卫跳过）
	if gained and SaveSystem != null and not SaveSystem.is_loading():
		SaveSystem.request_save()
	return gained


## 按装备类型排序蓝图库，Meta 界面稳定展示 13 条研究线
func sort_blueprints_by_type() -> void:
	blueprints.sort_custom(func(a: Blueprint, b: Blueprint) -> bool:
		return int(a.equipment_type) < int(b.equipment_type))


## 兼容旧调用名
func sort_blueprints_by_rarity() -> void:
	sort_blueprints_by_type()


func _get_blueprint_attributes(equipment_type: int, rarity: int, fallback: Dictionary = {}) -> Dictionary:
	if not fallback.is_empty():
		return fallback.duplicate()
	var template := ConfigLoader.get_equipment_template(equipment_type, rarity)
	return template.get("attributes", {}).duplicate()


## 获取某类型的最高研究记录
func get_blueprint_for_type(equipment_type: int) -> Blueprint:
	for bp in blueprints:
		if int(bp.equipment_type) == equipment_type:
			return bp
	return null


## 获取某类型最高已解锁稀有度，未研究返回 0
func get_research_level(equipment_type: int) -> int:
	var bp := get_blueprint_for_type(equipment_type)
	return int(bp.rarity) if bp != null else 0


## 为制造界面创建指定稀有度的临时蓝图
func create_craft_blueprint(equipment_type: int, rarity: int) -> Blueprint:
	if rarity < int(Equipment.Rarity.WHITE) or rarity > get_research_level(equipment_type):
		return null
	if not is_type_available_in_campaign(equipment_type):
		return null
	var bp := Blueprint.new()
	bp.id = "research_%d_%d" % [equipment_type, rarity]
	bp.equipment_type = equipment_type
	bp.rarity = rarity
	bp.base_attributes = _get_blueprint_attributes(equipment_type, rarity)
	return bp


## 核心类型始终可用；可选类型必须在本局战术背包中
func is_type_available_in_campaign(equipment_type: int) -> bool:
	return CORE_EQUIPMENT_TYPES.has(equipment_type) or tactical_backpack.has(equipment_type)


func get_campaign_equipment_types() -> Array[int]:
	var result: Array[int] = CORE_EQUIPMENT_TYPES.duplicate()
	for equipment_type in tactical_backpack:
		if not result.has(equipment_type):
			result.append(equipment_type)
	return result


## 装备卡上限由永久进度决定，配置缺失时保持初始 2 张。
func get_equipment_card_capacity() -> int:
	var initial := int(ConfigLoader.initial_resources_config.get("initial_equipment_card_capacity", 2))
	var maximum := int(ConfigLoader.initial_resources_config.get("max_equipment_card_capacity", 8))
	return clampi(equipment_card_capacity, initial, maximum)


## 新战役开始时补满，并恢复每类型最多兑换一次的限制。
func refill_equipment_cards() -> void:
	equipment_cards_remaining = get_equipment_card_capacity()
	equipment_card_redeemed_types.clear()
	resource_changed.emit("equipment_card", equipment_cards_remaining)


## 战役结算时清空未使用装备卡及其兑换记录。
func clear_equipment_cards() -> void:
	equipment_cards_remaining = 0
	equipment_card_redeemed_types.clear()
	resource_changed.emit("equipment_card", equipment_cards_remaining)


func can_redeem_equipment_type(equipment_type: int) -> bool:
	return equipment_cards_remaining > 0 \
		and is_type_available_in_campaign(equipment_type) \
		and not equipment_card_redeemed_types.has(equipment_type)


func consume_equipment_card(equipment_type: int) -> bool:
	if not can_redeem_equipment_type(equipment_type):
		return false
	equipment_cards_remaining -= 1
	equipment_card_redeemed_types.append(equipment_type)
	resource_changed.emit("equipment_card", equipment_cards_remaining)
	return true


## 战役胜利时按配置提升以后每次战役的补给上限。
func award_equipment_card_capacity(completed_campaign: int) -> int:
	var reward_campaigns: Array = ConfigLoader.initial_resources_config.get("equipment_card_reward_campaigns", [])
	var is_reward_campaign := false
	for campaign in reward_campaigns:
		if int(campaign) == completed_campaign:
			is_reward_campaign = true
			break
	if not is_reward_campaign:
		return 0
	var maximum := int(ConfigLoader.initial_resources_config.get("max_equipment_card_capacity", 8))
	if equipment_card_capacity >= maximum:
		return 0
	equipment_card_capacity += 1
	stats_equipment_card_capacity_gained += 1
	return 1


## 旧存档没有独立上限字段时，按当前待玩战役推导既有奖励。
func derive_equipment_card_capacity_from_campaign() -> void:
	var initial := int(ConfigLoader.initial_resources_config.get("initial_equipment_card_capacity", 2))
	var reward_campaigns: Array = ConfigLoader.initial_resources_config.get("equipment_card_reward_campaigns", [])
	var derived := initial
	for completed_campaign in reward_campaigns:
		if int(completed_campaign) <= campaign_index:
			derived += 1
	equipment_card_capacity = min(derived, int(ConfigLoader.initial_resources_config.get("max_equipment_card_capacity", 8)))


## 核心四类至少拥有白色研究，避免损坏或早期存档导致无法制造必装装备。
func ensure_core_research() -> void:
	for equipment_type in CORE_EQUIPMENT_TYPES:
		if get_research_level(equipment_type) > 0:
			continue
		var bp := Blueprint.new()
		bp.id = "core_research_%d" % equipment_type
		bp.equipment_type = equipment_type
		bp.rarity = Equipment.Rarity.WHITE
		bp.base_attributes = _get_blueprint_attributes(equipment_type, Equipment.Rarity.WHITE)
		add_blueprint(bp)


## 移除蓝图（回收时使用）
func remove_blueprint(blueprint: Blueprint) -> void:
	blueprints.erase(blueprint)
	tactical_backpack.erase(int(blueprint.equipment_type))


## 根据 ID 查找蓝图
func find_blueprint(id: String) -> Blueprint:
	for bp in blueprints:
		if bp.id == id:
			return bp
	return null


## 获取未放入战术背包的可选类型研究记录
func get_available_blueprints() -> Array[Blueprint]:
	var result: Array[Blueprint] = []
	for bp in blueprints:
		if OPTIONAL_EQUIPMENT_TYPES.has(int(bp.equipment_type)) and not tactical_backpack.has(int(bp.equipment_type)):
			result.append(bp)
	return result

## 战役进度
var current_stage: int = 1  # 当前全局关卡（1-30）
var current_wave: int = 1  # 当前波次（1-3）

## 单位耐久（战役内跨循环保留，-1 表示满耐久/未初始化）
## 战斗循环结束时保存，构筑循环维修时更新，进入战斗循环时恢复
var tank_stored_hp: int = -1
var base_stored_hp: int = -1

## 音量设置（0.0 ~ 1.0，持久化到存档，由 AudioManager 读取/写入）
var music_volume: float = 1.0
var sfx_volume: float = 1.0

## 新手指引剧情（作战简报）是否已看过（持久化到 settings.json，与游戏进度无关）
var story_intro_seen: bool = false

## 新手指引全局开关（持久化到 settings.json；首次运行默认开启）
var tutorial_enabled: bool = true
## 已完成的指引条目 id -> true（随游戏存档 save_game.json 持久化）：
## 新游戏开始时清空（重玩全部指引），读档时恢复存档内进度（错过补课语义不变）
var tutorial_done: Dictionary = {}

## 信号
signal resource_changed(resource_type: String, amount: int)
signal attribute_changed(entity: String, attribute: String, value: Variant)
signal equipment_changed(slot: String, equipment: Equipment)


## 初始化升级数据
func _ready() -> void:
	_initialize_upgrades()


## 初始化所有升级项为 0 级
func _initialize_upgrades() -> void:
	upgrades = {
		"tank_health": 0,
		"tank_speed": 0,
		"turret_rotation_speed": 0,
		"base_health": 0,
		"base_repair_speed": 0,
		"base_charge_speed": 0,
		"tactical_backpack_capacity": 0,
		"initial_gold_bonus": 0
	}


## 根据当前升级等级重新计算所有基础属性加成
## 在加载存档后调用，确保属性与升级等级一致
func recalculate_upgrade_bonuses() -> void:
	# 重置所有加成
	base_tank_max_health = 0
	base_tank_speed_multiplier = 0.0
	base_turret_rotation_multiplier = 0.0
	base_player_max_health = 0
	base_repair_speed_bonus = 0.0
	base_charge_speed_multiplier = 0.0
	tactical_backpack_capacity = int(ConfigLoader.initial_resources_config.get("initial_backpack_capacity", 2))
	
	if ConfigLoader.upgrade_configs.is_empty():
		trim_tactical_backpack()
		return
	
	# 按升级等级重新累加效果
	for upgrade_id in upgrades:
		var level = upgrades[upgrade_id]
		if level <= 0:
			continue
		var config = ConfigLoader.upgrade_configs.get(upgrade_id, {})
		var effect = config.get("effect_per_level", 0.0)
		match upgrade_id:
			"tank_health":
				base_tank_max_health = int(effect) * level
			"tank_speed":
				base_tank_speed_multiplier = effect * level
			"turret_rotation_speed":
				base_turret_rotation_multiplier = effect * level
			"base_health":
				base_player_max_health = int(effect) * level
			"base_repair_speed":
				base_repair_speed_bonus = effect * level
			"base_charge_speed":
				base_charge_speed_multiplier = effect * level
			"tactical_backpack_capacity":
				tactical_backpack_capacity = int(ConfigLoader.initial_resources_config.get("initial_backpack_capacity", 2)) + int(effect) * level
	trim_tactical_backpack()


## 当前战役初始金币 = 固定基础值 + 黑匣升级增量
func get_initial_campaign_gold() -> int:
	var base_gold := int(ConfigLoader.initial_resources_config.get("initial_gold", 800))
	var level := int(upgrades.get("initial_gold_bonus", 0))
	var config: Dictionary = ConfigLoader.upgrade_configs.get("initial_gold_bonus", {})
	return base_gold + level * int(config.get("effect_per_level", 0))


## 容量降低（洗点/旧存档迁移）后保留最先选择的类型，移除溢出项
func trim_tactical_backpack() -> void:
	var normalized: Array[int] = []
	for equipment_type in tactical_backpack:
		if OPTIONAL_EQUIPMENT_TYPES.has(equipment_type) and not normalized.has(equipment_type):
			normalized.append(equipment_type)
	while normalized.size() > tactical_backpack_capacity:
		normalized.pop_back()
	tactical_backpack.assign(normalized)


## 重置战役内资源
## 在战役结束时调用，清空金币、模组、装备和库存
## 永久资源（黑匣、蓝图、升级等级）不受影响
func reset_campaign_resources() -> void:
	gold = 0
	modules = 0
	equipped.clear()
	inventory.clear()
	item_slots.clear()
	weapon_ammo.clear()
	tank_stored_hp = -1
	base_stored_hp = -1
	# 重置波间商店临时强化
	shop_damage_multiplier = 1.0
	shop_fire_rate_multiplier = 1.0
	shop_move_speed_multiplier = 1.0
	shop_shield_energy = 0.0
	shop_repair_count = 0
	shop_shield_bought = 0
	clear_equipment_cards()
	resource_changed.emit("gold", gold)
	resource_changed.emit("modules", modules)
	resource_changed.emit("module", modules)
