extends Control

const UIFormatter = preload("res://scripts/ui_formatter.gd")

# UI组件引用
@onready var game_status_ui: PanelContainer = $MainContainer/GameTopUI/GameStatusUI
@onready var game_view: Control = $MainContainer/GameTopUI/GameViewFrame/GameView
@onready var game_props_ui: HBoxContainer = $BottomUI/Row/GamePropsUI
@onready var game_items_ui: HBoxContainer = $BottomUI/Row/GameItemsUI
@onready var game_enemy_status_ui: VBoxContainer = $MainContainer/RightUI/EnemyCard/GameEnemyStatusUI
@onready var game_player_base_status_ui: VBoxContainer = $MainContainer/RightUI/BaseCard/GamePlayerBaseStatusUI
@onready var game_player_tank_status_ui: VBoxContainer = $MainContainer/RightUI/TankCard/GamePlayerTankStatusUI
@onready var game_player_coins_status_ui: VBoxContainer = $MainContainer/RightUI/CoinsCard/GamePlayerCoinsStatusUI

# 敌方状态标签（直接引用 tscn 中的节点）
@onready var enemy_base_label: Label = $MainContainer/RightUI/EnemyCard/GameEnemyStatusUI/HBoxContainer/EnemyBaseNum
@onready var enemy_tank_label: Label = $MainContainer/RightUI/EnemyCard/GameEnemyStatusUI/HBoxContainer2/EnemyTankNum

# 状态标签
@onready var level_label: Label = $MainContainer/GameTopUI/GameStatusUI/Row/LevelLabel
@onready var time_label: Label = $MainContainer/GameTopUI/GameStatusUI/Row/TimeLabel

# 武器槽像素边框
const SLOT_TEX := preload("res://sprites/ui/ui_slot.png")
const SLOT_SELECTED_TEX := preload("res://sprites/ui/ui_slot_selected.png")
var _slot_style: StyleBoxTexture = null
var _slot_selected_style: StyleBoxTexture = null

# 游戏状态引用
var game_state: GameState = null

# UI 标签引用（用于动态更新）
var gold_label: Label = null
var modules_label: Label = null
var player_status_label: Label = null      # 坦克状态（耐久上方）
var player_health_label: Label = null
var player_shield_label: Label = null      # 坦克护盾（耐久下方）
var player_defense_label: Label = null
var player_firepower_label: Label = null
var player_mobility_label: Label = null
var base_status_label: Label = null        # 基地状态（耐久上方）
var base_health_label: Label = null
var base_energy_label: Label = null        # 基地能量站（耐久下方）
var base_defense_label: Label = null
var base_repair_label: Label = null

# 战斗 HUD：左侧武器、右侧可消耗道具。
var weapon_slot_textures: Array[TextureRect] = []
var item_slot_textures: Array[TextureRect] = []

func _ready() -> void:
	add_to_group("game_ui")
	# 构建武器槽九宫格样式
	_slot_style = _make_slot_style(SLOT_TEX)
	_slot_selected_style = _make_slot_style(SLOT_SELECTED_TEX)

	# 连接新的 GameState 信号
	GameState.resource_changed.connect(_on_resource_changed)
	ItemSystem.inventory_changed.connect(update_item_slots)
	
	# 连接 GameManager 信号
	GM.stage_changed.connect(_on_level_changed)
	GM.wave_changed.connect(_on_wave_changed)
	GM.sig_enemy_base_count_changed.connect(_on_enemy_base_count_changed)
	GM.sig_enemy_tank_count_changed.connect(_on_enemy_tank_count_changed)
	
	# 监听节点加入场景树，动态绑定玩家坦克/基地的信号
	get_tree().node_added.connect(_on_node_added)
	
	setup_props_slots()
	setup_status_displays()
	
	# 初始化显示
	update_all_ui()
	
	# 绑定已存在的玩家坦克和基地
	for tank in get_tree().get_nodes_in_group("player_tanks"):
		_bind_player_tank(tank)
	for base in GM.get_player_bases():
		_bind_player_base(base)

