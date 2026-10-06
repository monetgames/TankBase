extends Node2D
class_name PickupBurstEffect

## 拾取粒子特效
## 拾取掉落物时在位置爆出一圈金色粒子。

const DURATION := 0.35
const PARTICLE_COUNT := 8
const SPREAD_RADIUS := 14.0
const DEFAULT_COLOR := Color(1.0, 0.85, 0.3, 1.0)

var _elapsed := 0.0
var _directions: Array[Vector2] = []
var _particle_color := DEFAULT_COLOR

static func spawn_at(parent: Node, world_position: Vector2, color: Color = DEFAULT_COLOR) -> void:
	if parent == null:
		return
	var effect := PickupBurstEffect.new()
	effect._particle_color = color
	parent.add_child(effect)
	effect.global_position = world_position


func _ready() -> void:
	z_index = 12
	# 预生成方向，避免 _draw 中随机抖动
	for i in range(PARTICLE_COUNT):
		_directions.append(Vector2.UP.rotated(TAU * float(i) / float(PARTICLE_COUNT)))
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
	var dist := SPREAD_RADIUS * progress
	for dir in _directions:
		var pos := dir * dist
		# 粒子向外飞并缩小
		var size := lerpf(2.5, 0.5, progress)
		draw_rect(Rect2(pos.x - size * 0.5, pos.y - size * 0.5, size, size),
			Color(_particle_color.r, _particle_color.g, _particle_color.b, alpha))
