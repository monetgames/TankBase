extends Control
@onready var countdown_label: Label = $CountdownLabel

## 战斗循环场景
## 管理战斗中的波次显示和进度

# ===== 状态 =====
var _countdown_timer: float = 0.0
var _is_counting_down: bool = false
var _countdown_prefix: String = "下一波次："


func _ready() -> void:
	# 连接 GameManager 信号
	GM.wave_changed.connect(_on_wave_changed)
	GM.loot_gather_started.connect(_on_loot_gather_started)
	
	# 连接 WaveManager 信号
	WaveManager.wave_started.connect(_on_wave_started)


func _process(delta: float) -> void:
	# 更新波次间隔倒计时显示
	if _is_counting_down:
		_countdown_timer -= delta
		if _countdown_timer <= 0:
			_is_counting_down = false
			countdown_label.visible = false
		else:
			countdown_label.text = "%s%d 秒" % [_countdown_prefix, int(ceil(_countdown_timer))]


# ===== 信号处理 =====

func _on_wave_changed(wave: int) -> void:
	# 启动倒计时显示（下一波生成倒计时）
	_countdown_prefix = "下一波次倒计时："
	_start_wave_interval_countdown(WaveManager.wave_interval)


## 捡金币阶段开始（波次结束后、商店弹出前）
func _on_loot_gather_started(seconds: float) -> void:
	_countdown_prefix = "波间补给站倒计时："
	_start_wave_interval_countdown(seconds)


func _on_wave_started(_stage: int, _wave: int) -> void:
	_is_counting_down = false
	if countdown_label:
		countdown_label.visible = false

# ===== UI 更新 =====

func _start_wave_interval_countdown(seconds: float) -> void:
	_countdown_timer = seconds
	_is_counting_down = true
	if countdown_label:
		countdown_label.visible = true
		countdown_label.text = "%s%d 秒" % [_countdown_prefix, int(ceil(seconds))]
