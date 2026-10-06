# scripts/resources/enemy_data.gd
# 敌方单位数据模型 - 继承自 UnitData
# 用于敌方坦克和基地的数据存储，支持动态缩放
# 复用 tank_enemy.gd 和 base_enemy.gd 中的逻辑
class_name EnemyData
extends UnitData

# ============================================================================
# 敌方等级枚举
# ============================================================================

## 敌方单位等级
enum Level {
	NORMAL,  ## 普通
	ELITE,   ## 精英
	BOSS     ## BOSS
}

# ============================================================================
# 敌方特有属性
# ============================================================================

## 敌方等级
@export var level: Level = Level.NORMAL

## 探测范围（单位：格）
@export var detect_range: float = 8.0

## 开火范围（单位：格）
@export var fire_range: float = 6.0

## AI 智能度（0.0-1.0，越高越智能）
@export var ai_intelligence: float = 0.8

# ============================================================================
# 方法
# ============================================================================

## 应用动态缩放
## 根据关卡和波次动态调整敌方单位属性
## 缩放公式：属性 = 基础值 × (1.08)^(全局关卡-1) × (1.03)^(波次-1)
## @param stage: 全局关卡（1-30）
## @param wave: 当前波次（1-3）
func apply_scaling(stage: int, wave: int) -> void:
	# 计算关卡缩放系数
	var stage_multiplier = pow(1.08, stage - 1)
	
	# 计算波次缩放系数
	var wave_multiplier = pow(1.03, wave - 1)
	
	# 总缩放系数
	var total_multiplier = stage_multiplier * wave_multiplier
	
	# 应用缩放到各项属性
	max_health *= total_multiplier
	current_health = max_health  # 重置当前耐久为最大值
	shell_damage *= total_multiplier
	defense *= total_multiplier
