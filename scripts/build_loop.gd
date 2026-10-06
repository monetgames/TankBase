extends Control

## 构筑循环界面
## 提供装备制造、强化、装配和维修功能

# ===== 节点引用 =====
@onready var gold_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/GoldLabel
@onready var module_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/ModuleLabel
@onready var equipment_card_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/EquipmentCardLabel
@onready var stage_label: Label = $MarginContainer/VBoxContainer/TopBar/Row/StageLabel
@onready var blueprint_list: VBoxContainer = $MarginContainer/VBoxContainer/MainContent/LeftCol/CraftCard/CraftPanel/ScrollContainer/BlueprintList
@onready var inventory_list: VBoxContainer = $MarginContainer/VBoxContainer/MainContent/LeftCol/EnhanceCard/EnhancePanel/ScrollContainer/InventoryList
@onready var equipment_panel: PanelContainer = $MarginContainer/VBoxContainer/MainContent/RightCol/EquipCard/EquipmentPanel
@onready var tank_hp_bar: ProgressBar = $MarginContainer/VBoxContainer/MainContent/RightCol/RepairCard/RepairPanel/TankHPBar
@onready var base_hp_bar: ProgressBar = $MarginContainer/VBoxContainer/MainContent/RightCol/RepairCard/RepairPanel/BaseHPBar
@onready var repair_tank_btn: Button = $MarginContainer/VBoxContainer/MainContent/RightCol/RepairCard/RepairPanel/RepairTankButton
@onready var repair_base_btn: Button = $MarginContainer/VBoxContainer/MainContent/RightCol/RepairCard/RepairPanel/RepairBaseButton
@onready var enter_combat_btn: Button = $MarginContainer/VBoxContainer/BottomBar/Row/EnterCombatButton
@onready var return_meta_btn: Button = $MarginContainer/VBoxContainer/BottomBar/Row/ReturnMetaButton
## 通用二次确认弹窗（与新手引导卡片同款样式，模态冻结背景）
const ConfirmDialogScript := preload("res://scripts/ui/confirm_dialog.gd")
var _confirm_dialog: CanvasLayer = null

# ===== 装备图标 / 稀有度 / 用途映射 =====
const EQUIP_TYPE_ICON := {
	Equipment.Type.ENGINE: "engine",
	Equipment.Type.BEARING: "bearing",
	Equipment.Type.MAIN_GUN: "main_gun",
	Equipment.Type.SHELL: "shell",
	Equipment.Type.ARMOR: "armor",
	Equipment.Type.SHIELD: "shield",
	Equipment.Type.DIVING: "diving",
	Equipment.Type.STEALTH: "stealth",
	Equipment.Type.RADAR: "radar",
	Equipment.Type.EMP: "emp",
	Equipment.Type.BARRIER: "barrier",
	Equipment.Type.REPAIR_MACHINE: "repair_machine",
	Equipment.Type.ENERGY_STATION: "energy_station",
}
const RARITY_ICON := {
	Equipment.Rarity.WHITE: "white",
	Equipment.Rarity.BLUE: "blue",
	Equipment.Rarity.PURPLE: "purple",
	Equipment.Rarity.PINK: "pink",
	Equipment.Rarity.GOLD: "gold",
}

# ===== 浮窗 / 提示 =====
const _TIP_WIDTH := 236.0
var _tooltip_layer: CanvasLayer = null
var _tooltip_panel: PanelContainer = null
var _tooltip_content: VBoxContainer = null
var _toast_label: Label = null
var _toast_tween: Tween = null
var _pending_redeem_blueprint: Blueprint = null
var _pending_discard_equipment: Equipment = null
# 制造按钮登记表：金币变动时就地刷新可用态，避免重建整个蓝图列表
var _craft_buttons: Array[Button] = []
var _craft_costs: Array[int] = []



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
	# 连接信号
	EconomySystem.resource_gained.connect(_on_resource_changed)
	EconomySystem.resource_spent.connect(_on_resource_changed)
	enter_combat_btn.pressed.connect(_on_enter_combat_pressed)
	return_meta_btn.pressed.connect(_on_return_meta_pressed)
	# 通用二次确认弹窗：与新手引导卡片同款 UI 风格；打开期间遮罩冻结背景操作
	_confirm_dialog = ConfirmDialogScript.new()
	add_child(_confirm_dialog)
	_confirm_dialog.confirmed.connect(_on_equipment_action_confirmed)
	_confirm_dialog.canceled.connect(_on_equipment_action_canceled)
	repair_tank_btn.pressed.connect(func(): _on_repair_pressed("tank"))
	repair_base_btn.pressed.connect(func(): _on_repair_pressed("base"))
	
	# 连接 EquipmentPanel 信号
	equipment_panel.equip_requested.connect(_on_equip_requested)
	equipment_panel.unequip_requested.connect(_on_unequip_requested)
	equipment_panel.slot_clicked.connect(_on_slot_clicked)
	# 悬停已装配槽位的装备图标 → 复用库存同款装备详情浮窗
	equipment_panel.slot_icon_hovered.connect(_show_equipment_tooltip)
	equipment_panel.slot_icon_exited.connect(_hide_tooltip)
	
	# 初始化界面
	_setup_tooltip()
	_setup_toast()
	_refresh_resources()
	_build_blueprint_list()
	_build_equipment_inventory()
	_refresh_repair_panel()
	_update_enter_combat_button()
	# 战役进行中隐藏"返回 Meta"，仅战役开始前的构筑循环显示
	return_meta_btn.visible = not GM.campaign_started

	# 新手指引：首次进基地教制造/装配/回收；战役中途回基地教维修；
	# 首次持有模组（强化材料）时教"卸下→强化→重装"；出现升阶机会时教升阶/造高阶。
	# 卡片可见期间锁定「返回指挥部/进入战役」，收起后恢复各自原有可用态
	# （进入战役仍受"必装装齐"门槛约束）
	Tutorial.showing_changed.connect(_on_tutorial_showing_changed)
	if GameState.equipment_card_redeemed_types.is_empty():
		Tutorial.fire("build_card_redeem")
	else:
		Tutorial.fire("build_equip")
	if GM.campaign_started:
		Tutorial.fire("build_repair")
		if GameState.modules > 0:
			Tutorial.fire("build_enhance")
	if _has_ascend_opportunity():
		Tutorial.fire("build_ascend")
	_on_tutorial_showing_changed(Tutorial.is_showing())


