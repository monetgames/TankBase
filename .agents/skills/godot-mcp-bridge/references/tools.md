# Godot MCP Bridge 接口说明

> 面向开发者与 AI Agent 的快速参考。基于 fork v1.2.1（monetgames/godot-mcp-bridge，上游 TomasLucasUTN/godot-mcp-bridge v1.2.1）。
> 编辑器 WebSocket 端口 `6505`（HTTP `6506`：`GET /health` 健康检查、`POST /tool` 工具直调，见下文）；游戏运行时 helper 走同一端口。
> 全量工具数以 `curl http://127.0.0.1:6506/health` 或 `list_toolsets` 实时查询为准（v1.2.1 为 237 个）。

## 可用性标注

| 符号 | 含义 |
|---|---|
| ✅ | 已实测可用（2026-08-30，v1.1.6 实测，行为延续适用） |
| ⚠️ | 已注册、参数可解析，未实测（多为写操作，链路与 ✅ 同源可信） |
| 🎮 | 接口正常，但需**游戏正在运行**（MCPRuntime helper 已连接），否则按设计拒绝 |
| 🔌 | 需先用 `enable_toolset` 启用所属 toolset |

## HTTP 直调通道（无 MCP 客户端 / 脚本化场景）

bridge 在 `6506` 上提供不依赖 MCP 协议的 HTTP 工具直调，适合没有 MCP 客户端环境（CI、一次性脚本）或想绕开 MCP 握手快速验证链路时使用：

```bash
# 请求：{"name": "<工具名>", "args": {<参数>}}
curl -s -X POST http://127.0.0.1:6506/tool -H "Content-Type: application/json" \
  -d '{"name":"get_godot_status","args":{}}'

# 返回为 MCP content 包裹的双层 JSON，内层 text 需再解析一次：
# {"content":[{"type":"text","text":"{\"connected\":true,...}"}]}
```

实测（2026-09-29，v1.2.1）：`get_godot_status`、`validate_scripts` 均可用，与 MCP 走同一执行链路。约束与 MCP 调用一致——bridge 存活、编辑器已连接，运行时工具仍需游戏正在运行。批量的脚本化 eval 循环可参考项目根 `.mcp_eval/` 的历史做法（读 .gd 文件 → 包成 `game_eval` → POST）。

## 连接与状态管理

| 接口 | 可用性 | 用途 |
|---|---|---|
| `diagnose_connection` | ✅ | 连接诊断清单；断连时给出有序修复建议（排查首选） |
| `get_godot_status` | ✅ | 编辑器连接状态、项目路径、模式 |
| `list_toolsets` | ✅ | 列出全部 toolset、工具数与启停状态（数量以实时查询为准） |
| `get_guide` | ✅ | 读取内置工作流指南：`testing-loop` / `scene-editing` / `asset-generation` / `troubleshooting` / `debugging` / `tool-index`（无参列出） |
| `enable_toolset` | ⚠️ | 启用某个可选 toolset |
| `disable_toolset` | ⚠️ | 禁用某个 toolset |

## 项目与文件读取（只读）

| 接口 | 可用性 | 用途 |
|---|---|---|
| `list_dir` | ✅ | 列项目目录文件/文件夹 |
| `read_file` | ✅ | 读文本文件（支持 `start_line`/`end_line` 行区间） |
| `search_project` | ✅ | 全项目子串搜索，返回文件+行号（支持 glob 过滤） |
| `list_scripts` | ✅ | 列出项目全部 GDScript |
| `get_project_settings` | ✅ | 主场景/窗口尺寸/物理帧率/渲染方式摘要 |

## 引擎与场景查询（只读）

| 接口 | 可用性 | 用途 |
|---|---|---|
| `classdb_query` | ✅ | 查 Godot ClassDB 的类/方法/信号/继承，写代码前核对 API |
| `read_scene` | ✅ | 解析 .tscn 节点树；`max_depth` 省流量，`properties` 精准取属性 |
| `scene_tree_dump` | ✅ | 编辑器当前打开场景的节点树 |
| `find_nodes_by_type` | ✅ | 场景内按类名递归找节点（默认含子类） |
| `get_scene_dependencies` | ✅ | 场景资源依赖表（子场景/脚本/外部资源），无需加载场景 |

