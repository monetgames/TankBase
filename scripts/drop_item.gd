class_name DropItem
extends Area2D

const PickupBurstEffectScript := preload("res://scripts/pickup_burst_effect.gd")

enum DropType {
	GOLD,
	MODULE,
	ITEM,
	EQUIPMENT,
	BLUEPRINT,
	BLACK_BOX
}

var drop_type: DropType
var amount: int = 0
var item_data = null       # ItemData（道具数据）
var equipment: Equipment = null  # 新装备数据
var blueprint: Blueprint = null  # 蓝图数据
var spawn_time: float = 0.0
var lifetime: float = 30.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var lifetime_timer: Timer = $LifetimeTimer

func _ready() -> void:
	# 掉落物在 layer 9（project.godot: 2d_physics/layer_9="drops"）
	collision_layer = 256  # 2^8 → layer 9
	# 只扫描 layer 1（tanks_player）：敌方坦克在 layer 2，连重叠检测都不进入，
	# 从根本上杜绝"敌方坦克拾取道具/金币/模组"
	collision_mask = 1
	# 层级：在水面/冰面/空地（z=0）之上，在草地（z=10）/坦克/基地（z=5）之下
	z_index = 2
	add_to_group("drops")
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	if lifetime_timer:
		lifetime_timer.timeout.connect(_on_lifetime_expired)
		lifetime_timer.start(lifetime)

	# 按掉落类型设置贴图
	_apply_sprite()

## 各掉落类型的贴图路径
const DROP_TEXTURES := {
	DropType.GOLD: "res://sprites/coin.png",
	DropType.MODULE: "res://sprites/module.png",
	DropType.BLACK_BOX: "res://sprites/black_box.png",
}

func _apply_sprite() -> void:
	var path: String = DROP_TEXTURES.get(drop_type, "")
	if drop_type == DropType.ITEM and item_data != null:
		path = item_data.icon_path
	if path != "" and sprite:
		sprite.texture = load(path)

func _on_body_entered(body: Node2D) -> void:
	if _is_player_tank(body):
		try_pickup(body)

func _on_area_entered(area: Area2D) -> void:
	if _is_player_tank(area):
		try_pickup(area)

## 只有玩家坦克能拾取掉落物：敌方坦克/基地一律不行。
## 双重保险——碰撞掩码只扫玩家层，这里再按类型和分组校验一次。
func _is_player_tank(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node is TankEnemy or node is BaseEnemy:
		return false
	if node is TankPlayer:
		return true
	return node.is_in_group("player_tanks") and not node.is_in_group("enemy_tanks")

func try_pickup(_player: Node) -> void:
	# 兜底：任何非玩家单位都不得触发拾取（金币/模组/道具/装备/蓝图/黑匣同理）
	if not _is_player_tank(_player):
		return
	var success = false
	match drop_type:
		DropType.GOLD:
			EconomySystem.add_resource("gold", amount)
			success = true
			print("拾取金币: %d" % amount)
		DropType.MODULE:
			EconomySystem.add_resource("module", amount)
			success = true
			print("拾取模组: %d" % amount)
		DropType.ITEM:
			if item_data and item_data.has_meta("ammo_type"):
				var player_tank = _player as TankPlayer
				if player_tank:
					var slot = TankPlayer.WeaponSlot.MINE if item_data.get_meta("ammo_type") == "mine" else TankPlayer.WeaponSlot.ROCKET
					player_tank.add_ammo(slot, int(item_data.get_meta("pickup_amount", 5)))
					success = true
			elif ItemSystem and item_data:
				success = ItemSystem.add_item(item_data)
				if success:
					print("Picked up item")
					# 新手指引：首次拾取效果类道具（非武器）→ 暂停并教数字键使用
					Tutorial.fire("combat_item")
				else:
					print("Item slots full")
					_show_toast("道具栏已满")
		DropType.EQUIPMENT:
			if EquipmentSystem and equipment:
				GameState.inventory.append(equipment)
				success = true
				print("拾取装备: %s" % equipment.get_display_name())
		DropType.BLUEPRINT:
			if blueprint:
				if GameState.add_blueprint(blueprint):
					GameState.stats_blueprints_earned.append(blueprint)
				success = true
				print("拾取蓝图: %s" % blueprint.get_display_name())
		DropType.BLACK_BOX:
			EconomySystem.add_resource("black_box", amount)
			GameState.stats_black_boxes_earned += amount
			success = true
			print("拾取黑匣: %d" % amount)
	if success:
		# 拾取粒子特效
		PickupBurstEffectScript.spawn_at(get_parent(), global_position, _pickup_color())
		# 拾取音效
		if AudioManager:
			AudioManager.play_sfx("pickup")
		queue_free()


## 按掉落类型返回拾取粒子颜色
func _pickup_color() -> Color:
	match drop_type:
		DropType.GOLD:
			return Color(1.0, 0.85, 0.3, 1.0)
		DropType.MODULE:
			return Color(0.55, 0.78, 1.0, 1.0)
		DropType.BLACK_BOX:
			return Color(0.78, 0.45, 1.0, 1.0)
		_:
			return Color(0.45, 1.0, 0.55, 1.0)

func _show_toast(message: String) -> void:
	for ui in get_tree().get_nodes_in_group("game_ui"):
		if ui.has_method("show_toast"):
			ui.show_toast(message)
			return

func _on_lifetime_expired() -> void:
	queue_free()
