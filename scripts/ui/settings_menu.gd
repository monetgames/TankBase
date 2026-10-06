extends CanvasLayer

## 设置窗口：全局 ESC 唤起，可在游戏中随时打开。
## 功能：音乐/音量滑块（释放时试听）、操作手册（场景静态节点）、屏幕模式（窗口/全屏）、返回主菜单。
## 行为：点击面板外半透明区域或再按 ESC 关闭；
##       战斗循环中打开时暂停游戏、关闭恢复；Meta/构筑/主菜单中打开不暂停。

var _is_open: bool = false
var _paused_by_self: bool = false

@onready var _overlay: Control = $Overlay
@onready var _music_slider: HSlider = $Overlay/Center/Panel/VBox/MusicRow/MusicSlider
@onready var _music_value: Label = $Overlay/Center/Panel/VBox/MusicRow/MusicValue
@onready var _sfx_slider: HSlider = $Overlay/Center/Panel/VBox/SfxRow/SfxSlider
@onready var _sfx_value: Label = $Overlay/Center/Panel/VBox/SfxRow/SfxValue
@onready var _screen_btn: Button = $Overlay/Center/Panel/VBox/ScreenRow/ScreenButton
@onready var _tutorial_btn: Button = $Overlay/Center/Panel/VBox/TutorialRow/TutorialButton
@onready var _manual_btn: Button = $Overlay/Center/Panel/VBox/ManualButton
@onready var _menu_btn: Button = $Overlay/Center/Panel/VBox/MenuButton
@onready var _close_btn: Button = $Overlay/Center/Panel/VBox/CloseButton
@onready var _manual_center: CenterContainer = $Overlay/ManualCenter
@onready var _manual_close_btn: Button = $Overlay/ManualCenter/ManualPanel/VBox/ManualCloseButton


func _ready() -> void:
	# ALWAYS：未暂停（主菜单/Meta/构筑/结算）与已暂停（战斗中打开）都要响应按钮与 ESC。
	# 注意不能用 WHEN_PAUSED——它意味着"仅暂停时处理"，未暂停场景下整个窗口会被冻结（按钮点不了）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	# 点击面板外的半透明区域 → 关闭（Panel 及其子控件 STOP 会拦截自身点击）
	_overlay.gui_input.connect(_on_overlay_gui_input)
	# 手册打开时点击手册面板外区域 → 仅关闭手册（返回设置）
	_manual_center.gui_input.connect(_on_manual_center_gui_input)
	_music_slider.value_changed.connect(_on_music_changed)
	_sfx_slider.value_changed.connect(_on_sfx_changed)
	# 拖动结束（鼠标释放）→ 试听当前音量，让用户直观感知调整结果
	_music_slider.drag_ended.connect(_on_music_drag_ended)
	_sfx_slider.drag_ended.connect(_on_sfx_drag_ended)
	_screen_btn.pressed.connect(_on_screen_pressed)
	# 窗口模式实际生效（含回退）后刷新按钮文案
	SaveSystem.window_mode_changed.connect(func(_is_full: bool): _sync_screen_button())
	_tutorial_btn.pressed.connect(_on_tutorial_pressed)
	_manual_btn.pressed.connect(_show_manual)
	_manual_close_btn.pressed.connect(func(): _manual_center.visible = false)
	_menu_btn.pressed.connect(_on_menu_pressed)
	_close_btn.pressed.connect(close)


func _on_manual_center_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_manual_center.visible = false


func _unhandled_input(event: InputEvent) -> void:
	# 打开状态下再按 ESC → 关闭（与各场景的 ESC 唤起方互斥：双方都 set_input_as_handled）
	if _is_open and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


## 打开设置窗口（战斗循环中暂停游戏）
func open() -> void:
	visible = true
	_is_open = true
	_manual_center.visible = false
	# 主菜单中打开时不提供"返回主菜单"；战斗循环外关闭按钮为"关闭"
	_menu_btn.visible = GM.current_loop != GameManager.GameLoop.WELCOME
	_close_btn.text = "返回游戏" if GM.current_loop == GameManager.GameLoop.COMBAT else "关闭"
	_paused_by_self = false
	if GM.current_loop == GameManager.GameLoop.COMBAT and not get_tree().paused:
		get_tree().paused = true
		_paused_by_self = true
	_sync_ui()


