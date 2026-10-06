extends Node

## EquipmentSystem 单例
## 管理装备制造、强化、装配系统

## 装备槽位枚举
enum EquipmentSlot {
	# 坦克槽位
	TANK_ENGINE,      # 引擎
	TANK_BEARING,     # 轴承
	TANK_MAIN_GUN,    # 主炮
	TANK_SHELL,       # 炮弹
	TANK_ARMOR,       # 装甲
	TANK_SHIELD,      # 护盾
	TANK_SE_1,        # 特种装置 1
	TANK_SE_2,        # 特种装置 2
	# 基地槽位
	BASE_EMP,         # 反击（EMP）
	BASE_BARRIER,     # 防御（壁垒）
	BASE_SUPPLY_1,    # 补给 1（抢修机/能量站）
	BASE_SUPPLY_2     # 补给 2（抢修机/能量站）
}

## 强化配置
class EnhancementConfig:
	var level: int
	var module_cost: int
	var gold_cost: int
	var success_rate: float
	var attribute_multiplier: float

	func _init(l: int, cost: int, gold: int, rate: float, mult: float):
		level = l
		module_cost = cost
		gold_cost = gold
		success_rate = rate
		attribute_multiplier = mult

## 强化配置数组（从 config/equipment/equipment_templates.json enhancement 段加载）
var enhancement_configs: Array[EnhancementConfig] = []

func _ready() -> void:
	_load_enhancement_configs()

## 从 ConfigLoader 加载强化配置；缺失时回退内置默认值
func _load_enhancement_configs() -> void:
	enhancement_configs.clear()
	var levels: Array = ConfigLoader.get_enhancement_levels()
	if levels.is_empty():
		levels = [
			{"module_cost": 1, "gold_cost": 100, "success_rate": 1.0, "attribute_multiplier": 1.1},
			{"module_cost": 2, "gold_cost": 200, "success_rate": 0.8, "attribute_multiplier": 1.25},
			{"module_cost": 4, "gold_cost": 300, "success_rate": 0.5, "attribute_multiplier": 1.5},
		]
	for i in levels.size():
		var lv: Dictionary = levels[i]
		enhancement_configs.append(EnhancementConfig.new(
			i + 1,
			int(lv.get("module_cost", 1)),
			int(lv.get("gold_cost", (i + 1) * 100)),
			float(lv.get("success_rate", 1.0)),
			float(lv.get("attribute_multiplier", 1.0))))

## 隐身装备强化提供的闪避率：+1/+2/+3 = 5%/10%/15%（强化不改变探测倍率）
const STEALTH_ENHANCEMENT_DODGE_CHANCES: Array[float] = [0.05, 0.10, 0.15]


## 制造装备
## @param blueprint: 蓝图
## @return: 制造的装备，失败时返回 null
func craft_equipment(blueprint: Blueprint) -> Equipment:
	var cost = _calculate_craft_cost(blueprint.rarity)
	
	if GameState.gold < cost:
		EconomySystem.insufficient_resources.emit("gold", cost, GameState.gold)
		GameLog.warn("equipment", "制造金币不足 need=%d have=%d" % [cost, GameState.gold])
		return null
	
	# 消耗金币
	if not EconomySystem.spend_resource("gold", cost):
		GameLog.error("equipment", "制造扣费失败 cost=%d" % cost)
		return null
	
	# 创建装备
	var equipment = blueprint.create_equipment()
	equipment.origin = Equipment.Origin.GOLD_CRAFT

	# 如果蓝图 base_attributes 未初始化，从 ConfigLoader 补充并回写蓝图（避免下次再出现同样问题）
	if blueprint.base_attributes.is_empty():
		var template = ConfigLoader.get_equipment_template(blueprint.equipment_type, blueprint.rarity)
		blueprint.base_attributes = template.get("attributes", {}).duplicate()

	# 快照基础属性 + 初始 attributes = 基础属性副本（强化时基于 base_attributes 重算）
	equipment.base_attributes = blueprint.base_attributes.duplicate()
	equipment.attributes = equipment.base_attributes.duplicate()

	# 添加到库存
	GameState.inventory.append(equipment)
	GameState.stats_gold_crafted_count += 1
	sort_inventory()

	print("EquipmentSystem: 制造装备 %s，消耗 %d 金币，属性=%s" % [equipment.get_display_name(), cost, str(equipment.attributes)])
	return equipment