## 指引卡片显示期间锁定跳转按钮；收起后恢复「进入战役」的必装门槛判定
func _on_tutorial_showing_changed(showing: bool) -> void:
	return_meta_btn.disabled = showing
	if showing:
		enter_combat_btn.disabled = true
	else:
		_update_enter_combat_button()


## 新手指引条件：库存中存在可升阶装备（稀有度低于该类型蓝图且未到金），
## 或某类型蓝图稀有度高于已装配的同类型装备（可制造高阶替换）
func _has_ascend_opportunity() -> bool:
	for eq in GameState.inventory:
		if int(eq.rarity) < GameState.get_research_level(int(eq.type)) \
				and int(eq.rarity) < int(Equipment.Rarity.GOLD):
			return true
	for bp in GameState.blueprints:
		for eq in GameState.equipped.values():
			if int(bp.equipment_type) == int(eq.type) and int(bp.rarity) > int(eq.rarity):
				return true
	return false


# ===== 资源显示 =====

func _refresh_resources() -> void:
	gold_label.text = "金币：%d" % GameState.gold
	module_label.text = "模组：%d" % GameState.modules
	equipment_card_label.text = "装备卡：%d/%d" % [GameState.equipment_cards_remaining, GameState.get_equipment_card_capacity()]
	stage_label.text = "关卡 %d / %d" % [GM.current_stage, ConfigLoader.max_stages]


func _on_resource_changed(_type: String, _amount: int) -> void:
	_refresh_resources()
	if _type == "equipment_card":
		_build_blueprint_list()
	elif _type == "gold":
		# 制造按钮的可用态取决于金币，金币一变就要同步，否则会残留可点击的假按钮
		_refresh_craft_button_states()


# ===== 制造面板 =====

func _build_blueprint_list() -> void:
	_craft_buttons.clear()
	_craft_costs.clear()
	for child in blueprint_list.get_children():
		blueprint_list.remove_child(child)
		child.queue_free()

	for equipment_type in GameState.get_campaign_equipment_types():
		var max_rarity := GameState.get_research_level(equipment_type)
		if max_rarity <= 0:
			continue
		var blueprint_group := PanelContainer.new()
		blueprint_group.add_theme_stylebox_override("panel", _create_blueprint_group_style())
		var group_content := VBoxContainer.new()
		group_content.add_theme_constant_override("separation", 3)
		blueprint_group.add_child(group_content)

		var type_label := Label.new()
		type_label.text = "%s 蓝图" % [Equipment.get_type_name(equipment_type)]
		type_label.add_theme_color_override("font_color", Equipment.get_rarity_color(max_rarity))
		group_content.add_child(type_label)
		blueprint_list.add_child(blueprint_group)

		for rarity in range(int(Equipment.Rarity.WHITE), max_rarity + 1):
			var bp := GameState.create_craft_blueprint(equipment_type, rarity)
			if bp != null:
				var craft_slot := PanelContainer.new()
				craft_slot.add_theme_stylebox_override("panel", _create_craft_slot_style())
				craft_slot.add_child(_create_blueprint_row(bp))
				group_content.add_child(craft_slot)


func _create_blueprint_group_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = UIPalette.BG_CARD
	style.border_color = UIPalette.BORDER_DIM
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 6.0
	style.content_margin_top = 5.0
	style.content_margin_right = 6.0
	style.content_margin_bottom = 5.0
	return style


func _create_craft_slot_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = UIPalette.BG_DEEP
	style.border_color = UIPalette.BORDER_DIM
	style.set_border_width_all(1)
	style.set_corner_radius_all(1)
	style.content_margin_left = 5.0
	style.content_margin_top = 3.0
	style.content_margin_right = 5.0
	style.content_margin_bottom = 3.0
	return style


func _create_blueprint_row(bp: Blueprint) -> HBoxContainer:
	var row = HBoxContainer.new()
	
	# 蓝图名称和稀有度（颜色按稀有度）
	var name_label = Label.new()
	name_label.text = bp.get_display_name()
	name_label.add_theme_color_override("font_color", Equipment.get_rarity_color(bp.rarity))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	
	# 制造费用
	var cost = EquipmentSystem.calculate_craft_cost(bp.rarity)
	var cost_label = Label.new()
	cost_label.text = "%d 金币" % cost
	row.add_child(cost_label)
	
	# 制造按钮
	var btn = Button.new()
	btn.text = "制造"
	btn.disabled = not EconomySystem.has_resource("gold", cost)
	btn.pressed.connect(func(): _on_craft_pressed(bp))
	row.add_child(btn)
	_craft_buttons.append(btn)
	_craft_costs.append(int(cost))

	var redeem_btn := Button.new()
	redeem_btn.text = "兑换"
	var redeem_reason := _get_redeem_disabled_reason(bp)
	redeem_btn.disabled = not redeem_reason.is_empty()
	redeem_btn.tooltip_text = redeem_reason if not redeem_reason.is_empty() else "消耗 1 张装备卡，免费兑换此装备"
	redeem_btn.pressed.connect(func(): _on_redeem_pressed(bp))
	row.add_child(redeem_btn)
	return row


