extends PanelContainer

## EquipmentPanel - 可复用装备槽位面板
## 显示12个装备槽位（坦克8个 + 基地4个），支持装配和卸载操作

# ===== 信号 =====
## 请求装配装备到指定槽位
signal equip_requested(slot: int, equipment: Equipment)
## 请求卸载指定槽位的装备
signal unequip_requested(slot: int)
## 槽位被点击（用于选择装配目标）
signal slot_clicked(slot: int)
## 已装配槽位的装备图标被悬停（用于复用库存同款装备详情浮窗）
signal slot_icon_hovered(equipment: Equipment)
## 已装配槽位的装备图标被移出（隐藏浮窗）
signal slot_icon_exited()

# ===== 常量 =====
const SLOT_NAMES: Dictionary = {
	0: "引擎",
	1: "轴承",
	2: "主炮",
	3: "炮弹",
	4: "装甲",
	5: "护盾",
	6: "特种1",
	7: "特种2",
	8: "EMP",
	9: "壁垒",
	10: "补给1",
	11: "补给2"
}

# 坦克槽位范围
const TANK_SLOT_COUNT: int = 8
# 基地槽位范围
const BASE_SLOT_COUNT: int = 4
# 一行显示的槽位数量
const SLOT_COLUMNS: int = 4
# 槽位最小边长（布局未就绪时的兜底，保证仍是正方形）
const SLOT_MIN_SIZE: float = 48.0
# 槽位区可用宽度兜底（布局尚未完成时用于估算边长）
const SLOT_AREA_FALLBACK_WIDTH: float = 244.0

# 装备图标文件名映射（与构筑循环装备库存保持同一套命名）
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
# ===== 节点引用 =====
@onready var tank_slots_grid: GridContainer = $VBoxContainer/TankSection/TankSlotsGrid
@onready var base_slots_grid: GridContainer = $VBoxContainer/BaseSection/BaseSlotsGrid

# 槽位像素边框
const SLOT_TEX := preload("res://sprites/ui/ui_slot.png")
var _slot_style: StyleBoxTexture = null

# ===== 状态 =====
## 当前待装配的装备（由外部设置）
var pending_equipment: Equipment = null


func _ready() -> void:
	# 外层不绘制面板框：装配区已由 EquipCard 提供卡片外框，避免嵌套双框
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_slot_style = StyleBoxTexture.new()
	_slot_style.texture = SLOT_TEX
	_slot_style.texture_margin_left = 16.0
	_slot_style.texture_margin_top = 16.0
	_slot_style.texture_margin_right = 16.0
	_slot_style.texture_margin_bottom = 16.0
	# 3 行装备槽之间留约半行字高的行距（每行槽位上方留白）
	tank_slots_grid.add_theme_constant_override("v_separation", 8)
	base_slots_grid.add_theme_constant_override("v_separation", 8)
	# 等布局完成后再按真实可用宽度计算正方形槽位尺寸
	refresh.call_deferred()


## 刷新所有槽位显示
func refresh() -> void:
	_build_tank_slots()
	_build_base_slots()


## 设置待装配装备（从库存选中后调用）
## @param equipment: 待装配的装备，null 表示取消选择
func set_pending_equipment(equipment: Equipment) -> void:
	pending_equipment = equipment
	refresh()


## 构建坦克槽位（0-7）
func _build_tank_slots() -> void:
	# 先立即摘除再延迟释放：仅 queue_free 会让新旧槽位共存一帧，
	# 网格最小尺寸翻倍撑大整体布局，导致相邻 ScrollContainer 视口临时
	# 变大而钳制（不可恢复）其滚动位置
	for child in tank_slots_grid.get_children():
		tank_slots_grid.remove_child(child)
		child.queue_free()
	var slot_size := _compute_slot_size(tank_slots_grid)
	for i in range(TANK_SLOT_COUNT):
		tank_slots_grid.add_child(_create_slot_panel(i, slot_size))


## 构建基地槽位（8-11）
func _build_base_slots() -> void:
	# 同 _build_tank_slots：先摘除再释放，避免一帧内容翻倍
	for child in base_slots_grid.get_children():
		base_slots_grid.remove_child(child)
		child.queue_free()
	var slot_size := _compute_slot_size(base_slots_grid)
	for i in range(BASE_SLOT_COUNT):
		base_slots_grid.add_child(_create_slot_panel(TANK_SLOT_COUNT + i, slot_size))


