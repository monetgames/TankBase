extends Node2D
class_name DamagePopup

## 浮动伤害数字
## 命中单位时在头顶弹出伤害数值，向上漂浮并淡出；免疫/0 伤害显示"免疫"。

const FONT_PATH := "res://fonts/fusion-pixel-12px-monospaced-zh_hans.ttf.woff2"
const LIFETIME := 0.8
const RISE_PX := 16.0
const FONT_SIZE := 12

var _elapsed := 0.0
var _text := ""
var _color := Color.WHITE
var _font: Font = null


## 在 world_position（世界坐标）处生成一个浮动数字。
## @param parent: 挂载父节点（应为世界空间根，如 MapManager）
## @param text: 显示文本（数字或"免疫"）
## @param color: 文本颜色
static func spawn_at(parent: Node, world_position: Vector2, text: String, color: Color) -> void:
	if parent == null:
		return
	var popup := DamagePopup.new()
	popup._text = text
	popup._color = color
	parent.add_child(popup)
	popup.global_position = world_position


func _ready() -> void:
	z_index = 20
	_font = load(FONT_PATH) as Font


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= LIFETIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	if _font == null:
		return
	var progress := clampf(_elapsed / LIFETIME, 0.0, 1.0)
	var alpha := 1.0 - progress
	var pos := Vector2(0, -RISE_PX * progress)
	var fg := Color(_color.r, _color.g, _color.b, alpha)
	var outline := Color(0, 0, 0, alpha)
	draw_string_outline(_font, pos, _text, HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE, 2, outline)
	draw_string(_font, pos, _text, HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE, fg)