## 金币变动后就地刷新各「制造」按钮的可用态（不重建列表，保留滚动位置）
func _refresh_craft_button_states() -> void:
	for i in _craft_buttons.size():
		_craft_buttons[i].disabled = not EconomySystem.has_resource("gold", _craft_costs[i])


func _on_craft_pressed(bp: Blueprint) -> void:
	if bp == null:
		return
	var cost: int = EquipmentSystem.calculate_craft_cost(bp.rarity)
	# 金币不足时按钮本应禁用；此处兜底并给出提示，避免出现「点了没有任何反应」
	if not EconomySystem.has_resource("gold", cost):
		_refresh_craft_button_states()
		_show_toast("金币不足：制造%s需要 %d 金币" % [bp.get_display_name(), cost], UIPalette.RED)
		return
	var equipment = EquipmentSystem.craft_equipment(bp)
	if equipment:
		Tutorial.notify_gold_equipment_crafted()
		_build_blueprint_list()
		_build_equipment_inventory()
		# 刷新槽位面板：制造成功后该类型槽位「选择」按钮立即可按
		equipment_panel.refresh()
		_refresh_resources()


func _get_redeem_disabled_reason(bp: Blueprint) -> String:
	if bp == null:
		return "蓝图无效"
	if not GameState.is_type_available_in_campaign(int(bp.equipment_type)):
		return "该类型未放入本战役战术背包"
	if GameState.equipment_cards_remaining <= 0:
		return "本战役装备卡已用完"
	if GameState.equipment_card_redeemed_types.has(int(bp.equipment_type)):
		return "同一装备类型每次战役只能兑换一次"
	return ""


func _on_redeem_pressed(bp: Blueprint) -> void:
	if not _get_redeem_disabled_reason(bp).is_empty():
		return
	if int(bp.rarity) < GameState.get_research_level(int(bp.equipment_type)):
		_pending_redeem_blueprint = bp
		_pending_discard_equipment = null
		_confirm_dialog.open("确认低阶兑换",
			"已拥有%s色蓝图，仍要消耗 1 张装备卡兑换%s色%s吗？" % [
				Equipment.get_rarity_name(GameState.get_research_level(int(bp.equipment_type))),
				Equipment.get_rarity_name(bp.rarity), Equipment.get_type_name(bp.equipment_type)])
		return
	_redeem_equipment_card(bp)


func _redeem_equipment_card(bp: Blueprint) -> void:
	# 对话框确认前后都从当前研究线重建蓝图，避免连续点击使用过期状态。
	var current_bp := GameState.create_craft_blueprint(int(bp.equipment_type), int(bp.rarity))
	if current_bp == null or not _get_redeem_disabled_reason(current_bp).is_empty():
		_show_toast("兑换条件已变化", UIPalette.RED)
		return
	var equipment := EquipmentSystem.redeem_equipment_card(current_bp)
	if equipment == null:
		_show_toast("兑换失败", UIPalette.RED)
		return
	Tutorial.notify_equipment_card_redeemed()
	_build_blueprint_list()
	_build_equipment_inventory()
	equipment_panel.refresh()
	_refresh_resources()
	_show_toast("装备卡兑换：%s" % equipment.get_display_name(), UIPalette.GREEN)


func _on_equipment_action_confirmed() -> void:
	if _pending_redeem_blueprint != null:
		var bp := _pending_redeem_blueprint
		_pending_redeem_blueprint = null
		_redeem_equipment_card(bp)
		return
	if _pending_discard_equipment != null:
		var equipment := _pending_discard_equipment
		_pending_discard_equipment = null
		if EquipmentSystem.discard_equipment(equipment):
			_build_equipment_inventory()
			equipment_panel.refresh()
			_show_toast("已丢弃装备卡兑换的装备", UIPalette.TEXT_MUTED)
		else:
			_show_toast("装备已不在库存中", UIPalette.RED)


## 取消确认：仅清空待处理状态，不执行任何操作
func _on_equipment_action_canceled() -> void:
	_pending_redeem_blueprint = null
	_pending_discard_equipment = null


# ===== 强化面板 =====

func _build_equipment_inventory() -> void:
	# 先立即摘除再延迟释放，避免新旧行共存一帧造成内容高度瞬时翻倍
	for child in inventory_list.get_children():
		inventory_list.remove_child(child)
		child.queue_free()

	# 与 Meta 循环蓝图库同序：按装备类型升序（插入/移出后均会重排）
	EquipmentSystem.sort_inventory()

	if GameState.inventory.is_empty():
		var label = Label.new()
		label.text = "（库存为空）"
		inventory_list.add_child(label)
		return
	
	for equipment in GameState.inventory:
		_add_inventory_row(equipment)


