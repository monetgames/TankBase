extends Node2D
class_name ShieldAura

## 覆盖坦克全身的半透明方形护盾光圈。
var _elapsed := 0.0

func _ready() -> void:
	z_index = 1
	queue_redraw()

func _process(delta: float) -> void:
	_elapsed += delta
	queue_redraw()

func _draw() -> void:
	var pulse := 0.08 * sin(_elapsed * TAU * 2.0)
	var fill := Color(0.18, 0.82, 1.0, 0.20 + pulse)
	var edge := Color(0.56, 0.94, 1.0, 0.75 + pulse)
	draw_rect(Rect2(-17, -17, 34, 34), fill, true)
	draw_rect(Rect2(-17, -17, 34, 34), edge, false, 1.5)
