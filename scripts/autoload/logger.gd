extends Node

## 全局日志模块（autoload 名 GameLog，注册顺序置于所有 autoload 之首，保持零依赖）。
##
## 用途：记录关键节点与异常，落盘到 user://logs/，供线上问题追溯。
##
## 写入纪律（严格控制日志体量与写入频次）：
##   1. 只记录关键节点（战役开始/结束、存档读写）与异常（失败路径、配置错误）；
##   2. 一般调试 print 不进入日志，保持控制台输出即可；
##   3. 禁止在每帧、每次命中、每次循环中调用，避免战斗期日志风暴；
##   4. 单条消息单行化并截断到 MAX_MESSAGE_LEN；
##   5. 相同消息在 DEDUP_WINDOW_SEC 内只记一次，每分钟总量不超过 MAX_PER_MINUTE 条；
##   6. 文件超过 MAX_FILE_BYTES 自动轮转，最多保留 MAX_FILES 份（含当前）。
##
## 用法：
##   GameLog.info("campaign", "战役开始 stage=1")
##   GameLog.warn("save", "设置解析失败，使用默认设置")
##   GameLog.error("config", "配置解析失败 file=drop_rates.json err=...")

enum Level { INFO, WARN, ERROR }

const LOG_DIR := "user://logs"
const LOG_PATH := "user://logs/game.log"
## 单条消息最大长度（超出截断，防止把长文本/配置整段写进日志）
const MAX_MESSAGE_LEN := 200
## 同一条消息的去重窗口（秒）：循环中反复触发的同类异常只记一次
const DEDUP_WINDOW_SEC := 10.0
## 每分钟写入上限：异常风暴时的硬性熔断
const MAX_PER_MINUTE := 60
## 单份日志文件大小上限（超出轮转）
const MAX_FILE_BYTES := 512 * 1024
## 保留的日志文件份数：game.log + game.1.log ... game.(MAX_FILES-1).log
const MAX_FILES := 3

var _current_bytes := 0
var _minute_start := 0.0
var _minute_count := 0
var _dedup: Dictionary = {}
var _exited := false


func _ready() -> void:
	# 暂停期间（结算/弹窗）也要能记录
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	_current_bytes = _file_size(LOG_PATH)
	_rotate_if_needed(0)
	_write(Level.INFO, "session", "启动 v%s | Godot %s | 平台 %s" % [
		str(ProjectSettings.get_setting("application/config/version", "?")),
		str(Engine.get_version_info().get("string", "?")),
		OS.get_name()])


func _exit_tree() -> void:
	if _exited:
		return
	_exited = true
	_write(Level.INFO, "session", "退出")


## 关键节点（低频）：战役开始/结束、存档读写完成等
func info(category: String, message: String) -> void:
	_write(Level.INFO, category, message)


## 可恢复异常：配置缺失回退默认、非法参数被拒绝、存档缺失等
func warn(category: String, message: String) -> void:
	_write(Level.WARN, category, message)


## 失败路径：读写失败、解析失败、关键流程中断
func error(category: String, message: String) -> void:
	_write(Level.ERROR, category, message)


## 失败路径 + 结构化上下文（键值自动拼接并截断），用于问题追溯
func exception(category: String, message: String, context: Dictionary = {}) -> void:
	var extra := ""
	if not context.is_empty():
		var parts: Array[String] = []
		for key in context:
			parts.append("%s=%s" % [key, str(context[key])])
		extra = " | " + ", ".join(parts)
	_write(Level.ERROR, category, message + extra)


# ===== 内部实现 =====

func _write(level: Level, category: String, message: String) -> void:
	if not _allow_write(level, category, message):
		return
	var line := "[%s] [%s] [%s] %s" % [
		Time.get_datetime_string_from_system(false, true),
		_level_name(level), category, _sanitize(message)]
	_append(line)
	# 异常同时输出到控制台便于开发期即时发现；INFO 只落盘，避免刷屏
	match level:
		Level.ERROR:
			push_error("GameLog: %s" % line)
		Level.WARN:
			push_warning("GameLog: %s" % line)


## 频次控制：每分钟熔断 + 相同消息去重
func _allow_write(level: Level, category: String, message: String) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _minute_start >= 60.0:
		_minute_start = now
		_minute_count = 0
	if _minute_count >= MAX_PER_MINUTE:
		return false
	var key := "%d|%s|%s" % [int(level), category, message.substr(0, 80)]
	var last: float = float(_dedup.get(key, -DEDUP_WINDOW_SEC * 2.0))
	if now - last < DEDUP_WINDOW_SEC:
		return false
	# 去重表防膨胀
	if _dedup.size() >= 256:
		_dedup.clear()
	_dedup[key] = now
	_minute_count += 1
	return true


## 单行化 + 截断，保证一条日志一行、长度可控
func _sanitize(message: String) -> String:
	var one_line := message.replace("\n", " ").replace("\r", " ").strip_edges()
	if one_line.length() <= MAX_MESSAGE_LEN:
		return one_line
	return one_line.substr(0, MAX_MESSAGE_LEN) + "…"


## 追加一行并立即落盘（异常追溯要求崩溃前已写入磁盘）
func _append(line: String) -> void:
	var payload := line + "\n"
	_rotate_if_needed(payload.length())
	# READ_WRITE 不会创建文件，首次写入（或轮转后）需以 WRITE 建立
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_string(payload)
	file.close()
	_current_bytes += payload.length()


## 超出单份上限时轮转：game.log → game.1.log → …，最老一份丢弃
func _rotate_if_needed(incoming: int) -> void:
	if _current_bytes + incoming <= MAX_FILE_BYTES:
		return
	var dir := DirAccess.open(LOG_DIR)
	if dir == null:
		return
	dir.remove("game.%d.log" % (MAX_FILES - 1))
	for index in range(MAX_FILES - 2, 0, -1):
		if dir.file_exists("game.%d.log" % index):
			dir.rename("game.%d.log" % index, "game.%d.log" % (index + 1))
	if dir.file_exists("game.log"):
		dir.rename("game.log", "game.1.log")
	_current_bytes = 0


func _level_name(level: Level) -> String:
	match level:
		Level.WARN:
			return "WARN"
		Level.ERROR:
			return "ERROR"
		_:
			return "INFO"


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return int(size)
