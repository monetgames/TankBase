extends Node

## ConfigLoader 单例
## 加载和管理所有游戏配置文件

## 配置文件路径
const TANK_CONFIG_PATH = "res://config/tank/player_tank.json"
const BASE_CONFIG_PATH = "res://config/base/player_base.json"
const EQUIPMENT_CONFIG_PATH = "res://config/equipment/equipment_templates.json"
const ENEMY_CONFIG_PATH = "res://config/enemy/enemy_units.json"
const UPGRADE_CONFIG_PATH = "res://config/upgrade/upgrades.json"
const DROP_CONFIG_PATH = "res://config/drop/drop_rates.json"
const WAVE_CONFIG_PATH = "res://config/wave/wave_configs.json"
const INITIAL_RESOURCES_CONFIG_PATH = "res://config/economy/initial_resources.json"
const ITEMS_CONFIG_PATH = "res://config/items/items.json"

## 配置数据
var tank_config: Dictionary = {}
var base_config: Dictionary = {}
var equipment_configs: Dictionary = {}
## 装备强化等级配置：数组下标 = 强化等级-1，字段 module_cost/gold_cost/success_rate/attribute_multiplier
var enhancement_levels: Array = []
var enemy_configs: Dictionary = {}
var upgrade_configs: Dictionary = {}
var drop_configs: Dictionary = {}
var wave_configs: Array[Dictionary] = []
var wave_pressure_config: Dictionary = {}
var max_stages: int = 30
var max_waves_per_stage: int = 3
var loot_gather_interval: float = 3.0  # 波次结束后捡金币阶段时长（秒），之后弹波间补给站
var initial_resources_config: Dictionary = {}
var items_config: Dictionary = {}


## 初始化时加载所有配置文件
func _ready() -> void:
	_load_all_configs()


## 加载所有配置文件
func _load_all_configs() -> void:
	print("========================================")
	print("开始加载配置文件...")
	print("========================================")
	
	# 加载坦克配置
	tank_config = load_json(TANK_CONFIG_PATH)
	if tank_config.is_empty():
		GameLog.warn("config", "坦克配置缺失，回退默认值")
		tank_config = _get_default_tank_config()
	
	# 加载基地配置
	base_config = load_json(BASE_CONFIG_PATH)
	if base_config.is_empty():
		GameLog.warn("config", "基地配置缺失，回退默认值")
		base_config = _get_default_base_config()
	
	# 加载装备配置
	var equipment_data = load_json(EQUIPMENT_CONFIG_PATH)
	if equipment_data.is_empty():
		GameLog.warn("config", "装备配置缺失，回退默认值")
		equipment_configs = _get_default_equipment_configs()
	else:
		equipment_configs = _parse_equipment_configs(equipment_data)
	# 加载装备强化配置（费用/成功率/属性倍率配置化）
	enhancement_levels = _parse_enhancement_levels(equipment_data)
	
	# 加载敌方单位配置
	enemy_configs = load_json(ENEMY_CONFIG_PATH)
	if enemy_configs.is_empty():
		GameLog.warn("config", "敌方单位配置缺失，回退默认值")
		enemy_configs = _get_default_enemy_configs()
	
	# 加载升级配置
	upgrade_configs = load_json(UPGRADE_CONFIG_PATH)
	if upgrade_configs.is_empty():
		GameLog.warn("config", "升级配置缺失，回退默认值")
		upgrade_configs = _get_default_upgrade_configs()
	
	# 加载掉落配置
	drop_configs = load_json(DROP_CONFIG_PATH)
	if drop_configs.is_empty():
		GameLog.warn("config", "掉落配置缺失，回退默认值")
		drop_configs = _get_default_drop_configs()
	
	# 加载波次配置
	var wave_data = load_json(WAVE_CONFIG_PATH)
	if wave_data.is_empty():
		GameLog.warn("config", "波次配置缺失，回退默认值")
		wave_configs = _get_default_wave_configs()
	else:
		var raw_waves = wave_data.get("waves", [])
		wave_configs.assign(raw_waves)
		wave_pressure_config = wave_data.get("first_stage_pressure", {})
		max_stages = wave_data.get("max_stages", 30)
		max_waves_per_stage = wave_data.get("max_waves_per_stage", 3)
		loot_gather_interval = float(wave_data.get("loot_gather_interval", 3.0))
	
	# 加载初始资源配置
	initial_resources_config = load_json(INITIAL_RESOURCES_CONFIG_PATH)
	if initial_resources_config.is_empty():
		GameLog.warn("config", "初始资源配置缺失，回退默认值")
		initial_resources_config = _get_default_initial_resources_config()
	
	# 加载道具配置
	items_config = load_json(ITEMS_CONFIG_PATH)
	if items_config.is_empty():
		GameLog.warn("config", "道具配置缺失，回退默认值")
		items_config = _get_default_items_config()
	
	print("========================================")
	print("配置文件加载完成")
	print("========================================")
	GameLog.info("config", "配置加载完成")


