extends Node

## DropSystem 单例
## 管理敌方单位被摧毁后的掉落物生成

const DROP_ITEM_SCENE = preload("res://scenes/drop_item.tscn")
const DropFlashEffectScript := preload("res://scripts/drop_flash_effect.gd")

var active_drops: Array = []
var _item_spawn_timer := 0.0
## 越级蓝图：整个战役内偶尔出现的「高于上限一档」蓝图，名额按战役惰性重置
var _overcap_budget: int = 0
var _overcap_campaign: int = -1

const ITEM_CONFIG_KEYS := ["shield", "firepower_boost", "speed_boost", "time_freeze", "health_restore", "mine", "rocket"]

## 通过当前场景显示"获得新蓝图"提示（带稀有度颜色）
func _notify_blueprint_toast(bp: Blueprint) -> void:
	var scene = get_tree().current_scene
	if scene and scene.has_method("show_blueprint_toast"):
		scene.show_blueprint_toast(bp)


func _ready() -> void:
	_reset_item_spawn_timer()

func _process(delta: float) -> void:
	# 只在实际战斗中补给；场上数量受配置限制，避免刷屏。
	if GM.current_loop != GameManager.GameLoop.COMBAT:
		return
	_item_spawn_timer -= delta
	if _item_spawn_timer > 0.0:
		return
	_reset_item_spawn_timer()
	var spawn_cfg: Dictionary = ConfigLoader.items_config.get("spawn", {})
	if _active_item_count() < int(spawn_cfg.get("max_active", 4)):
		spawn_random_combat_item()

func _reset_item_spawn_timer() -> void:
	var cfg: Dictionary = ConfigLoader.items_config.get("spawn", {}) if ConfigLoader else {}
	_item_spawn_timer = randf_range(float(cfg.get("interval_min", 15.0)), float(cfg.get("interval_max", 20.0)))

func _active_item_count() -> int:
	var count := 0
	for drop in active_drops:
		if is_instance_valid(drop) and drop.drop_type == DropItem.DropType.ITEM:
			count += 1
	return count

func spawn_random_combat_item() -> void:
	var map_manager = GM.get_map_manager()
	if map_manager == null:
		return
	var key: String = ITEM_CONFIG_KEYS[randi() % ITEM_CONFIG_KEYS.size()]
	var drop = DROP_ITEM_SCENE.instantiate()
	drop.drop_type = DropItem.DropType.ITEM
	drop.item_data = _make_item(key)
	drop.lifetime = float(ConfigLoader.items_config.get("spawn", {}).get("lifetime", 18.0))
	drop.position = _find_valid_item_position(map_manager)
	drop.z_index = 2
	_add_drop_to_scene(drop)

func _make_item(key: String) -> ItemData:
	var item := ItemData.new()
	var cfg: Dictionary = ConfigLoader.items_config.get(key, {})
	item.icon_path = str(cfg.get("icon", ""))
	item.duration = float(cfg.get("duration", 0.0))
	item.effect_value = float(cfg.get("effect_value", 0.0))
	match key:
		"shield": item.item_type = ItemData.ItemType.SHIELD
		"firepower_boost": item.item_type = ItemData.ItemType.FIREPOWER_BOOST
		"speed_boost": item.item_type = ItemData.ItemType.SPEED_BOOST
		"time_freeze": item.item_type = ItemData.ItemType.TIME_FREEZE
		"health_restore": item.item_type = ItemData.ItemType.HEALTH_RESTORE
		"mine", "rocket":
			item.set_meta("ammo_type", key)
			item.set_meta("pickup_amount", int(cfg.get("pickup_amount", 5)))
	return item

func _find_valid_item_position(map_manager: Node) -> Vector2:
	var width: int = int(map_manager.get("map_width"))
	var height: int = int(map_manager.get("map_height"))
	var grid: float = float(map_manager.get("grid_size"))
	var exclusion: float = float(ConfigLoader.items_config.get("spawn", {}).get("base_exclusion_radius", 64.0))
	for _attempt in range(80):
		var candidate := Vector2(randi_range(1, max(1, width - 2)) * grid, randi_range(1, max(1, height - 2)) * grid)
		# 吸附到格子中心，避免跨格导致与砖块/石块等重叠
		candidate = map_manager.grid_to_world(map_manager.world_to_grid(candidate))
		if not _is_valid_item_position(candidate, map_manager, exclusion):
			continue
		return candidate
	return _find_free_position(Vector2(width * grid * 0.5, height * grid * 0.5))