## 使用装备卡兑换一件本局许可的装备。每种类型每战役仅可兑换一次。
func redeem_equipment_card(blueprint: Blueprint) -> Equipment:
	if blueprint == null:
		return null
	var equipment_type := int(blueprint.equipment_type)
	if not GameState.can_redeem_equipment_type(equipment_type):
		return null
	var equipment := blueprint.create_equipment()
	if equipment == null:
		return null
	if blueprint.base_attributes.is_empty():
		var template := ConfigLoader.get_equipment_template(blueprint.equipment_type, blueprint.rarity)
		blueprint.base_attributes = template.get("attributes", {}).duplicate()
	equipment.base_attributes = blueprint.base_attributes.duplicate()
	equipment.attributes = equipment.base_attributes.duplicate()
	equipment.origin = Equipment.Origin.EQUIPMENT_CARD
	GameState.inventory.append(equipment)
	if not GameState.consume_equipment_card(equipment_type):
		GameState.inventory.erase(equipment)
		return null
	sort_inventory()
	print("EquipmentSystem: 装备卡兑换 %s，剩余 %d 张" % [equipment.get_display_name(), GameState.equipment_cards_remaining])
	return equipment


## 强化装备
## @param equipment: 要强化的装备
## @return: 是否成功强化
func enhance_equipment(equipment: Equipment) -> bool:
	if equipment.enhancement_level >= 3:
		push_warning("装备已达到最大强化等级")
		return false

	var config = enhancement_configs[equipment.enhancement_level]
	
	# 检查模组是否足够
	if not EconomySystem.spend_resource("module", config.module_cost):
		return false
	
	# 检查并消耗金币（强化金币费用：走配置 C1）
	var gold_cost = config.gold_cost
	if not EconomySystem.spend_resource("gold", gold_cost):
		# 金币不足时回滚模组消耗
		EconomySystem.add_resource("module", config.module_cost)
		return false
	
	# 强化判定
	var success = randf() < config.success_rate
	if success:
		equipment.enhancement_level += 1
		# 基于 base_attributes 按当前强化等级重算属性（内部按 enhancement_level 取倍率）
		_apply_enhancement(equipment)
		print("EquipmentSystem: 强化成功 %s -> +%d" % [equipment.get_display_name(), equipment.enhancement_level])
		return true
	else:
		print("EquipmentSystem: 强化失败 %s" % equipment.get_display_name())
		return false


## 将库存装备升到更高稀有度，完整保留强化等级。
## 费用采用制造差价，保证不同成长路径总成本一致。
func ascend_equipment(equipment: Equipment, target_rarity: Equipment.Rarity) -> bool:
	if equipment == null or not GameState.inventory.has(equipment):
		push_warning("只有库存中的未装配装备可以升阶")
		return false
	if int(target_rarity) <= int(equipment.rarity):
		return false
	if int(target_rarity) > GameState.get_research_level(int(equipment.type)):
		push_warning("目标稀有度尚未研究")
		return false
	if not GameState.is_type_available_in_campaign(int(equipment.type)):
		push_warning("本局未携带该装备类型的制造许可")
		return false
	var cost := calculate_ascend_cost(equipment.rarity, target_rarity)
	if cost <= 0 or not EconomySystem.spend_resource("gold", cost):
		return false
	var template := ConfigLoader.get_equipment_template(equipment.type, target_rarity)
	equipment.rarity = target_rarity
	equipment.base_attributes = template.get("attributes", {}).duplicate()
	equipment.attributes = equipment.base_attributes.duplicate()
	if equipment.enhancement_level > 0:
		_apply_enhancement(equipment)
	print("EquipmentSystem: 装备升阶为 %s，消耗 %d 金币，强化等级保留" % [equipment.get_display_name(), cost])
	return true


## 装配装备
## @param slot: 装备槽位
## @param equipment: 要装配的装备
## @return: 是否成功装配
func equip(slot: int, equipment: Equipment) -> bool:
	if not is_valid_slot(slot, equipment.type):
		GameLog.warn("equipment", "装配槽位不匹配 slot=%d type=%d" % [slot, int(equipment.type)])
		return false
	
	# 卸载旧装备
	if GameState.equipped.has(slot):
		unequip(slot)
	
	# 装配新装备
	GameState.equipped[slot] = equipment
	_apply_equipment_attributes(equipment)
	GameState.equipment_changed.emit(_slot_to_string(slot), equipment)
	
	# 从库存移除
	GameState.inventory.erase(equipment)
	sort_inventory()

	print("EquipmentSystem: 装配装备 %s 到槽位 %s" % [equipment.get_display_name(), _slot_to_string(slot)])
	return true


