extends Node2D
class_name SpawnFlashEffect

## 单位出生前显示的 8 帧光标动画。
const FRAME_COUNT := 8
const FPS := 16.0
const DEFAULT_DURATION := 0.5
const FLASH_COLOR := Color("f1f1f1")

# 每项为从中心向外扩张的同色矩形 [x, y, width, height]。
# 坐标与原始 32x32 帧图保持同一像素网格，中心位于 (0, 0)。
const FRAME_RECTS := [
	[[-1, -3, 2, 6], [-3, -1, 6, 2]],
	[[-1, -7, 2, 14], [-7, -1, 14, 2]],
	[[-1, -11, 2, 22], [-11, -1, 22, 2], [-3, -3, 6, 6]],
	[[-1, -13, 2, 26], [-13, -1, 26, 2], [-3, -7, 6, 14], [-7, -3, 14, 6]],
	[[-1, -13, 2, 26], [-13, -1, 26, 2], [-3, -9, 6, 18], [-5, -5, 10, 10], [-9, -3, 18, 6]],
	[[-1, -13, 2, 26], [-13, -1, 26, 2], [-3, -7, 6, 14], [-7, -3, 14, 6]],
	[[-1, -11, 2, 22], [-11, -1, 22, 2], [-3, -3, 6, 6]],
	[[-1, -7, 2, 14], [-7, -1, 14, 2]],
]

var _elapsed := 0.0
var duration := DEFAULT_DURATION

static func spawn_at(parent: Node, world_position: Vector2, effect_duration: float = DEFAULT_DURATION) -> void:
	if parent == null:
		return
	var effect := SpawnFlashEffect.new()
	effect.duration = maxf(effect_duration, 0.01)
	parent.add_child(effect)
	effect.global_position = world_position

func _ready() -> void:
	z_index = 11
	queue_redraw()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var frame_index := int(_elapsed * FPS) % FRAME_COUNT
	for rect_data in FRAME_RECTS[frame_index]:
		draw_rect(Rect2(rect_data[0], rect_data[1], rect_data[2], rect_data[3]), FLASH_COLOR)
