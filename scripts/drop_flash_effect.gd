extends Node2D
class_name DropFlashEffect

## 掉落物生成闪光特效
## 掉落物出现时在其位置显示一个短促的向上扩散光柱。

const DURATION := 0.4
const FLASH_COLOR := Color(1.0, 0.92, 0.55, 0.9)

var _elapsed := 0.0

static func spawn_at(parent: Node, world_position: Vector2) -> void:
	if parent == null:
		return
	var effect := DropFlashEffect.new()
	parent.add_child(effect)
	effect.global_position = world_position


func _ready() -> void:
	z_index = 11
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
	# 中心光点
	draw_circle(Vector2.ZERO, lerpf(2.0, 6.0, progress), Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.6 * alpha))
	# 向上光柱
	var pillar_h := lerpf(4.0, 14.0, progress)
	draw_rect(Rect2(-1.0, -pillar_h, 2.0, pillar_h), Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.8 * alpha))
	# 扩散环
	var ring_r := lerpf(2.0, 10.0, progress)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 16, Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.5 * alpha), 1.0)
