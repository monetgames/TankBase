extends StaticBody2D
class_name BaseParent

const HealthBarScript := preload("res://scripts/health_bar.gd")

## 属性变化信号（供UI监听）
signal stats_changed(current_hp: int, max_hp: int, defense: int)

# 生命值
var max_hp: int = 50			    	# 最大生命值
var current_hp: int:
	set(value):
		if current_hp != value:
			current_hp = value
			stats_changed.emit(current_hp, max_hp, defense)
var base_level: int = 1                 # 基地等级

# 战斗属性
var defense: int = 0                   # 防御力

# 耐久血条：我方长期显示，敌方受击后显示 5 秒
var health_bar: Node2D = null
var health_bar_always_visible := false

func _ready() -> void:
	# 从配置加载初始值
	_load_from_config()
	current_hp = max_hp


## 设置基地帧动画（子类在 _ready 中调用；sheet 为横向帧序列，每帧 32x32）
func set_base_sprite_frames(sheet: Texture2D, frame_count: int = 4, fps: float = 4.0) -> void:
	var spr := get_node_or_null("Sprite2D") as AnimatedSprite2D
	if spr == null or sheet == null:
		return
	var frames := SpriteFrames.new()
	frames.add_animation("idle")
	frames.set_animation_speed("idle", fps)
	frames.set_animation_loop("idle", true)
	for i in range(frame_count):
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2(i * 32, 0, 32, 32)
		frames.add_frame("idle", at)
	spr.sprite_frames = frames
	spr.animation = &"idle"
	spr.play()

# 从配置文件加载基地属性
func _load_from_config() -> void:
	if ConfigLoader:
		# 子类会重写此方法来加载特定配置
		pass
	
func _physics_process(_delta: float) -> void:
	_ensure_health_bar()
	# 更新 GameState 中的基地血量
	_update_game_state_health()
	
	if current_hp <= 0:
		_on_base_destroyed()

# 更新 GameState 中的基地血量（由子类重写）
func _update_game_state_health() -> void:
	pass

# 设置基地位置，传入全局坐标
func set_base_pos(role : String, pos : Vector2) -> void:
	position = pos
	GM.sig_base_pos_changed.emit(role, get_path())

# 销毁基地时的处理
func _on_base_destroyed() -> void:
	GM.unregister_base(self)
	queue_free()

# 获取防御值（供伤害计算使用）
func get_defense() -> int:
	return defense


# ------------ 耐久血条 ------------
# 惰性创建血条（子类 _ready 未调用 super，故放在 _physics_process 首次执行时创建）
func _ensure_health_bar() -> void:
	if health_bar != null:
		return
	health_bar = HealthBarScript.new()
	add_child(health_bar)
	health_bar.setup(self, health_bar_always_visible, Vector2(16, -10))


# 受击通知：敌方血条临时显示（由 DamageCalculator 调用）
func _on_damaged() -> void:
	if health_bar != null:
		health_bar.on_damaged()


# 头顶世界坐标（用于浮动伤害数字定位；基地视觉中心在原点 + (16, 16)）
func get_head_world_position() -> Vector2:
	return global_position + Vector2(16, -8)