func _is_valid_item_position(candidate: Vector2, map_manager: Node, exclusion: float) -> bool:
	# 水面、石块、砖块均不可拾取；也不贴近任意阵营基地。
	var tile_type := str(map_manager.get_tile_type_at(candidate))
	if tile_type in ["water", "stone", "brick"]:
		return false
	for base in GM.get_player_bases() + GM.get_enemy_bases():
		if is_instance_valid(base) and candidate.distance_to(base.global_position) < exclusion:
			return false
	return true


## 敌方坦克被摧毁时生成掉落物
## @param position: 掉落位置
## @param tank_level: 坦克等级（"normal", "elite", "boss"），决定金币掉落档位
func spawn_drop_from_enemy_tank(position: Vector2, tank_level: String = "normal") -> void:
	# 掉落金币（按强度分档，来自 drop_rates.json：普通8-12 / 精英45-55 / BOSS140-160）
	var gold_amount = _get_tank_gold_by_level(tank_level)
	spawn_gold(position, gold_amount)
	
	# 按概率掉落蓝图（概率来自 drop_rates.json：普通3% / 精英6% / BOSS12%）
	var bp_rate = _get_blueprint_probability("enemy_tank", tank_level, 0.05)
	if randf() < bp_rate:
		var rarity = _roll_rarity("enemy_tank", tank_level, Equipment.Rarity.WHITE)
		spawn_blueprint(position, rarity)


## 按坦克等级获取金币掉落档位（来自 drop_rates.json）
## @param tank_level: 坦克等级（"normal", "elite", "boss"）
## @return: 金币数量
func _get_tank_gold_by_level(tank_level: String) -> int:
	var cfg = ConfigLoader.drop_configs.get("enemy_tank", {}).get("gold", {})
	return _roll_range(cfg.get(tank_level, [8, 12]))


## 按基地等级获取金币掉落档位（来自 drop_rates.json）
## @param base_level: 基地等级（"normal", "elite", "boss"）
## @return: 金币数量
func _get_base_gold_by_level(base_level: String) -> int:
	var cfg = ConfigLoader.drop_configs.get("enemy_base", {}).get("gold", {})
	return _roll_range(cfg.get(base_level, [80, 120]))


## 敌方基地被摧毁时生成掉落物
## @param position: 掉落位置
## @param base_level: 基地等级（"normal", "elite", "boss"）
func spawn_drop_from_enemy_base(position: Vector2, base_level: String = "normal") -> void:
	# 掉落模组（来自 drop_rates.json：普通1 / 精英2-3 / BOSS5-8）
	var module_cfg = ConfigLoader.drop_configs.get("enemy_base", {}).get("module", {})
	var module_amount = _roll_range(module_cfg.get(base_level, [1, 1]))
	spawn_modules(position, module_amount)
	
	# 掉落金币（按基地等级分档，来自 drop_rates.json）
	var gold_amount = _get_base_gold_by_level(base_level)
	spawn_gold(position, gold_amount)
	
	# 黑匣直接发放（无实体掉落）：概率 black_box_chance × 数量 black_box
	# （精英 0.75×[0,1] / BOSS 1.0×[1,1]，来自 drop_rates.json）
	var bb_chance := float(ConfigLoader.drop_configs.get("enemy_base", {}).get("black_box_chance", {}).get(base_level, 1.0))
	if randf() < bb_chance:
		var bb_cfg = ConfigLoader.drop_configs.get("enemy_base", {}).get("black_box", {})
		var bb_val = bb_cfg.get(base_level, 0)
		if bb_val is Array:
			bb_val = randi_range(int(bb_val[0]), int(bb_val[1]))
		if int(bb_val) > 0:
			_grant_black_box(int(bb_val))
	
	# 按概率掉落蓝图（概率与稀有度权重来自 drop_rates.json）
	var bp_rate = _get_blueprint_probability("enemy_base", base_level, 0.15)
	if randf() < bp_rate:
		var rarity = _roll_rarity("enemy_base", base_level, Equipment.Rarity.WHITE)
		spawn_blueprint(position, rarity)


## 生成金币掉落物
## @param position: 位置
## @param amount: 数量
func spawn_gold(position: Vector2, amount: int) -> void:
	var drop = DROP_ITEM_SCENE.instantiate()
	drop.drop_type = DropItem.DropType.GOLD
	drop.amount = amount
	drop.position = _find_free_position(position)
	drop.z_index = 2
	_add_drop_to_scene(drop)
	print("DropSystem: 生成金币掉落 x%d 于 %s" % [amount, position])


