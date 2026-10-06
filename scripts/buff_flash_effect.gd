extends Node2D
class_name BuffFlashEffect

## 道具增益/强化成功闪光特效
## 道具生效或强化成功时在玩家坦克身上显示一圈绿色闪光。

const DURATION := 0.5
const RING_COLOR := Color(0.45, 1.0, 0.55, 0.9)
const FILL_COLOR := Color(0.45, 1.0, 0.55, 0.15)
const MAX_RADIUS := 22.0

var _elapsed := 0.0
var _color := RING_COLOR

static func spawn_at(parent: Node, world_position: Vector2, color: Color = RING_COLOR) -> void:
	if parent == null:
		return
	var effect := BuffFlashEffect.new()
	effect._color = color
	parent.add_child(effect)
	effect.global_position = world_position


func _ready() -> void:
	z_index = 12
	queue_redraw()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= DURATION:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var progress := clampf(_elapsed / DURATION, 0.0, 1.0)
	var alpha := 1.0 - progress
	var radius := MAX_RADIUS * (0.5 + 0.5 * progress)
	# 扩散环
	draw_circle(Vector2.ZERO, radius, Color(_color.r, _color.g, _color.b, FILL_COLOR.a * alpha))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 24, Color(_color.r, _color.g, _color.b, alpha), 2.0)
	# 中心十字光
	var cross := 8.0 * (1.0 - progress)
	draw_line(Vector2(-cross, 0), Vector2(cross, 0), Color(_color.r, _color.g, _color.b, alpha), 1.5)
	draw_line(Vector2(0, -cross), Vector2(0, cross), Color(_color.r, _color.g, _color.b, alpha), 1.5)
