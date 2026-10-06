extends Control

## Meta 循环界面
## 提供黑匣升级和战术背包配置功能

# ===== 节点引用 =====
@onready var black_box_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/BlackBoxLabel
@onready var initial_gold_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/InitialGoldLabel
@onready var equipment_card_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/EquipmentCardLabel
@onready var reset_upgrades_button: Button = $MarginContainer/VBoxContainer/TopBar/Row/ResetUpgradesButton
@onready var upgrade_list: VBoxContainer = $MarginContainer/VBoxContainer/MainContent/UpgradeCard/UpgradePanel/ScrollContainer/UpgradeList
@onready var backpack_grid: GridContainer = $MarginContainer/VBoxContainer/MainContent/RightCol/BackpackCard/BackpackPanel/BackpackGrid
@onready var blueprint_list: VBoxContainer = $MarginContainer/VBoxContainer/MainContent/RightCol/BlueprintCard/BlueprintPanel/ScrollContainer/BlueprintList
@onready var start_button: Button = $MarginContainer/VBoxContainer/BottomBar/Row/StartCampaignButton

# 背包槽像素边框
const SLOT_TEX := preload("res://sprites/ui/ui_slot.png")
var _slot_style: StyleBoxTexture = null

## 升级按钮统一尺寸（实测值，字体/主题固定故写死）：
## 宽 74 = 最长文案"（9黑匣）"渲染宽 54px + 按钮内边距 20px；
## 高 40 = 标准行（含"当前效果"行）高度。0 级行缺少该行、行高仅 34，固定高度后各行按钮一致
const UPGRADE_BUTTON_WIDTH := 74.0
const UPGRADE_BUTTON_HEIGHT := 40.0

# ===== 升级配置（从 ConfigLoader 加载）=====
var _upgrade_items: Array[Dictionary] = []

# ===== 浮窗（tooltip，复用构筑循环样式）=====
const _TIP_WIDTH := 236.0
var _tooltip_layer: CanvasLayer = null
var _tooltip_panel: PanelContainer = null
var _tooltip_content: VBoxContainer = null


# ===== 设置窗口（ESC 唤起）=====
const SettingsMenuScene := preload("res://scenes/ui/settings_menu.tscn")
var _settings_menu: CanvasLayer = null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not get_tree().paused:
		_toggle_settings()
		get_viewport().set_input_as_handled()


func _toggle_settings() -> void:
	if _settings_menu == null:
		_settings_menu = SettingsMenuScene.instantiate()
		add_child(_settings_menu)
	if _settings_menu.is_open():
		_settings_menu.close()
	else:
		_settings_menu.open()


func _ready() -> void:
	# 构建背包槽九宫格样式
	_slot_style = StyleBoxTexture.new()
	_slot_style.texture = SLOT_TEX
	_slot_style.texture_margin_left = 16.0
	_slot_style.texture_margin_top = 16.0
	_slot_style.texture_margin_right = 16.0
	_slot_style.texture_margin_bottom = 16.0

	# 连接信号
	EconomySystem.resource_gained.connect(_on_resource_changed)
	EconomySystem.resource_spent.connect(_on_resource_changed)
	EconomySystem.upgrade_purchased.connect(_on_upgrade_purchased)
	EconomySystem.upgrades_reset.connect(_on_upgrades_reset)
	start_button.pressed.connect(_on_start_button_pressed)
	reset_upgrades_button.pressed.connect(_on_reset_upgrades_pressed)

	# 初始化界面
	_setup_tooltip()
	_refresh_resource_display()
	_build_upgrade_list()
	_build_backpack_grid()
	_refresh_blueprint_list()

	# 新手指引：指挥部三连（概念 / 背包+抢修机 / 开始战役）；
	# 战役结算返回时按条件补"黑匣使用"与"新蓝图入包"。
	# 卡片可见期间锁定「开始战役」，全部点完（或关闭指引）后解锁，防止连点跳进构筑循环
	Tutorial.showing_changed.connect(_on_tutorial_showing_changed)
	Tutorial.fire("meta_intro")
	Tutorial.fire("meta_backpack")
	Tutorial.fire("meta_start")
	if Tutorial.consume_campaign_finished():
		if GameState.black_boxes > 0:
			Tutorial.fire("meta_blackbox")
		if Tutorial.has_new_blueprints():
			Tutorial.fire("meta_newblueprint")
	_on_tutorial_showing_changed(Tutorial.is_showing())