## 生成模组掉落物
## @param position: 位置
## @param amount: 数量
func spawn_modules(position: Vector2, amount: int) -> void:
	var drop = DROP_ITEM_SCENE.instantiate()
	drop.drop_type = DropItem.DropType.MODULE
	drop.amount = amount
	drop.position = _find_free_position(position)
	drop.z_index = 2
	_add_drop_to_scene(drop)
	print("DropSystem: 生成模组掉落 x%d 于 %s" % [amount, position])


## 生成蓝图掉落物（蓝图直接获得，不生成地图上的掉落物）。
## 每次掉落只有 1 件，稀有度在本战役上限内选择能实际提升研究的类型。
## 另有「越级蓝图」：整个战役偶尔出现 2-3 件高于上限一档的蓝图（见 _roll_overcap_rarity）。
func spawn_blueprint(_position: Vector2, rolled_rarity: Equipment.Rarity) -> void:
	var campaign := _campaign_for_stage(GM.current_stage)
	var cap := _get_battle_rarity_cap(campaign)
	# 越级名额命中时本次蓝图升一档；否则走上限内的常规选择
	var overcap_rarity := _roll_overcap_rarity(campaign, cap)
	var rarity := overcap_rarity if overcap_rarity > 0 else _resolve_improving_rarity(int(rolled_rarity), cap)
	if rarity <= 0:
		_grant_blueprint_fallback_gold(cap)
		return
	# 越级蓝图优先落在本战役可制造的类型上，到手即可用
	var preferred: Array[int] = []
	if overcap_rarity > 0:
		preferred = _campaign_types_below(rarity)
	var bp := _make_smart_blueprint(rarity, [], preferred)
	if bp == null:
		_grant_blueprint_fallback_gold(cap)
		return
	bp.id = "drop_bp_%d" % Time.get_ticks_msec()
	var added: bool = GameState.add_blueprint(bp)
	if added:
		GameState.stats_blueprints_earned.append(bp)
		_notify_blueprint_toast(bp)
	print("DropSystem: 获得智能研究蓝图 [%s]（研究提升=%s，战役上限=%d%s）" % [
		bp.get_display_name(), str(added), cap, "，越级" if overcap_rarity > 0 else ""])


## 生成战役结束时的蓝图奖励（直接添加到 GameState，不生成掉落物）
## @return: 生成的蓝图列表
func generate_blueprint_rewards() -> Array[Blueprint]:
	var rewards: Array[Blueprint] = []
	var stage = GM.current_stage
	var campaign := _campaign_for_stage(stage)
	var reward_cfg: Dictionary = ConfigLoader.drop_configs.get("campaign_reward", {})
	var critical_campaigns: Array = reward_cfg.get("critical_output_campaigns", [])
	var excluded_types: Array[int] = []

	# 每次三关战役奖励 1-2 张蓝图；第 2/4/6/8 次优先补主炮、炮弹到对应档。
	var count := _get_reward_count_by_stage(stage)
	for i in range(count):
		var rarity := int(_get_reward_rarity_by_stage(stage))
		var preferred: Array[int] = []
		if _contains_campaign(critical_campaigns, campaign):
			preferred = [Equipment.Type.MAIN_GUN, Equipment.Type.SHELL]
		var bp := _make_smart_blueprint(rarity, excluded_types, preferred)
		if bp == null:
			_grant_blueprint_fallback_gold(rarity)
			continue
		bp.id = "reward_bp_%d_%d" % [stage, i]
		excluded_types.append(int(bp.equipment_type))
		# 智能候选保证研究会提升；保留防御性判断以避免未来配置变更产生重复奖励。
		if GameState.add_blueprint(bp):
			rewards.append(bp)
			GameState.stats_blueprints_earned.append(bp)

	return rewards


## 当前关卡所属战役（1-10）。直接使用关卡号，避免结算前 campaign_index 尚未推进造成错档。
func _campaign_for_stage(stage: int) -> int:
	return clampi(int(ceil(float(maxi(stage, 1)) / 3.0)), 1, 10)


## JSON 数字可能以浮点 Variant 载入，按数值比较保证配置名单稳定生效。
func _contains_campaign(campaigns: Array, campaign: int) -> bool:
	for configured_campaign in campaigns:
		if int(configured_campaign) == campaign:
			return true
	return false


