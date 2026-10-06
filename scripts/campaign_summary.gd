extends Control

## 战役总结界面（美化版）
## 军规 UI 统一配色（UIPalette）+ 数值滚动/评级弹出动画 + 胜利烟花特效
##
## 动画时间线（胜利）：
##   0.0s 标题弹入 + 金色闪光 → 0.4s 统计/奖励行渐入（数值滚动 1.4s）
##   → 1.2s 根据最终统计计算评级后，评级徽章弹出（5 因素取最低：坦克/基地耐久损耗、击毁敌方坦克/基地、耗时）
##   → 1.3s 烟花层开始燃放，播放 max(2, ceil(统计滚动总时长/单次时长)) 遍后淡出

# ===== 节点引用 =====
@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleRow/TitleLabel
@onready var rating_badge: PanelContainer = $MarginContainer/VBoxContainer/TitleRow/RatingBadge
@onready var rating_label: Label = $MarginContainer/VBoxContainer/TitleRow/RatingBadge/RatingLabel
@onready var subtitle_label: Label = $MarginContainer/VBoxContainer/SubtitleLabel
@onready var stats_container: VBoxContainer = $MarginContainer/VBoxContainer/StatsCard/StatsPanel/StatsContainer
@onready var rewards_scroll: ScrollContainer = $MarginContainer/VBoxContainer/RewardsCard/RewardsPanel/RewardsScroll
@onready var rewards_container: VBoxContainer = $MarginContainer/VBoxContainer/RewardsCard/RewardsPanel/RewardsScroll/RewardsContainer
@onready var return_btn: Button = $MarginContainer/VBoxContainer/BottomBar/ReturnMetaButton
@onready var flash_rect: ColorRect = $FlashRect
@onready var fireworks_layer: Control = $FireworksLayer

# ===== 统计数据 =====
var _is_victory: bool = false
var _stats: Dictionary = {}
var _setup_done := false  # 防止快照兜底与 GM 信号重复触发两次动画
var _stats_anim_end := 0.0  # 统计数值滚动的结束时刻（决定烟花播放次数）

# ===== 设置窗口（ESC 唤起）=====
const SettingsMenuScene := preload("res://scenes/ui/settings_menu.tscn")
var _settings_menu: CanvasLayer = null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not get_tree().paused:
		_toggle_settings()
		get_viewport().set_input_as_handled()


func _toggle_settings() -> void:
	if _settings_menu == null:
		_settings_menu = SettingsMenuScene.instantiate()
		add_child(_settings_menu)
	if _settings_menu.is_open():
		_settings_menu.close()
	else:
		_settings_menu.open()


func _ready() -> void:
	return_btn.pressed.connect(_on_return_meta_pressed)
	# 场景中的标签只是编辑器占位，最终评级计算完成前不得显示。
	rating_badge.visible = false

	# 监听 GameManager 信号（场景切换后发出）
	GM.campaign_victory.connect(_on_campaign_victory)
	GM.campaign_defeat.connect(_on_campaign_defeat)

	# 快照兜底（主路径）：结算信号可能早于本场景 _ready 发出而丢失，
	# 直接从 GameState.stats_snapshot 读取显示，保证数据不空
	var snapshot: Dictionary = _calculate_statistics()
	if not snapshot.is_empty():
		if snapshot.get("victory", false):
			setup_victory(snapshot)
		else:
			setup_defeat(str(snapshot.get("reason", "")), snapshot)


## 配置胜利界面
## @param stats: 统计数据字典
func setup_victory(stats: Dictionary = {}) -> void:
	if _setup_done:
		return
	_setup_done = true
	_is_victory = true
	_stats = stats
	_display_victory()


## 配置失败界面
## @param reason: 失败原因
## @param stats: 统计数据字典
func setup_defeat(reason: String = "", stats: Dictionary = {}) -> void:
	if _setup_done:
		return
	_setup_done = true
	_is_victory = false
	_stats = stats
	_stats["reason"] = reason
	_display_defeat(str(_stats.get("reason", "")))


