class_name Equipment
extends Resource

## 装备数据模型
## 定义装备的类型、稀有度、强化等级和属性

enum Type {
	# 坦克装备
	ENGINE,           # 引擎 - 提供移动速度加成
	BEARING,          # 轴承 - 提供炮台旋转速度加成
	MAIN_GUN,         # 主炮 - 提供炮弹速度和射击冷却加成
	SHELL,            # 炮弹 - 提供炮弹伤害和射程加成
	ARMOR,            # 装甲 - 提供防御值
	SHIELD,           # 护盾 - 提供护盾能量
	DIVING,           # 潜渡 - 解锁水面通行能力
	STEALTH,          # 隐身 - 降低被敌方探测概率
	RADAR,            # 雷达 - 提升战场信息感知
	# 基地装备
	EMP,              # 电磁脉冲 - 自动瘫痪进入范围的敌方坦克
	BARRIER,          # 壁垒 - 提供基地防御值
	REPAIR_MACHINE,   # 抢修机 - 提供战斗维修能力
	ENERGY_STATION    # 能量站 - 提供护盾充能能力
}

enum Rarity {
	WHITE = 1,   # 白色 - 普通
	BLUE = 2,    # 蓝色 - 高级
	PURPLE = 3,  # 紫色 - 稀有
	PINK = 4,    # 粉色 - 神器
	GOLD = 5     # 金色 - 传说
}

## 装备取得来源。装备卡兑换来源用于禁止回收套利，必须随装备全生命周期保存。
enum Origin {
	GOLD_CRAFT,
	EQUIPMENT_CARD,
}

## 唯一标识符
@export var id: String = ""

## 装备类型
@export var type: Type = Type.ENGINE

## 稀有度
@export var rarity: Rarity = Rarity.WHITE

## 强化等级 (0-3)
@export var enhancement_level: int = 0

## 取得来源；普通制造默认为 GOLD_CRAFT。
@export var origin: Origin = Origin.GOLD_CRAFT

## 属性字典 - 存储装备的所有属性加成（强化后为"基础值 × 当前等级倍率"）
@export var attributes: Dictionary = {}

## 基础属性快照 - 制造时从蓝图 base_attributes 复制，强化时基于此快照重算
## 规则：最终值 = 基础值 × (1 + 系数)，+1→×1.10、+2→×1.25、+3→×1.50
@export var base_attributes: Dictionary = {}


## 获取装备的显示名称
## 格式："+强化等级 类型名 (稀有度名)"
## 例如："+2 引擎 (紫色)"
func get_display_name() -> String:
	var prefix = ""
	if enhancement_level > 0:
		prefix = "+" + str(enhancement_level) + " "
	return prefix + Equipment.get_type_name(type) + " (" + Equipment.get_rarity_name(rarity) + ")"


## 获取装备类型的中文名称（静态方法）
static func get_type_name(equipment_type: Type) -> String:
	match equipment_type:
		Type.ENGINE:
			return "引擎"
		Type.BEARING:
			return "轴承"
		Type.MAIN_GUN:
			return "主炮"
		Type.SHELL:
			return "炮弹"
		Type.ARMOR:
			return "装甲"
		Type.SHIELD:
			return "护盾"
		Type.DIVING:
			return "潜渡"
		Type.STEALTH:
			return "隐身"
		Type.RADAR:
			return "雷达"
		Type.EMP:
			return "EMP"
		Type.BARRIER:
			return "壁垒"
		Type.REPAIR_MACHINE:
			return "抢修机"
		Type.ENERGY_STATION:
			return "能量站"
	return "未知"


## 获取稀有度的中文名称（静态方法，去"色"字：蓝/紫/粉/金/白）
static func get_rarity_name(equipment_rarity: Rarity) -> String:
	match equipment_rarity:
		Rarity.WHITE:
			return "白"
		Rarity.BLUE:
			return "蓝"
		Rarity.PURPLE:
			return "紫"
		Rarity.PINK:
			return "粉"
		Rarity.GOLD:
			return "金"
	return "未知"


## 获取稀有度对应的字体颜色（静态方法，全界面统一使用）
## 与 UIPalette 的 RARITY_* 常量一致：白/蓝/紫/粉/金
static func get_rarity_color(equipment_rarity: Rarity) -> Color:
	match equipment_rarity:
		Rarity.BLUE:
			return UIPalette.RARITY_ADV
		Rarity.PURPLE:
			return UIPalette.RARITY_RARE
		Rarity.PINK:
			return UIPalette.RARITY_EPIC
		Rarity.GOLD:
			return UIPalette.RARITY_LEGEND
		_:
			return UIPalette.RARITY_COMMON  # WHITE 白


## 获取装备类型的功能描述（静态方法，浮窗/详情共用）
static func get_type_desc(equipment_type: Type) -> String:
	match equipment_type:
		Type.ENGINE:
			return "提升坦克移动速度"
		Type.BEARING:
			return "提升炮塔旋转速度"
		Type.MAIN_GUN:
			return "提升炮弹速度与射击频率"
		Type.SHELL:
			return "提升炮弹伤害与射程"
		Type.ARMOR:
			return "减少坦克受到的伤害"
		Type.SHIELD:
			return "提高护盾能量"
		Type.DIVING:
			return "提升水面移动速度"
		Type.STEALTH:
			return "缩短敌方坦克探测距离；开炮会短暂暴露；强化提升闪避率"
		Type.RADAR:
			return "扩大战场侦察范围和效果"
		Type.EMP:
			return "增强对敌瘫痪和持续伤害效果"
		Type.BARRIER:
			return "提升基地防御力"
		Type.REPAIR_MACHINE:
			return "加速维修坦克，减少金币消耗"
		Type.ENERGY_STATION:
			return "提高护盾充能速度与充能量"
	return ""
