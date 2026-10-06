class_name ItemData
extends Resource

enum ItemType {
	SHIELD,           # 护盾 - 10秒无敌
	FIREPOWER_BOOST,  # 火力提升 - 50% 持续15秒
	SPEED_BOOST,      # 速度提升 - 50% 持续15秒
	TIME_FREEZE,      # 时间冻结 - 敌人停止5秒
	HEALTH_RESTORE    # 耐久恢复 - 恢复50%耐久
}

@export var item_type: ItemType = ItemType.SHIELD
@export var icon_path: String = ""
@export var duration: float = 0.0  # 效果持续时间
@export var effect_value: float = 0.0  # 效果数值