## 脚本校验与错误（只读）

| 接口 | 可用性 | 用途 |
|---|---|---|
| `validate_scripts` | ✅ | 批量校验 GDScript 编译；**改代码后的标准验证手段**，优先传 `paths` 列表 |
| `get_errors` | ✅ | 汇总编辑器 Output + Debugger Errors（文件/行号/严重度） |
| `get_console_log` | ✅ | 编辑器输出日志（支持 `filter` 子串过滤） |
| `get_runtime_log` | 🎮 | 游戏内环形缓冲日志（脚本经 `MCPRuntime.push_runtime_log` 推送） |

## 场景编辑（写）

| 接口 | 可用性 | 用途 |
|---|---|---|
| `create_scene` | ⚠️ | 新建场景文件 |
| `add_node` | ⚠️ | 向场景添加节点 |
| `remove_node` | ⚠️ | 删除节点 |
| `duplicate_node` | ⚠️ | 复制节点 |
| `move_node` | ⚠️ | 移动节点（改父子关系/顺序） |
| `rename_node` | ⚠️ | 重命名节点 |
| `modify_node_property` | ⚠️ | 修改单个节点属性 |
| `set_node_properties` | ⚠️ | 批量设置节点属性 |
| `set_node_reference` | ⚠️ | 设置节点引用（NodePath/Resource） |
| `attach_script` | ⚠️ | 给节点挂脚本 |
| `connect_signal` | ⚠️ | 连接信号 |
| `instance_scene` | ⚠️ | 在场景中实例化子场景 |
| `batch_scene_edit` | ⚠️ | 单场景内多操作合并为一次往返 |

## 脚本与文件编辑（写）

| 接口 | 可用性 | 用途 |
|---|---|---|
| `create_script` | ✅ | 新建 .gd（实测通过，配对自清理验证） |
| `edit_script` | ⚠️ | 编辑已有 .gd |
| `delete_file` | ✅ | 删文件；**必须 `confirm: true`**，默认留 .bak（`create_backup: false` 关闭）；文件在编辑器打开时拒绝删除 |

## 批量执行

| 接口 | 可用性 | 用途 |
|---|---|---|
| `batch_execute` | ⚠️ | 一次请求按序跑多个工具调用（跨场景批量构建；不能嵌套，够不着运行时工具） |

## 运行与截图

| 接口 | 可用性 | 用途 |
|---|---|---|
| `run_scene` | ⚠️🎮 | 启动游戏（可 `wait_for_runtime` 等 helper 连上） |
| `stop_scene` | ⚠️🎮 | 停止运行 |
| `take_screenshot` | ⚠️🎮 | 运行中游戏截图（需要 runtime 连接） |

## 渲染与编辑器管理

| 接口 | 可用性 | 用途 |
|---|---|---|
| `render_scene_preview` | ✅ | **不跑游戏**离屏渲染 2D 场景为 PNG（检查布局首选，默认存 `addons/godot_mcp/cache/previews/`） |
| `rescan_filesystem` | ✅ | 触发文件系统重扫（外部新建/删除文件后调用；新 autoload/class_name 需 `restart_editor`） |
| `restart_editor` | ⚠️ | 重启编辑器（会中断当前编辑会话，慎用） |

## 可选 Toolset 一览（默认关闭，需 `enable_toolset`）

工具数为 v1.1.6 实测值，当前版本用 `list_toolsets` 查实时数量。