func _physics_process(_delta: float) -> void:
	# 时间显示无法信号化，用物理帧更新。
	# 口径与结算一致：GameState.stats_combat_seconds（玩家坦克可活动时间，
	# 不含暂停/商店/构筑循环），每次战役开始时由 reset_campaign_stats 归零。
	var total_seconds: int = int(GameState.stats_combat_seconds)
	var minutes: int = total_seconds / 60
	var seconds: int = total_seconds % 60
	time_label.text = "时间 %02d:%02d" % [minutes, seconds]
	# 状态、护盾、能量站随帧持续变化，逐帧刷新
	_update_dynamic_status_displays()

# ===== 设置窗口（ESC 唤起）=====

var _settings_menu: CanvasLayer = null


func _unhandled_input(event: InputEvent) -> void:
	# ESC 打开设置窗口（未暂停时才响应；打开中的 ESC 由 settings_menu 自己处理）
	if event.is_action_pressed("ui_cancel") and not get_tree().paused:
		_toggle_settings()
		get_viewport().set_input_as_handled()


## 打开/关闭设置窗口
func _toggle_settings() -> void:
	if _settings_menu == null:
		var scene: PackedScene = load("res://scenes/ui/settings_menu.tscn")
		if scene == null:
			push_error("GameUI: 无法加载设置窗口场景")
			return
		_settings_menu = scene.instantiate()
		add_child(_settings_menu)
	if _settings_menu.is_open():
		_settings_menu.close()
	else:
		_settings_menu.open()

## 屏幕提示（浮动文字，2 秒后自动消失）
func show_toast(message: String, color: Color = UIPalette.AMBER) -> void:
	var toast: Label = get_node_or_null("ToastLabel")
	if toast == null:
		return
	toast.text = message
	toast.add_theme_color_override("font_color", color)
	toast.visible = true
	# 2 秒后隐藏（异步计时，不阻塞主循环）
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(toast):
		toast.visible = false


## 获得新蓝图提示（蓝图名用对应稀有度颜色）
func show_blueprint_toast(blueprint: Blueprint) -> void:
	var color: Color = Equipment.get_rarity_color(blueprint.rarity)
	show_toast("获得新蓝图 %s" % blueprint.get_display_name(), color)

func _on_node_added(node: Node) -> void:
	# node_added 在 _ready 之前触发，用 call_deferred 延迟到 _ready 完成后再绑定
	if node is TankPlayer:
		call_deferred("_bind_player_tank", node)
	elif node is BaseParent and not (node is BaseEnemy):
		call_deferred("_bind_player_base", node)

func _bind_player_tank(tank: Node) -> void:
	if tank.has_signal("stats_changed") and not tank.stats_changed.is_connected(_on_tank_stats_changed):
		tank.stats_changed.connect(_on_tank_stats_changed)
	if tank.has_signal("weapon_slot_changed") and not tank.weapon_slot_changed.is_connected(_on_weapon_slot_changed):
		tank.weapon_slot_changed.connect(_on_weapon_slot_changed)
	# 立即刷新一次
	_on_player_attributes_changed()
	update_item_slots()

func _bind_player_base(base: Node) -> void:
	if base.has_signal("stats_changed") and not base.stats_changed.is_connected(_on_base_stats_changed):
		base.stats_changed.connect(_on_base_stats_changed)
	# 立即刷新一次
	_on_base_attributes_changed()

# ===== 信号处理器 =====

func _on_tank_stats_changed(cur_hp: int, max_hp: int, fp: int, def: int, spd: float) -> void:
	if player_health_label:
		player_health_label.text = "耐久 %d/%d" % [cur_hp, max_hp]
	if player_defense_label:
		player_defense_label.text = "防御 %d" % def
	if player_firepower_label:
		player_firepower_label.text = "火力 %d" % fp
	if player_mobility_label:
		player_mobility_label.text = "机动 %.0f" % spd