func _add_inventory_row(equipment: Equipment) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	# 装备图标（hover 显示详情浮窗）
	var icon := TextureRect.new()
	icon.texture = _get_equipment_icon(equipment)
	icon.custom_minimum_size = Vector2(32, 32)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_entered.connect(func(): _show_equipment_tooltip(equipment))
	icon.mouse_exited.connect(_hide_tooltip)
	row.add_child(icon)

	# 装备名（hover 显示详情浮窗）
	var name_label := Label.new()
	name_label.text = equipment.get_display_name()
	name_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	name_label.add_theme_color_override("font_color", Equipment.get_rarity_color(equipment.rarity))
	name_label.mouse_entered.connect(func(): _show_equipment_tooltip(equipment))
	name_label.mouse_exited.connect(_hide_tooltip)
	row.add_child(name_label)

	# 弹簧（把按钮推到右侧）
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# 升阶按钮（hover 显示升阶前后详情）
	var research_level := GameState.get_research_level(int(equipment.type))
	var can_ascend: bool = int(equipment.rarity) < research_level and int(equipment.rarity) < int(Equipment.Rarity.GOLD)
	var ascend_btn := Button.new()
	ascend_btn.text = "升阶"
	if can_ascend:
		var target_rarity: Equipment.Rarity = int(equipment.rarity) + 1
		var ascend_cost := EquipmentSystem.calculate_ascend_cost(equipment.rarity, target_rarity)
		ascend_btn.disabled = not EconomySystem.has_resource("gold", ascend_cost)
		ascend_btn.pressed.connect(func(): _on_ascend_pressed(equipment, target_rarity))
		ascend_btn.mouse_entered.connect(func(): _show_ascend_tooltip(equipment, target_rarity, ascend_cost))
	else:
		ascend_btn.disabled = true
	ascend_btn.mouse_exited.connect(_hide_tooltip)
	row.add_child(ascend_btn)

	# 强化按钮（最高+3）；金雷达禁止强化
	var is_gold_radar: bool = equipment.type == Equipment.Type.RADAR and equipment.rarity == Equipment.Rarity.GOLD
	var can_enhance: bool = equipment.enhancement_level < 3 and not is_gold_radar
	var enhance_btn := Button.new()
	if can_enhance:
		var enhance_cost := _get_enhance_cost(equipment.enhancement_level)
		var enhance_gold_cost := _get_enhance_gold_cost(equipment.enhancement_level)
		enhance_btn.text = "强化"
		enhance_btn.disabled = not (EconomySystem.has_resource("module", enhance_cost) and EconomySystem.has_resource("gold", enhance_gold_cost))
		enhance_btn.pressed.connect(func(): _on_enhance_pressed(equipment))
		enhance_btn.mouse_entered.connect(func(): _show_enhance_tooltip(equipment, enhance_cost, enhance_gold_cost))
	else:
		enhance_btn.text = "满强化"
		enhance_btn.disabled = true
	enhance_btn.mouse_exited.connect(_hide_tooltip)
	row.add_child(enhance_btn)

	# 装配按钮（hover 显示目标槽位）
	var equip_btn := Button.new()
	equip_btn.text = "装配"
	equip_btn.pressed.connect(func(): _on_select_for_equip(equipment))
	equip_btn.mouse_entered.connect(func(): _show_equip_tooltip(equipment))
	equip_btn.mouse_exited.connect(_hide_tooltip)
	row.add_child(equip_btn)

	# 装备卡来源不可回收，只能二次确认后无收益丢弃。
	var recycle_btn := Button.new()
	if equipment.origin == Equipment.Origin.EQUIPMENT_CARD:
		recycle_btn.text = "丢弃"
		recycle_btn.tooltip_text = "装备卡兑换的装备不可回收"
		recycle_btn.pressed.connect(func(): _on_discard_pressed(equipment))
		recycle_btn.mouse_entered.connect(func(): _show_discard_tooltip())
	else:
		recycle_btn.text = "回收"
		recycle_btn.pressed.connect(func(): _on_recycle_pressed(equipment))
		recycle_btn.mouse_entered.connect(func(): _show_recycle_tooltip(equipment))
	recycle_btn.mouse_exited.connect(_hide_tooltip)
	row.add_child(recycle_btn)

	inventory_list.add_child(row)


## 强化模组费用（equipment_templates.json enhancement 段，与 EquipmentSystem 同源）
func _get_enhance_cost(current_level: int) -> int:
	if current_level >= 0 and current_level < EquipmentSystem.enhancement_configs.size():
		return EquipmentSystem.enhancement_configs[current_level].module_cost
	return 0


## 强化金币费用（与 EquipmentSystem 扣费同源）
func _get_enhance_gold_cost(current_level: int) -> int:
	if current_level >= 0 and current_level < EquipmentSystem.enhancement_configs.size():
		return EquipmentSystem.enhancement_configs[current_level].gold_cost
	return 0


## 强化成功率（返回整数百分比）
func _get_enhance_success_rate(current_level: int) -> int:
	if current_level >= 0 and current_level < EquipmentSystem.enhancement_configs.size():
		return int(round(EquipmentSystem.enhancement_configs[current_level].success_rate * 100.0))
	return 0


func _on_enhance_pressed(equipment: Equipment) -> void:
	var success = EquipmentSystem.enhance_equipment(equipment)
	_build_equipment_inventory()
	equipment_panel.refresh()
	_refresh_resources()
	if success:
		_show_toast("强化成功：%s" % equipment.get_display_name(), UIPalette.GREEN)
	else:
		_show_toast("强化失败：%s" % equipment.get_display_name(), UIPalette.RED)