## 指引卡片显示期间锁定「开始战役」
func _on_tutorial_showing_changed(showing: bool) -> void:
	start_button.disabled = showing


# ===== 资源显示 =====

func _refresh_resource_display() -> void:
	black_box_label.text = "黑匣：%d" % GameState.black_boxes
	initial_gold_label.text = "初始金币：%d" % GameState.get_initial_campaign_gold()
	if GameState.equipment_cards_remaining > 0:
		equipment_card_label.text = "装备卡：%d/%d" % [GameState.equipment_cards_remaining, GameState.get_equipment_card_capacity()]
	else:
		equipment_card_label.text = "装备卡：%d" % GameState.get_equipment_card_capacity()
	reset_upgrades_button.disabled = EconomySystem.get_spent_black_boxes() <= 0


func _on_resource_changed(_type: String, _amount: int) -> void:
	_refresh_resource_display()


# ===== 升级列表 =====

func _build_upgrade_list() -> void:
	# 清空列表（remove_child 立即脱离场景树，避免重建后 UpgradeRow_x 同名冲突）
	for child in upgrade_list.get_children():
		upgrade_list.remove_child(child)
		child.queue_free()
	
	# 从配置加载升级项
	var configs = ConfigLoader.upgrade_configs
	if configs.is_empty():
		_add_upgrade_item_default()
		return
	
	for upgrade_id in configs:
		var config = configs[upgrade_id]
		# 跳过注释键（值不是字典的条目）
		if typeof(config) != TYPE_DICTIONARY:
			continue
		_add_upgrade_item(upgrade_id, config)


func _add_upgrade_item(upgrade_id: String, config: Dictionary) -> void:
	var current_level = GameState.upgrades.get(upgrade_id, 0)
	var max_level = config.get("max_level", 1)
	var cost_list = config.get("cost_per_level", [1])
	var cost = cost_list[current_level] if current_level < cost_list.size() else 0
	var name_cn = config.get("name", config.get("name_cn", upgrade_id))
	var desc = config.get("description", "")
	var effect = config.get("effect_per_level", 0.0)
	var is_maxed = current_level >= max_level
	
	# 外层容器（带背景）
	var panel = PanelContainer.new()
	panel.name = "UpgradeRow_" + upgrade_id
	
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	
	# 左侧：名称 + 描述 + 当前效果（垂直居中：0 级行缺"当前效果"行时，文字块与标准行居中对齐）
	var info_vbox = VBoxContainer.new()
	info_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vbox.add_theme_constant_override("separation", 2)
	row.add_child(info_vbox)
	
	var name_label = Label.new()
	name_label.text = name_cn
	name_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	info_vbox.add_child(name_label)

	var desc_label = Label.new()
	desc_label.text = desc
	desc_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	desc_label.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_vbox.add_child(desc_label)

	# 当前效果值
	if current_level > 0:
		var current_effect_label = Label.new()
		var total_effect = effect * current_level
		current_effect_label.text = "当前效果：+%s" % _format_effect(upgrade_id, total_effect)
		current_effect_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
		current_effect_label.add_theme_color_override("font_color", UIPalette.GREEN)
		info_vbox.add_child(current_effect_label)
	
	# 中间：等级进度
	var level_vbox = VBoxContainer.new()
	level_vbox.custom_minimum_size = Vector2(70, 0)
	level_vbox.add_theme_constant_override("separation", 4)
	row.add_child(level_vbox)
	
	var level_label = Label.new()
	level_label.text = "%d / %d 级" % [current_level, max_level]
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	if is_maxed:
		level_label.add_theme_color_override("font_color", UIPalette.AMBER)
	level_vbox.add_child(level_label)
	
	var progress = ProgressBar.new()
	progress.min_value = 0
	progress.max_value = max_level
	progress.value = current_level
	progress.custom_minimum_size = Vector2(70, 12)
	progress.show_percentage = false
	level_vbox.add_child(progress)
	
	# 右侧：升级按钮（统一尺寸，保证各行按钮纵向对齐）
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(UPGRADE_BUTTON_WIDTH, UPGRADE_BUTTON_HEIGHT)
	if is_maxed:
		btn.text = "已满级"
		btn.disabled = true
	else:
		var can_afford = EconomySystem.has_resource("black_box", cost)
		btn.text = "升级\n（%d黑匣）" % cost
		btn.disabled = not can_afford
	btn.pressed.connect(func(): _on_upgrade_pressed(upgrade_id))
	row.add_child(btn)
	
	upgrade_list.add_child(panel)