## 卸载装备
## @param slot: 装备槽位
## @return: 卸载的装备，失败时返回 null
func unequip(slot: EquipmentSlot) -> Equipment:
	if not GameState.equipped.has(slot):
		return null
	
	var equipment = GameState.equipped[slot]
	GameState.equipped.erase(slot)
	_remove_equipment_attributes(equipment)
	GameState.equipment_changed.emit(_slot_to_string(slot), null)
	
	# 添加回库存
	GameState.inventory.append(equipment)
	sort_inventory()

	print("EquipmentSystem: 卸载装备 %s 从槽位 %s" % [equipment.get_display_name(), _slot_to_string(slot)])
	return equipment


## 回收装备
## @param equipment: 要回收的装备
## @return: 返还的金币数量
func recycle_equipment(equipment: Equipment) -> int:
	if equipment == null or not GameState.inventory.has(equipment):
		GameLog.warn("equipment", "回收目标不在库存，已忽略")
		return 0
	if equipment.origin == Equipment.Origin.EQUIPMENT_CARD:
		GameLog.warn("equipment", "装备卡兑换的装备不可回收")
		return 0
	var cost = _calculate_craft_cost(equipment.rarity)
	var refund = int(cost * 0.5)  # 返还 50% 费用
	
	# 从库存移除
	GameState.inventory.erase(equipment)
	sort_inventory()

	# 添加金币
	EconomySystem.add_resource("gold", refund)
	
	print("EquipmentSystem: 回收装备 %s，返还 %d 金币" % [equipment.get_display_name(), refund])
	return refund


## 丢弃装备卡兑换装备，不返还任何资源。丢弃后同类型本战役仍不能再次兑换。
func discard_equipment(equipment: Equipment) -> bool:
	if equipment == null or not GameState.inventory.has(equipment):
		return false
	GameState.inventory.erase(equipment)
	sort_inventory()
	print("EquipmentSystem: 丢弃装备 %s" % equipment.get_display_name())
	return true


## 库存排序：与 Meta 循环蓝图库保持同序（装备类型升序），
## 同类型内按稀有度、强化等级从高到低，保证顺序确定。
## 制造/卸载（插入）与装配/回收（移出）后均会调用，列表顺序始终稳定。
func sort_inventory() -> void:
	GameState.inventory.sort_custom(func(a: Equipment, b: Equipment) -> bool:
		var ta := int(a.type)
		var tb := int(b.type)
		if ta != tb:
			return ta < tb
		var ra := int(a.rarity)
		var rb := int(b.rarity)
		if ra != rb:
			return ra > rb
		return a.enhancement_level > b.enhancement_level)


## 装备数值评分（用于装配槽「选择」按钮自动挑最优装备）
## 权重：稀有度 > 强化等级 > 属性加成。
## 属性按「越大越好」累加；cooldown（冷却）与 detection_range_multiplier（探测倍率）为「越小越好」取负。
## @return: 评分，数值越高越优
func score_equipment(equipment: Equipment) -> float:
	if equipment == null:
		return -INF
	var score := float(int(equipment.rarity)) * 1e9 + float(equipment.enhancement_level) * 1e6
	for key in equipment.attributes:
		var v = equipment.attributes[key]
		if v is bool:
			if v:
				score += 1.0
		elif v is int or v is float:
			var k := String(key)
			if k == "cooldown" or k == "detection_range_multiplier":
				score -= float(v)
			else:
				score += float(v)
	return score


## 计算制造费用（公开方法）
## @param rarity: 稀有度
## @return: 制造费用
func calculate_craft_cost(rarity: Equipment.Rarity) -> int:
	return _calculate_craft_cost(rarity)


func calculate_ascend_cost(current_rarity: Equipment.Rarity, target_rarity: Equipment.Rarity) -> int:
	return maxi(0, _calculate_craft_cost(target_rarity) - _calculate_craft_cost(current_rarity))


