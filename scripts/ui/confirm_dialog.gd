extends CanvasLayer
class_name ConfirmDialog

## ConfirmDialog - 通用二次确认弹窗
## 与新手引导卡片（TutorialManager 的卡片）使用同一套 UI 风格：
##   BG_PANEL 底 + BORDER_HI 边框(2px) + 圆角 4 + 16/12 内边距 + 右下角按钮行。
## 模态：全屏半透明遮罩拦截所有点击，打开期间背景 UI 全部不可按（冻结）。
## 用法：
##   var dlg := ConfirmDialog.new()
##   add_child(dlg)
##   dlg.confirmed.connect(_on_confirmed)
##   dlg.open("确认丢弃", "丢弃装备卡兑换的装备？不会返还装备卡或金币。")

## 点击「确认」
signal confirmed
## 点击「取消」
signal canceled

const CARD_WIDTH := 430.0
const FONT_SIZE := 15
## 高于新手引导卡片层（90），确保确认弹窗始终在最上层
const LAYER_INDEX := 95

var _overlay: Control = null
var _title_label: Label = null
var _message_label: RichTextLabel = null
var _ok_btn: Button = null
var _cancel_btn: Button = null


func _ready() -> void:
	layer = LAYER_INDEX
	visible = false
	_build_ui()


func _build_ui() -> void:
	# 全屏遮罩：mouse_filter = STOP 吃掉所有点击 → 打开期间背景 UI 不可交互（冻结）
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.047059, 0.070588, 0.039216, 0.88)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	# 卡片：与新手引导卡片同款样式
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UIPalette.BG_PANEL
	sb.border_color = UIPalette.BORDER_HI
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)

	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	vb.add_theme_constant_override("separation", 12)
	card.add_child(vb)

	# 标题
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", UIPalette.GREEN_TEXT)
	_title_label.add_theme_font_size_override("font_size", FONT_SIZE + 3)
	vb.add_child(_title_label)

	# 正文（与引导卡片一致使用 RichTextLabel，支持 BBCode 着色）
	_message_label = RichTextLabel.new()
	_message_label.bbcode_enabled = true
	_message_label.fit_content = true
	_message_label.scroll_active = false
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_color_override("default_color", UIPalette.TEXT_MAIN)
	_message_label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	_message_label.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	vb.add_child(_message_label)

	# 按钮行（右对齐，风格与引导卡片一致）
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)

	_cancel_btn = Button.new()
	_cancel_btn.text = "取消"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	row.add_child(_cancel_btn)

	_ok_btn = Button.new()
	_ok_btn.text = "确认"
	_ok_btn.focus_mode = Control.FOCUS_NONE
	_ok_btn.add_theme_color_override("font_color", UIPalette.AMBER)
	_ok_btn.pressed.connect(_on_ok_pressed)
	row.add_child(_ok_btn)


## 打开确认弹窗（模态：遮罩拦截背景点击，只能通过按钮关闭）
func open(title: String, message: String, ok_text: String = "确认", cancel_text: String = "取消") -> void:
	_title_label.text = title
	_message_label.text = message
	_ok_btn.text = ok_text
	_cancel_btn.text = cancel_text
	visible = true


## 关闭弹窗
func close() -> void:
	visible = false
	# 释放焦点：避免触发弹窗的按钮（如「丢弃」「兑换」）在弹窗关闭后仍处于 focus 高亮态
	get_viewport().gui_release_focus()


func _on_ok_pressed() -> void:
	close()
	confirmed.emit()


func _on_cancel_pressed() -> void:
	close()
	canceled.emit()