func _on_campaign_victory() -> void:
	setup_victory(_calculate_statistics())


func _on_campaign_defeat(reason: String) -> void:
	setup_defeat(reason, _calculate_statistics())


# ===== 界面显示 =====

func _display_victory() -> void:
	title_label.text = "战役胜利！"
	title_label.add_theme_color_override("font_color", UIPalette.YELLOW)
	subtitle_label.text = "第 %d 关 · 第 %d 波 作战完成" % [
		_stats.get("stage", GM.current_stage),
		_stats.get("wave", GM.current_wave),
	]
	subtitle_label.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
	rating_badge.visible = false

	_populate_stats()
	_populate_rewards()
	_play_intro()


func _display_defeat(reason: String) -> void:
	title_label.text = "战役失败"
	title_label.add_theme_color_override("font_color", UIPalette.RED)

	# 进度与失败原因合并进副标题（颜色与胜利副标题一致）
	var reason_text := "战役失败"
	match reason:
		"player_tank_destroyed":
			reason_text = "坦克被摧毁"
		"player_base_destroyed":
			reason_text = "基地被摧毁"
	subtitle_label.text = "第 %d 关 · 第 %d 波 %s" % [
		_stats.get("stage", GM.current_stage),
		_stats.get("wave", GM.current_wave),
		reason_text,
	]
	subtitle_label.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
	rating_badge.visible = false

	_populate_stats()
	_populate_rewards()
	_play_intro()


## 入场动画编排
func _play_intro() -> void:
	# 等一帧让容器完成布局，pivot/scale 才有正确的中心
	await get_tree().process_frame
	if not is_inside_tree():
		return

	_animate_title()
	if _is_victory:
		_flash()
		_show_rating_later()
		_spawn_fireworks_later()
	else:
		_pulse_title_later()

	# 等布局稳定后收缩会溢出的明细字号，保证整行放下
	await get_tree().process_frame
	if is_inside_tree():
		_fit_rows(stats_container)

	# 键盘/手柄可直接确认返回
	return_btn.grab_focus()