## 计算制造费用
## @param rarity: 稀有度
## @return: 制造费用
func _calculate_craft_cost(rarity: Equipment.Rarity) -> int:
	match rarity:
		Equipment.Rarity.WHITE: return 100
		Equipment.Rarity.BLUE: return 300
		Equipment.Rarity.PURPLE: return 900
		Equipment.Rarity.PINK: return 2700
		Equipment.Rarity.GOLD: return 8100
	return 0


## 应用强化：基于 base_attributes 按当前强化等级重算属性
## 公式：最终值 = 基础值 × 当前等级最终倍率（+1→1.10、+2→1.25、+3→1.50，enhancement_configs 数值不变）
## 仅数值型属性参与倍率重算；布尔开关（如潜渡 water_traversal）保持不变；cooldown 键只随稀有度变化、不随强化放大。
## reduction/penalty 键不做截断。
## @param equipment: 装备（须已 increment enhancement_level）
func _apply_enhancement(equipment: Equipment) -> void:
	var level := equipment.enhancement_level
	if level < 1 or level > enhancement_configs.size():
		return
	var multiplier: float = enhancement_configs[level - 1].attribute_multiplier

	# 兼容旧存档/旧装备：base_attributes 缺失时把当前 attributes 视为基础值
	if equipment.base_attributes.is_empty():
		equipment.base_attributes = equipment.attributes.duplicate()

	for key in equipment.base_attributes:
		var base_val = equipment.base_attributes[key]
		# 布尔开关（如 water_traversal）不参与强化倍率
		if base_val is bool:
			continue
		# 冷却类属性只随稀有度变化（否则冷却会越强化越久）
		if String(key) == "cooldown":
			continue
		# 隐身暴露时长只随稀有度变化，不随强化放大
		if String(key) == "exposure_duration":
			continue
		# 隐身探测倍率不参与强化：保持基础值（强化收益改为闪避率，见下）
		if String(key) == "detection_range_multiplier":
			continue
		equipment.attributes[key] = float(base_val) * multiplier

	# 隐身装备：强化提供闪避率（+1/+2/+3 = 5%/10%/15%）
	if equipment.type == Equipment.Type.STEALTH:
		var dodge_index := clampi(level - 1, 0, STEALTH_ENHANCEMENT_DODGE_CHANCES.size() - 1)
		equipment.attributes["dodge_chance"] = STEALTH_ENHANCEMENT_DODGE_CHANCES[dodge_index]