func _get_battle_rarity_cap(campaign: int) -> int:
	var cfg: Dictionary = ConfigLoader.drop_configs.get("smart_blueprint", {})
	var table: Array = cfg.get("battle_rarity_cap_by_campaign", [])
	if campaign >= 1 and campaign <= table.size():
		return clampi(int(table[campaign - 1]), int(Equipment.Rarity.WHITE), int(Equipment.Rarity.GOLD))
	return mini(int(Equipment.Rarity.GOLD), 1 + int((campaign - 1) / 2.0))


## 返回指定稀有度真正能提高研究的类型；excluded 用于结算同一次奖励去重。
func get_smart_eligible_types(rarity: int, excluded: Array[int] = []) -> Array[int]:
	var eligible: Array[int] = []
	for equipment_type in Equipment.Type.values():
		var t := int(equipment_type)
		if excluded.has(t):
			continue
		if GameState.get_research_level(t) < rarity:
			eligible.append(t)
	return eligible


## 掉落掷到较低档但没有有效目标时，向本战役上限内的下一可提升档推进。
func _resolve_improving_rarity(rolled_rarity: int, cap: int) -> int:
	var start := clampi(rolled_rarity, int(Equipment.Rarity.WHITE), cap)
	for rarity in range(start, cap + 1):
		if not get_smart_eligible_types(rarity).is_empty():
			return rarity
	return 0


## 越级蓝图：整个战役掉落的蓝图中，偶尔出现 2-3 件「高于本战役上限一档」的蓝图。
## 每次掉落仍然只有 1 件；名额按战役发放（惰性重置），用完后本战役恢复正常掉落。
## 触发条件：本战役上限未封顶，且上限之上仍存在能提升研究的稀有度档。
## @param campaign: 当前战役（1-10）
## @param cap: 本战役战斗蓝图稀有度上限
## @return: 本次掉落的越级稀有度（cap+1）；未越级时返回 0
func _roll_overcap_rarity(campaign: int, cap: int) -> int:
	if cap >= int(Equipment.Rarity.GOLD):
		return 0
	var cfg: Dictionary = ConfigLoader.drop_configs.get("smart_blueprint", {})
	# 进入新战役时发放名额：本战役是否出现越级蓝图、共几件
	if _overcap_campaign != campaign:
		_overcap_campaign = campaign
		if randf() < float(cfg.get("overcap_campaign_chance", 0.0)):
			_overcap_budget = maxi(1, _roll_range(cfg.get("overcap_count_per_campaign", [2, 3])))
		else:
			_overcap_budget = 0
		print("DropSystem: 战役 %d 越级蓝图名额 %d" % [campaign, _overcap_budget])
	if _overcap_budget <= 0:
		return 0
	if randf() >= float(cfg.get("overcap_rise_chance", 0.0)):
		return 0
	# 上限之上无可提升档位时名额不消耗，留待后续掉落
	if _resolve_improving_rarity(cap + 1, cap + 1) <= cap:
		return 0
	_overcap_budget -= 1
	print("DropSystem: 越级蓝图掉落（高出上限一档，本战役剩余名额 %d）" % _overcap_budget)
	GameLog.info("drop", "越级蓝图 rarity=%d campaign=%d 剩余名额=%d" % [cap + 1, campaign, _overcap_budget])
	return cap + 1


## 本战役可制造、且研究等级低于目标稀有度的装备类型（越级蓝图的优先候选）
func _campaign_types_below(rarity: int) -> Array[int]:
	var result: Array[int] = []
	for equipment_type in GameState.get_campaign_equipment_types():
		if GameState.get_research_level(equipment_type) < rarity:
			result.append(equipment_type)
	return result


func _make_smart_blueprint(rarity: int, excluded: Array[int], preferred: Array[int]) -> Blueprint:
	var equipment_type := _select_smart_blueprint_type(rarity, excluded, preferred)
	if equipment_type < 0:
		return null
	var bp := Blueprint.new()
	bp.equipment_type = equipment_type as Equipment.Type
	bp.rarity = rarity as Equipment.Rarity
	bp.base_attributes = ConfigLoader.get_equipment_template(bp.equipment_type, bp.rarity).get("attributes", {}).duplicate()
	return bp


