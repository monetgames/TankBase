extends Control
class_name StoryIntro
## 新手指引剧情播放器（冷硬军事简报风，6 幕）
##
## 入口：主菜单「开始游戏/新游戏」→ 播完进入 META 循环并落盘已看标记。
## 「继续游戏」不播放本简报。
##
## 交互：空格/回车/点击画面推进（打字中先补完全文）；第二幕起可用「上一篇」回看上一幕；不提供跳过。

const TYPE_SPEED := 28.0            # 打字机速度（字/秒）
const TICK_INTERVAL := 4            # 每 N 个字符播放一次打字音
const COLOR_DOT_ON := Color("#97C459")
const COLOR_DOT_OFF := Color("#2E3D28")

const _TEXTURES: Array[Texture2D] = [
	preload("res://sprites/story/intro_01.png"),
	preload("res://sprites/story/intro_02.png"),
	preload("res://sprites/story/intro_03.png"),
	preload("res://sprites/story/intro_04.png"),
	preload("res://sprites/story/intro_05.png"),
	preload("res://sprites/story/intro_06.png"),
]

@onready var title_label: Label = $Margin/VBox/Header/Title
@onready var page_label: Label = $Margin/VBox/Header/Page
@onready var art: TextureRect = $Margin/VBox/ArtPanel/ArtCenter/Art
@onready var body_label: Label = $Margin/VBox/BodyPanel/BodyVBox/Body
@onready var tip_label: Label = $Margin/VBox/BodyPanel/BodyVBox/Tip
@onready var dots_box: HBoxContainer = $Margin/VBox/BottomBar/Dots
@onready var prev_button: Button = $Margin/VBox/BottomBar/PrevButton
@onready var next_button: Button = $Margin/VBox/BottomBar/NextButton

var _slides: Array[Dictionary] = StoryIntroData.SLIDES
var _index := 0
var _type_accum := 0.0
var _tick_count := 0
var _is_typing := false
var _finished := false
var _dots: Array[ColorRect] = []


func _ready() -> void:
	# Q 弹动效（悬停/按下音效由 AudioManager 全局挂接，这里不再重复播）
	for btn: Button in [prev_button, next_button]:
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_button_pressed.bind(btn))
	next_button.pressed.connect(_advance.bind(false))
	prev_button.pressed.connect(_go_back)
	# 点击画面任意处推进（按钮自身会拦截点击，不会双触发）
	$Background.gui_input.connect(_on_background_input)

	_build_dots()
	_show_slide(0)


func _process(delta: float) -> void:
	if not _is_typing or _finished:
		return
	_type_accum += delta * TYPE_SPEED
	var total := body_label.text.length()
	var target := mini(int(_type_accum), total)
	if target != body_label.visible_characters:
		body_label.visible_characters = target
		_tick_count += 1
		if _tick_count % TICK_INTERVAL == 0:
			AudioManager.play_sfx("button_hover", -24.0, randf_range(1.5, 1.8))
	if target >= total:
		_on_typing_done()


func _unhandled_input(event: InputEvent) -> void:
	# 只保留空格/回车推进；先标记事件已处理再推进，
	# 因为最后一幕 _finish 会切场景，离树后 get_viewport() 为 null
	if _finished:
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_advance()


# ===== 幕切换 =====

func _show_slide(i: int) -> void:
	_index = i
	var slide: Dictionary = _slides[i]
	title_label.text = slide["title"]
	page_label.text = "简报 %02d / %02d" % [i + 1, _slides.size()]
	art.texture = _TEXTURES[i]
	art.modulate.a = 0.0
	var tw := art.create_tween()
	tw.tween_property(art, "modulate:a", 1.0, 0.25)

	# 重置打字机（先隐藏要点，正文打完再淡入）
	body_label.text = slide["body"]
	body_label.visible_characters = 0
	tip_label.text = "▶ 要点：" + slide["tip"]
	_type_accum = 0.0
	_tick_count = 0
	_is_typing = true
	tip_label.modulate.a = 0.0

	prev_button.visible = i > 0
	next_button.text = "继续 ▶" if i < _slides.size() - 1 else "开始作战 ▶"
	_refresh_dots()


func _advance(play_sound := true) -> void:
	if _finished:
		return
	if play_sound:
		# 空格/回车/点击画面推进的反馈音（按钮点击的音效由全局挂接负责）
		AudioManager.play_sfx("button", -4.0, randf_range(0.9, 1.1))
	if _is_typing:
		# 打字中第一次点击：补完全文
		body_label.visible_characters = body_label.text.length()
		_on_typing_done()
		return
	if _index >= _slides.size() - 1:
		_finish()
	else:
		_show_slide(_index + 1)


func _go_back() -> void:
	if _finished or _index <= 0:
		return
	_show_slide(_index - 1)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	AudioManager.play_sfx("upgrade", -2.0, 1.0)
	if SaveSystem:
		SaveSystem.mark_story_intro_seen()
	GM.transition_to_loop(GameManager.GameLoop.META)


func _on_typing_done() -> void:
	_is_typing = false
	body_label.visible_characters = -1  # -1 = 全部可见（防最后字符差一）
	var tw := tip_label.create_tween()
	tw.tween_property(tip_label, "modulate:a", 1.0, 0.2)


# ===== UI 构建 =====

func _build_dots() -> void:
	for i in _slides.size():
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(14, 6)
		dot.color = COLOR_DOT_OFF
		dots_box.add_child(dot)
		_dots.append(dot)


func _refresh_dots() -> void:
	for i in _dots.size():
		_dots[i].color = COLOR_DOT_ON if i <= _index else COLOR_DOT_OFF


func _on_button_pressed(btn: Button) -> void:
	btn.pivot_offset = btn.size / 2.0
	var tw := btn.create_tween()
	tw.tween_property(btn, "scale", Vector2(1.14, 0.86), 0.05)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.4) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_advance()
