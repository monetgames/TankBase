---
name: godot-mcp-bridge
description: 通过 godot-mcp-bridge 的 MCP 工具驱动 TankBase 的 Godot 编辑器与运行中游戏（validate_scripts、run_scene、take_screenshot、game_eval、场景编辑、runtime 调试等）。凡涉及：测试/运行/调试游戏、游戏截图、查看报错日志、用 MCP 修改场景或脚本、连接 Godot 编辑器、检查游戏状态——即使用户没提 "MCP" 两个字也要用本 skill。Use whenever the task touches the Godot editor or the running game via MCP tools.
---

# 通过 MCP 驱动 Godot（godot-mcp-bridge）

TankBase 用 [godot-mcp-bridge](https://github.com/monetgames/godot-mcp-bridge) 让 AI agent 直接操作 Godot 编辑器与运行中的游戏。编辑器插件以 git 子模块放在 `addons/godot_mcp`（fork：[monetgames/godot-mcp-bridge](https://github.com/monetgames/godot-mcp-bridge)，基于上游 v1.2.1，另含 Godot 4.4 兼容与 snippet 缓存路径修复）。

agent 侧无需安装任何 Godot 插件，只要 MCP 客户端配置里拉起 server 即可：

```json
{ "mcpServers": { "godot": { "command": "npx", "args": ["-y", "godot-mcp-bridge"] } } }
```

## 架构与开工前提

- **MCP server**：`npx godot-mcp-bridge`，stdio MCP，WebSocket 监听 `6505`，HTTP health 在 `6506`。
- **编辑器插件**：`addons/godot_mcp` 子模块，编辑器打开时自动连 6505，并自动注册 `MCPRuntime` autoload。
- **运行时 helper**：`run_scene` 启动的游戏经同一端口回连，解锁运行时工具。

开工前按序确认（缺哪个补哪个，不要跳步）：

1. `curl -s http://127.0.0.1:6506/health` —— 有 JSON（`{"server":"godot-mcp-bridge",...}`）说明 bridge 活着。
2. Godot 编辑器已打开本项目且启用了 Godot MCP 插件 —— 没开就打开（`/Applications/Godot4.7.app/Contents/MacOS/Godot --path <项目路径> --editor`），插件每 2 秒自动重连。
3. 连接异常时**先调 `diagnose_connection`**，按它给出的有序清单修复，不要盲目重试。

## 铁律（每条都有教训在里面）

1. **改完任何 .gd 必须跑 `validate_scripts`，优先传 `paths` 列表**（全项目扫描约 34ms/脚本，大项目会逼近看门狗）。本项目把 warning 提升为 error，`var x := <Variant 表达式>` 这类问题只有它能抓出来——编辑器里能跑不代表干净。
2. **运行时工具 ≠ 编辑器工具**：`take_screenshot` / `send_input` / `game_eval` / `get_runtime_log` 需要游戏**正在运行**。返回 "Runtime helper is not connected" 是状态不是故障——先 `run_scene`（可带 `wait_for_runtime`）。
3. **默认只开放只读工具**；写操作大多在可选 toolset 里，先 `list_toolsets` 看清单、`enable_toolset` 启用。
4. **外部新建/删除文件后调 `rescan_filesystem`**，否则 .import 不会生成；新 autoload / `class_name` 需要 `restart_editor` 才能被识别。
5. **`delete_file` 必须传 `confirm: true`**；正被编辑器打开的文件会拒绝删除（`force: true` 可绕过但可能崩编辑器，禁用）。
6. **临时文件别写进 `addons/godot_mcp` 根目录**：插件自身的缓存/临时脚本统一走 `addons/godot_mcp/cache/`（已 gitignore）。旧版本散落在插件根的 `__mcp_snippet_*.gd` 会被新版本自动清理。
7. 若编辑器覆盖了外部对文件的修改：改用 MCP 接口改，或关编辑器→改文件→再开编辑器。

## 典型循环

- **改代码循环**：edit → `validate_scripts{paths:[...]}` → `run_scene` → `take_screenshot` + `get_errors` → `stop_scene`。
- **查问题**：`diagnose_connection`（断连）→ `get_errors`（Output+Debugger 汇总）→ `get_console_log{filter}`（过滤日志）→ 游戏运行中用 `get_runtime_log`。
- **只看布局不跑游戏**：`render_scene_preview` 离屏渲染 2D 场景为 PNG（存 `addons/godot_mcp/cache/previews/`），检查 UI/场景排版首选。
- **运行时调试**：启用 `runtime` toolset 后可 `send_input`、`query_runtime_node`、`game_eval`（编辑器侧会先预编译 snippet，语法错不会打断游戏）、`await_signal_runtime`。

## 完整接口目录

调用不熟悉的工具前，先读 [references/tools.md](references/tools.md)——按类别分表的完整工具清单（连接管理、只读查询、场景/脚本编辑、运行与截图、可选 toolset 索引）、每个工具的实测可用性标注，以及一份踩坑记录。