## 配置文件缺失时显示占位提示
func _add_upgrade_item_default() -> void:
	var label = Label.new()
	label.text = "（升级配置加载中...）"
	upgrade_list.add_child(label)


func _on_upgrade_pressed(upgrade_id: String) -> void:
	EconomySystem.upgrade(upgrade_id)


## 格式化升级效果值为可读字符串
func _format_effect(upgrade_id: String, value: float) -> String:
	match upgrade_id:
		"tank_health":
			return "%d HP" % int(value)
		"tank_speed":
			return "%.1f u/s" % value
		"turret_rotation_speed":
			return "%d°/s" % int(value)
		"base_health":
			return "%d HP" % int(value)
		"base_repair_speed":
			return "%.0f HP/s" % value
		"base_charge_speed":
			return "%d 能量/s" % int(value)
		"tactical_backpack_capacity":
			return "%d 格" % int(value)
		"initial_gold_bonus":
			return "%d 金币" % int(value)
	return "%.1f" % value


func _on_upgrade_purchased(_upgrade_id: String, _level: int) -> void:
	# 刷新升级列表以更新等级显示
	_build_upgrade_list()
	_refresh_resource_display()
	# 背包容量升级后立即新增槽位，并刷新可放入蓝图的按钮状态。
	if _upgrade_id == "tactical_backpack_capacity":
		_build_backpack_grid()
		_refresh_blueprint_list()


func _on_reset_upgrades_pressed() -> void:
	EconomySystem.reset_all_upgrades()
	SaveSystem.save_game()


func _on_upgrades_reset(_refunded_black_boxes: int) -> void:
	_build_upgrade_list()
	_build_backpack_grid()
	_refresh_blueprint_list()
	_refresh_resource_display()


# ===== 战术背包 =====

func _build_backpack_grid() -> void:
	# 清空背包格子（remove_child 立即脱离场景树，避免重建后 BackpackSlot_x 同名冲突导致刷新失败）
	for child in backpack_grid.get_children():
		backpack_grid.remove_child(child)
		child.queue_free()
	
	var capacity = GameState.tactical_backpack_capacity
	backpack_grid.columns = mini(capacity, 3)
	
	for i in range(capacity):
		var slot = _create_backpack_slot(i)
		backpack_grid.add_child(slot)
	
	_refresh_backpack_display()


func _create_backpack_slot(index: int) -> Panel:
	var panel = Panel.new()
	# 卡片高 40px 可容纳两行字
	panel.custom_minimum_size = Vector2(85, 40)
	panel.name = "BackpackSlot_%d" % index
	if _slot_style:
		panel.add_theme_stylebox_override("panel", _slot_style)

	var label = Label.new()
	label.name = "SlotLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.clip_text = true
	panel.add_child(label)
	
	# 点击槽位移除蓝图
	var btn = Button.new()
	btn.flat = true
	btn.name = "SlotButton"
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.pressed.connect(func(): _on_backpack_slot_pressed(index))
	panel.add_child(btn)
	
	return panel