func _on_base_stats_changed(cur_hp: int, max_hp: int, def: int) -> void:
	if base_health_label:
		base_health_label.text = "耐久 %d/%d" % [cur_hp, max_hp]
	if base_defense_label:
		base_defense_label.text = "防御 %d" % def

func _on_weapon_slot_changed(_slot: int, _ammo: int) -> void:
	update_item_slots()

func _on_resource_changed(resource_type: String, amount: int) -> void:
	match resource_type:
		"gold":
			if gold_label:
				gold_label.text = "金币 %d" % amount
		"module":
			if modules_label:
				modules_label.text = "模组 %d" % amount

func _on_gold_changed(new_value: int) -> void:
	if gold_label:
		gold_label.text = "金币 %d" % new_value

func _on_modules_changed(new_value: int) -> void:
	if modules_label:
		modules_label.text = "模组 %d" % new_value

func _on_player_attributes_changed() -> void:
	# 从实际坦克节点读取属性
	var tanks = get_tree().get_nodes_in_group("player_tanks") if get_tree() else []
	if tanks.is_empty():
		return
	var tank = tanks[0]
	if player_health_label:
		# 直接访问属性而不是使用get()
		var current_hp = tank.current_hp if "current_hp" in tank else 0
		var max_hp = tank.max_hp if "max_hp" in tank else 0
		player_health_label.text = "耐久 %d/%d" % [int(current_hp), int(max_hp)]
	if player_defense_label:
		var defense = tank.defense if "defense" in tank else 0
		player_defense_label.text = "防御 %d" % int(defense)
	if player_firepower_label:
		var firepower = tank.firepower if "firepower" in tank else 0
		player_firepower_label.text = "火力 %d" % int(firepower)
	if player_mobility_label:
		var move_speed = tank.move_speed if "move_speed" in tank else 0.0
		player_mobility_label.text = "机动 %.0f" % float(move_speed)

func _on_base_attributes_changed() -> void:
	# 从实际基地节点读取属性
	var bases = GM.get_player_bases()
	if bases.is_empty():
		return
	var base = bases[0]
	if base_health_label:
		# 直接访问属性而不是使用get()
		var current_hp = base.current_hp if "current_hp" in base else 0
		var max_hp = base.max_hp if "max_hp" in base else 0
		base_health_label.text = "耐久 %d/%d" % [int(current_hp), int(max_hp)]
	if base_defense_label:
		var defense = base.defense if "defense" in base else 0
		base_defense_label.text = "防御 %d" % int(defense)
	if base_repair_label:
		base_repair_label.text = "维修效率 x1.0"


## 逐帧刷新坦克/基地的状态、护盾、能量站显示（数值持续变化，无法纯信号驱动）
func _update_dynamic_status_displays() -> void:
	_update_tank_dynamic_displays()
	_update_base_dynamic_displays()


func _update_tank_dynamic_displays() -> void:
	var tanks = get_tree().get_nodes_in_group("player_tanks") if get_tree() else []
	if tanks.is_empty():
		return
	var tank = tanks[0]
	if not is_instance_valid(tank):
		return
	# 状态
	if player_status_label:
		var status: String = tank.get_status_text() if tank.has_method("get_status_text") else "正常"
		player_status_label.text = "状态 %s" % status
	# 护盾（保留整数）
	if player_shield_label:
		var max_shield: float = tank.max_shield_energy if "max_shield_energy" in tank else 0.0
		var cur_shield: float = tank.shield_energy if "shield_energy" in tank else 0.0
		if max_shield > 0.0:
			player_shield_label.text = "护盾 %d/%d" % [int(cur_shield), int(max_shield)]
		else:
			player_shield_label.text = "护盾 无"