## 随机权重：当前核心/背包类型 ×3，未解锁或最低研究类型 ×2，条件可叠乘。
## preferred 仅用于结算关键输出保底，仍只会从可提升且未重复的类型中选取。
func _select_smart_blueprint_type(rarity: int, excluded: Array[int], preferred: Array[int]) -> int:
	var eligible := get_smart_eligible_types(rarity, excluded)
	if eligible.is_empty():
		return -1
	var priority: Array[int] = []
	for equipment_type in eligible:
		if preferred.has(equipment_type):
			priority.append(equipment_type)
	if not priority.is_empty():
		eligible = priority
	var minimum_research := int(Equipment.Rarity.GOLD)
	for equipment_type in eligible:
		minimum_research = mini(minimum_research, GameState.get_research_level(equipment_type))
	var total_weight := 0
	var weights: Array[int] = []
	for equipment_type in eligible:
		var weight := 1
		if GameState.is_type_available_in_campaign(equipment_type):
			weight *= 3
		var research := GameState.get_research_level(equipment_type)
		if research == 0 or research == minimum_research:
			weight *= 2
		weights.append(weight)
		total_weight += weight
	var roll := randi_range(1, total_weight)
	for i in eligible.size():
		roll -= weights[i]
		if roll <= 0:
			return eligible[i]
	return eligible.back()


## 重复蓝图兜底：按稀有度折算金币，即时入账战役内金币池。
## 注：金币为战役内资源，战役结束随 reset_campaign_resources() 清零（设计如此，不跨战役结转）。
func _grant_blueprint_fallback_gold(rarity: int) -> void:
	var cfg: Dictionary = ConfigLoader.drop_configs.get("smart_blueprint", {})
	var table: Array = cfg.get("fallback_gold_by_rarity", [80, 180, 360, 810, 2400])
	var index := clampi(rarity, int(Equipment.Rarity.WHITE), int(Equipment.Rarity.GOLD)) - 1
	var amount := maxi(1, int(table[index])) if index < table.size() else 1
	EconomySystem.add_resource("gold", amount)
	var scene := get_tree().current_scene
	if scene and scene.has_method("show_toast"):
		scene.show_toast("获得重复蓝图，自动转化为 金币 x%d" % amount)


## 移除掉落物引用
## @param drop: 掉落物节点
func remove_drop(drop: Node) -> void:
	active_drops.erase(drop)


# ===== 私有方法 =====

## 将掉落物添加到场景
func _add_drop_to_scene(drop: Node) -> void:
	var map_manager = GM.get_map_manager()
	if map_manager:
		map_manager.add_child(drop)
	else:
		var scene = get_tree().current_scene
		if scene:
			scene.add_child(drop)
	# 掉落生成闪光
	if drop.get_parent():
		DropFlashEffectScript.spawn_at(drop.get_parent(), drop.position)
	active_drops.append(drop)


## 根据基地等级决定蓝图稀有度（现役路径走 drop_rates.json 权重表）
func _get_blueprint_rarity_by_level(level: String) -> Equipment.Rarity:
	match level:
		"normal": return Equipment.Rarity.WHITE
		"elite":  return Equipment.Rarity.BLUE
		"boss":   return Equipment.Rarity.PURPLE
	return Equipment.Rarity.WHITE


## 从 drop_rates.json 获取蓝图掉落概率（按来源类型+等级）
func _get_blueprint_probability(source: String, level: String, default_val: float) -> float:
	var prob_cfg = ConfigLoader.drop_configs.get(source, {}).get("blueprint_probability", {})
	if prob_cfg is Dictionary and prob_cfg.has(level):
		return float(prob_cfg[level])
	return default_val


## 按稀有度权重表掷稀有度（drop_rates.json：权重越高越易出）
func _roll_rarity(source: String, level: String, default_rarity: Equipment.Rarity) -> Equipment.Rarity:
	var weights = ConfigLoader.drop_configs.get(source, {}).get("blueprint_rarity_weights", {})
	if not (weights is Dictionary and weights.has(level)):
		return default_rarity
	var weight_dict: Dictionary = weights[level]
	var total := 0
	for w in weight_dict.values():
		total += int(w)
	if total <= 0:
		return default_rarity
	var roll := randi_range(1, total)
	var acc := 0
	for rarity_name in weight_dict:
		acc += int(weight_dict[rarity_name])
		if roll <= acc:
			return Equipment.Rarity[rarity_name]
	return default_rarity


## 从区间 [min, max] 掷随机整数；支持单个数字
func _roll_range(cfg: Variant) -> int:
	if cfg is Array and cfg.size() >= 2:
		return randi_range(int(cfg[0]), int(cfg[1]))
	if cfg is int:
		return cfg
	if cfg is float:
		return int(cfg)
	return 0


