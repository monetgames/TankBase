extends Control
## 波间商店（WaveShop）
## 每波结束后弹出，花金币购买战役内临时强化。
## 强化跨波次保留，战役结束时由 GameState.reset_campaign_resources() 清空。
## 挂载：game_manager 波间调用 open()，关闭后恢复波次间隔倒计时。
## UI 结构在 wave_shop.tscn 中可视化编辑（标题/注释/商品行/按钮），
## 本脚本只负责状态管理与刷新逻辑。

class_name WaveShop

# ===== 商店商品定义 =====
# 每个商品：id / 每档价格
# 名称与描述文案在场景对应 RowXxx 节点的 NameLabel / DescLabel 中编辑
const ITEMS: Array[Dictionary] = [
	{"id": "damage", "prices": [100, 200, 400]},
	{"id": "fire_rate", "prices": [100, 200, 400]},
	{"id": "move_speed", "prices": [80, 160, 320]},
	{"id": "repair", "prices": [150, 300]},
	{"id": "shield", "prices": [200, 400]},
]

# 商品 id -> 场景中商品行节点路径（行内固定子节点：BuyButton / LevelLabel / PriceLabel）
const ROW_PATHS: Dictionary = {
	"damage": "CenterContainer/PanelContainer/VBoxContainer/ItemsBox/RowDamage",
	"fire_rate": "CenterContainer/PanelContainer/VBoxContainer/ItemsBox/RowFireRate",
	"move_speed": "CenterContainer/PanelContainer/VBoxContainer/ItemsBox/RowMoveSpeed",
	"repair": "CenterContainer/PanelContainer/VBoxContainer/ItemsBox/RowRepair",
	"shield": "CenterContainer/PanelContainer/VBoxContainer/ItemsBox/RowShield",
}

# 商店护盾每档增加的能量护盾额度（当前能量与最大能量同时 +150，本次战役有效）
const SHIELD_ENERGY_PER_PURCHASE := 150.0

# ===== UI 节点引用 =====
@onready var _gold_label: Label = $CenterContainer/PanelContainer/VBoxContainer/GoldLabel
@onready var _continue_btn: Button = $CenterContainer/PanelContainer/VBoxContainer/ContinueButton
var _item_rows: Dictionary = {}  # item_id -> {btn, level_label, price_label}

# ===== 状态 =====

func _ready() -> void:
	# 关键：商店打开时游戏处于暂停态（get_tree().paused = true），
	# 必须能响应输入，否则按钮的 _gui_input 被暂停冻结、无法点击。
	# 用 ALWAYS 而不是 WHEN_PAUSED：WHEN_PAUSED 只在"已暂停"时处理，一旦暂停态被
	# 其它系统提前恢复（战斗内暂停式指引卡片关闭时会还原到卡片弹出前的暂停状态），
	# 整个商店会被冻结 —— 表现为"购买/继续战斗"全部点不动（偶现）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	# 场景默认可见便于编辑器直观预览；游戏中进入时先隐藏，待波间弹出时由 open() 显示
	visible = false
	# 收集场景中的商品行节点并连接购买按钮
	for item in ITEMS:
		var row := get_node(ROW_PATHS[item["id"]]) as HBoxContainer
		var btn := row.get_node("BuyButton") as Button
		btn.pressed.connect(func(): _on_buy(item))
		_item_rows[item["id"]] = {
			"btn": btn,
			"level_label": row.get_node("LevelLabel"),
			"price_label": row.get_node("PriceLabel"),
		}
	_continue_btn.pressed.connect(close)
	_refresh()


func _process(_delta: float) -> void:
	# 自愈：商店展示期间必须保持暂停。若暂停态被其它系统（如战斗内暂停式指引卡片
	# 关闭时还原暂停前状态）提前恢复，这里立刻重新暂停，避免商店按钮冻结或
	# 战场在购物期间继续跑。仅战斗循环中生效，返回主菜单等场景切换后不再干预。
	if not visible:
		return
	if GM.current_loop != GameManager.GameLoop.COMBAT:
		return
	if not get_tree().paused:
		get_tree().paused = true


## 打开商店（由 game_manager 波间调用；关卡/波次参数保留以兼容旧调用，当前无显示用途）
func open(_stage: int, _wave: int) -> void:
	visible = true
	# 暂停游戏，等待玩家购物
	get_tree().paused = true
	_refresh()
	# 购物期间暂停 BGM（仍在战斗循环，关闭时恢复）
	AudioManager.set_music_paused(true)
	# 新手指引：首次进入波间补给站（商店已暂停，指引卡片为非暂停式，不会恢复暂停态）
	Tutorial.fire("shop_wave")


## 关闭商店并恢复游戏
func close() -> void:
	visible = false
	get_tree().paused = false
	AudioManager.set_music_paused(false)
	# 通知 GameManager 继续波次流程
	if GM.has_method("on_shop_closed"):
		GM.on_shop_closed()


# ===== 逻辑 =====

## 获取某商品当前已购档位
func _get_level(item_id: String) -> int:
	match item_id:
		"damage":
			return int(round((GameState.shop_damage_multiplier - 1.0) * 10.0))
		"fire_rate":
			return int(round((GameState.shop_fire_rate_multiplier - 1.0) * 10.0))
		"move_speed":
			return int(round((GameState.shop_move_speed_multiplier - 1.0) * 10.0))
		"repair":
			return GameState.shop_repair_count
		"shield":
			return GameState.shop_shield_bought
	return 0