func _update_base_dynamic_displays() -> void:
	var bases = GM.get_player_bases()
	if bases.is_empty():
		return
	var base = bases[0]
	if not is_instance_valid(base) or not base.is_inside_tree():
		return
	# 状态
	if base_status_label:
		var status: String = base.get_status_text() if base.has_method("get_status_text") else "正常"
		base_status_label.text = "状态 %s" % status
	# 能量站（保留整数）
	if base_energy_label:
		var max_charge: float = base.max_charge_capacity if "max_charge_capacity" in base else 0.0
		var cur_charge: float = base.current_charge if "current_charge" in base else 0.0
		if max_charge > 0.0:
			base_energy_label.text = "能量站 %d/%d" % [int(cur_charge), int(max_charge)]
		else:
			base_energy_label.text = "能量站 无"


func _on_level_changed(new_value: int) -> void:
	level_label.text = "关卡%d/%d 波次%d/%d" % [new_value, ConfigLoader.max_stages, GM.current_wave, ConfigLoader.max_waves_per_stage]

func _on_wave_changed(new_value: int) -> void:
	level_label.text = "关卡%d/%d 波次%d/%d" % [GM.current_stage, ConfigLoader.max_stages, new_value, ConfigLoader.max_waves_per_stage]

func _on_enemy_base_count_changed(count: int) -> void:
	if enemy_base_label:
		enemy_base_label.text = "%d" % count

func _on_enemy_tank_count_changed(count: int) -> void:
	if enemy_tank_label:
		enemy_tank_label.text = "%d" % count

func _on_enemy_status_changed() -> void:
	update_enemy_status_display()

func _on_node_removed(node: Node) -> void:
	if node.is_in_group("enemy_tanks"):
		update_enemy_status_display()

# ===== UI 更新方法 =====

func update_all_ui() -> void:
	# 更新顶部状态栏
	level_label.text = "关卡%d/%d 波次%d/%d" % [GM.current_stage, ConfigLoader.max_stages, GM.current_wave, ConfigLoader.max_waves_per_stage]
	
	# 更新资源显示
	if gold_label:
		gold_label.text = "金币 %d" % GameState.gold
	if modules_label:
		modules_label.text = "模组 %d" % GameState.modules
	
	# 更新玩家属性
	_on_player_attributes_changed()
	_on_base_attributes_changed()
	
	# 更新武器和道具槽位
	update_item_slots()
	
	# 更新敌方状态
	update_enemy_status_display()

func update_enemy_status_display() -> void:
	var enemy_bases = GM.get_enemy_bases()
	var enemy_tanks = get_tree().get_nodes_in_group("enemy_tanks") if get_tree() else []
	if enemy_base_label:
		enemy_base_label.text = "%d" % enemy_bases.size()
	if enemy_tank_label:
		enemy_tank_label.text = "%d" % enemy_tanks.size()

func update_item_slots() -> void:
	# 武器位在左侧；可消耗道具位在右侧，数字键 1–6 对应道具位。
	var tanks = get_tree().get_nodes_in_group("player_tanks") if get_tree() else []
	if tanks.is_empty() or weapon_slot_textures.size() < 3 or item_slot_textures.size() < 6:
		return
	var tank = tanks[0]
	if not "current_weapon_slot" in tank:
		return
	
	# 武器槽名称
	var weapon_names = ["主炮", "地雷", "火箭"]
	for i in range(3):
		if i >= weapon_slot_textures.size():
			break
		var slot_node = weapon_slot_textures[i].get_parent()
		if slot_node == null:
			continue
		# 找到槽位下的标签
		var label = slot_node.get_node_or_null("WeaponLabel")
		if label == null:
			continue
		var ammo = tank.weapon_ammo.get(i, 0)
		var ammo_text = "∞" if ammo < 0 else str(ammo)
		label.text = "%s\n%s" % [weapon_names[i], ammo_text]
		# 高亮当前选中槽位（像素选中框 + 主题色文字）
		var is_selected: bool = tank.current_weapon_slot == i
		if slot_node is Panel and _slot_style and _slot_selected_style:
			slot_node.add_theme_stylebox_override("panel", _slot_selected_style if is_selected else _slot_style)
		label.add_theme_color_override("font_color", UIPalette.GREEN if is_selected else UIPalette.TEXT_MAIN)
	for i in range(6):
		var slot_node = item_slot_textures[i].get_parent()
		var label = slot_node.get_node_or_null("ItemLabel") as Label
		var icon = item_slot_textures[i]
		var item: ItemData = GameState.item_slots[i] if i < GameState.item_slots.size() else null
		if item:
			icon.texture = load(item.icon_path) if not item.icon_path.is_empty() else null
			icon.visible = icon.texture != null
			label.text = "%d\n%s" % [i + 1, _item_short_name(item)]
			label.tooltip_text = _item_display_name(item)
		else:
			icon.texture = null
			icon.visible = false
			label.text = "%d\n—" % [i + 1]
			label.tooltip_text = "空道具槽"