func _on_ascend_pressed(equipment: Equipment, target_rarity: Equipment.Rarity) -> void:
	if EquipmentSystem.ascend_equipment(equipment, target_rarity):
		_build_equipment_inventory()
		equipment_panel.refresh()
		_refresh_resources()
		_show_toast("升阶成功：%s" % equipment.get_display_name(), UIPalette.GREEN)
	else:
		_show_toast("升阶失败：%s" % equipment.get_display_name(), UIPalette.RED)


func _on_select_for_equip(equipment: Equipment) -> void:
	# 自动找到合适的空槽位直接装配
	var target_slot = _find_suitable_slot(equipment)
	if target_slot >= 0:
		EquipmentSystem.equip(target_slot, equipment)
		equipment_panel.refresh()
		_build_equipment_inventory()
		_update_enter_combat_button()
		Tutorial.fire("build_bulk")
	else:
		print("BuildLoop: 没有合适的空槽位可装配 %s" % equipment.get_display_name())


## 根据装备类型找到合适的空槽位
## @return: 槽位索引，-1 表示没有合适的空槽位
func _find_suitable_slot(equipment: Equipment) -> int:
	# 装备类型到槽位的映射（优先槽位在前）
	var type_to_slots: Dictionary = {
		Equipment.Type.ENGINE:          [EquipmentSystem.EquipmentSlot.TANK_ENGINE],
		Equipment.Type.BEARING:         [EquipmentSystem.EquipmentSlot.TANK_BEARING],
		Equipment.Type.MAIN_GUN:        [EquipmentSystem.EquipmentSlot.TANK_MAIN_GUN],
		Equipment.Type.SHELL:           [EquipmentSystem.EquipmentSlot.TANK_SHELL],
		Equipment.Type.ARMOR:           [EquipmentSystem.EquipmentSlot.TANK_ARMOR],
		Equipment.Type.SHIELD:          [EquipmentSystem.EquipmentSlot.TANK_SHIELD],
		Equipment.Type.DIVING:          [EquipmentSystem.EquipmentSlot.TANK_SE_1, EquipmentSystem.EquipmentSlot.TANK_SE_2],
		Equipment.Type.STEALTH:         [EquipmentSystem.EquipmentSlot.TANK_SE_1, EquipmentSystem.EquipmentSlot.TANK_SE_2],
		Equipment.Type.RADAR:           [EquipmentSystem.EquipmentSlot.TANK_SE_1, EquipmentSystem.EquipmentSlot.TANK_SE_2],
		Equipment.Type.EMP:             [EquipmentSystem.EquipmentSlot.BASE_EMP],
		Equipment.Type.BARRIER:         [EquipmentSystem.EquipmentSlot.BASE_BARRIER],
		Equipment.Type.REPAIR_MACHINE:  [EquipmentSystem.EquipmentSlot.BASE_SUPPLY_1, EquipmentSystem.EquipmentSlot.BASE_SUPPLY_2],
		Equipment.Type.ENERGY_STATION:  [EquipmentSystem.EquipmentSlot.BASE_SUPPLY_1, EquipmentSystem.EquipmentSlot.BASE_SUPPLY_2],
	}
	var candidates = type_to_slots.get(equipment.type, [])
	for slot in candidates:
		if not GameState.equipped.has(slot):
			return slot
	# 所有候选槽位都已占用，返回第一个（覆盖）
	if candidates.size() > 0:
		return candidates[0]
	return -1


func _on_recycle_pressed(equipment: Equipment) -> void:
	var gold_returned = EquipmentSystem.recycle_equipment(equipment)
	print("BuildLoop: 回收装备，获得 %d 金币" % gold_returned)
	_build_equipment_inventory()
	equipment_panel.refresh()
	_refresh_resources()


func _on_discard_pressed(equipment: Equipment) -> void:
	if equipment == null or equipment.origin != Equipment.Origin.EQUIPMENT_CARD or not GameState.inventory.has(equipment):
		return
	_pending_redeem_blueprint = null
	_pending_discard_equipment = equipment
	_confirm_dialog.open("确认丢弃", "丢弃装备卡兑换的装备？不会返还装备卡或金币。")


# ===== 装配面板（由 EquipmentPanel 组件处理）=====

## 处理 EquipmentPanel 发出的装配请求
func _on_equip_requested(slot: int, equipment: Equipment) -> void:
	EquipmentSystem.equip(slot, equipment)
	equipment_panel.refresh()
	_build_equipment_inventory()
	_update_enter_combat_button()
	Tutorial.fire("build_bulk")


## 处理 EquipmentPanel 发出的卸载请求
func _on_unequip_requested(slot: int) -> void:
	EquipmentSystem.unequip(slot)
	equipment_panel.refresh()
	_build_equipment_inventory()
	_update_enter_combat_button()


## 处理槽位「选择」按钮：自动装配库存中适用于该槽位、数值最优的装备
func _on_slot_clicked(slot_index: int) -> void:
	var best: Equipment = null
	var best_score := -INF
	for e in GameState.inventory:
		if not EquipmentSystem.is_valid_slot(slot_index, e.type):
			continue
		var s := EquipmentSystem.score_equipment(e)
		if s > best_score:
			best_score = s
			best = e
	if best == null:
		return
	EquipmentSystem.equip(slot_index, best)
	equipment_panel.refresh()
	_build_equipment_inventory()
	_update_enter_combat_button()


# ===== 维修面板 =====