func _refresh_backpack_display() -> void:
	var capacity = GameState.tactical_backpack_capacity
	for i in range(capacity):
		var slot = backpack_grid.get_node_or_null("BackpackSlot_%d" % i)
		if slot == null:
			continue
		var label = slot.get_node_or_null("SlotLabel")
		if label == null:
			continue

		# 空槽无交互，标记按钮静音（见 AudioManager 全局按钮音效）
		var btn: Button = slot.get_node_or_null("SlotButton")

		if i < GameState.tactical_backpack.size():
			var equipment_type: int = GameState.tactical_backpack[i]
			var rarity := GameState.get_research_level(equipment_type)
			label.text = "%s 蓝图" % Equipment.get_type_name(equipment_type)
			label.add_theme_color_override("font_color", _get_rarity_color(rarity))
			if btn != null:
				btn.remove_meta("no_button_sfx")
		else:
			label.text = "空"
			label.add_theme_color_override("font_color", UIPalette.TEXT_MAIN)
			if btn != null:
				btn.set_meta("no_button_sfx", true)


func _on_backpack_slot_pressed(index: int) -> void:
	if index < GameState.tactical_backpack.size():
		# 将蓝图移回蓝图列表
		GameState.tactical_backpack.remove_at(index)
		_refresh_backpack_display()
		_refresh_blueprint_list()


## 根据稀有度返回对应字体颜色（白/蓝/紫/粉/金，统一委托 Equipment 静态方法）
func _get_rarity_color(rarity: Equipment.Rarity) -> Color:
	return Equipment.get_rarity_color(rarity)


# ===== 蓝图列表 =====

func _refresh_blueprint_list() -> void:
	# 先立即摘除再延迟释放，避免新旧行共存一帧造成内容高度瞬时翻倍
	for child in blueprint_list.get_children():
		blueprint_list.remove_child(child)
		child.queue_free()
	
	# 每种装备只显示一条最高研究等级记录
	var sorted_blueprints: Array[Blueprint] = GameState.blueprints.duplicate()
	sorted_blueprints.sort_custom(func(a: Blueprint, b: Blueprint) -> bool:
		return int(a.equipment_type) < int(b.equipment_type))
	
	for bp in sorted_blueprints:
		_add_blueprint_item(bp)
	
	if blueprint_list.get_child_count() == 0:
		var label = Label.new()
		label.text = "（暂无蓝图）"
		blueprint_list.add_child(label)


func _add_blueprint_item(bp: Blueprint) -> void:
	var row = HBoxContainer.new()

	var label = Label.new()
	label.text = "%s 蓝图" % [Equipment.get_type_name(bp.equipment_type)]
	label.add_theme_color_override("font_color", _get_rarity_color(bp.rarity))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Label 默认忽略鼠标，需显式接收才能触发 hover 浮窗
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_entered.connect(func(): _show_blueprint_tooltip(bp))
	label.mouse_exited.connect(_hide_tooltip)
	row.add_child(label)
	
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(80,0)
	var equipment_type := int(bp.equipment_type)
	if GameState.CORE_EQUIPMENT_TYPES.has(equipment_type):
		btn.text = "必装"
		btn.disabled = true
	elif GameState.tactical_backpack.has(equipment_type):
		btn.text = "已装入"
		btn.disabled = true
	else:
		btn.text = "放入背包"
		btn.disabled = GameState.tactical_backpack.size() >= GameState.tactical_backpack_capacity
		btn.pressed.connect(func(): _on_add_to_backpack(equipment_type))
	row.add_child(btn)
	
	blueprint_list.add_child(row)