func _item_short_name(item: ItemData) -> String:
	return ["护盾", "火力", "加速", "冻结", "耐久"][item.item_type]

func _item_display_name(item: ItemData) -> String:
	return ["护盾（10秒无敌）", "火力强化", "速度强化", "时间冻结", "耐久恢复"][item.item_type]

func _make_slot_style(tex: Texture2D) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = tex
	style.texture_margin_left = 16.0
	style.texture_margin_top = 16.0
	style.texture_margin_right = 16.0
	style.texture_margin_bottom = 16.0
	style.content_margin_left = 2.0
	style.content_margin_top = 2.0
	style.content_margin_right = 2.0
	style.content_margin_bottom = 2.0
	return style

func setup_props_slots() -> void:
	# 清空现有槽位
	for child in game_props_ui.get_children():
		child.queue_free()
	for child in game_items_ui.get_children():
		child.queue_free()
	weapon_slot_textures.clear()
	item_slot_textures.clear()

	# 创建3个武器槽位（主炮/地雷/火箭）
	var weapon_names = ["主炮", "地雷", "火箭"]
	for i in range(3):
		var slot_panel = Panel.new()
		slot_panel.custom_minimum_size = Vector2(44, 44)
		if _slot_style:
			slot_panel.add_theme_stylebox_override("panel", _slot_style)

		var label = Label.new()
		label.name = "WeaponLabel"
		label.text = weapon_names[i] + "\n∞" if i == 0 else weapon_names[i] + "\n0"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
		slot_panel.add_child(label)

		# 用 TextureRect 占位（保持数组结构）
		var tex = TextureRect.new()
		tex.visible = false
		slot_panel.add_child(tex)

		game_props_ui.add_child(slot_panel)
		weapon_slot_textures.append(tex)

	# 再创建六个可消耗道具槽，快捷键与位置一一对应。
	for i in range(6):
		var slot_panel = Panel.new()
		slot_panel.custom_minimum_size = Vector2(44, 44)
		if _slot_style:
			slot_panel.add_theme_stylebox_override("panel", _slot_style)
		var tex = TextureRect.new()
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_panel.add_child(tex)
		var label = Label.new()
		label.name = "ItemLabel"
		label.text = "%d\n—" % [i + 1]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
		slot_panel.add_child(label)
		game_items_ui.add_child(slot_panel)
		item_slot_textures.append(tex)

func setup_status_displays() -> void:
	# 敌方状态显示
	setup_enemy_status()
	setup_player_base_status()
	setup_player_tank_status()
	setup_player_coins_status()

func setup_enemy_status() -> void:
	# 节点已在 game_ui.tscn 中定义，直接通过 @onready 引用，无需动态创建
	update_enemy_status_display()