## 购买商品
func _on_buy(item: Dictionary) -> void:
	var level := _get_level(item["id"])
	var prices: Array = item["prices"]
	if level >= prices.size():
		return
	var cost: int = _get_price(item, level)
	if not EconomySystem.spend_resource("gold", cost):
		return

	match item["id"]:
		"damage":
			GameState.shop_damage_multiplier += 0.1
			_spawn_enhance_flash(Color(1.0, 0.55, 0.18))  # 橙红（火力）
		"fire_rate":
			GameState.shop_fire_rate_multiplier += 0.1
			_spawn_enhance_flash(Color(1.0, 0.84, 0.30))  # 金黄（射速）
		"move_speed":
			GameState.shop_move_speed_multiplier += 0.1
			_spawn_enhance_flash(Color(0.45, 1.0, 0.55))  # 绿色（机动）
		"repair":
			GameState.shop_repair_count += 1
			_heal_player_tank(0.5)
			_spawn_enhance_flash(Color(0.45, 1.0, 0.55))  # 绿色（维修）
		"shield":
			GameState.shop_shield_bought += 1
			GameState.shop_shield_energy += SHIELD_ENERGY_PER_PURCHASE
			_add_shop_shield_to_tanks(SHIELD_ENERGY_PER_PURCHASE)
			_spawn_enhance_flash(Color(0.38, 0.82, 1.0))  # 蓝色（护盾）

	# 刷新玩家坦克属性（让强化立即生效）
	_apply_buffs_to_tanks()
	_refresh()


## 获取商品当前档位价格；战场维修按"基地维修同样耐久 ×2"动态定价
func _get_price(item: Dictionary, level: int) -> int:
	if item["id"] == "repair":
		return _calc_repair_price()
	var prices: Array = item["prices"]
	return int(prices[level])


## 战场维修价格 = 恢复 50% 耐久所需基地维修金币的 2 倍
## 基地维修 100 HP 消耗 repair_cost_per_100hp 金币，恢复 max_hp × 50% 同耐久 × 2 即为本商品价格
func _calc_repair_price() -> int:
	var cost_per_100hp: int = int(ConfigLoader.base_config.get("repair_cost_per_100hp", 5))
	var tank := _get_first_player_tank()
	if tank == null or not ("max_hp" in tank):
		return 0
	var heal_amount: float = float(tank.max_hp) * 0.5
	var base_cost: float = heal_amount * cost_per_100hp / 100.0
	return max(1, int(base_cost * 2.0))


## 获取场上第一个玩家坦克（用于读取耐久计算维修价格）
func _get_first_player_tank() -> Node:
	var tanks = get_tree().get_nodes_in_group("player_tanks")
	if tanks.is_empty():
		return null
	return tanks[0]


## 将商店强化应用到场上玩家坦克
func _apply_buffs_to_tanks() -> void:
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if is_instance_valid(tank) and tank.has_method("_apply_shop_buffs"):
			# 先重算装备基准，再叠商店 buff
			tank._apply_all_equipped()


## 强化成功闪光：在玩家坦克头顶生成对应颜色的闪光
const BuffFlashEffectScript := preload("res://scripts/buff_flash_effect.gd")
func _spawn_enhance_flash(color: Color) -> void:
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if not is_instance_valid(tank):
			continue
		var pos: Vector2 = tank.global_position
		if tank.has_method("get_head_world_position"):
			pos = tank.get_head_world_position()
		BuffFlashEffectScript.spawn_at(tank.get_parent(), pos, color)


## 将商店护盾能量加成应用到场上玩家坦克（当前能量与最大能量同时增加）
func _add_shop_shield_to_tanks(x: float) -> void:
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		if is_instance_valid(tank) and tank.has_method("add_shop_shield_energy"):
			tank.add_shop_shield_energy(x)


## 治疗玩家坦克一定比例耐久
func _heal_player_tank(ratio: float) -> void:
	var tanks = get_tree().get_nodes_in_group("player_tanks")
	if tanks.is_empty():
		return
	var tank = tanks[0]
	if not is_instance_valid(tank):
		return
	var heal_amount: int = int(tank.max_hp * ratio)
	tank.current_hp = mini(tank.current_hp + heal_amount, tank.max_hp)
	print("WaveShop: 战场维修 +%d HP（当前 %d/%d）" % [heal_amount, tank.current_hp, tank.max_hp])


## 刷新商店显示
func _refresh() -> void:
	if _gold_label:
		_gold_label.text = "金币 %d" % GameState.gold

	for item in ITEMS:
		var row: Dictionary = _item_rows.get(item["id"], {})
		if row.is_empty():
			continue
		var level := _get_level(item["id"])
		var prices: Array = item["prices"]
		var btn: Button = row["btn"]
		var level_label: Label = row["level_label"]
		var price_label: Label = row["price_label"]

		level_label.text = "Lv.%d/%d" % [level, prices.size()]

		if level >= prices.size():
			btn.text = "已满"
			btn.disabled = true
			price_label.text = "——"
		else:
			var cost: int = _get_price(item, level)
			price_label.text = "%d 金币" % cost
			btn.text = "购买"
			btn.disabled = not EconomySystem.has_resource("gold", cost)