func _on_add_to_backpack(equipment_type: int) -> void:
	if GameState.add_to_backpack(equipment_type):
		_refresh_backpack_display()
		_refresh_blueprint_list()


# ===== 蓝图浮窗 =====

## 蓝图名称 hover 浮窗：两行说明（宽度自适应内容）
func _show_blueprint_tooltip(bp: Blueprint) -> void:
	var rarity_name := Equipment.get_rarity_name(bp.rarity)
	var rarity_color := Equipment.get_rarity_color(bp.rarity)
	var type_name := Equipment.get_type_name(bp.equipment_type)
	var build := func(box: VBoxContainer) -> void:
		# 第一行：最高制造紫装「主炮（紫）」（装备名按稀有度着色）
		var line1 := HBoxContainer.new()
		line1.add_child(_tip_label("最高制造%s装「" % rarity_name, UIPalette.TEXT_MAIN, UIPalette.FONT_S, false))
		line1.add_child(_tip_label("%s（%s）」" % [type_name, rarity_name], rarity_color, UIPalette.FONT_S, false))
		box.add_child(line1)
		# 第二行：装备功能描述
		box.add_child(_tip_label(Equipment.get_type_desc(bp.equipment_type), UIPalette.TEXT_MAIN, UIPalette.FONT_S, false))
	_show_tooltip(build, 0.0)


# ===== 浮窗（tooltip）系统（与构筑循环同款样式）=====

func _setup_tooltip() -> void:
	_tooltip_layer = CanvasLayer.new()
	_tooltip_layer.layer = 100
	add_child(_tooltip_layer)
	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.visible = false
	_tooltip_panel.z_index = 100
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = UIPalette.BG_PANEL
	style.border_color = UIPalette.BORDER_HI
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 10.0
	style.content_margin_top = 8.0
	style.content_margin_right = 10.0
	style.content_margin_bottom = 8.0
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	style.shadow_size = 5
	style.shadow_offset = Vector2(0.0, 2.0)
	_tooltip_panel.add_theme_stylebox_override("panel", style)
	_tooltip_content = VBoxContainer.new()
	_tooltip_content.add_theme_constant_override("separation", 5)
	# 关键：给定内容最小宽度，避免中文 autowrap 时收缩成单字竖排
	_tooltip_content.custom_minimum_size.x = _TIP_WIDTH
	_tooltip_panel.add_child(_tooltip_content)
	_tooltip_layer.add_child(_tooltip_panel)


func _process(_delta: float) -> void:
	if _tooltip_panel != null and _tooltip_panel.visible:
		_update_tooltip_position()


func _update_tooltip_position() -> void:
	var mouse := get_global_mouse_position()
	var pos := mouse + Vector2(18, 14)
	var vp := get_viewport_rect().size
	_tooltip_panel.reset_size()
	var ts := _tooltip_panel.size
	if pos.x + ts.x > vp.x:
		pos.x = mouse.x - ts.x - 10.0
	if pos.y + ts.y > vp.y:
		pos.y = mouse.y - ts.y - 10.0
	_tooltip_panel.global_position = pos


func _show_tooltip(build: Callable, min_width: float = _TIP_WIDTH) -> void:
	for c in _tooltip_content.get_children():
		c.queue_free()
	_tooltip_content.custom_minimum_size.x = min_width
	build.call(_tooltip_content)
	_tooltip_panel.visible = true
	_update_tooltip_position()


func _hide_tooltip() -> void:
	if _tooltip_panel != null:
		_tooltip_panel.visible = false


func _tip_label(text: String, color: Color = UIPalette.TEXT_MAIN, font_size: int = UIPalette.FONT_S, autowrap: bool = true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", font_size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if autowrap else TextServer.AUTOWRAP_OFF
	return l


# ===== 开始战役 =====

func _on_start_button_pressed() -> void:
	# 保存游戏
	SaveSystem.save_game()
	print("MetaLoop: 开始新战役")
	GM.start_new_campaign()
