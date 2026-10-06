extends Node

## MCPRuntime 装载器（autoload 指向本文件，而不是直接指向 addon 脚本）。
##
## 为什么需要这一层：
##   1) 开发期需要 godot_mcp 的"运行时桥"（MCPRuntime：take_screenshot / send_input /
##      query_runtime_node / get_runtime_log 等 game-side 工具）；
##   2) 但导出时 `addons/*` 被排除（见 export_presets.cfg 的 exclude_filter），发布模板也
##      裁剪了 WebSocket 模块。若 autoload 直接指向 addon 脚本，导出包会缺失该脚本。
##
## 做法：本文件位于 `scripts/`，始终随工程一起导出；由它在"确实可用"时才动态挂载真正的运行时：
##   · 编辑器内（含 F5 运行游戏）：WebSocketPeer 存在且 addon 脚本可加载 → 挂上真正的 MCPRuntime；
##   · 导出包：WebSocket 模块已裁剪 / addon 未打包 → 直接空转，不报错、不开 socket。
##
## 效果：编辑器用 MCP 完全不受影响，导出包自动排除 MCP 运行时，无需每次发布前手动注释 project.godot。

## 真正的运行时脚本（仅开发期存在）
const RUNTIME_SCRIPT_PATH := "res://addons/godot_mcp/runtime/mcp_runtime.gd"
## 挂载后的节点名（便于在远程场景树里辨认）
const RUNTIME_NODE_NAME := "MCPRuntimeImpl"


func _ready() -> void:
	# 发布模板裁掉了 websocket 模块：MCP 只服务于开发期，此处直接不装载
	if not ClassDB.class_exists("WebSocketPeer"):
		return
	# addon 未打包（导出包）或已被移除：不装载
	if not ResourceLoader.exists(RUNTIME_SCRIPT_PATH):
		return
	var runtime_script: Script = load(RUNTIME_SCRIPT_PATH)
	if runtime_script == null:
		return
	var runtime := Node.new()
	runtime.name = RUNTIME_NODE_NAME
	runtime.set_script(runtime_script)
	# 子节点入树即触发其 _ready（连接 MCP bridge、启动 socket 泵）
	add_child(runtime)
