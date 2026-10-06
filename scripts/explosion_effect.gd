extends Node2D
class_name ExplosionEffect

## 所有武器命中有效目标时共用的短促爆炸效果。
const DURATION := 0.28

var _elapsed := 0.0

static func spawn_at(parent: Node, world_position: Vector2) -> void:
	if parent == null:
		return
	var effect := ExplosionEffect.new()
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
	# 小范围爆炸：高亮中心 + 扩散环 + 火花。
	var radius := lerpf(3.0, 10.0, progress)
	var alpha := 1.0 - progress
	draw_circle(Vector2.ZERO, lerpf(5.0, 2.0, progress), Color(1.0, 0.78, 0.18, 0.92 * alpha))
	draw_circle(Vector2.ZERO, radius, Color(1.0, 0.45, 0.04, 0.30 * alpha))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 16, Color(1.0, 0.9, 0.38, alpha), 2.0)
	for i in range(4):
		var direction := Vector2.UP.rotated(TAU * float(i) / 4.0 + 0.35)
		draw_line(direction * radius * 0.45, direction * radius, Color(1.0, 0.42, 0.05, alpha), 1.5)