func _animate_title() -> void:
	title_label.pivot_offset = title_label.size / 2.0
	title_label.modulate.a = 0.0
	title_label.scale = Vector2(1.8, 1.8)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(title_label, "modulate:a", 1.0, 0.2)
	tw.tween_property(title_label, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _flash() -> void:
	flash_rect.color.a = 0.3
	create_tween().tween_property(flash_rect, "color:a", 0.0, 0.4)


func _show_rating_later() -> void:
	await get_tree().create_timer(1.2).timeout
	if not is_inside_tree():
		return
	var rating := _compute_rating()
	rating_label.text = rating.grade
	rating_label.add_theme_color_override("font_color", rating.color)
	rating_badge.modulate.a = 0.0
	rating_badge.scale = Vector2(2.2, 2.2)
	rating_badge.visible = true
	# 显示后等布局刷新，确保徽章以正确的中心点弹出。
	await get_tree().process_frame
	if not is_inside_tree():
		return
	rating_badge.pivot_offset = rating_badge.size / 2.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(rating_badge, "modulate:a", 1.0, 0.18)
	tw.tween_property(rating_badge, "scale", Vector2.ONE, 0.45) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pulse_title_later() -> void:
	# 失败：标题缓慢呼吸两轮，克制不闹
	await get_tree().create_timer(0.8).timeout
	if not is_inside_tree():
		return
	var tw := create_tween()
	tw.tween_property(title_label, "modulate:a", 0.6, 0.5)
	tw.tween_property(title_label, "modulate:a", 1.0, 0.5)
	tw.set_loops(2)


func _spawn_fireworks_later() -> void:
	await get_tree().create_timer(1.3).timeout
	if not is_inside_tree():
		return
	var area := fireworks_layer.size
	# 播放次数：两遍与统计数值滚动时长取长（向上取整保留整数遍）
	var plays := maxi(2, ceili(_stats_anim_end / FIREWORKS_PLAY_SEC))
	# 主烟花层
	FireworksEffect.spawn_at(fireworks_layer, area / 2.0, area.y * 0.95, 0.9, plays)
	# 回声层：延迟错位镜像、更淡，制造纵深感
	await get_tree().create_timer(1.1).timeout
	if not is_inside_tree():
		return
	FireworksEffect.spawn_at(
		fireworks_layer,
		area / 2.0 + Vector2(randf_range(-40.0, 40.0), -16.0),
		area.y * 0.85, 0.55, plays)


# ===== 行构建与数值动画 =====

## 添加一行「键：值」条目，可选行内明细与行尾评级字母；返回 {row, value}（value 用于数值滚动）
## final_value_text：数值滚动结束时的最终文本，供行宽测量用（滚动起始文本偏短会低估宽度）
func _add_row(container: VBoxContainer, key_text: String, delay: float, value_color: Color,
		grade: String = "", detail: String = "", final_value_text: String = "") -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var key_label := Label.new()
	key_label.text = key_text + "："
	key_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
	key_label.add_theme_color_override("font_color", UIPalette.TEXT_MAIN)
	row.add_child(key_label)

	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
	value_label.add_theme_color_override("font_color", value_color)
	row.add_child(value_label)

	if not detail.is_empty():
		var detail_label := Label.new()
		detail_label.text = detail
		detail_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
		detail_label.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
		row.add_child(detail_label)
		row.set_meta("detail_label", detail_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	if not grade.is_empty():
		var grade_label := Label.new()
		grade_label.text = grade
		grade_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
		grade_label.add_theme_color_override("font_color", _grade_color(grade))
		row.add_child(grade_label)

	row.set_meta("value_label", value_label)
	row.set_meta("final_value_text", final_value_text if not final_value_text.is_empty() else value_label.text)

	row.modulate.a = 0.0
	container.add_child(row)
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(row, "modulate:a", 1.0, 0.25)
	return {"row": row, "value": value_label}


## 布局稳定后逐行检查宽度：明细可能撑爆整行时，向下试探能放下的最大字号
## （2px 一档，能保持 24px 原字号就保持，即将溢出才缩小，且只缩到刚好放下）
func _fit_rows(container: VBoxContainer) -> void:
	var available := container.size.x
	if available <= 0.0:
		return
	for child in container.get_children():
		var hbox := child as HBoxContainer
		if hbox == null or not hbox.has_meta("detail_label"):
			continue
		var detail_label: Label = hbox.get_meta("detail_label")
		var value_label: Label = hbox.get_meta("value_label")
		var final_text: String = hbox.get_meta("final_value_text")
		var size := int(detail_label.get_theme_font_size("font_size"))
		var needed := _row_needed_width(hbox, value_label, final_text, size)
		while needed > available and size > UIPalette.FONT_S:
			size -= 2
			needed = _row_needed_width(hbox, value_label, final_text, size)
		detail_label.add_theme_font_size_override("font_size", size)


## 计算一行在给定明细字号下的总宽度
func _row_needed_width(row: HBoxContainer, value_label: Label, final_text: String, detail_size: int) -> float:
	var font := value_label.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	var sep := 4.0
	var needed := 0.0
	var children := row.get_children()
	for i in children.size():
		var lbl := children[i] as Label
		if lbl == null:
			continue
		var text := lbl.text
		var size := int(lbl.get_theme_font_size("font_size"))
		if lbl == value_label:
			text = final_text
		elif row.get_meta("detail_label") == lbl:
			size = detail_size
		needed += font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if i < children.size() - 1:
			needed += sep
	return needed


## 构建行内明细文本（如「（普通×7 精英×2）」），无数据返回空串
func _build_level_detail(by_level: Dictionary) -> String:
	var parts: Array = []
	for lv in ["normal", "elite", "boss"]:
		if by_level.has(lv) and int(by_level[lv]) > 0:
			parts.append("%s×%d" % [_get_level_display_name(lv), int(by_level[lv])])
	if parts.is_empty():
		return ""
	return "（%s）" % " ".join(parts)


## 数值滚动：从 0 滚到 final_value，用 formatter 格式化（时长计入统计滚动总时长）
func _count_to(label: Label, final_value: float, formatter: Callable, delay: float, duration: float = 1.4) -> void:
	_stats_anim_end = maxf(_stats_anim_end, delay + duration)
	label.text = formatter.call(0.0)
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_method(func(v: float): label.text = formatter.call(v), 0.0, final_value, duration)


func _fmt_int(v: float) -> String:
	return str(int(round(v)))


func _fmt_time(v: float) -> String:
	var t := int(v)
	return "%d分%02d秒" % [t / 60, t % 60]


func _fmt_pct(v: float) -> String:
	return "%.1f%%" % v


## 耐久损耗按严重度配色（口径与评级阈值一致）
func _loss_color(pct: float) -> Color:
	if pct <= 50.0:
		return UIPalette.GREEN
	elif pct <= 100.0:
		return UIPalette.AMBER
	return UIPalette.RED


# ===== 评级 =====
# 5 个因素各自评 S/A/B/C，最终评级 = 全 S 则 S，否则取最低。
# 因素与阈值（用户定义 + 耗时测算）：
# - 坦克耐久损耗：战役累计实际掉血 / 各关最大耐久之和（回复不计，可 >100%）
#   S≤50% A≤100% B≤200% C>200%
# - 基地耐久损耗：同上口径与阈值
# - 击毁敌方坦克：击毁数 / 战役预计总生产（各敌方基地工厂上限之和）S≥80% A≥60% B≥40% C其他
# - 击毁敌方基地：战役胜利必然击毁全部敌方基地，固定 S
# - 耗时：3 关 × 3 波，按波次节奏测算正常通关 8~25 分钟（战斗活动时间口径）；
#   S≤25min A≤35min B≤45min，超出即 C（防挂机等刷）
const RANK_ORDER := {"S": 0, "A": 1, "B": 2, "C": 3}
const TIME_GRADE_S := 1500.0  # 25 分钟
const TIME_GRADE_A := 2100.0  # 35 分钟
const TIME_GRADE_B := 2700.0  # 45 分钟
const FIREWORKS_PLAY_SEC := 20.0 / 12.0  # 烟花单次播放时长（20 帧 @12fps）


## 耐久损耗评级：S≤50% A≤100% B≤200% C>200%
func _grade_loss(pct: float) -> String:
	if pct <= 50.0:
		return "S"
	elif pct <= 100.0:
		return "A"
	elif pct <= 200.0:
		return "B"
	return "C"


func _grade_kill_pct(pct: float) -> String:
	if pct >= 0.8:
		return "S"
	elif pct >= 0.6:
		return "A"
	elif pct >= 0.4:
		return "B"
	return "C"


func _grade_time(seconds: float) -> String:
	if seconds <= TIME_GRADE_S:
		return "S"
	elif seconds <= TIME_GRADE_A:
		return "A"
	elif seconds <= TIME_GRADE_B:
		return "B"
	return "C"


## 最终评级：5 因素各自评级，全 S 得 S，否则取最低
func _compute_rating() -> Dictionary:
	var tank_loss := _get_tank_loss_pct()
	var base_loss := _get_base_loss_pct()
	# 击毁敌方坦克百分比；预计总产量未知（旧存档/异常数据）时不惩罚
	var planned: int = _stats.get("enemy_tanks_planned", 0)
	var kill_pct := -1.0
	if planned > 0:
		kill_pct = float(_stats.get("tanks_killed", 0)) / float(planned)

	var grades: Array[String] = [
		_grade_loss(tank_loss),
		_grade_loss(base_loss),
		_grade_kill_pct(kill_pct) if kill_pct >= 0.0 else "S",
		"S" if _is_victory else "C",  # 击毁敌方基地：胜利必然全灭，固定 S
		_grade_time(float(_stats.get("combat_seconds", 0.0))),
	]

	# 取最低评级
	var final_grade := "S"
	for g in grades:
		if RANK_ORDER[g] > RANK_ORDER[final_grade]:
			final_grade = g
	return {"grade": final_grade, "color": _grade_color(final_grade)}


func _grade_color(grade: String) -> Color:
	match grade:
		"S":
			return UIPalette.RARITY_LEGEND
		"A":
			return UIPalette.GREEN
		"B":
			return UIPalette.TEAL
		_:
			return UIPalette.TEXT_MUTED


func _populate_stats() -> void:
	for child in stats_container.get_children():
		child.queue_free()
	_stats_anim_end = 0.0

	var row_delay := 0.45
	var stagger := 0.14

	# 评级仅在胜利时显示（失败不参与评级）
	var show_grades := _is_victory
	var tanks_planned: int = _stats.get("enemy_tanks_planned", 0)
	var g_time := _grade_time(float(_stats.get("combat_seconds", 0.0))) if show_grades else ""
	var g_base_kill := "S" if show_grades else ""
	var g_tank_kill := ""
	if show_grades:
		g_tank_kill = _grade_kill_pct(float(_stats.get("tanks_killed", 0)) / float(tanks_planned)) if tanks_planned > 0 else "S"
	var g_base_loss := _grade_loss(_get_base_loss_pct()) if show_grades else ""
	var g_tank_loss := _grade_loss(_get_tank_loss_pct()) if show_grades else ""

	# 耗时
	var time_text := _fmt_time(float(int(_stats.get("combat_seconds", 0))))
	var time_row := _add_row(stats_container, "耗时", row_delay, UIPalette.AMBER, g_time, "", time_text)
	_count_to(time_row.value, float(int(_stats.get("combat_seconds", 0))), _fmt_time, row_delay + 0.05)
	row_delay += stagger

	# 击毁敌方基地（行内明细）
	var bases_killed: int = _stats.get("bases_killed", 0)
	var bases_row := _add_row(stats_container, "击毁敌方基地", row_delay,
			UIPalette.GREEN if bases_killed > 0 else UIPalette.TEXT_MUTED,
			g_base_kill, _build_level_detail(_stats.get("base_kills_by_level", {})), str(bases_killed))
	_count_to(bases_row.value, float(bases_killed), _fmt_int, row_delay + 0.05)
	row_delay += stagger

	# 击毁敌方坦克（预计总产量已知时显示「击毁/预计」比值，行内明细）
	var tanks_killed: int = _stats.get("tanks_killed", 0)
	var tanks_final := str(tanks_killed) if tanks_planned <= 0 else "%d/%d" % [tanks_killed, tanks_planned]
	var tanks_row := _add_row(stats_container, "击毁敌方坦克", row_delay,
			UIPalette.GREEN if tanks_killed > 0 else UIPalette.TEXT_MUTED,
			g_tank_kill, _build_level_detail(_stats.get("tank_kills_by_level", {})), tanks_final)
	if tanks_planned > 0:
		_count_to(tanks_row.value, float(tanks_killed),
				func(v: float): return "%d/%d" % [int(round(v)), tanks_planned], row_delay + 0.05)
	else:
		_count_to(tanks_row.value, float(tanks_killed), _fmt_int, row_delay + 0.05)
	row_delay += stagger

	# 耐久损耗（仅胜利时显示，数值滚动 + 按严重度变色；口径为战役累计实际掉血/各关总耐久）
	if _is_victory:
		var base_loss := _get_base_loss_pct()
		var base_loss_row := _add_row(stats_container, "基地耐久损耗", row_delay,
				_loss_color(base_loss), g_base_loss, "", _fmt_pct(base_loss))
		_count_to(base_loss_row.value, base_loss, _fmt_pct, row_delay + 0.05)
		row_delay += stagger

		var tank_loss := _get_tank_loss_pct()
		var tank_loss_row := _add_row(stats_container, "坦克耐久损耗", row_delay,
				_loss_color(tank_loss), g_tank_loss, "", _fmt_pct(tank_loss))
		_count_to(tank_loss_row.value, tank_loss, _fmt_pct, row_delay + 0.05)
	else:
		# 失败也显示耐久损耗（口径与胜利一致，仅无评级）
		var base_loss := _get_base_loss_pct()
		var base_loss_row := _add_row(stats_container, "基地耐久损耗", row_delay,
				_loss_color(base_loss), "", "", _fmt_pct(base_loss))
		_count_to(base_loss_row.value, base_loss, _fmt_pct, row_delay + 0.05)
		row_delay += stagger

		var tank_loss := _get_tank_loss_pct()
		var tank_loss_row := _add_row(stats_container, "坦克耐久损耗", row_delay,
				_loss_color(tank_loss), "", "", _fmt_pct(tank_loss))
		_count_to(tank_loss_row.value, tank_loss, _fmt_pct, row_delay + 0.05)


## 坦克耐久损耗（%）：战役累计实际掉血/各关总耐久（维修回血后可重复掉血，允许 >100%），
## 缺数据时退回旧口径
func _get_tank_loss_pct() -> float:
	var hp_total: int = _stats.get("tank_hp_total", 0)
	if hp_total > 0:
		return maxf(float(_stats.get("tank_dmg_taken", 0)) / float(hp_total) * 100.0, 0.0)
	return maxf(float(_stats.get("tank_hp_loss_pct", 0.0)), 0.0)


## 基地耐久损耗（%）：口径同坦克，允许 >100%
func _get_base_loss_pct() -> float:
	var hp_total: int = _stats.get("base_hp_total", 0)
	if hp_total > 0:
		return maxf(float(_stats.get("base_dmg_taken", 0)) / float(hp_total) * 100.0, 0.0)
	return maxf(float(_stats.get("base_hp_loss_pct", 0.0)), 0.0)


## 等级显示名（中文）
func _get_level_display_name(lv: String) -> String:
	match lv:
		"normal": return "普通"
		"elite": return "精英"
		"boss": return "BOSS"
	return lv


func _rarity_color(rarity: int) -> Color:
	match rarity:
		Equipment.Rarity.BLUE:
			return UIPalette.RARITY_ADV
		Equipment.Rarity.PURPLE:
			return UIPalette.RARITY_RARE
		Equipment.Rarity.PINK:
			return UIPalette.RARITY_EPIC
		Equipment.Rarity.GOLD:
			return UIPalette.RARITY_LEGEND
		_:
			return UIPalette.RARITY_COMMON


func _populate_rewards() -> void:
	for child in rewards_container.get_children():
		child.queue_free()
	# 奖励多时列表可滚动，始终从顶部开始浏览
	rewards_scroll.scroll_vertical = 0

	var row_delay := 0.7
	var stagger := 0.12

	# 仅命中首次通关补给奖励的胜利结算显示，避免无奖励时出现空行。
	var card_capacity_gain: int = _stats.get("equipment_card_capacity_gained", 0)
	if card_capacity_gain > 0:
		var next_capacity: int = _stats.get("next_equipment_card_capacity", 0)
		var card_row := _add_row(rewards_container, "装备卡", row_delay, UIPalette.RARITY_ADV,
			"", " （下次战役共 %d 张）" % next_capacity, "%d" % card_capacity_gain)
		_count_to(card_row.value, float(card_capacity_gain), func(v: float): return "%d" % int(round(v)), row_delay + 0.05)
		row_delay += stagger

	# 黑匣（数值滚动）
	var black_box_count: int = _stats.get("black_boxes_earned", 0)
	if black_box_count > 0:
		var bb_row := _add_row(rewards_container, "黑匣", row_delay, UIPalette.YELLOW)
		_count_to(bb_row.value, float(black_box_count), _fmt_int, row_delay + 0.05)
		row_delay += stagger

	# 蓝图个数（数值滚动），其下网格罗列新获得的蓝图（按稀有度配色，3 列换行，
	# 避免数量多时奖励卡纵向撑出屏幕）
	var blueprints_earned: Array = _stats.get("blueprints_earned", [])
	if not blueprints_earned.is_empty():
		var bp_row := _add_row(rewards_container, "蓝图", row_delay, UIPalette.TEAL)
		_count_to(bp_row.value, float(blueprints_earned.size()), _fmt_int, row_delay + 0.05)
		row_delay += stagger
		var bp_grid := GridContainer.new()
		bp_grid.columns = 3
		bp_grid.add_theme_constant_override("h_separation", 16)
		bp_grid.add_theme_constant_override("v_separation", 4)
		bp_grid.modulate.a = 0.0
		rewards_container.add_child(bp_grid)
		for bp in blueprints_earned:
			var bp_label := Label.new()
			if bp is Blueprint:
				bp_label.text = "· %s 蓝图" % bp._get_type_name()
				bp_label.add_theme_color_override("font_color", _rarity_color(bp.rarity))
			else:
				bp_label.text = "· %s" % str(bp)
				bp_label.add_theme_color_override("font_color", UIPalette.TEXT_MAIN)
			bp_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
			bp_grid.add_child(bp_label)
		var tw := create_tween()
		tw.tween_interval(row_delay)
		tw.tween_property(bp_grid, "modulate:a", 1.0, 0.25)
		row_delay += stagger

	# 循环挑战提示（仅战役胜利时展示；失败不预告下一轮，重打当前轮即可）：
	# 首次通关第 10 战役 → 显示解锁提示；之后每次胜利提示下一轮与难度增幅
	if _is_victory and GameState.cycle_count >= 1:
		if GameState.cycle_count == 1:
			_add_loop_notice("已解锁最终战役循环挑战！", UIPalette.RARITY_LEGEND, row_delay)
			row_delay += stagger
		# 下一步进入的轮次与增幅：x = cycle_count（轮次从 1 起算），y = 10 × cycle_count
		# （与下轮敌方 scaling ×(1+0.1×cycle_count) 一致）
		_add_loop_notice("下轮（第 %d 轮）循环挑战，敌方强度将提升 %d%%" % [
			GameState.cycle_count, GameState.cycle_count * 10], UIPalette.AMBER, row_delay)
		row_delay += stagger

	if black_box_count == 0 and blueprints_earned.is_empty() and card_capacity_gain == 0:
		var no_reward_label := Label.new()
		no_reward_label.text = "（本次战役无额外奖励）"
		no_reward_label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
		no_reward_label.add_theme_color_override("font_color", UIPalette.TEXT_MUTED)
		no_reward_label.modulate.a = 0.0
		rewards_container.add_child(no_reward_label)
		var tw := create_tween()
		tw.tween_interval(row_delay)
		tw.tween_property(no_reward_label, "modulate:a", 1.0, 0.25)


## 追加循环挑战提示行（渐显动画，与奖励行同一容器）
func _add_loop_notice(text: String, color: Color, delay: float) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", UIPalette.FONT_M)
	label.add_theme_color_override("font_color", color)
	label.modulate.a = 0.0
	rewards_container.add_child(label)
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(label, "modulate:a", 1.0, 0.25)


# ===== 统计计算 =====

func _calculate_statistics() -> Dictionary:
	# 优先读取结算快照（由 GameManager._finalize_campaign 生成，数据真实）
	var snapshot: Dictionary = GameState.stats_snapshot
	if not snapshot.is_empty():
		return snapshot

	# 兜底：快照缺失时返回空（直接加载结算场景等异常场景，界面显示为空壳）
	return {}


# ===== 返回 Meta =====

func _on_return_meta_pressed() -> void:
	print("CampaignSummary: 返回 Meta 循环")
	# 新手指引：战役结算回访（黑匣使用 / 新蓝图入包），由指挥部场景消费
	Tutorial.notify_campaign_finished()
	GM.transition_to_loop(GM.GameLoop.META)
