extends Node

## AudioManager 单例
## 职责：Music / SFX 两条总线、统一播放接口、程序化生成音效、音量持久化。
## 素材说明：当前项目无音频素材，采用程序生成（AudioStreamWAV 波形合成），
## 后续有素材时只需替换 _ensure_sfx 的生成逻辑为 load("res://audio/xxx.wav") 即可。

const SAMPLE_RATE := 22050

# 音效缓存：name -> AudioStreamWAV（懒生成）
var _sfx_cache: Dictionary = {}

# SFX 播放器池（避免同帧多音效抢占）
var _sfx_players: Array[AudioStreamPlayer] = []
const SFX_POOL_SIZE := 8

# 音乐播放器
var _music_player: AudioStreamPlayer = null

# 音乐试听播放器（音量调整反馈，独立于 BGM 不打断循环）
var _music_preview_player: AudioStreamPlayer = null

# 音量（0.0 ~ 1.0），持久化到存档
var music_volume: float = 1.0
var sfx_volume: float = 1.0


func _ready() -> void:
	_setup_buses()
	_setup_players()
	# 从 GameState 恢复音量（SaveSystem 加载存档后写入 GameState）
	music_volume = float(GameState.get("music_volume") if GameState.get("music_volume") != null else 1.0)
	sfx_volume = float(GameState.get("sfx_volume") if GameState.get("sfx_volume") != null else 1.0)
	_apply_volumes()
	_setup_global_button_sfx()


# ---------- 总线与播放器 ----------

func _setup_buses() -> void:
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")


func _setup_players() -> void:
	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_players.append(p)

	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music"
	add_child(_music_player)


func _apply_volumes() -> void:
	var music_idx := AudioServer.get_bus_index("Music")
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if music_idx != -1:
		AudioServer.set_bus_volume_db(music_idx, _linear_to_db(music_volume))
	if sfx_idx != -1:
		AudioServer.set_bus_volume_db(sfx_idx, _linear_to_db(sfx_volume))


func _linear_to_db(v: float) -> float:
	if v <= 0.0:
		return -80.0
	return linear_to_db(v)


# ---------- 音量设置 ----------

func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	GameState.set("music_volume", music_volume)
	_apply_volumes()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	GameState.set("sfx_volume", sfx_volume)
	_apply_volumes()


# ---------- 播放接口 ----------