## 加载 JSON 文件
## @param path: 文件路径
## @return: 解析后的字典，失败时返回空字典
func load_json(path: String) -> Dictionary:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		GameLog.error("config", "配置文件无法打开 path=%s" % path)
		return {}
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		GameLog.exception("config", "配置解析失败", {
			"path": path, "line": json.get_error_line(), "err": json.get_error_message()})
		return {}
	
	print("✓ 加载配置文件: " + path)
	return json.data


## 解析装备配置数据
## 将装备配置转换为 type -> rarity -> attributes 的结构
func _parse_equipment_configs(data: Dictionary) -> Dictionary:
	var parsed = {}
	
	# 解析坦克装备
	if data.has("tank_equipment"):
		for equipment_type in data["tank_equipment"]:
			if equipment_type.begins_with("_"):
				continue
			
			var templates = data["tank_equipment"][equipment_type].get("templates", [])
			parsed[equipment_type] = {}
			
			for template in templates:
				var rarity = int(template.get("rarity", 1))  # 转换为整数
				parsed[equipment_type][rarity] = template
	
	# 解析基地装备
	if data.has("base_equipment"):
		for equipment_type in data["base_equipment"]:
			if equipment_type.begins_with("_"):
				continue

			var templates = data["base_equipment"][equipment_type].get("templates", [])
			parsed[equipment_type] = {}

			for template in templates:
				var rarity = int(template.get("rarity", 1))  # 转换为整数
				parsed[equipment_type][rarity] = template

	return parsed


## 解析装备强化配置；配置缺失/非法时回退默认值
func _parse_enhancement_levels(equipment_data: Dictionary) -> Array:
	var levels: Array = []
	var section: Dictionary = equipment_data.get("enhancement", {})
	var raw_list: Array = section.get("levels", [])
	if raw_list.is_empty():
		push_warning("强化配置缺失，使用默认强化数值")
		raw_list = [
			{"module_cost": 1, "gold_cost": 100, "success_rate": 1.0, "attribute_multiplier": 1.1},
			{"module_cost": 2, "gold_cost": 200, "success_rate": 0.8, "attribute_multiplier": 1.25},
			{"module_cost": 4, "gold_cost": 300, "success_rate": 0.5, "attribute_multiplier": 1.5},
		]
	for i in raw_list.size():
		var lv: Dictionary = raw_list[i]
		if typeof(lv) != TYPE_DICTIONARY:
			continue
		levels.append({
			"module_cost": int(lv.get("module_cost", 1)),
			"gold_cost": int(lv.get("gold_cost", (i + 1) * 100)),
			"success_rate": clampf(float(lv.get("success_rate", 1.0)), 0.0, 1.0),
			"attribute_multiplier": maxf(1.0, float(lv.get("attribute_multiplier", 1.0))),
		})
	return levels


## 获取装备强化等级配置（供 EquipmentSystem 读取）
func get_enhancement_levels() -> Array:
	return enhancement_levels


## 获取装备模板
## @param type: 装备类型（Equipment.Type 枚举）
## @param rarity: 稀有度（Equipment.Rarity 枚举）
## @return: 装备模板字典
func get_equipment_template(type: Equipment.Type, rarity: Equipment.Rarity) -> Dictionary:
	var type_name = _equipment_type_to_string(type)
	
	if not equipment_configs.has(type_name):
		push_warning("装备类型不存在: '%s'，当前已有类型: %s" % [type_name, str(equipment_configs.keys())])
		return {}
	
	if not equipment_configs[type_name].has(rarity):
		push_warning("装备稀有度不存在: %s - rarity=%d，当前已有稀有度: %s" % [type_name, rarity, str(equipment_configs[type_name].keys())])
		return {}
	
	return equipment_configs[type_name][rarity]


