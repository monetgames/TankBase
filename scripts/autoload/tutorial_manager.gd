extends Node

## TutorialManager 自动加载单例：新手指引系统（框架 + 保命条目，分阶段）。
##
## 语义：
##   · 首次运行默认开启；设置界面可全局开关（settings.json 持久化）。
##   · 每条指引"首次遇到才教"（完成标记随游戏存档持久化）；中途关闭 → 不再弹；
##     中途重新开启 → 未完成的条目下次遇到仍会弹出（错过补课）。
##   · 仅第一条指引（meta_intro）带「关闭指引」按钮，点击后提示 ESC→设置可重开，
##     卡片停留数秒自动收起；其余条目只有「知道了」。
##   · 卡片可见期间经 showing_changed 通知场景锁定跳转按钮（指挥部=开始战役、
##     基地=返回指挥部/进入战役），收起后场景自行恢复按钮原有可用态。
##   · 战斗内仅 2 条暂停式指引（首次受击 / 首次拾取道具）；暂停与既有暂停互斥由
##     "记录前置暂停态、关闭时恢复"保证，不与波间商店/ESC 菜单叠加。
##
## 文案：HINTS 内为 BBCode，颜色一律经 _c/_btn/_rar 包装取自 UIPalette 与
## Equipment.get_rarity_color，本文件不出现硬编码色值。
## 使用：游戏代码在事件点调用 Tutorial.fire("hint_id")；框架负责去重、排队、
##       完成标记与展示。条目文案集中在本文件 HINTS 表，加条目 = 加一条 + 一个 fire。

signal showing_changed(is_showing: bool)

const CARD_WIDTH := 430.0
const FONT_SIZE := 15
const CLOSE_MSG_DELAY := 2.5   # 点击「关闭指引」后提示语停留秒数（随后自动收卡）

# ===== 指引定义表 =====
# text    卡片正文（BBCode；\n 分行）
# pause   展示时暂停游戏（默认 false）；关闭卡片时恢复
# closable 显示「关闭指引」按钮（仅 meta_intro）
# pos     "bottom"（默认，贴底避开场景底部跳转按钮栏）| "center"（垂直居中，战斗暂停卡用）
var HINTS: Dictionary = {}

var _queue: Array[String] = []
var _layer: CanvasLayer = null
var _card: PanelContainer = null
var _label: RichTextLabel = null
var _close_btn: Button = null
var _current_id := ""
var _we_paused := false
var _campaign_finished_pending := false
var _build_card_redeemed_this_visit := false


func _ready() -> void:
	_build_hints()


# ---------- BBCode 包装（颜色统一出处：UIPalette / 稀有度色） ----------

func _c(s: String, color: Color) -> String:
	return "[color=#%s]%s[/color]" % [color.to_html(false), s]


## 按钮类引导：橙黄（AMBER）加粗，含引号一起染色
func _btn(s: String) -> String:
	return "[b][color=#%s]%s[/color][/b]" % [UIPalette.AMBER.to_html(false), s]


func _rar(rarity: int, s: String) -> String:
	return _c(s, Equipment.get_rarity_color(rarity as Equipment.Rarity))


