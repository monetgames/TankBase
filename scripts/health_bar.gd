extends Node2D
class_name HealthBar

## 单位耐久血条
## 我方坦克/基地长期显示；敌方坦克/基地受攻击后显示 5 秒，5 秒内无被攻击则隐藏。

const WIDTH := 32.0
const HEIGHT := 4.0
const HIDE_DELAY := 5.0

# 能量条（护盾/能量站）：耐久条下方紧挨的一条细窄条
const ENERGY_BAR_HEIGHT := 2.0
const ENERGY_GAP := 2.0
const ENERGY_FILL := Color("#f1f1f1")

const BG_COLOR := Color(0.0, 0.0, 0.0, 0.55)
const BORDER_COLOR := Color(0.0, 0.0, 0.0, 0.85)
const FILL_HIGH := Color(0.59, 0.77, 0.35)   # 绿（耐久充足）
const FILL_MID := Color(0.94, 0.62, 0.15)    # 黄（耐久中等）
const FILL_LOW := Color(0.89, 0.29, 0.29)    # 红（耐久危险）

var target: Node = null
var always_visible := false
var forced_visible := false
var _hide_timer := 0.0


## 绑定目标单位并设置显示策略。
## @param t: 目标单位（需有 current_hp / max_hp）
## @param always: 是否长期显示（我方 true，敌方 false）
## @param offset: 相对单位原点的血条中心位置
func setup(t: Node, always: bool, offset: Vector2) -> void:
	target = t
	always_visible = always
	position = offset
	z_index = 10
	visible = always
	set_process(true)


## 受击通知：敌方血条临时显示 5 秒（由 DamageCalculator 调用）
func on_damaged() -> void:
	if always_visible:
		return
	_hide_timer = HIDE_DELAY
	visible = true


## 强制显示（雷达 show_enemy_health）：true 时常显；false 时交还受击计时逻辑隐藏
func set_forced_visible(v: bool) -> void:
	forced_visible = v
	if v:
		visible = true


func _process(delta: float) -> void:
	if not is_instance_valid(target):
		queue_free()
		return
	if not always_visible and not forced_visible and visible:
		_hide_timer -= delta
		if _hide_timer <= 0.0:
			visible = false
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(target):
		return
	var max_hp := float(target.max_hp)
	if max_hp <= 0.0:
		return
	var ratio := clampf(float(target.current_hp) / max_hp, 0.0, 1.0)
	var x := -WIDTH / 2.0
	draw_rect(Rect2(x - 1.0, -1.0, WIDTH + 2.0, HEIGHT + 2.0), BORDER_COLOR)
	draw_rect(Rect2(x, 0.0, WIDTH, HEIGHT), BG_COLOR)
	if ratio > 0.0:
		draw_rect(Rect2(x, 0.0, WIDTH * ratio, HEIGHT), _fill_color(ratio))
	_draw_energy_bar(x)


## 在耐久条下方绘制能量条（坦克=护盾能量，基地=能量站储量）
func _draw_energy_bar(x: float) -> void:
	var cur := -1.0
	var max_v := 0.0
	# 坦克护盾能量
	if "max_shield_energy" in target and float(target.max_shield_energy) > 0.0:
		max_v = float(target.max_shield_energy)
		cur = float(target.shield_energy)
	# 基地能量站储量
	elif "max_charge_capacity" in target and float(target.max_charge_capacity) > 0.0:
		max_v = float(target.max_charge_capacity)
		cur = float(target.current_charge)
	else:
		return
	if max_v <= 0.0:
		return
	var ratio := clampf(cur / max_v, 0.0, 1.0)
	var y := HEIGHT + ENERGY_GAP
	draw_rect(Rect2(x - 1.0, y - 1.0, WIDTH + 2.0, ENERGY_BAR_HEIGHT + 2.0), BORDER_COLOR)
	draw_rect(Rect2(x, y, WIDTH, ENERGY_BAR_HEIGHT), BG_COLOR)
	if ratio > 0.0:
		draw_rect(Rect2(x, y, WIDTH * ratio, ENERGY_BAR_HEIGHT), ENERGY_FILL)


func _fill_color(ratio: float) -> Color:
	if ratio > 0.5:
		return FILL_HIGH
	elif ratio > 0.25:
		return FILL_MID
	return FILL_LOW
