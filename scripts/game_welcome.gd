extends Control

## 游戏主菜单
## 按钮组（场景静态节点，可在编辑器直观调整）：
##   继续游戏（有存档时显示）/ 开始游戏·新游戏 / 设置 / 关于 / 退出游戏
## 存档规则见 SaveSystem：进入战役后才开始落盘；新游戏在通过新战役第一关前保护旧档。

const SettingsMenuScene := preload("res://scenes/ui/settings_menu.tscn")

@onready var continue_button: Button = $CenterLayout/VBox/ContinueGameButton
@onready var start_button: Button = $CenterLayout/VBox/StartGameButton
@onready var settings_button: Button = $CenterLayout/VBox/SettingsButton
@onready var about_button: Button = $CenterLayout/VBox/AboutButton
@onready var exit_button: Button = $CenterLayout/VBox/ExitButton
@onready var tank_body: AnimatedSprite2D = $CenterLayout/VBox/IconRow/TankIcon/Body
@onready var base_sprite: AnimatedSprite2D = $CenterLayout/VBox/IconRow/BaseIcon/Base
@onready var about_layer: CanvasLayer = $AboutLayer
@onready var about_overlay: Control = $AboutLayer/Overlay
@onready var about_close_btn: Button = $AboutLayer/Overlay/Center/AboutPanel/VBox/AboutCloseButton
@onready var copy_url_btn: Button = $AboutLayer/Overlay/Center/AboutPanel/VBox/RepoRow/CopyUrlButton
@onready var version_label: Label = $AboutLayer/Overlay/Center/AboutPanel/VBox/VersionLabel

var _settings_menu: CanvasLayer = null
var _copy_tween: Tween = null

func _ready() -> void:
	continue_button.pressed.connect(_on_continue_pressed)
	start_button.pressed.connect(_on_start_pressed)
	settings_button.pressed.connect(_toggle_settings)
	about_button.pressed.connect(_show_about)
	exit_button.pressed.connect(_on_exit_pressed)
	about_close_btn.pressed.connect(func(): about_layer.visible = false)
	copy_url_btn.pressed.connect(_on_copy_url_pressed)
	# 点击"关于"面板外的半透明区域 → 关闭（面板及按钮会拦截自身点击）
	about_overlay.gui_input.connect(_on_about_overlay_gui_input)
	# 按钮音效 + Q 弹动效（鼠标进入 / 按下）
	for btn in [continue_button, start_button, settings_button, about_button, exit_button, about_close_btn]:
		_add_button_fx(btn)
	_refresh_buttons()
	# 版本号从 project.godot 的 application/config/version 读取，避免各处手写不同步
	version_label.text = "版本号：" + str(ProjectSettings.get_setting("application/config/version", "0.0.1"))
	tank_body.play("idle")
	base_sprite.play("idle")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if about_layer.visible:
			about_layer.visible = false
		else:
			_toggle_settings()
		get_viewport().set_input_as_handled()


## 按是否存在存档切换按钮：无档 → 开始游戏；有档 → 继续游戏 + 新游戏
## 通关第 10 战役后（cycle_count > 0），继续按钮显性化为循环挑战轮次
## 轮次从 1 起算：首次通关后进入第 1 轮，通关后递增为第 2 轮
func _refresh_buttons() -> void:
	var has_save: bool = SaveSystem.has_save()
	continue_button.visible = has_save
	start_button.text = "新 游 戏" if has_save else "开 始 游 戏"
	if has_save and GameState.cycle_count > 0:
		continue_button.text = "循环挑战（第 %d 轮）" % GameState.cycle_count
	else:
		continue_button.text = "继 续 游 戏"
	_apply_uniform_button_width()