| Toolset | 工具数 | 用途 | 代表工具 |
|---|---|---|---|
| `runtime` | 29 | 驱动运行中游戏：输入、eval、节点/属性实时访问、录像回放、多人 | `send_input` `query_runtime_node` `game_eval` `await_signal_runtime` |
| `editor` | 14 | 编辑器自身：开发者活动、选区、性能、撤销重做 | `get_editor_activity` `get_editor_selection` `undo_last` `save_scene` |
| `project_config` | 13 | 项目设置/输入表/autoload/资源 | `configure_input_map` `setup_autoload` `create_resource` |
| `analysis` | 9 | 项目健康：未用资源、循环依赖、场景复杂度、信号流 | `find_unused_resources` `analyze_scene_complexity` |
| `code_intel` | 8 | GDScript 语言服务：符号导航/重命名/诊断 | `gd_definition` `gd_references` `gd_diagnostics` |
| `debug` | 11 | 断点步调（Debug Adapter 6006）：断点/栈/作用域/表达式 | `debug_set_breakpoints` `debug_stack_trace` |
| `scene_editing` | 14 | 碰撞形状/贴图/材质/分组/锚点/信号断开 | `set_collision_shape` `set_sprite_texture` `set_anchor_preset` |
| `scaffolding` | 12 | 脚手架：信号接线、@onready、状态机、C#、多人样板 | `scaffold_entity` `scaffold_state_machine` |
| `animation` | 14 | AnimationPlayer/AnimationTree 轨道与状态机 | `create_animation` `set_animation_keyframe` |
| `physics` | 7 | 碰撞形状/射线/物理层/预设 | `setup_collision` `set_physics_layers` |
| `tilemap` | 8 | TileMapLayer 单元格/地形/自动铺贴 | `tilemap_set_cell` `tilemap_autotile` |
| `3d` | 9 | 网格实例/灯光/环境/相机/骨骼 | `add_mesh_instance` `setup_lighting` |
| `shaders` | 6 | GDShader 创建/编辑/参数 | `create_shader` `set_shader_param` |
| `navigation` | 5 | 导航区域/烘焙/代理/层 | `bake_navigation_mesh` |
| `ui` | 6 | Theme 资源：颜色/样式盒/字体 | `create_theme` `set_theme_color` |
| `vfx` | 5 | GPUParticles 粒子与渐变 | `create_particles` |
| `audio` | 3 | 音频播放器节点与总线 | `add_audio_player` |
| `export` | 4 | 导出预设与异步导出任务 | `export_project` `get_export_status` |
| `refactor` | 5 | 项目级重命名/批量属性/文件移动 | `rename_symbol_project_wide` `rename_file` |
| `testing` | 6 | GUT 测试、场景/网格校验、断言 | `run_gut_tests` `validate_scene_integrity` |
| `utility` | 2 | 2D 资产生成、项目/场景可视化 | `generate_2d_asset` `map_project` |

## 使用注意（踩坑记录）

1. **本项目将 warning 视为 error**：`var x := <Variant 表达式>` 会触发 `The variable type is being inferred from a Variant value` Parse Error。用 `validate_scripts` 验证时会暴露。
2. **运行时工具 ≠ 编辑器工具**：`get_runtime_log` / `take_screenshot` / `send_input` / `game_eval` 等需要游戏在跑；游戏没运行时返回的不是故障，而是「Runtime helper is not connected」。
3. **`rescan_filesystem` 报 not connected**：多半是 Godot 编辑器没开；打开编辑器（MCP 插件自动连 6505）即可，无需重启 bridge。
4. **`delete_file` 双保险**：`confirm: true` 必传；文件正被编辑器打开时会被拒（`force: true` 可绕过，但可能崩编辑器，勿用）。
5. **编辑器未打开时所有依赖编辑器的接口都会失败**：先跑 `diagnose_connection` 定位，别盲目重试。
6. **`validate_scripts` 优先传 `paths`**：全项目扫描约 34ms/脚本，大项目会逼近 20s 看门狗。
7. **新文件（如图片）加入项目后**调 `rescan_filesystem`，否则 `.import` 不会生成。
8. 若修改文件后被 Godot 编辑器覆盖修改，可通过 MCP 接口修改，或关闭编辑器，修改文件之后再打开。
9. **`game_eval` 的临时 snippet 已落在 `addons/godot_mcp/cache/eval_snippets/`**（v1.2.1 fork 修改，已 gitignore）；旧版本散落在插件根目录的 `__mcp_snippet_*.gd` 会被新版本在下次校验时自动清理。