func _build_hints() -> void:
	var g := func(s: String): return _c(s, UIPalette.GREEN_TEXT)   # 标题/我方：绿
	var amber := func(s: String): return _c(s, UIPalette.AMBER)    # 金币
	var y := func(s: String): return _c(s, UIPalette.YELLOW)       # F 键/黑匣
	var teal := func(s: String): return _c(s, UIPalette.TEAL)      # 蓝图/模组/装备图标
	var red := func(s: String): return _c(s, UIPalette.RED)        # 敌方/危险

	HINTS = {
		"meta_intro": {
			"text": "这里是%s——每次战役的后勤中枢。\n· %s：击毁敌方精英/BOSS 基地获得，用于永久强化属性，可随时%s。\n· %s：每次战役开始会补满，用于免费兑换装备；未使用的装备卡不会跨战役保留。\n· %s：用于制造装备的设计图，由低到高分为%s→%s→%s→%s→%s五种稀有度阶级，高阶蓝图会自动覆盖低阶蓝图。"
				% [g.call("指挥部"), y.call("黑匣"), _btn("「重置黑匣」"), _rar(2, "装备卡"),
				teal.call("蓝图"), _rar(1, "白"), _rar(2, "蓝"), _rar(3, "紫"), _rar(4, "粉"), _rar(5, "金")],
			"closable": true,
		},
		"meta_backpack": {
			"text": "%s决定本局能制造的装备（引擎/轴承/主炮/炮弹四类核心不占槽位）。\n建议把「抢修机」放入背包，基地装配后可以按 %s 键维修坦克，请点击右侧蓝图库中的%s。"
				% [g.call("战术背包"), y.call("F"), _btn("「放入背包」")],
		},
		"meta_start": {
			"text": "准备就绪后，点击下方%s进入基地装配坦克。" % _btn("「开始战役」"),
		},
		"build_card_redeem": {
			"text": "这里是%s——关卡间的强化与维修站。右上角显示的%s用于兑换任意装备。先在蓝图列表找到「引擎」和「轴承」，分别点击%s免费兑换这两件装备。"
				% [g.call("基地"), _rar(2, "装备卡"), _btn("「兑换」")],
		},
		"build_equip": {
			"text": "兑换成功后，装备进入%s。把鼠标悬停在库存的%s上可查看属性，点%s装到右侧装备槽。"
				% [g.call("装备库存"), teal.call("装备图标"), _btn("「装配」")],
		},
		"build_bulk": {
			"text": "用完装备卡后，剩下的其他装备需要消耗金币%s，并逐一%s装到右侧装备槽，同一类型只能装配一件。金币制造的无用装备可以半价%s；装备卡兑换的装备只能%s且不会返还资源。\n对了，别忘记装上「抢修机」。坦克和基地的装备都装齐后%s。"
				% [_btn("「制造」"), _btn("「装配」"), _btn("「回收」"), _btn("「丢弃」"), _btn("「进入战役」")],
		},
		"build_repair": {
			"text": "过关回到基地，耐久不会自动恢复，出发前记得%s、%s。"
				% [_btn("「维修坦克」"), _btn("「维修基地」")],
			"pos": "center",
		},
		"build_enhance": {
			"text": "有%s了，这是强化材料。\n在右侧装备栏%s装备，在左侧装备库存%s装备（强化最高 +3，消耗模组与金币，失败不掉级但材料照收），完成后重新%s上阵。"
				% [teal.call("模组"), _btn("「卸载」"), _btn("「强化」"), _btn("「装配」")],
		},
		"build_ascend": {
			"text": "获得高阶%s，可以对装备升阶了。\n查看%s是否有高阶蓝图，可以%s对应装备到装备库存中%s，以提升稀有度（强化等级完整保留）。"
				% [teal.call("蓝图"), g.call("战术背包"), _btn("「卸载」"), _btn("「升阶」")],
		},
		"combat_intro": {
			"text": "战场识别：绿色是%s，灰色是%s。\n目标：保住我方坦克和基地，击毁所有敌方坦克和基地\n注意：坦克和基地被毁都%s！\n界面顶部是关卡进度和时间，右侧是敌我双方数值和探测雷达，底部是武器%s和道具%s。"
				% [g.call("我方坦克与基地"), red.call("敌方"), red.call("不可重生"),
				_btn("（滚轮切换）"), _btn("（数字键使用）")],
		},
		"combat_damage": {
			"text": "受到攻击了！把坦克开回%s附近，按 %s 键维修（装配「抢修机」消耗金币维修）。"
				% [g.call("绿色我方基地"), y.call("F")],
			"pause": true,
		},
		"combat_item": {
			"text": "捡到道具了。按道具栏对应的%s使用道具；武器类道具（地雷/火箭）用鼠标%s切到武器槽后%s释放。"
				% [_btn("数字键（1-6）"), _btn("滚轮"), _btn("左键")],
			"pause": true,
		},
		"shop_wave": {
			"text": "这里是波间补给站，使用%s%s实现本次战役内属性强化，如购买护盾需注意：有「护盾」装备才可使用。买完%s。"
				% [amber.call("金币"), _btn("「购买」"), _btn("「继续战斗」")],
		},
		"meta_blackbox": {
			"text": "有%s了！在指挥部消耗黑匣可永久提升属性、扩容战术背包、增加初始金币；点错也没关系，%s会全额返还黑匣。"
				% [y.call("黑匣"), _btn("「重置黑匣」")],
		},
		"meta_newblueprint": {
			"text": "拿到新%s了（高阶蓝图自动覆盖低阶）。非核心蓝图需要放入%s，本局才能制造；必备的核心四类始终可用。"
				% [teal.call("蓝图"), g.call("战术背包")],
		},
		# 新增教学条目：在此登记后，在对应游戏事件点补 fire 调用即生效。
	}


# ---------- 对外接口 ----------

## 事件点调用：展示一条指引（已看过/已关闭/已在队列时自动忽略）
func fire(id: String) -> void:
	if not SaveSystem.is_tutorial_enabled():
		return
	if SaveSystem.is_tutorial_done(id):
		return
	if not HINTS.has(id):
		push_warning("TutorialManager: 未知指引 id \"%s\"" % id)
		return
	if id == _current_id or id in _queue:
		return
	_queue.append(id)
	_process_queue()


## 卡片当前是否可见（场景可用于锁定跳转按钮）
func is_showing() -> bool:
	return _card != null


## 构筑教学只由实际成功操作推进，不能因关闭提示或连续点击而跳过关键步骤。
func notify_equipment_card_redeemed() -> void:
	_build_card_redeemed_this_visit = true
	fire("build_equip")


