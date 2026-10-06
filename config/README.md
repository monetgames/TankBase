# 数值配置说明（config/）

游戏全部数值集中在本目录，均为 JSON 文件，由 `scripts/autoload/config_loader.gd`
（ConfigLoader 单例）在启动时统一加载。

## 目录结构

| 文件 | 内容 | 加载到 |
|---|---|---|
| `tank/player_tank.json` | 玩家坦克基线属性（耐久/火力/射速/转速/机动等） | `ConfigLoader.tank_config` |
| `base/player_base.json` | 玩家基地属性（耐久、维修费用、基地作用范围等） | `ConfigLoader.base_config` |
| `equipment/equipment_templates.json` | 装备模板（13 类装备 × 白/蓝/紫/粉/金五档稀有度）+ `enhancement` 强化段（费用/成功率/属性倍率） | `ConfigLoader.equipment_configs` / `ConfigLoader.enhancement_levels` |
| `enemy/enemy_units.json` | 敌方单位（普通/精英/BOSS 坦克与敌方基地）及跨关卡三曲线缩放参数 | `ConfigLoader.enemy_configs` |
| `wave/wave_configs.json` | 30 关 × 每关 3 波的波次编排、关卡压力、拾取阶段时长 | `ConfigLoader.wave_configs` / `wave_pressure_config` |
| `drop/drop_rates.json` | 掉落概率、蓝图稀有度权重、战役结算奖励、智能蓝图规则 | `ConfigLoader.drop_configs` |
| `economy/initial_resources.json` | 新战役初始金币、背包/装备卡容量、初始蓝图与模组 | `ConfigLoader.initial_resources_config` |
| `upgrade/upgrades.json` | 构筑界面 8 条升级线的逐级费用与效果 | `ConfigLoader.upgrade_configs` |
| `items/items.json` | 消耗品道具定义与效果 | `ConfigLoader.items_config` |

## 修改约定

1. **键名不要改**：消费代码按键名读取（如 `tank_enemy.gd` 读敌方缩放曲线、
   `radar_ui.gd` 读雷达强化键、`game_state.gd` 逐键匹配升级线）。改键名等于删功能。
2. **`_comment` / `_description` / `_field_descriptions` 是给人看的说明字段**，
   不参与逻辑，改数值时请顺手同步说明。
3. **文件缺失或非法时自动回退内置默认值**，并在日志输出 `GameLog.warn` 告警——
   改完配置跑一次游戏，没有 config 告警即为兼容。
4. 数值单位在 `_comment` 中就近标注（HP、金币、秒、像素等）。

## 与代码的对应关系

- 强化等级费用/成功率/倍率：`equipment_templates.json` 的 `enhancement.levels`
  ↔ `ConfigLoader.enhancement_levels`（数组下标 = 强化等级 - 1）↔ `EquipmentSystem`。
- 敌方跨关卡成长：`enemy_units.json` 的 `scaling` 段 ↔ `base_enemy.gd` / `tank_enemy.gd`
  的 `apply_scaling`。
- 波次编排：`wave_configs.json` 的 `waves[]` ↔ `WaveManager`（`max_stages` 默认 30、
  `max_waves_per_stage` 默认 3）。