## 统一主菜单按钮宽度：全部按"循环挑战（第 N 轮）"文案取宽，保证五个按钮同宽
## 场景内基准宽 229px（= 第 1 轮文案宽 209 + 按钮内边距 20）；两位数轮次时整体加宽，
## 避免继续按钮单独变宽破坏对齐。
func _apply_uniform_button_width() -> void:
	var buttons: Array[Button] = [continue_button, start_button, settings_button, about_button, exit_button]
	var probe := "循环挑战（第 %d 轮）" % maxi(GameState.cycle_count, 1)
	var width := 0.0
	for btn in buttons:
		width = maxf(width, btn.custom_minimum_size.x)
		var font: Font = btn.get_theme_font("font")
		if font == null:
			continue
		var font_size: int = btn.get_theme_font_size("font_size")
		var pad := 0.0
		var style: StyleBox = btn.get_theme_stylebox("normal")
		if style != null:
			pad = style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT)
		width = maxf(width, font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x + pad)
	if width > 0.0:
		for btn in buttons:
			btn.custom_minimum_size.x = width


## 继续游戏：从磁盘恢复最新存档进度（同时覆盖内存中的临时/新游戏状态）
func _on_continue_pressed() -> void:
	if not SaveSystem.load_game():
		push_warning("GameWelcome: 继续游戏失败（存档读取失败）")
		return
	GM.continue_game_from_save()


## 开始游戏/新游戏：全新档案；有旧档时进入保护期（通过新战役第一关前不落盘）
## 先播"作战简报"（新手指引剧情），播完进入指挥部；「继续游戏」不播简报
func _on_start_pressed() -> void:
	SaveSystem.start_new_game(SaveSystem.has_save())
	get_tree().change_scene_to_file("res://scenes/story_intro.tscn")


func _on_exit_pressed() -> void:
	SaveSystem.save_settings()
	get_tree().quit()


func _on_about_overlay_gui_input(event: InputEvent) -> void:
	# 半透明遮罩被点击（未被面板消费）→ 关闭关于窗口
	if event is InputEventMouseButton and event.pressed:
		about_layer.visible = false


# ===== 设置窗口 =====

func _toggle_settings() -> void:
	if _settings_menu == null:
		_settings_menu = SettingsMenuScene.instantiate()
		add_child(_settings_menu)
	if _settings_menu.is_open():
		_settings_menu.close()
	else:
		_settings_menu.open()


# ===== 关于窗口 =====

func _show_about() -> void:
	about_layer.visible = true


# ===== 复制仓库网址 =====

## 复制官网仓库地址到剪贴板，并把按钮文字临时变为"已复制网址"作为提示
func _on_copy_url_pressed() -> void:
	DisplayServer.clipboard_set("https://github.com/monetgames/TankBase")
	if _copy_tween != null and _copy_tween.is_valid():
		_copy_tween.kill()
	copy_url_btn.text = "已复制网址"
	_copy_tween = copy_url_btn.create_tween()
	_copy_tween.tween_interval(1.2)
	_copy_tween.tween_callback(func():
		copy_url_btn.text = "复制网址")


# ===== 按钮 Q 弹动效 =====
# 按钮音效由 AudioManager 全局挂接（所有 BaseButton 悬停/按下随机 pitch），此处只做动效

var _fx_tweens: Dictionary = {}  # Button -> Tween（新动效前杀旧动效，避免叠加打架）


## 挂接 Q 弹反馈：鼠标进入（压扁弹起）、按下（更强压扁）
func _add_button_fx(btn: Button) -> void:
	btn.mouse_entered.connect(_fx_hover.bind(btn))
	btn.pressed.connect(_fx_pressed.bind(btn))


func _fx_hover(btn: Button) -> void:
	_fx_bounce(btn, Vector2(1.08, 0.92), 0.08)


func _fx_pressed(btn: Button) -> void:
	_fx_bounce(btn, Vector2(1.14, 0.86), 0.05)


## 压扁后弹性回弹：先快速压到 squash，再 ELASTIC 弹回 1:1（pivot 居中，缩放不偏移）
func _fx_bounce(btn: Button, squash: Vector2, hit_time: float) -> void:
	if _fx_tweens.has(btn):
		var old: Tween = _fx_tweens[btn]
		old.kill()
	btn.pivot_offset = btn.size / 2.0
	var tw := btn.create_tween()
	tw.tween_property(btn, "scale", squash, hit_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_fx_tweens[btn] = tw