## 应用装备属性
## @param equipment: 装备
func _apply_equipment_attributes(equipment: Equipment) -> void:
	var attrs = equipment.attributes
	match equipment.type:
		# ===== 坦克装备 =====
		Equipment.Type.ENGINE:
			# 引擎：提升移动速度
			GameState.attribute_changed.emit("tank", "move_speed_bonus",
				attrs.get("move_speed_bonus", 0.0))
		Equipment.Type.BEARING:
			# 轴承：提升炮台旋转速度
			GameState.attribute_changed.emit("tank", "turret_rotation_bonus",
				attrs.get("turret_rotation_bonus", 0.0))
		Equipment.Type.MAIN_GUN:
			# 主炮：提升炮弹速度、缩短射击冷却
			GameState.attribute_changed.emit("tank", "shell_speed",
				attrs.get("shell_speed", 0.0))
			GameState.attribute_changed.emit("tank", "shoot_cooldown_reduction",
				attrs.get("shoot_cooldown_reduction", 0.0))
		Equipment.Type.SHELL:
			# 炮弹：提升伤害和射程
			GameState.attribute_changed.emit("tank", "shell_damage_bonus",
				attrs.get("shell_damage_bonus", 0.0))
			GameState.attribute_changed.emit("tank", "shell_range_bonus",
				attrs.get("shell_range_bonus", 0.0))
		Equipment.Type.ARMOR:
			# 装甲：提升防御值
			GameState.attribute_changed.emit("tank", "defense_bonus",
				attrs.get("defense_bonus", 0))
		Equipment.Type.SHIELD:
			# 护盾：提供护盾能量上限
			GameState.attribute_changed.emit("tank", "shield_energy_max",
				attrs.get("shield_energy_max", 0.0))
		Equipment.Type.DIVING:
			# 潜渡：解锁水面通行，并按稀有度设置水面移速倍率
			GameState.attribute_changed.emit("tank", "can_cross_water", true)
			GameState.attribute_changed.emit("tank", "water_speed_penalty",
				attrs.get("water_speed_penalty", 1.0))
		Equipment.Type.STEALTH:
			# 隐身：缩小敌方探测范围倍率；强化提供闪避率；开炮短暂暴露
			GameState.attribute_changed.emit("tank", "stealth_multiplier",
				attrs.get("detection_range_multiplier", 1.0))
			GameState.attribute_changed.emit("tank", "dodge_chance",
				attrs.get("dodge_chance", 0.0))
			GameState.attribute_changed.emit("tank", "stealth_exposure_duration",
				attrs.get("exposure_duration", 0.0))
		Equipment.Type.RADAR:
			# 雷达：提升探测范围（配置字段为 detection_range，白 8 格 → 金全图 999）
			GameState.attribute_changed.emit("tank", "radar_range",
				attrs.get("detection_range", 0.0))
			GameState.attribute_changed.emit("tank", "radar_show_enemy_health",
				attrs.get("show_enemy_health", false))
			GameState.attribute_changed.emit("tank", "radar_show_production_queue",
				attrs.get("show_production_queue", false))
			GameState.attribute_changed.emit("tank", "radar_show_full_map",
				attrs.get("show_full_map", false))
			GameState.attribute_changed.emit("tank", "radar_show_base_intel",
				attrs.get("show_base_intel", false))
		# ===== 基地装备 =====
		Equipment.Type.EMP:
			# EMP：范围/瘫痪时长/冷却/持续伤害/瘫痪效果差异化
			GameState.attribute_changed.emit("base", "emp_range",
				attrs.get("emp_range", 0.0))
			GameState.attribute_changed.emit("base", "emp_stun_duration",
				attrs.get("stun_duration", 3.0))
			GameState.attribute_changed.emit("base", "emp_cooldown",
				attrs.get("cooldown", 10.0))
			GameState.attribute_changed.emit("base", "emp_dot_damage",
				attrs.get("dot_damage", 0.0))
			GameState.attribute_changed.emit("base", "emp_disable_movement",
				attrs.get("disable_movement", true))
			GameState.attribute_changed.emit("base", "emp_disable_shooting",
				attrs.get("disable_shooting", false))
		Equipment.Type.BARRIER:
			# 壁垒：提升基地防御值
			GameState.attribute_changed.emit("base", "defense_bonus",
				attrs.get("defense_bonus", 0))
		Equipment.Type.REPAIR_MACHINE:
			# 抢修机：提供维修速度与维修折扣
			GameState.attribute_changed.emit("base", "repair_speed",
				attrs.get("repair_speed", 0.0))
			GameState.attribute_changed.emit("base", "repair_discount",
				attrs.get("repair_discount", 0.0))
		Equipment.Type.ENERGY_STATION:
			# 能量站：提供充能速度和容量
			GameState.attribute_changed.emit("base", "charge_speed",
				attrs.get("charge_speed", 0.0))
			GameState.attribute_changed.emit("base", "max_charge_capacity",
				attrs.get("max_charge_capacity", 0.0))