## 获取坦克/基地的最大耐久（与战斗中节点计算口径一致：配置 + 黑匣加成）
func _get_unit_max_hp(target: String) -> int:
	if target == "tank":
		return int(ConfigLoader.tank_config.get("max_health", 1000)) + GameState.base_tank_max_health
	return int(ConfigLoader.base_config.get("max_health", 2000)) + GameState.base_player_max_health


## 获取坦克/基地当前耐久（构筑循环中战斗场景已卸载，从 GameState 读取；-1 表示满耐久）
func _get_unit_current_hp(target: String) -> int:
	var max_hp = _get_unit_max_hp(target)
	var stored = GameState.tank_stored_hp if target == "tank" else GameState.base_stored_hp
	if stored < 0:
		return max_hp
	return mini(stored, max_hp)


func _get_repair_cost(target: String) -> int:
	var missing = _get_unit_max_hp(target) - _get_unit_current_hp(target)
	var cost_per_100 = ConfigLoader.base_config.get("repair_cost_per_100hp", 5)
	return int(missing / 100.0 * cost_per_100)


func _refresh_repair_panel() -> void:
	var tank_max = _get_unit_max_hp("tank")
	var base_max = _get_unit_max_hp("base")
	var tank_cur = _get_unit_current_hp("tank")
	var base_cur = _get_unit_current_hp("base")

	tank_hp_bar.max_value = tank_max
	tank_hp_bar.value = tank_cur
	base_hp_bar.max_value = base_max
	base_hp_bar.value = base_cur

	var tank_repair_cost = _get_repair_cost("tank")
	var base_repair_cost = _get_repair_cost("base")

	repair_tank_btn.text = "维修坦克 (%d 金币)" % tank_repair_cost
	repair_tank_btn.disabled = tank_repair_cost <= 0 or not EconomySystem.has_resource("gold", tank_repair_cost)
	repair_base_btn.text = "维修基地 (%d 金币)" % base_repair_cost
	repair_base_btn.disabled = base_repair_cost <= 0 or not EconomySystem.has_resource("gold", base_repair_cost)


func _on_repair_pressed(target: String) -> void:
	var cost = _get_repair_cost(target)
	if cost <= 0:
		return

	if EconomySystem.spend_resource("gold", cost):
		# 维修写回 GameState，进入战斗循环时由坦克/基地节点恢复
		if target == "tank":
			GameState.tank_stored_hp = _get_unit_max_hp("tank")
		else:
			GameState.base_stored_hp = _get_unit_max_hp("base")
		print("BuildLoop: 维修%s，花费 %d 金币" % [target, cost])
		_refresh_repair_panel()
		_refresh_resources()


# ===== 进入战斗 =====

func _check_can_enter_combat() -> bool:
	# 检查必需装备：引擎(0)、轴承(1)、主炮(2)、炮弹(3)
	var required_slots = [0, 1, 2, 3]
	for slot in required_slots:
		if not GameState.equipped.has(slot):
			return false
	return true


func _update_enter_combat_button() -> void:
	var can_enter = _check_can_enter_combat()
	enter_combat_btn.disabled = not can_enter


func _on_enter_combat_pressed() -> void:
	if not _check_can_enter_combat():
		return
	print("BuildLoop: 进入战斗循环")
	GM.transition_to_loop(GM.GameLoop.COMBAT)


## 返回 Meta 循环（防止背包为空时在构筑循环卡死）
func _on_return_meta_pressed() -> void:
	print("BuildLoop: 返回 Meta 循环")
	GM.transition_to_loop(GM.GameLoop.META)


# ===== 装备图标 =====
func _get_equipment_icon(equipment: Equipment) -> Texture2D:
	var path := "res://sprites/equipment/%s_%s.png" % [
		EQUIP_TYPE_ICON.get(equipment.type, ""), RARITY_ICON.get(equipment.rarity, "white")]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


# ===== 浮窗（tooltip）系统 =====
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


func _tip_separator() -> HSeparator:
	var line := StyleBoxLine.new()
	line.color = UIPalette.BORDER_HI
	line.thickness = 1
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", line)
	sep.add_theme_constant_override("separation", 6)
	return sep


func _tip_icon(equipment: Equipment) -> TextureRect:
	var t := TextureRect.new()
	t.texture = _get_equipment_icon(equipment)
	t.custom_minimum_size = Vector2(32, 32)
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return t


