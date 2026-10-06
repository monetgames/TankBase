extends Node2D
class_name EmpBlastEffect

## EMP 电磁脉冲扩散特效
## 从基地中心向外扩散的青蓝色环形脉冲。

const DURATION := 0.6
const RING_COUNT := 3
const DEFAULT_RADIUS := 96.0
const RING_COLOR := Color(0.38, 0.78, 1.0, 0.9)
const FILL_COLOR := Color(0.38, 0.78, 1.0, 0.12)

var _elapsed := 0.0
var _max_radius := DEFAULT_RADIUS

static func spawn_at(parent: Node, world_position: Vector2, range_px: float = DEFAULT_RADIUS) -> void:
	if parent == null:
		return
	var effect := EmpBlastEffect.new()
	effect._max_radius = range_px
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
	# 三层环依次扩散
	for i in range(RING_COUNT):
		var ring_progress := clampf(progress * RING_COUNT - float(i), 0.0, 1.0)
		if ring_progress <= 0.0:
			continue
		var radius := _max_radius * ring_progress
		var ring_alpha := alpha * (1.0 - ring_progress * 0.3)
		draw_circle(Vector2.ZERO, radius, Color(FILL_COLOR.r, FILL_COLOR.g, FILL_COLOR.b, FILL_COLOR.a * ring_alpha))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32,
			Color(RING_COLOR.r, RING_COLOR.g, RING_COLOR.b, ring_alpha), 2.0)