## 获取敌方单位模板
## @param unit_type: 单位类型（"tank" 或 "base"）
## @param level: 等级（"normal", "elite", "boss"）
## @return: 敌方单位模板字典
func get_enemy_template(unit_type: String, level: String) -> Dictionary:
	var unit_key = unit_type + "s"  # "tank" -> "tanks", "base" -> "bases"
	
	if not enemy_configs.has(unit_key):
		push_warning("敌方单位类型不存在: " + unit_type)
		return {}
	
	if not enemy_configs[unit_key].has(level):
		push_warning("敌方单位等级不存在: " + unit_type + " - " + level)
		return {}
	
	return enemy_configs[unit_key][level]


## 将 Equipment.Type 枚举转换为字符串
func _equipment_type_to_string(type: Equipment.Type) -> String:
	match type:
		Equipment.Type.ENGINE: return "engine"
		Equipment.Type.BEARING: return "bearing"
		Equipment.Type.MAIN_GUN: return "main_gun"
		Equipment.Type.SHELL: return "shell"
		Equipment.Type.ARMOR: return "armor"
		Equipment.Type.SHIELD: return "shield"
		Equipment.Type.DIVING: return "diving"
		Equipment.Type.STEALTH: return "stealth"
		Equipment.Type.RADAR: return "radar"
		Equipment.Type.EMP: return "emp"
		Equipment.Type.BARRIER: return "barrier"
		Equipment.Type.REPAIR_MACHINE: return "repair_machine"
		Equipment.Type.ENERGY_STATION: return "energy_station"
	return ""


## 默认坦克配置
func _get_default_tank_config() -> Dictionary:
	return {
		"max_health": 1000,
		"move_speed": 3.0,
		"turret_rotation_speed": 90,
		"shell_damage": 50,
		"shell_range": 6.0,
		"shell_speed": 8.0,
		"shoot_cooldown": 1.0
	}


## 默认基地配置
func _get_default_base_config() -> Dictionary:
	return {
		"max_health": 2000,
		"defense": 0,
		"repair_speed": 0,
		"repair_cost_per_100hp": 10,
		"charge_speed": 0,
		"max_charge_capacity": 0,
		"base_range": 3.0
	}


## 默认装备配置
func _get_default_equipment_configs() -> Dictionary:
	return {}


## 默认敌方单位配置
func _get_default_enemy_configs() -> Dictionary:
	return {
		"tanks": {
			"normal": {
				"max_health": 150,
				"defense": 0,
				"shell_damage": 20,
				"move_speed": 2.0,
				"detect_range": 8.0,
				"scout_base_detect_range": 15.0,
				"fire_range": 6.0
			}
		},
		"bases": {
			"normal": {
				"max_health": 300,
				"defense": 0,
				"max_tanks": 4,
				"production_interval": 10.0
			}
		}
	}


## 默认升级配置
func _get_default_upgrade_configs() -> Dictionary:
	return {}


## 默认掉落配置
func _get_default_drop_configs() -> Dictionary:
	return {}


## 默认波次配置
func _get_default_wave_configs() -> Array[Dictionary]:
	return []


## 默认初始资源配置
func _get_default_initial_resources_config() -> Dictionary:
	return {
		"initial_gold": 800,
		"initial_modules": 0,
		"initial_black_boxes": 0,
		"initial_backpack_capacity": 2,
		"initial_equipment_card_capacity": 2,
		"max_equipment_card_capacity": 8,
		"equipment_card_reward_campaigns": [1, 2, 3, 5, 7, 9],
		"initial_blueprints": [
			{"type": "engine", "rarity": 1},
			{"type": "bearing", "rarity": 1},
			{"type": "main_gun", "rarity": 1},
			{"type": "shell", "rarity": 1},
			{"type": "repair_machine", "rarity": 1},
		]
	}


## 默认道具配置
func _get_default_items_config() -> Dictionary:
	return {
		"mine": {"damage_multiplier": 3.0},
		"rocket": {"damage_multiplier": 2.0}
	}