## 播放音效（统一入口）；pitch_scale 支持随机音高变化（按钮反馈等）
## 内置双层限流，避免高频重复发声：
##   1) 同名限流：同一名声效在最小间隔内重复触发则丢弃（间隔按"正常游戏频率"定制：
##      动作音只去同帧堆叠故很短；警报类以其时长为间隔，防止多重警报叠音）；
##   2) 全局限流：任意 0.5s 窗口内最多 12 次发声，防止多源齐响造成嘈杂。
func play_sfx(sfx_name: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	var stream := _ensure_sfx(sfx_name)
	if stream == null:
		return
	# —— 同名限流 ——
	var now_ms := Time.get_ticks_msec()
	var min_interval_ms := int(float(SFX_MIN_INTERVAL.get(sfx_name, SFX_MIN_INTERVAL_DEFAULT)) * 1000.0)
	if now_ms - int(_sfx_last_played_ms.get(sfx_name, -1000000000)) < min_interval_ms:
		return
	# —— 全局限流 ——
	_prune_global_play_times(now_ms)
	if _global_play_times.size() >= SFX_GLOBAL_MAX:
		return
	_sfx_last_played_ms[sfx_name] = now_ms
	_global_play_times.append(now_ms)
	var player := _find_free_sfx_player()
	if player == null:
		return
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.play()


# ---------- 播放限流 ----------

## 同名声效最小播放间隔（秒）；未列入的用默认值
const SFX_MIN_INTERVAL_DEFAULT := 0.06   # 默认：仅去同帧/近同帧堆叠
const SFX_MIN_INTERVAL := {
	"shoot": 0.08,        # 多坦克同帧开火只保留一声
	"explosion": 0.08,    # 同帧多爆只保留一声
	"destroy": 0.2,       # 摧毁音更长，间隔稍大
	"pickup": 0.05,       # 连续拾金币保留紧凑反馈感
	"alert_spot": 0.4,    # 锁定警示：0.4s 内多坦克同时锁定只响一声
	"alert_base": 1.2,    # 发现基地警报：间隔 = 音效自身时长，杜绝叠音
	"victory": 0.5,
	"defeat": 0.5,
	"wave_start": 0.5,
}
const SFX_GLOBAL_WINDOW_MS := 500  # 全局限流窗口（毫秒）
const SFX_GLOBAL_MAX := 12         # 窗口内最大发声次数（正常玩法远低于此，只拦嘈杂尖峰）

var _sfx_last_played_ms: Dictionary = {}   # 音效名 -> 上次实际发声时刻（msec）
var _global_play_times: Array[int] = []    # 窗口内各次发声时刻（msec）


func _prune_global_play_times(now_ms: int) -> void:
	var kept: Array[int] = []
	for t in _global_play_times:
		if now_ms - t < SFX_GLOBAL_WINDOW_MS:
			kept.append(t)
	_global_play_times = kept


# ---------- 全局按钮音效 ----------

## 所有进入场景树的 BaseButton（含动态创建）自动挂悬停/按下随机 pitch 音效，
## 手感与主菜单一致：悬停 button_hover（-8dB，pitch 0.9~1.1）、按下 button（0dB，pitch 0.85~1.15）
func _setup_global_button_sfx() -> void:
	get_tree().node_added.connect(_on_node_added_for_button_sfx)


func _on_node_added_for_button_sfx(node: Node) -> void:
	if node is BaseButton:
		node.mouse_entered.connect(_play_button_hover.bind(node))
		node.pressed.connect(_play_button_press.bind(node))


## 置灰（disabled）与带 no_button_sfx 标记的按钮不发声
## （无交互的按钮按下不该有反馈音；标记在运行时增删，故每次触发时检查）
func _play_button_hover(btn: BaseButton) -> void:
	if btn.disabled or btn.has_meta("no_button_sfx"):
		return
	play_sfx("button_hover", -8.0, randf_range(0.9, 1.1))


func _play_button_press(btn: BaseButton) -> void:
	if btn.disabled or btn.has_meta("no_button_sfx"):
		return
	play_sfx("button", 0.0, randf_range(0.85, 1.15))


## 播放背景音乐（循环）
func play_music(music_name: String) -> void:
	var stream := _ensure_sfx(music_name)
	if stream == null or _music_player == null:
		return
	if _music_player.stream == stream and _music_player.playing:
		return
	_music_player.stream = stream
	_music_player.play()


func stop_music() -> void:
	if _music_player:
		_music_player.stop()


## 暂停/恢复背景音乐（保留播放进度；离开战场时暂停，回战场恢复）
func set_music_paused(paused: bool) -> void:
	if _music_player and _music_player.stream != null:
		_music_player.stream_paused = paused


## 播放音乐总线试听音（短琶音；用于设置界面音量调整反馈，不打断当前 BGM）
func play_music_preview() -> void:
	if _music_preview_player == null:
		_music_preview_player = AudioStreamPlayer.new()
		_music_preview_player.bus = "Music"
		add_child(_music_preview_player)
	_music_preview_player.stream = _ensure_sfx("victory")
	_music_preview_player.play()


func _find_free_sfx_player() -> AudioStreamPlayer:
	for p in _sfx_players:
		if not p.playing:
			return p
	return _sfx_players[0]  # 池满时抢占最早的一个


# ---------- 程序化音效生成（无素材时的占位方案） ----------

func _ensure_sfx(sfx_name: String) -> AudioStreamWAV:
	if _sfx_cache.has(sfx_name):
		return _sfx_cache[sfx_name]
	var wav := _generate_sfx(sfx_name)
	if wav != null:
		_sfx_cache[sfx_name] = wav
	return wav


func _generate_sfx(sfx_name: String) -> AudioStreamWAV:
	match sfx_name:
		"shoot":
			return _tone(880.0, 220.0, 0.09, 0.4)
		"explosion":
			return _noise(0.25, 0.6)
		"destroy":
			return _tone(180.0, 60.0, 0.35, 0.7)
		"pickup":
			return _tone(440.0, 880.0, 0.12, 0.4)
		"button":
			return _tone(660.0, 660.0, 0.05, 0.3)
		"button_hover":
			return _tone(880.0, 990.0, 0.05, 0.25)
		"craft":
			return _tone(520.0, 1040.0, 0.2, 0.4)
		"upgrade":
			return _tone(600.0, 1200.0, 0.18, 0.4)
		"wave_start":
			return _tone(440.0, 440.0, 0.4, 0.5)
		"alert_spot":
			# 敌方坦克首次锁定玩家：短促上行双音
			return _arpeggio([880.0, 1245.0], 0.16, 0.45)
		"alert_base":
			# 敌方侦察型发现玩家基地：急促双音警报，约 1.2 秒（与头顶无线电波特效同长）
			return _arpeggio([880.0, 660.0, 880.0, 660.0], 1.2, 0.5)
		"victory":
			return _arpeggio([523.0, 659.0, 784.0, 1046.0], 0.5, 0.5)
		"defeat":
			return _arpeggio([400.0, 300.0, 220.0, 150.0], 0.5, 0.5)
		"battle_music":
			return _generate_bgm()
		_:
			return _tone(440.0, 440.0, 0.1, 0.3)


## 单音（频率从 f0 线性滑到 f1，指数衰减包络）
func _tone(f0: float, f1: float, duration: float, volume: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * duration)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / n
		var freq: float = lerpf(f0, f1, t)
		phase += TAU * freq / SAMPLE_RATE
		var env := pow(1.0 - t, 2.0)  # 指数衰减
		samples[i] = sin(phase) * volume * env
	return _to_wav(samples)


## 白噪声（爆炸）
func _noise(duration: float, volume: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * duration)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in range(n):
		var t := float(i) / n
		var env := pow(1.0 - t, 2.0)
		samples[i] = rng.randf_range(-1.0, 1.0) * volume * env
	return _to_wav(samples)


## 音阶（胜利/失败）
func _arpeggio(freqs: Array, duration: float, volume: float) -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	var seg := int(SAMPLE_RATE * duration / freqs.size())
	var phase := 0.0
	for f in freqs:
		for i in range(seg):
			var t := float(i) / seg
			phase += TAU * float(f) / SAMPLE_RATE
			var env := pow(1.0 - t, 1.5)
			samples.append(sin(phase) * volume * env)
	return _to_wav(samples)


## 战斗 BGM：电子风四小节循环（A 小调 Am-F-C-G，112 BPM）
## 配方：方波贝斯（8 分音符律动）+ 四踩底鼓 + 反拍踩镲 + 和弦琶音点缀，
## 芯片音（chiptune）质感贴合像素军事风；各层尾音都在循环内衰减，接缝无爆音。
func _generate_bgm() -> AudioStreamWAV:
	var bpm := 112.0
	var beat := 60.0 / bpm
	var bar := beat * 4.0
	var total := bar * 4.0
	var n := int(SAMPLE_RATE * total)
	var samples := PackedFloat32Array()
	samples.resize(n)

	# 根音（A2 F2 C3 G2）与对应和弦音
	var roots := [110.0, 87.31, 130.81, 98.0]
	var chords := [
		[220.0, 261.63, 329.63],   # Am: A3 C4 E4
		[174.61, 220.0, 261.63],   # F:  F3 A3 C4
		[261.63, 329.63, 392.0],   # C:  C4 E4 G4
		[196.0, 246.94, 293.66],   # G:  G3 B3 D4
	]

	# 贝斯：每 8 分音符一个根音（每小节第 4 个八分上翻八度增加律动）
	var eighth := beat / 2.0
	for bar_i in range(4):
		for e in range(8):
			var start := int((bar_i * bar + e * eighth) * SAMPLE_RATE)
			var freq: float = roots[bar_i]
			if e % 4 == 3:
				freq *= 2.0
			_add_square(samples, start, int(eighth * 0.9 * SAMPLE_RATE), freq, 0.14)

	# 底鼓：每拍
	for bar_i in range(4):
		for b in range(4):
			_add_kick(samples, int((bar_i * bar + b * beat) * SAMPLE_RATE), 0.5)

	# 踩镲：反拍
	for bar_i in range(4):
		for e in range(4):
			_add_hat(samples, int((bar_i * bar + (e + 0.5) * beat) * SAMPLE_RATE), 0.10)

	# 琶音点缀：每小节后半（拍 3-4）16 分音符上行，先原位后高八度
	var sixteenth := beat / 4.0
	for bar_i in range(4):
		var ch: Array = chords[bar_i]
		for k in range(8):
			var start := int((bar_i * bar + 2.0 * beat + k * sixteenth) * SAMPLE_RATE)
			var freq: float = ch[k % 3]
			if k >= 4:
				freq *= 2.0
			_add_square(samples, start, int(sixteenth * 0.8 * SAMPLE_RATE), freq, 0.05)

	var wav := _to_wav(samples)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = n
	return wav


## 方波音符（指数衰减包络），叠加写入采样数组
func _add_square(samples: PackedFloat32Array, start: int, dur: int, freq: float, volume: float) -> void:
	var phase := 0.0
	var last := mini(start + dur, samples.size())
	for i in range(maxi(start, 0), last):
		phase += TAU * freq / SAMPLE_RATE
		var t := float(i - start) / dur
		var env := pow(1.0 - t, 1.3)
		var sq := 1.0 if fmod(phase, TAU) < PI else -1.0
		samples[i] = samples[i] + sq * volume * env


## 底鼓：正弦频率快速下坠（150→45Hz），模拟电子鼓 kick
func _add_kick(samples: PackedFloat32Array, start: int, volume: float) -> void:
	var dur := int(0.09 * SAMPLE_RATE)
	var phase := 0.0
	var last := mini(start + dur, samples.size())
	for i in range(maxi(start, 0), last):
		var t := float(i - start) / dur
		phase += TAU * lerpf(150.0, 45.0, t) / SAMPLE_RATE
		samples[i] = samples[i] + sin(phase) * volume * pow(1.0 - t, 2.0)


## 踩镲：短促白噪声（确定性种子，保证每次生成一致）
func _add_hat(samples: PackedFloat32Array, start: int, volume: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = start
	var dur := int(0.03 * SAMPLE_RATE)
	var last := mini(start + dur, samples.size())
	for i in range(maxi(start, 0), last):
		var t := float(i - start) / dur
		samples[i] = samples[i] + rng.randf_range(-1.0, 1.0) * volume * pow(1.0 - t, 3.0)


## PackedFloat32Array → AudioStreamWAV（16-bit PCM）
func _to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	var bytes := PackedByteArray()
	for s in samples:
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		bytes.append(v & 0xFF)
		bytes.append((v >> 8) & 0xFF)
	wav.data = bytes
	return wav
