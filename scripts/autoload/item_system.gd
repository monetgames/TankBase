extends Node
# ItemSystem autoload 单例：管理消耗品道具及其效果

const MAX_SLOTS = 6
const BuffFlashEffectScript := preload("res://scripts/buff_flash_effect.gd")

# 道具增益特效颜色映射
const BUFF_COLORS := {
	ItemData.ItemType.SHIELD: Color(0.38, 0.82, 1.0, 0.9),       # 蓝色（护盾）
	ItemData.ItemType.FIREPOWER_BOOST: Color(1.0, 0.55, 0.18, 0.9), # 橙红（增伤）
	ItemData.ItemType.SPEED_BOOST: Color(0.45, 1.0, 0.55, 0.9),   # 绿色（加速）
	ItemData.ItemType.TIME_FREEZE: Color(0.62, 0.70, 0.82, 0.9),  # 灰蓝（冻结）
	ItemData.ItemType.HEALTH_RESTORE: Color(1.0, 0.35, 0.45, 0.9), # 红色（恢复）
}

var active_effects: Dictionary = {}  # item_type -> Timer
signal inventory_changed

func add_item(item_data: ItemData) -> bool:
	if GameState.item_slots.size() >= MAX_SLOTS:
		return false  # 道具栏已满
	
	GameState.item_slots.append(item_data)
	inventory_changed.emit()
	return true

func use_item(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= GameState.item_slots.size():
		return false
	
	var item = GameState.item_slots[slot_index]
	apply_item_effect(item)
	
	# 从道具栏移除
	GameState.item_slots.remove_at(slot_index)
	inventory_changed.emit()
	return true

func apply_item_effect(item: ItemData) -> void:
	# 道具生效闪光
	_spawn_buff_flash(item.item_type)
	match item.item_type:
		ItemData.ItemType.SHIELD:
			apply_shield_effect(item.duration)
		ItemData.ItemType.FIREPOWER_BOOST:
			apply_firepower_boost(item.effect_value, item.duration)
		ItemData.ItemType.SPEED_BOOST:
			apply_speed_boost(item.effect_value, item.duration)
		ItemData.ItemType.TIME_FREEZE:
			apply_time_freeze(item.duration)
		ItemData.ItemType.HEALTH_RESTORE:
			apply_health_restore(item.effect_value)

func apply_shield_effect(duration: float) -> void:
	# 道具护盾：立即免疫 duration 秒，复用统一护盾机制与 shield_aura 特效
	var player = get_player_tank()
	if not player:
		return

	if player.has_method("grant_item_shield"):
		player.grant_item_shield(duration)

func apply_firepower_boost(multiplier: float, duration: float) -> void:
	var player = get_player_tank()
	if not player:
		return
	
	var original_firepower = player.firepower
	player.firepower = int(original_firepower * multiplier)
	
	var timer = create_effect_timer(duration)
	timer.timeout.connect(func(): 
		if is_instance_valid(player):
			player.firepower = original_firepower
	)
	active_effects[ItemData.ItemType.FIREPOWER_BOOST] = timer

func apply_speed_boost(multiplier: float, duration: float) -> void:
	var player = get_player_tank()
	if not player:
		return
	
	var original_speed = player.move_speed
	player.move_speed = original_speed * multiplier
	
	var timer = create_effect_timer(duration)
	timer.timeout.connect(func(): 
		if is_instance_valid(player):
			player.move_speed = original_speed
	)
	active_effects[ItemData.ItemType.SPEED_BOOST] = timer

func apply_time_freeze(duration: float) -> void:
	# 冻结所有敌方坦克
	var enemy_tanks = get_tree().get_nodes_in_group("enemy_tanks")
	for tank in enemy_tanks:
		if tank.has_method("set_frozen"):
			tank.set_frozen(true)
	
	var timer = create_effect_timer(duration)
	timer.timeout.connect(func():
		var tanks = get_tree().get_nodes_in_group("enemy_tanks")
		for tank in tanks:
			if is_instance_valid(tank) and tank.has_method("set_frozen"):
				tank.set_frozen(false)
	)
	active_effects[ItemData.ItemType.TIME_FREEZE] = timer

func apply_health_restore(restore_percent: float) -> void:
	var player = get_player_tank()
	if not player:
		return
	
	var restore_amount = int(player.max_hp * restore_percent)
	player.current_hp = min(player.current_hp + restore_amount, player.max_hp)

func create_effect_timer(duration: float) -> Timer:
	var timer = Timer.new()
	timer.wait_time = duration
	timer.one_shot = true
	add_child(timer)
	timer.start()
	return timer

func get_player_tank() -> Node:
	var players = get_tree().get_nodes_in_group("player_tanks")
	if players.size() > 0:
		return players[0]
	return null


## 在玩家坦克头顶生成道具增益闪光特效
func _spawn_buff_flash(item_type: int) -> void:
	var player = get_player_tank()
	if not player:
		return
	var color: Color = BUFF_COLORS.get(item_type, BuffFlashEffectScript.RING_COLOR)
	var pos: Vector2 = player.global_position
	if player.has_method("get_head_world_position"):
		pos = player.get_head_world_position()
	var parent = player.get_parent()
	BuffFlashEffectScript.spawn_at(parent, pos, color)
