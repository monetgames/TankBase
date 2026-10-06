# scripts/resources/unit_data.gd
# 单位数据模型 - 用于坦克和基地的数据存储
# 复用 tank_parent.gd 和 base_parent.gd 中的逻辑
class_name UnitData
extends Resource

# ============================================================================
# 基础属性
# ============================================================================

## 最大耐久值
@export var max_health: float = 1000.0

## 当前耐久值
@export var current_health: float = 1000.0

## 防御值（用于伤害计算）
@export var defense: float = 0.0

## 当前护盾能量
@export var shield_energy: float = 0.0

## 最大护盾能量
@export var max_shield_energy: float = 0.0

# ============================================================================
# 坦克属性
# ============================================================================

## 炮弹伤害
@export var shell_damage: float = 50.0

## 射程（单位：格）
@export var shell_range: float = 6.0

## 炮弹速度（单位：u/s）
@export var shell_speed: float = 8.0

## 射击冷却时间（单位：秒）
@export var shoot_cooldown: float = 1.0

## 移动速度（单位：u/s）
@export var move_speed: float = 3.0

## 炮台旋转速度（单位：度/秒）
@export var turret_rotation_speed: float = 90.0

# ============================================================================
# 基地属性
# ============================================================================

## 维修速度（单位：HP/秒）
@export var repair_speed: float = 0.0

## 维修折扣（0.0-1.0，表示折扣百分比）
@export var repair_discount: float = 0.0

## 充能速度（单位：能量/秒）
@export var charge_speed: float = 20.0

## 最大充能量（单次战斗循环内的充能上限）
@export var max_charge_capacity: float = 0.0

# ============================================================================
# 方法
# ============================================================================

## 应用伤害到单位
## 伤害优先扣除护盾能量，护盾耗尽后扣除耐久值
## 使用 DamageCalculator 计算实际伤害（考虑防御值）
## @param damage: 原始伤害值
## @return: 实际造成的伤害值（扣除防御后）
func apply_damage(damage: float) -> float:
	# 使用 DamageCalculator 计算实际伤害（考虑防御值）
	# 注意：DamageCalculator.calculate_damage 接受 int 参数
	var actual_damage = DamageCalculator.calculate_damage(int(damage), int(defense))
	var remaining_damage = float(actual_damage)
	
	# 护盾优先承受伤害
	if shield_energy > 0:
		var shield_absorbed = min(shield_energy, remaining_damage)
		shield_energy -= shield_absorbed
		remaining_damage -= shield_absorbed
	
	# 剩余伤害扣除耐久值
	if remaining_damage > 0:
		current_health -= remaining_damage
	
	return float(actual_damage)

## 判断单位是否存活
## @return: 如果当前耐久值大于 0 则返回 true，否则返回 false
func is_alive() -> bool:
	return current_health > 0