func setup_player_base_status() -> void:
	# 清空现有内容
	for child in game_player_base_status_ui.get_children():
		child.queue_free()
	
	# 玩家基地状态
	var player_base_container = HBoxContainer.new()
	var base_icon = TextureRect.new()
	base_icon.texture = load("res://sprites/base_player.png")
	base_icon.custom_minimum_size = Vector2(16, 16)
	base_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	base_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	
	var base_title = Label.new()
	base_title.text = "基地"
	base_title.add_theme_color_override("font_color", UIPalette.GREEN_TEXT)
	
	player_base_container.add_child(base_icon)
	player_base_container.add_child(base_title)
	game_player_base_status_ui.add_child(player_base_container)
	
	# 创建属性标签并保存引用（状态在耐久上方，能量站在耐久下方）
	base_status_label = Label.new()
	base_status_label.text = "状态 正常"
	base_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	base_status_label.custom_minimum_size = Vector2(100, 0)
	game_player_base_status_ui.add_child(base_status_label)
	
	base_health_label = Label.new()
	base_health_label.text = "耐久 500"
	game_player_base_status_ui.add_child(base_health_label)
	
	base_energy_label = Label.new()
	base_energy_label.text = "能量站 无"
	game_player_base_status_ui.add_child(base_energy_label)
	
	base_defense_label = Label.new()
	base_defense_label.text = "防御 0"
	game_player_base_status_ui.add_child(base_defense_label)
	
	base_repair_label = Label.new()
	base_repair_label.text = UIFormatter.format_repair_efficiency(1.0)
	game_player_base_status_ui.add_child(base_repair_label)

func setup_player_tank_status() -> void:
	# 清空现有内容
	for child in game_player_tank_status_ui.get_children():
		child.queue_free()
	
	# 玩家坦克状态
	var player_tank_container = HBoxContainer.new()
	var tank_icon = TextureRect.new()
	tank_icon.texture = load("res://sprites/tank_player_icon.png")
	tank_icon.custom_minimum_size = Vector2(16, 16)
	tank_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	tank_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	
	var tank_title = Label.new()
	tank_title.text = "坦克"
	tank_title.add_theme_color_override("font_color", UIPalette.GREEN_TEXT)
	
	player_tank_container.add_child(tank_icon)
	player_tank_container.add_child(tank_title)
	game_player_tank_status_ui.add_child(player_tank_container)
	
	# 创建属性标签并保存引用（状态在耐久上方，护盾在耐久下方）
	player_status_label = Label.new()
	player_status_label.text = "状态 正常"
	player_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	player_status_label.custom_minimum_size = Vector2(100, 0)
	game_player_tank_status_ui.add_child(player_status_label)
	
	player_health_label = Label.new()
	player_health_label.text = "耐久 100"
	game_player_tank_status_ui.add_child(player_health_label)
	
	player_shield_label = Label.new()
	player_shield_label.text = "护盾 无"
	game_player_tank_status_ui.add_child(player_shield_label)
	
	player_defense_label = Label.new()
	player_defense_label.text = "防御 0"
	game_player_tank_status_ui.add_child(player_defense_label)
	
	player_firepower_label = Label.new()
	player_firepower_label.text = "火力 50"
	game_player_tank_status_ui.add_child(player_firepower_label)
	
	player_mobility_label = Label.new()
	player_mobility_label.text = "机动 50"
	game_player_tank_status_ui.add_child(player_mobility_label)

func setup_player_coins_status() -> void:
	# 清空现有内容
	for child in game_player_coins_status_ui.get_children():
		child.queue_free()
	
	# 补给卡片标题
	var coins_title := Label.new()
	coins_title.text = "补给"
	coins_title.add_theme_color_override("font_color", UIPalette.GREEN_TEXT)
	game_player_coins_status_ui.add_child(coins_title)

	# 创建金币和模组标签并保存引用
	gold_label = Label.new()
	gold_label.text = "金币 0"
	gold_label.add_theme_color_override("font_color", UIPalette.AMBER)
	game_player_coins_status_ui.add_child(gold_label)

	modules_label = Label.new()
	modules_label.text = "模组 0"
	modules_label.add_theme_color_override("font_color", UIPalette.TEAL)
	game_player_coins_status_ui.add_child(modules_label)
