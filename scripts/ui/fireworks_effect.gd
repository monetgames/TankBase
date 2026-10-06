extends AnimatedSprite2D
class_name FireworksEffect

## 胜利烟花帧动画特效
## 播放 sprites/fireworks/fireworks1..20.png 组成的整屏烟花秀。
## 指定播放次数时播完自动淡出移除；未指定（<=0）则随机间隔无限重播。
## 每次重播随机水平翻转制造变化，加色混合在深底上发光。

const FRAME_COUNT := 20
const FRAME_PATH_FMT := "res://sprites/fireworks/fireworks%d.png"
const BASE_HEIGHT := 576.0
const FPS := 12.0
const FADE_OUT_DURATION := 0.8

static var _shared_frames: SpriteFrames = null

var _rng := RandomNumberGenerator.new()
var plays_left := 0  # 剩余播放次数（<=0 表示无限循环）


## 在 parent 下生成一个铺满高度 height_px 的烟花层
## @param play_count: 播放次数上限（<=0 无限循环）
static func spawn_at(parent: Node, center: Vector2, height_px: float, alpha: float = 1.0, play_count: int = 0) -> FireworksEffect:
	if parent == null:
		return null
	var fx := FireworksEffect.new()
	fx.sprite_frames = _get_shared_frames()
	fx.plays_left = play_count
	fx.modulate = Color(1.0, 1.0, 1.0, alpha)
	parent.add_child(fx)
	fx.position = center
	fx.scale = Vector2.ONE * (height_px / BASE_HEIGHT)
	return fx


static func _get_shared_frames() -> SpriteFrames:
	if _shared_frames:
		return _shared_frames
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("default")
	frames.set_animation_speed("default", FPS)
	frames.set_animation_loop("default", false)
	for i in range(1, FRAME_COUNT + 1):
		var tex: Texture2D = load(FRAME_PATH_FMT % i)
		if tex:
			frames.add_frame("default", tex)
	_shared_frames = frames
	return frames


func _ready() -> void:
	# 加色混合：深底上呈现发光感，且不遮挡 UI（层由父节点排序控制）
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	animation_finished.connect(_on_animation_finished)
	play("default")


func _on_animation_finished() -> void:
	if plays_left > 0:
		plays_left -= 1
		if plays_left <= 0:
			_fade_out()
			return
	var delay := _rng.randf_range(0.5, 1.3)
	var timer := get_tree().create_timer(delay)
	timer.timeout.connect(_replay)


func _fade_out() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, FADE_OUT_DURATION)
	tw.tween_callback(queue_free)


func _replay() -> void:
	if not is_inside_tree():
		return
	# 随机镜像 + 轻微错位，让每次重播略有不同
	flip_h = _rng.randf() < 0.5
	play("default")