## 创建单个槽位面板：紧凑布局（名称、图标/占位、操作按钮都在槽位内部），
## 槽位保持正方形（边长 = slot_size），避免挤占纵向空间。
## 图标在名称与按钮之间的区域居中显示。
## @param slot_index: 槽位索引（0-11）
## @param slot_size: 正方形槽位边长
## @return: 槽位面板节点
func _create_slot_panel(slot_index: int, slot_size: float) -> Panel:
	var panel = Panel.new()
	panel.custom_minimum_size = Vector2(slot_size, slot_size)
	panel.name = "Slot_%d" % slot_index
	if _slot_style:
		panel.add_theme_stylebox_override("panel", _slot_style)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 1)
	panel.add_child(vbox)

	# 槽位名称（槽位内顶部）
	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_index, "槽%d" % slot_index)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	name_label.add_theme_color_override("font_color", UIPalette.GREEN_TEXT)
	vbox.add_child(name_label)

	# 图标（或占位文字）在名称与按钮之间的区域居中
	var equipped: Equipment = GameState.equipped.get(slot_index)
	if equipped:
		var icon_holder := CenterContainer.new()
		icon_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var icon = TextureRect.new()
		icon.name = "EquipIcon"
		icon.texture = _get_equipment_icon(equipped)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# 紧凑布局下图标适中（约 0.52 槽位边长），避免挤压按钮
		var icon_size: float = slot_size * 0.52
		icon.custom_minimum_size = Vector2(icon_size, icon_size)
		icon.size = Vector2(icon_size, icon_size)
		# 悬停图标时复用库存同款装备详情浮窗（由 build_loop 监听信号显示）
		icon.mouse_entered.connect(func(): slot_icon_hovered.emit(equipped))
		icon.mouse_exited.connect(slot_icon_exited.emit)
		icon_holder.add_child(icon)
		vbox.add_child(icon_holder)
	else:
		var placeholder = Label.new()
		placeholder.name = "EquipLabel"
		placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
		placeholder.add_theme_font_size_override("font_size", UIPalette.FONT_S)
		if slot_index < TANK_SLOT_COUNT and slot_index <= 3:
			placeholder.text = "必装"
			placeholder.add_theme_color_override("font_color", UIPalette.RED)
		else:
			placeholder.text = "空"
			placeholder.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
		vbox.add_child(placeholder)

	# 操作按钮（槽位内底部）
	vbox.add_child(_create_slot_button(slot_index))

	return panel


## 创建槽位内的操作按钮（选择/装配/卸载）
func _create_slot_button(slot_index: int) -> Button:
	var btn = Button.new()
	btn.add_theme_font_size_override("font_size", UIPalette.FONT_S)
	var equipped: Equipment = GameState.equipped.get(slot_index)
	if equipped:
		btn.text = "卸载"
		btn.pressed.connect(func(): _on_unequip_pressed(slot_index))
	elif pending_equipment != null:
		btn.text = "装配"
		btn.pressed.connect(func(): _on_equip_pressed(slot_index, pending_equipment))
	else:
		btn.text = "选择"
		# 库存无适用装备时置灰不可按；制造出可用装备后才可按
		var available := _has_available_equipment(slot_index)
		btn.disabled = not available
		if not available:
			# 主题默认禁用态对比弱，叠加半透明让「灰色不可按」更直观
			btn.modulate = Color(1.0, 1.0, 1.0, 0.5)
		btn.pressed.connect(func(): slot_clicked.emit(slot_index))
	return btn


## 处理装配按钮点击
func _on_equip_pressed(slot: int, equipment: Equipment) -> void:
	equip_requested.emit(slot, equipment)
	pending_equipment = null
	refresh()


## 处理卸载按钮点击
func _on_unequip_pressed(slot: int) -> void:
	unequip_requested.emit(slot)
	refresh()


## 按网格当前可用宽度计算正方形槽位边长：一行四列，尽量贴满且不超出边框
func _compute_slot_size(grid: GridContainer) -> float:
	var avail: float = grid.size.x
	if avail <= 0.0:
		avail = SLOT_AREA_FALLBACK_WIDTH
	var sep: float = float(grid.get_theme_constant("h_separation"))
	var edge: float = floor((avail - sep * float(SLOT_COLUMNS - 1)) / float(SLOT_COLUMNS))
	return maxf(SLOT_MIN_SIZE, edge)


## 库存中是否存在可装配到该槽位的装备（决定「选择」按钮是否可点）
func _has_available_equipment(slot_index: int) -> bool:
	for e in GameState.inventory:
		if EquipmentSystem.is_valid_slot(slot_index, e.type):
			return true
	return false


## 装备图标（与构筑循环装备库存同一套命名）
func _get_equipment_icon(equipment: Equipment) -> Texture2D:
	var path := "res://sprites/equipment/%s_%s.png" % [
		EQUIP_TYPE_ICON.get(equipment.type, ""), RARITY_ICON.get(equipment.rarity, "white")]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null
