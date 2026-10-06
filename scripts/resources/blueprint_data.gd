class_name Blueprint
extends Resource

## 蓝图数据模型
## 永久存档中每种类型只保留最高研究等级；构筑循环会据此生成各稀有度的临时制造蓝图。

## 唯一标识符
@export var id: String = ""

## 装备类型
@export var equipment_type: Equipment.Type = Equipment.Type.ENGINE

## 稀有度
@export var rarity: Equipment.Rarity = Equipment.Rarity.WHITE

## 基础属性字典 - 存储装备的基础属性值
@export var base_attributes: Dictionary = {}


## 获取蓝图的显示名称
## 格式：类型名 (稀有度名)
## 例如：引擎 (紫色)
func get_display_name() -> String:
	var type_name = _get_type_name()
	var rarity_name = _get_rarity_name()
	return "%s (%s)" % [type_name, rarity_name]


## 获取装备类型的中文名称
func _get_type_name() -> String:
	match equipment_type:
		Equipment.Type.ENGINE:
			return "引擎"
		Equipment.Type.BEARING:
			return "轴承"
		Equipment.Type.MAIN_GUN:
			return "主炮"
		Equipment.Type.SHELL:
			return "炮弹"
		Equipment.Type.ARMOR:
			return "装甲"
		Equipment.Type.SHIELD:
			return "护盾"
		Equipment.Type.DIVING:
			return "潜渡"
		Equipment.Type.STEALTH:
			return "隐身"
		Equipment.Type.RADAR:
			return "雷达"
		Equipment.Type.EMP:
			return "EMP"
		Equipment.Type.BARRIER:
			return "壁垒"
		Equipment.Type.REPAIR_MACHINE:
			return "抢修机"
		Equipment.Type.ENERGY_STATION:
			return "能量站"
	return "未知"


## 获取稀有度的中文名称（去"色"字，统一走 Equipment.get_rarity_name）
func _get_rarity_name() -> String:
	return Equipment.get_rarity_name(rarity)


## 根据蓝图创建装备实例
## 从 ConfigLoader 读取对应类型和稀有度的属性模板
func create_equipment() -> Equipment:
	var equipment = Equipment.new()
	equipment.id = id + "_" + str(Time.get_ticks_msec())
	equipment.type = equipment_type
	equipment.rarity = rarity
	equipment.enhancement_level = 0
	
	# 优先使用蓝图自带的 base_attributes，否则从配置读取模板
	if not base_attributes.is_empty():
		equipment.attributes = base_attributes.duplicate()
	else:
		var template = ConfigLoader.get_equipment_template(equipment_type, rarity)
		equipment.attributes = template.get("attributes", {}).duplicate()
	
	print("Blueprint.create_equipment: type=%d, rarity=%d, base_attributes=%s, result_attrs=%s" % [equipment_type, rarity, str(base_attributes), str(equipment.attributes)])
	return equipment