func notify_gold_equipment_crafted() -> void:
	if _build_card_redeemed_this_visit or not GameState.equipment_card_redeemed_types.is_empty():
		fire("build_equip")


## 战役结算（胜利/失败）返回指挥部前调用，用于结算回访类指引
func notify_campaign_finished() -> void:
	_campaign_finished_pending = true


## 是否有战役刚结束待回访（由指挥部场景消费一次）
func consume_campaign_finished() -> bool:
	var v := _campaign_finished_pending
	_campaign_finished_pending = false
	return v


## 是否获得了"初始五张白图"之外的新蓝图（类型扩充 或 任一稀有度提升）
func has_new_blueprints() -> bool:
	if GameState.blueprints.size() > 5:
		return true
	for bp in GameState.blueprints:
		if int(bp.rarity) > int(Equipment.Rarity.WHITE):
			return true
	return false


# ---------- 内部：队列与展示 ----------

func _process_queue() -> void:
	if _card != null or _queue.is_empty():
		return
	if not SaveSystem.is_tutorial_enabled():
		_queue.clear()  # 展示中关闭指引 → 丢弃后续排队
		return
	var id: String = _queue.pop_front()
	_show(id)


func _show(id: String) -> void:
	_current_id = id
	var def: Dictionary = HINTS.get(id, {})

	if _layer == null:
		_layer = CanvasLayer.new()
		_layer.layer = 90
		# 暂停式指引需要卡片在树暂停时仍可点击
		_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		# fire 可能发生在场景 _ready 期间（root 正在装配子节点），必须延迟入树
		get_tree().root.add_child.call_deferred(_layer)

	# 卡片
	_card = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UIPalette.BG_PANEL
	sb.border_color = UIPalette.BORDER_HI
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_card.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	vb.add_theme_constant_override("separation", 12)
	_card.add_child(vb)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("default_color", UIPalette.TEXT_MAIN)
	_label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	_label.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	_label.text = def.get("text", "")
	vb.add_child(_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)

	if def.get("closable", false):
		_close_btn = Button.new()
		_close_btn.text = "关闭指引"
		_close_btn.focus_mode = Control.FOCUS_NONE
		_close_btn.add_theme_color_override("font_color", UIPalette.RED)
		_close_btn.pressed.connect(_on_close_tutorial)
		row.add_child(_close_btn)

	var ok_btn := Button.new()
	ok_btn.text = "知道了"
	ok_btn.focus_mode = Control.FOCUS_NONE
	ok_btn.add_theme_color_override("font_color", UIPalette.AMBER)
	ok_btn.pressed.connect(_dismiss)
	row.add_child(ok_btn)

	# 容器：full-rect 且不拦截卡片外点击；默认贴底（避开底部跳转按钮栏，
	# 同时不遮住指引中要用户点击的列表按钮），战斗暂停卡用 center 居中强调
	var holder := MarginContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if def.get("pos", "bottom") == "center":
		holder.add_theme_constant_override("margin_left", 40)
		holder.add_theme_constant_override("margin_right", 40)
		var center := CenterContainer.new()
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(center)
		center.add_child(_card)
	else:
		holder.add_theme_constant_override("margin_bottom", 76)
		holder.add_theme_constant_override("margin_left", 40)
		holder.add_theme_constant_override("margin_right", 40)
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_END
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(col)
		_card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(_card)
	_layer.add_child(holder)

	# 暂停式指引：记录前置暂停态再暂停，关闭时恢复（不与商店/ESC 暂停叠加）
	_we_paused = false
	if def.get("pause", false) and not get_tree().paused:
		get_tree().paused = true
		_we_paused = true

	showing_changed.emit(true)


## 关闭当前卡片
## @param mark_done: 是否记为已完成（点「知道了」= true；中途离开场景 = false）
func _dismiss(mark_done: bool = true) -> void:
	if _card == null:
		return
	if mark_done:
		SaveSystem.mark_tutorial_done(_current_id)
	_current_id = ""
	_card.queue_free()
	_card = null
	_label = null
	_close_btn = null
	if _we_paused:
		get_tree().paused = false
		_we_paused = false
	_process_queue()
	if _card == null:
		showing_changed.emit(false)


## 不记为完成地关闭当前指引（ESC → 设置 → 返回主菜单等中途离开场景时调用）：
## 视为没有点过「知道了」——卡片立即收起，且完成标记不写入，下次遇到该条目仍会教。
func dismiss_without_completing() -> void:
	_queue.clear()
	_dismiss(false)


func _on_close_tutorial() -> void:
	SaveSystem.set_tutorial_enabled(false)
	if _label != null:
		_label.text = "新手指引已关闭。之后可随时按 ESC 打开「设置」，在其中重新开启。"
	if _close_btn != null:
		_close_btn.visible = false
	# 提示语停留片刻后自动收卡（跳转按钮随之解锁；队列已因关闭而清空）
	get_tree().create_timer(CLOSE_MSG_DELAY).timeout.connect(_dismiss)