## 移除装备属性（装备卸载时归零对应加成）
## @param equipment: 装备
func _remove_equipment_attributes(equipment: Equipment) -> void:
	match equipment.type:
		Equipment.Type.ENGINE:
			GameState.attribute_changed.emit("tank", "move_speed_bonus", 0.0)
		Equipment.Type.BEARING:
			GameState.attribute_changed.emit("tank", "turret_rotation_bonus", 0.0)
		Equipment.Type.MAIN_GUN:
			GameState.attribute_changed.emit("tank", "shell_speed", 0.0)
			GameState.attribute_changed.emit("tank", "shoot_cooldown_reduction", 0.0)
		Equipment.Type.SHELL:
			GameState.attribute_changed.emit("tank", "shell_damage_bonus", 0.0)
			GameState.attribute_changed.emit("tank", "shell_range_bonus", 0.0)
		Equipment.Type.ARMOR:
			GameState.attribute_changed.emit("tank", "defense_bonus", 0)
		Equipment.Type.SHIELD:
			GameState.attribute_changed.emit("tank", "shield_energy_max", 0.0)
		Equipment.Type.DIVING:
			GameState.attribute_changed.emit("tank", "can_cross_water", false)
			GameState.attribute_changed.emit("tank", "water_speed_penalty", 1.0)
		Equipment.Type.STEALTH:
			GameState.attribute_changed.emit("tank", "stealth_multiplier", 1.0)
			GameState.attribute_changed.emit("tank", "dodge_chance", 0.0)
			GameState.attribute_changed.emit("tank", "stealth_exposure_duration", 0.0)
		Equipment.Type.RADAR:
			GameState.attribute_changed.emit("tank", "radar_range", 0.0)
			GameState.attribute_changed.emit("tank", "radar_show_enemy_health", false)
			GameState.attribute_changed.emit("tank", "radar_show_production_queue", false)
			GameState.attribute_changed.emit("tank", "radar_show_full_map", false)
			GameState.attribute_changed.emit("tank", "radar_show_base_intel", false)
		Equipment.Type.EMP:
			GameState.attribute_changed.emit("base", "emp_range", 0.0)
			GameState.attribute_changed.emit("base", "emp_stun_duration", 0.0)
			GameState.attribute_changed.emit("base", "emp_cooldown", 0.0)
			GameState.attribute_changed.emit("base", "emp_dot_damage", 0.0)
			GameState.attribute_changed.emit("base", "emp_disable_movement", false)
			GameState.attribute_changed.emit("base", "emp_disable_shooting", false)
		Equipment.Type.BARRIER:
			GameState.attribute_changed.emit("base", "defense_bonus", 0)
		Equipment.Type.REPAIR_MACHINE:
			GameState.attribute_changed.emit("base", "repair_speed", 0.0)
			GameState.attribute_changed.emit("base", "repair_discount", 0.0)
		Equipment.Type.ENERGY_STATION:
			GameState.attribute_changed.emit("base", "charge_speed", 0.0)
			GameState.attribute_changed.emit("base", "max_charge_capacity", 0.0)


## 检查槽位和装备类型是否匹配
## @param slot: 装备槽位（EquipmentSlot 枚举值）
## @param type: 装备类型
## @return: 是否匹配
func is_valid_slot(slot: int, type: Equipment.Type) -> bool:
	match slot:
		EquipmentSlot.TANK_ENGINE:
			return type == Equipment.Type.ENGINE
		EquipmentSlot.TANK_BEARING:
			return type == Equipment.Type.BEARING
		EquipmentSlot.TANK_MAIN_GUN:
			return type == Equipment.Type.MAIN_GUN
		EquipmentSlot.TANK_SHELL:
			return type == Equipment.Type.SHELL
		EquipmentSlot.TANK_ARMOR:
			return type == Equipment.Type.ARMOR
		EquipmentSlot.TANK_SHIELD:
			return type == Equipment.Type.SHIELD
		EquipmentSlot.TANK_SE_1, EquipmentSlot.TANK_SE_2:
			return type in [Equipment.Type.DIVING, Equipment.Type.STEALTH, Equipment.Type.RADAR]
		EquipmentSlot.BASE_EMP:
			return type == Equipment.Type.EMP
		EquipmentSlot.BASE_BARRIER:
			return type == Equipment.Type.BARRIER
		EquipmentSlot.BASE_SUPPLY_1, EquipmentSlot.BASE_SUPPLY_2:
			return type in [Equipment.Type.REPAIR_MACHINE, Equipment.Type.ENERGY_STATION]
	return false


## 将槽位枚举转换为字符串
## @param slot: 装备槽位
## @return: 槽位名称
func _slot_to_string(slot: int) -> String:
	match slot:
		EquipmentSlot.TANK_ENGINE: return "tank_engine"
		EquipmentSlot.TANK_BEARING: return "tank_bearing"
		EquipmentSlot.TANK_MAIN_GUN: return "tank_main_gun"
		EquipmentSlot.TANK_SHELL: return "tank_shell"
		EquipmentSlot.TANK_ARMOR: return "tank_armor"
		EquipmentSlot.TANK_SHIELD: return "tank_shield"
		EquipmentSlot.TANK_SE_1: return "tank_se_1"
		EquipmentSlot.TANK_SE_2: return "tank_se_2"
		EquipmentSlot.BASE_EMP: return "base_emp"
		EquipmentSlot.BASE_BARRIER: return "base_barrier"
		EquipmentSlot.BASE_SUPPLY_1: return "base_supply_1"
		EquipmentSlot.BASE_SUPPLY_2: return "base_supply_2"
	return ""
