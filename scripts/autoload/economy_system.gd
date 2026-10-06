extends Node

## EconomySystem 单例
## 管理资源和升级系统

## 信号
signal resource_gained(type: String, amount: int)
signal resource_spent(type: String, amount: int)
signal upgrade_purchased(upgrade_id: String, level: int)
signal upgrades_reset(refunded_black_boxes: int)
signal insufficient_resources(resource_type: String, required: int, current: int)


## 添加资源
## @param type: 资源类型（"black_box", "gold", "module"）
## @param amount: 数量
func add_resource(type: String, amount: int) -> void:
	match type:
		"black_box":
			GameState.black_boxes += amount
		"gold":
			GameState.gold += amount
		"module":
			GameState.modules += amount
		_:
			GameLog.warn("economy", "未知资源类型 type=%s" % type)
			return
	
	resource_gained.emit(type, amount)
	GameState.resource_changed.emit(type, _get_resource_amount(type))
	print("EconomySystem: 添加资源 %s +%d，当前 %d" % [type, amount, _get_resource_amount(type)])
	# 获得黑匣实时存档（读档/初始化期间由 _loading 守卫跳过；新游戏保护期由 request_save 跳过）
	if type == "black_box" and amount > 0 and SaveSystem != null and not SaveSystem.is_loading():
		SaveSystem.request_save()


## 消耗资源
## @param type: 资源类型（"black_box", "gold", "module"）
## @param amount: 数量
## @return: 是否成功消耗
func spend_resource(type: String, amount: int) -> bool:
	if not has_resource(type, amount):
		insufficient_resources.emit(type, amount, _get_resource_amount(type))
		return false
	
	match type:
		"black_box":
			GameState.black_boxes -= amount
		"gold":
			GameState.gold -= amount
		"module":
			GameState.modules -= amount
		_:
			GameLog.warn("economy", "未知资源类型 type=%s" % type)
			return false
	
	resource_spent.emit(type, amount)
	GameState.resource_changed.emit(type, _get_resource_amount(type))
	print("EconomySystem: 消耗资源 %s -%d，剩余 %d" % [type, amount, _get_resource_amount(type)])
	return true


## 检查资源是否足够
## @param type: 资源类型
## @param amount: 需要的数量
## @return: 是否足够
func has_resource(type: String, amount: int) -> bool:
	return _get_resource_amount(type) >= amount


## 执行升级
## @param upgrade_id: 升级 ID
## @return: 是否成功升级
func upgrade(upgrade_id: String) -> bool:
	# 从 ConfigLoader 获取升级配置
	if not ConfigLoader.upgrade_configs.has(upgrade_id):
		GameLog.error("economy", "升级 ID 不存在 id=%s" % upgrade_id)
		return false
	
	var config = ConfigLoader.upgrade_configs[upgrade_id]
	var current_level = GameState.upgrades.get(upgrade_id, 0)
	var max_level = config.get("max_level", 0)
	
	# 检查是否已达到最大等级
	if current_level >= max_level:
		push_warning("升级已达到最大等级: " + upgrade_id)
		return false
	
	# 获取升级费用
	var cost_per_level = config.get("cost_per_level", [])
	if current_level >= cost_per_level.size():
		GameLog.error("economy", "升级费用配置错误 id=%s level=%d" % [upgrade_id, current_level])
		return false
	
	var cost = cost_per_level[current_level]
	
	# 检查黑匣是否足够
	if not spend_resource("black_box", cost):
		return false
	
	# 升级成功
	GameState.upgrades[upgrade_id] = current_level + 1
	
	# 应用升级效果
	var effect = config.get("effect_per_level", 0.0)
	_apply_upgrade_effect(upgrade_id, effect)
	
	upgrade_purchased.emit(upgrade_id, current_level + 1)
	print("EconomySystem: 升级成功 %s -> 等级 %d" % [upgrade_id, current_level + 1])
	return true


## 应用升级效果
## @param upgrade_id: 升级 ID
## @param effect: 每级效果值（来自配置）
func _apply_upgrade_effect(upgrade_id: String, effect: float) -> void:
	match upgrade_id:
		"tank_health":
			# 提升坦克基础最大耐久（累加，每次升级增加 effect HP）
			GameState.base_tank_max_health += int(effect)
			GameState.attribute_changed.emit("tank", "max_health", GameState.base_tank_max_health)
		"tank_speed":
			# 提升坦克移动速度倍率（累加百分比）
			GameState.base_tank_speed_multiplier += effect
			GameState.attribute_changed.emit("tank", "speed_multiplier", GameState.base_tank_speed_multiplier)
		"turret_rotation_speed":
			# 提升炮台旋转速度倍率
			GameState.base_turret_rotation_multiplier += effect
			GameState.attribute_changed.emit("tank", "turret_rotation_multiplier", GameState.base_turret_rotation_multiplier)
		"base_health":
			# 提升基地基础最大耐久
			GameState.base_player_max_health += int(effect)
			GameState.attribute_changed.emit("base", "max_health", GameState.base_player_max_health)
		"base_repair_speed":
			# 提升基地维修速度基础值
			GameState.base_repair_speed_bonus += effect
			GameState.attribute_changed.emit("base", "repair_speed_bonus", GameState.base_repair_speed_bonus)
		"base_charge_speed":
			# 提升基地充能速度倍率
			GameState.base_charge_speed_multiplier += effect
			GameState.attribute_changed.emit("base", "charge_speed_multiplier", GameState.base_charge_speed_multiplier)
		"tactical_backpack_capacity":
			# 扩展战术背包容量
			GameState.tactical_backpack_capacity += int(effect)
		"initial_gold_bonus":
			# 初始金币通过 GameState.get_initial_campaign_gold() 按等级实时计算
			pass
		_:
			push_warning("未知升级 ID: " + upgrade_id)


## 重置全部黑匣升级并返还实际投入，永久蓝图和战术类型选择不重置。
## 背包容量降低后会保留最先选择的类型并移除溢出项。
func reset_all_upgrades() -> int:
	var refund := get_spent_black_boxes()
	for upgrade_id in ConfigLoader.upgrade_configs:
		var config = ConfigLoader.upgrade_configs[upgrade_id]
		if typeof(config) != TYPE_DICTIONARY:
			continue
		GameState.upgrades[upgrade_id] = 0
	GameState.recalculate_upgrade_bonuses()
	if refund > 0:
		add_resource("black_box", refund)
	upgrades_reset.emit(refund)
	print("EconomySystem: 已重置全部黑匣升级，返还 %d 黑匣" % refund)
	return refund


func get_spent_black_boxes() -> int:
	var spent := 0
	for upgrade_id in ConfigLoader.upgrade_configs:
		var config = ConfigLoader.upgrade_configs[upgrade_id]
		if typeof(config) != TYPE_DICTIONARY:
			continue
		var level := int(GameState.upgrades.get(upgrade_id, 0))
		var costs: Array = config.get("cost_per_level", [])
		for i in range(mini(level, costs.size())):
			spent += int(costs[i])
	return spent


## 获取资源数量
## @param type: 资源类型
## @return: 资源数量
func _get_resource_amount(type: String) -> int:
	match type:
		"black_box":
			return GameState.black_boxes
		"gold":
			return GameState.gold
		"module":
			return GameState.modules
	return 0