## 黑匣直接发放（无实体掉落）+ 屏幕提示
func _grant_black_box(amount: int) -> void:
	EconomySystem.add_resource("black_box", amount)
	# 记录战役内获得黑匣（供结算界面显示）
	GameState.stats_black_boxes_earned += amount
	print("DropSystem: 直接获得黑匣 x%d" % amount)
	# 屏幕提示（Toast）：当前场景（game_ui）提供 show_toast 方法
	var scene = get_tree().current_scene
	if scene and scene.has_method("show_toast"):
		scene.show_toast("获得黑匣 x%d" % amount)


## 战役结算蓝图奖励稀有度（drop_rates.json campaign_reward.rarity_by_campaign；缺配置回退原公式）
func _get_reward_rarity_by_stage(stage: int) -> Equipment.Rarity:
		var campaign := clampi(int(ceil(float(stage) / 3.0)), 1, 10)
		var table: Array = ConfigLoader.drop_configs.get("campaign_reward", {}).get("rarity_by_campaign", [])
		if campaign >= 1 and campaign <= table.size():
				return clampi(int(table[campaign - 1]), 1, 5) as Equipment.Rarity
		# 回退：战役组两两升一阶，封顶金
		var tier := mini(5, 1 + int((campaign - 1) / 2.0))
		return tier as Equipment.Rarity


## 战役结算蓝图奖励数量（campaign_reward.count_by_campaign）
func _get_reward_count_by_stage(stage: int) -> int:
		var campaign := clampi(int(ceil(float(stage) / 3.0)), 1, 10)
		var table: Array = ConfigLoader.drop_configs.get("campaign_reward", {}).get("count_by_campaign", [])
		if campaign >= 1 and campaign <= table.size():
				return maxi(1, int(table[campaign - 1]))
		# 回退：前 5 组 1 张、后 5 组 2 张
		return 1 if campaign <= 5 else 2


## 掉落物之间的最小间距（像素）
const DROP_MIN_GAP: float = 18.0

## 在中心附近找一个不与现有掉落物重叠的位置
## 位置吸附到格子中心（16×16轮廓落在单个格子内），且不可在砖块/石块中
## 多次尝试随机偏移并逐渐扩大半径；兜底逐层搜索最近的可放置格
func _find_free_position(center: Vector2) -> Vector2:
	var map_manager = GM.get_map_manager()
	var best := Vector2.INF
	var best_min_dist := -1.0
	for attempt in range(10):
		var radius := 16.0 + attempt * 4.0
		var candidate := center + Vector2(randf_range(-radius, radius), randf_range(-radius, radius))
		if map_manager:
			candidate = _snap_to_cell_center(map_manager, candidate)
		if not _is_drop_placeable(map_manager, candidate):
			continue
		var min_dist := INF
		for d in active_drops:
			if is_instance_valid(d):
				min_dist = minf(min_dist, candidate.distance_to(d.global_position))
		if min_dist >= DROP_MIN_GAP:
			return candidate
		if min_dist > best_min_dist:
			best_min_dist = min_dist
			best = candidate
	if best != Vector2.INF:
		return best
	# 全部尝试均不可放置：逐层搜索最近的可放置格（吸附格子中心）
	if map_manager:
		var fallback := _find_nearest_drop_tile(map_manager, center)
		if fallback != Vector2.INF:
			return fallback
	return center


## 将任意世界坐标吸附到最近的格子中心（(gx+0.5)*16, (gy+0.5)*16）
func _snap_to_cell_center(map_manager: Node, pos: Vector2) -> Vector2:
	var cell = map_manager.world_to_grid(pos)
	return map_manager.grid_to_world(cell)


## 掉落物是否可放置在该位置：不可在砖块/石块中；水面/冰面/空地/草地均可
func _is_drop_placeable(map_manager: Node, pos: Vector2) -> bool:
	if map_manager == null:
		return true
	var tile_type := str(map_manager.get_tile_type_at(pos))
	return tile_type not in ["brick", "stone"]


## 从 center 所在格逐层向外搜索，返回最近的可放置格（非砖块/石块）的格子中心
## 找不到则返回 Vector2.INF
func _find_nearest_drop_tile(map_manager: Node, center: Vector2) -> Vector2:
	var origin = map_manager.world_to_grid(center)
	var max_radius: int = 20
	for radius in range(1, max_radius + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dy) != radius:
					continue
				var cell = Vector2i(origin.x + dx, origin.y + dy)
				var world_pos = map_manager.grid_to_world(cell)
				if _is_drop_placeable(map_manager, world_pos):
					return world_pos
	return Vector2.INF