func _tip_lr_row(left_text: String, right_text: String, left_color: Color, right_color: Color, font_size: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var left := _tip_label(left_text, left_color, font_size)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	var arrow := _tip_label("→", UIPalette.GREEN_TEXT, UIPalette.FONT_M, false)
	arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(arrow)
	var right := _tip_label(right_text, right_color, font_size)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	return row


# ===== 装备详情浮窗 =====
func _show_equipment_tooltip(equipment: Equipment) -> void:
	_show_tooltip(func(box: VBoxContainer) -> void:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		head.add_child(_tip_icon(equipment))
		var head_text := VBoxContainer.new()
		head_text.add_theme_constant_override("separation", 2)
		head_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head_text.add_child(_tip_label(equipment.get_display_name(), Equipment.get_rarity_color(equipment.rarity), UIPalette.FONT_M))
		head_text.add_child(_tip_label(Equipment.get_type_desc(equipment.type), UIPalette.TEXT_MUTED))
		head.add_child(head_text)
		box.add_child(head)
		var stats := _format_equipment_stats(equipment)
		if stats != "":
			box.add_child(_tip_separator())
			box.add_child(_tip_label(stats, UIPalette.TEXT_MAIN))
	)


# ===== 升阶浮窗 =====
func _show_ascend_tooltip(equipment: Equipment, target_rarity: Equipment.Rarity, cost: int) -> void:
	var before := equipment.get_display_name()
	var after := _preview_display_name(equipment, target_rarity, equipment.enhancement_level)
	var before_stats := _format_stats_for(equipment.type, equipment.attributes)
	var after_stats := _format_stats_for(equipment.type, _preview_attributes(equipment, target_rarity, equipment.enhancement_level))
	_show_tooltip(func(box: VBoxContainer) -> void:
		# 上：标题 + 名称（升阶前 → 升阶后）
		box.add_child(_tip_label("升阶", UIPalette.GREEN_TEXT, UIPalette.FONT_M))
		box.add_child(_tip_label("保留强化等级", UIPalette.TEXT_MUTED))
		box.add_child(_tip_separator())
		box.add_child(_tip_lr_row(before, after,
			Equipment.get_rarity_color(equipment.rarity),
			Equipment.get_rarity_color(target_rarity), UIPalette.FONT_S))
		# 中：数值变化（升阶前 → 升阶后）
		if before_stats != "" or after_stats != "":
			box.add_child(_tip_separator())
			box.add_child(_tip_lr_row(before_stats, after_stats, UIPalette.TEXT_MUTED, UIPalette.TEXT_MAIN, UIPalette.FONT_S))
		# 下：消耗
		box.add_child(_tip_separator())
		box.add_child(_tip_label("消耗：%d 金币" % cost, UIPalette.AMBER))
	)


# ===== 强化浮窗 =====
func _show_enhance_tooltip(equipment: Equipment, module_cost: int, gold_cost: int) -> void:
	var next_level := equipment.enhancement_level + 1
	var before := equipment.get_display_name()
	var after := _preview_display_name(equipment, equipment.rarity, next_level)
	var before_stats := _format_stats_for(equipment.type, equipment.attributes)
	var after_stats := _format_stats_for(equipment.type, _preview_attributes(equipment, equipment.rarity, next_level))
	var rate := _get_enhance_success_rate(equipment.enhancement_level)
	_show_tooltip(func(box: VBoxContainer) -> void:
		# 上：标题 + 名称（强化前 → 强化后）
		# 复用 _tip_lr_row 三列布局：两侧等宽扩展，箭头与下方数值行纵向对齐
		box.add_child(_tip_lr_row("强化 +%d" % equipment.enhancement_level, "+%d" % next_level,
			UIPalette.GREEN_TEXT, UIPalette.GREEN_TEXT, UIPalette.FONT_M))
		box.add_child(_tip_separator())
		box.add_child(_tip_lr_row(before, after,
			Equipment.get_rarity_color(equipment.rarity),
			Equipment.get_rarity_color(equipment.rarity), UIPalette.FONT_S))
		# 中：数值变化（强化前 → 强化后）
		if before_stats != "" or after_stats != "":
			box.add_child(_tip_separator())
			box.add_child(_tip_lr_row(before_stats, after_stats, UIPalette.TEXT_MUTED, UIPalette.TEXT_MAIN, UIPalette.FONT_S))
		# 下：消耗 + 成功率
		box.add_child(_tip_separator())
		box.add_child(_tip_label("消耗：%d 模组 + %d 金币" % [module_cost, gold_cost], UIPalette.AMBER))
		box.add_child(_tip_label("成功率：%d%%" % rate, UIPalette.TEAL))
	)


# ===== 装配浮窗 =====
func _show_equip_tooltip(equipment: Equipment) -> void:
	var target := "装配到坦克槽位" if int(equipment.type) <= int(Equipment.Type.RADAR) else "装配到基地槽位"
	# 短文本浮窗：不设最小宽度 + 关闭自动换行，宽度随文本自适应
	var build := func(box: VBoxContainer) -> void:
		box.add_child(_tip_label(target, UIPalette.TEXT_MAIN, UIPalette.FONT_S, false))
	_show_tooltip(build, 0.0)


# ===== 回收浮窗 =====
func _show_recycle_tooltip(equipment: Equipment) -> void:
	var gold := int(EquipmentSystem.calculate_craft_cost(equipment.rarity) * 0.5)
	# 短文本浮窗：不设最小宽度 + 关闭自动换行，宽度随文本自适应
	var build := func(box: VBoxContainer) -> void:
		box.add_child(_tip_label("回收获得 %d 金币" % gold, UIPalette.AMBER, UIPalette.FONT_S, false))
	_show_tooltip(build, 0.0)


func _show_discard_tooltip() -> void:
	var build := func(box: VBoxContainer) -> void:
		box.add_child(_tip_label("装备卡兑换的装备不可回收", UIPalette.RED, UIPalette.FONT_S, false))
		box.add_child(_tip_label("丢弃不会返还装备卡或金币", UIPalette.TEXT_MUTED, UIPalette.FONT_S, false))
	_show_tooltip(build, 0.0)


# ===== 提示（toast）系统 =====
func _setup_toast() -> void:
	_toast_label = Label.new()
	_toast_label.visible = false
	_toast_label.z_index = 101
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
	_toast_label.add_theme_color_override("font_color", UIPalette.TEXT_MAIN)
	_tooltip_layer.add_child(_toast_label)


func _show_toast(text: String, color: Color) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	_toast_label.reset_size()
	var vp := get_viewport_rect().size
	_toast_label.global_position = Vector2((vp.x - _toast_label.size.x) * 0.5, 24.0)
	_toast_label.visible = true
	_toast_label.modulate.a = 1.0
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.4)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)
	_toast_tween.tween_callback(func(): _toast_label.visible = false)


