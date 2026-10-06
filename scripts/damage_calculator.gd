extends Node

## DamageCalculator 单例
## 伤害计算：实际伤害 = 炮弹伤害 × 100 / (100 + 防御)
## 护盾/无敌统一免疫：护盾激活或无敌期间完全免疫所有攻击
## 隐身装备强化提供闪避率：触发时同样不掉耐久，飘字显示"闪避"
## 命中单位时弹出浮动伤害数字（免疫/0 显示"免疫"），并通知血条刷新

const DamagePopupScript := preload("res://scripts/damage_popup.gd")

## 伤害数字颜色：伤害为亮黄，免疫/0 为灰蓝，闪避为浅绿
const DAMAGE_COLOR := Color(1.0, 0.84, 0.30)
const IMMUNE_COLOR := Color(0.62, 0.70, 0.82)
const DODGE_COLOR := Color(0.60, 0.95, 0.65)


## 计算实际伤害值
## @param attack_power: 攻击火力
## @param target_defense: 目标防御值
## @return: 实际伤害值
static func calculate_damage(attack_power: int, target_defense: int) -> int:
	if target_defense <= 0:
		return attack_power
	# 减伤率软上限 78%（承伤率下限 22%），防止高防御接近无敌
	var mult := maxf(100.0 / (100.0 + target_defense), 0.22)
	return max(1, int(round(attack_power * mult)))


## 应用伤害到目标，并触发浮动伤害数字与血条刷新。
## 三种护盾（道具/商店/能量）任一激活、或出生无敌时，完全免疫本次伤害。
## @param target: 目标节点
## @param attack_power: 攻击火力
## @return: 实际对耐久造成的伤害值（免疫时为 0）
static func apply_damage(target: Node, attack_power: int, armor_penetration: float = 0.0) -> int:
	# 护盾/无敌统一免疫：道具护盾、商店护盾、能量护盾、出生无敌。
	if target.has_method("is_damage_immune") and target.is_damage_immune():
		_notify_hit(target, true, 0)
		return 0

	# 闪避判定：隐身装备强化提供的闪避率（类似免疫，不掉耐久，飘字"闪避"）
	var dodge := 0.0
	if target.has_method("get_dodge_chance"):
		dodge = float(target.get_dodge_chance())
	elif "dodge_chance" in target:
		dodge = float(target.dodge_chance)
	if dodge > 0.0 and randf() < dodge:
		_notify_hit(target, true, 0, "闪避", DODGE_COLOR)
		return 0

	var defense = 0
	if target.has_method("get_defense"):
		defense = target.get_defense()
	elif "defense" in target:
		defense = target.defense

	# 穿甲：armor_penetration 比例伤害无视防御，其余走防御公式（精英/BOSS 0.2）
	var pen := clampf(armor_penetration, 0.0, 1.0)
	var hp_damage := calculate_damage(int(round(attack_power * (1.0 - pen))), defense) + int(round(attack_power * pen))
	if hp_damage <= 0:
		_notify_hit(target, true, 0)
		return 0

	# 扣耐久
	if target.has_method("take_damage"):
		target.take_damage(hp_damage)
	elif "current_hp" in target:
		target.current_hp -= hp_damage

	# 评级统计：玩家单位承受的实际耐久伤害（免疫 0 伤与维修回复都不经过此处）
	if target.is_in_group("player_tanks"):
		GameState.register_damage_taken(true, hp_damage)
	elif target is BasePlayer:
		GameState.register_damage_taken(false, hp_damage)

	_notify_hit(target, false, hp_damage)

	return hp_damage


## 通知目标刷新血条显示（敌方受击后显示 5 秒），并在头顶弹出浮动伤害数字。
## override_text/override_color：特殊状态（如"闪避"）用于覆盖默认文本与颜色。
static func _notify_hit(target: Node, is_immune: bool, hp_damage: int,
		override_text: String = "", override_color: Color = Color(0, 0, 0, 0)) -> void:
	# 血条：敌方受击后临时显示
	if target.has_method("_on_damaged"):
		target._on_damaged()

	# 浮动伤害数字
	var text := override_text if not override_text.is_empty() else ("免疫" if is_immune else str(hp_damage))
	var color := override_color if override_color.a > 0.0 else (IMMUNE_COLOR if is_immune else DAMAGE_COLOR)
	var parent := _get_world_parent(target)
	if parent == null:
		return
	var pos: Vector2 = target.global_position
	if target.has_method("get_head_world_position"):
		pos = target.get_head_world_position()
	DamagePopupScript.spawn_at(parent, pos, text, color)


## 伤害数字需挂到世界空间根（MapManager）下，否则会跟随目标移动。
static func _get_world_parent(target: Node) -> Node:
	var mm = GM.get_map_manager()
	if mm != null:
		return mm
	return target.get_parent()