## 关闭设置窗口（若由本窗口暂停则恢复游戏）
func close() -> void:
	visible = false
	_is_open = false
	# 关闭后释放全视口焦点：避免按 ESC 关闭时，触发按钮/其它控件仍处于 focus 高亮态（绿色残留）
	get_viewport().gui_release_focus()
	if _paused_by_self:
		get_tree().paused = false
		_paused_by_self = false


func _on_overlay_gui_input(event: InputEvent) -> void:
	# 半透明遮罩被点击（未被面板消费）→ 关闭设置
	if event is InputEventMouseButton and event.pressed:
		close()


# ===== 音量 =====

func _sync_ui() -> void:
	_music_slider.value = round(AudioManager.music_volume * 100.0)
	_music_value.text = "%d%%" % int(_music_slider.value)
	_sfx_slider.value = round(AudioManager.sfx_volume * 100.0)
	_sfx_value.text = "%d%%" % int(_sfx_slider.value)
	_sync_screen_button()
	_sync_tutorial_button()


func _on_music_changed(value: float) -> void:
	AudioManager.set_music_volume(value / 100.0)
	_music_value.text = "%d%%" % int(value)
	SaveSystem.save_settings()


func _on_sfx_changed(value: float) -> void:
	AudioManager.set_sfx_volume(value / 100.0)
	_sfx_value.text = "%d%%" % int(value)
	SaveSystem.save_settings()


func _on_music_drag_ended(value_changed: bool) -> void:
	# 鼠标释放且值有变化 → 音乐总线试听（不打断当前 BGM）
	if value_changed:
		AudioManager.play_music_preview()


func _on_sfx_drag_ended(value_changed: bool) -> void:
	# 鼠标释放且值有变化 → 音效总线试听
	if value_changed:
		AudioManager.play_sfx("pickup")


# ===== 新手指引 =====

func _sync_tutorial_button() -> void:
	_tutorial_btn.text = "开启" if SaveSystem.is_tutorial_enabled() else "关闭"


func _on_tutorial_pressed() -> void:
	# 关闭不清除完成记录；重新开启后未完成的指引下次遇到仍会弹出（错过补课）
	SaveSystem.set_tutorial_enabled(not SaveSystem.is_tutorial_enabled())
	_sync_tutorial_button()


# ===== 屏幕模式 =====

func _sync_screen_button() -> void:
	if SaveSystem.is_fullscreen():
		_screen_btn.text = "全屏模式"
	elif SaveSystem.is_using_fullscreen_fallback():
		# 已尝试全屏但运行环境不支持（编辑器内嵌窗口只支持窗口模式）
		_screen_btn.text = "全屏（不可用）"
	else:
		_screen_btn.text = "窗口模式"


func _on_screen_pressed() -> void:
	# 统一走 SaveSystem：不支持真全屏的运行环境（Windows 编辑器内嵌窗口会提示
	# "Embedded window only supports Windowed mode."）会自动回退为无边框最大化窗口，
	# 并由 SaveSystem 负责落盘；按钮文案延后一帧同步，确保显示最终生效的模式
	SaveSystem.set_fullscreen(not SaveSystem.is_fullscreen())
	_sync_screen_button()


# ===== 返回主菜单 =====

func _on_menu_pressed() -> void:
	# 离开游戏前落盘当前进度（新游戏未通过第一关时自动跳过，保护旧存档）
	SaveSystem.save_game()
	if _paused_by_self:
		get_tree().paused = false
		_paused_by_self = false
	_is_open = false
	visible = false
	GM.transition_to_loop(GameManager.GameLoop.WELCOME)


# ===== 操作手册（像素风按键说明）=====

## 显示操作手册面板（位于设置面板之上，点击"关闭"返回设置）
## 手册内容为场景静态节点（settings_menu.tscn 的 ManualList），可在编辑器直观调整
func _show_manual() -> void:
	_manual_center.visible = true