# ===== 数值格式化与属性预览 =====
func _format_equipment_stats(equipment: Equipment) -> String:
	return _format_stats_for(equipment.type, equipment.attributes)


func _format_stats_for(type: Equipment.Type, attrs: Dictionary) -> String:
	var lines: Array[String] = []
	match type:
		Equipment.Type.ENGINE:
			lines.append("移动速度 +%s u/s" % _fmt_num(attrs.get("move_speed_bonus", 0.0)))
		Equipment.Type.BEARING:
			lines.append("旋转速度 +%s °/s" % _fmt_num(attrs.get("turret_rotation_bonus", 0.0)))
		Equipment.Type.MAIN_GUN:
			lines.append("炮弹速度 %s u/s" % _fmt_num(attrs.get("shell_speed", 0.0)))
			lines.append("冷却削减 %s s" % _fmt_num(attrs.get("shoot_cooldown_reduction", 0.0)))
		Equipment.Type.SHELL:
			lines.append("炮弹伤害 +%d" % int(attrs.get("shell_damage_bonus", 0.0)))
			lines.append("射程 %s u" % _fmt_num(attrs.get("shell_range_bonus", 0.0)))
		Equipment.Type.ARMOR:
			lines.append("防御 +%d" % int(attrs.get("defense_bonus", 0.0)))
		Equipment.Type.SHIELD:
			lines.append("护盾能量 %d" % int(attrs.get("shield_energy_max", 0.0)))
		Equipment.Type.DIVING:
			lines.append("水面移速 ×%s" % _fmt_num(attrs.get("water_speed_penalty", 1.0)))
		Equipment.Type.STEALTH:
			lines.append("探测范围 ×%s" % _fmt_num(attrs.get("detection_range_multiplier", 1.0)))
			lines.append("开炮暴露 %s s" % _fmt_num(attrs.get("exposure_duration", 0.0)))
			var dodge_pct := float(attrs.get("dodge_chance", 0.0)) * 100.0
			if dodge_pct > 0.0:
				lines.append("闪避率 +%s%%" % _fmt_num(dodge_pct))
		Equipment.Type.RADAR:
			lines.append("侦测范围 %s 格" % _fmt_num(attrs.get("detection_range", 0.0)))
		Equipment.Type.EMP:
			lines.append("范围 %s 格" % _fmt_num(attrs.get("emp_range", 0.0)))
			lines.append("瘫痪 %s s" % _fmt_num(attrs.get("stun_duration", 0.0)))
			if float(attrs.get("dot_damage", 0.0)) > 0.0:
				lines.append("持续伤害 %d" % int(attrs.get("dot_damage", 0.0)))
			lines.append("冷却 %s s" % _fmt_num(attrs.get("cooldown", 0.0)))
		Equipment.Type.BARRIER:
			lines.append("基地防御 +%d" % int(attrs.get("defense_bonus", 0.0)))
		Equipment.Type.REPAIR_MACHINE:
			lines.append("维修速度 %d HP/s" % int(attrs.get("repair_speed", 0.0)))
			lines.append("维修折扣 %d%%" % int(float(attrs.get("repair_discount", 0.0)) * 100.0))
		Equipment.Type.ENERGY_STATION:
			lines.append("充能速度 %d/s" % int(attrs.get("charge_speed", 0.0)))
			lines.append("最大充能 %d" % int(attrs.get("max_charge_capacity", 0.0)))
	return "\n".join(lines)


## 数字紧凑格式化（整数去小数点）
func _fmt_num(v: Variant) -> String:
	var f := float(v)
	if is_equal_approx(f, round(f)):
		return str(int(round(f)))
	return "%.2f" % f


## 预览某稀有度+强化等级下的属性（与 EquipmentSystem._apply_enhancement 同规则）
func _preview_attributes(equipment: Equipment, rarity: int, enh_level: int) -> Dictionary:
	var template: Dictionary = ConfigLoader.get_equipment_template(equipment.type, rarity)
	var base: Dictionary = template.get("attributes", {}).duplicate()
	if enh_level <= 0 or EquipmentSystem.enhancement_configs.is_empty():
		return base
	var multiplier: float = EquipmentSystem.enhancement_configs[enh_level - 1].attribute_multiplier
	var result := {}
	for key in base:
		var v: Variant = base[key]
		if v is bool:
			result[key] = v
		elif String(key) == "cooldown":
			result[key] = v
		elif String(key) == "exposure_duration":
			result[key] = v
		elif String(key) == "detection_range_multiplier":
			result[key] = v
		else:
			result[key] = float(v) * multiplier
	# 隐身装备：强化提供闪避率（与 EquipmentSystem._apply_enhancement 同规则）
	if equipment.type == Equipment.Type.STEALTH:
		var chances: Array[float] = EquipmentSystem.STEALTH_ENHANCEMENT_DODGE_CHANCES
		var dodge_index := clampi(enh_level - 1, 0, chances.size() - 1)
		result["dodge_chance"] = chances[dodge_index]
	return result


## 预览显示名称（+强化 类型 (稀有度)）
func _preview_display_name(equipment: Equipment, rarity: int, enh_level: int) -> String:
	var prefix := ""
	if enh_level > 0:
		prefix = "+%d " % enh_level
	return "%s%s (%s)" % [prefix, Equipment.get_type_name(equipment.type), Equipment.get_rarity_name(rarity)]
