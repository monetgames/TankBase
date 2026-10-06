class_name UIPalette
## 军规像素 UI 配色规范（方案B）
## 代码中所有 UI 颜色统一从这里取，禁止散落硬编码。

# 底色
const BG_DEEP := Color("#0C120A")      # 最深底（槽位/输入框底）
const BG_PANEL := Color("#182216")     # 面板底
const BG_CARD := Color("#10160E")      # 卡片底/视窗底
const BG_PRESSED := Color("#2E3D28")   # 按压底

# 边框
const BORDER := Color("#4A5D3A")       # 主边框
const BORDER_HI := Color("#6B8A55")    # 高亮边框
const BORDER_DIM := Color("#2E3D28")   # 弱边框/分隔线

# 主色（磷光绿系）
const GREEN := Color("#97C459")        # 主强调/正常状态/选中
const GREEN_DARK := Color("#3B6D11")   # 深绿
const GREEN_TEXT := Color("#9CCC65")   # 标题文字绿

# 功能色
const AMBER := Color("#EF9F27")        # 警示/金币/时间
const AMBER_DARK := Color("#BA7517")   # 精英敌/次级警示
const TEAL := Color("#5DCAA5")         # 护盾/能量
const TEAL_DARK := Color("#1D9E75")    # 护盾填充
const RED := Color("#E24B4A")          # 危险/敌方/低耐久
const YELLOW := Color("#FAC775")       # 道具/拾取物

# 文字
const TEXT_MAIN := Color("#D8E0C8")    # 正文（浅绿白）
const TEXT_MUTED := Color("#7A8570")   # 次要文字
const TEXT_DARK := Color("#0C120A")    # 深底反白用

# 装备稀有度（沿用游戏设定，偏向像素风饱和度）
const RARITY_COMMON := Color("#B4B2A9")   # 普通-白
const RARITY_ADV := Color("#5D9CEC")      # 高级-蓝
const RARITY_RARE := Color("#B57FDD")     # 稀有-紫
const RARITY_EPIC := Color("#ED93B1")     # 神器-粉
const RARITY_LEGEND := Color("#FAC775")   # 传说-金

# 字号（缝合像素字体 12px 基准，只用 12 的整数倍）
const FONT_S := 12
const FONT_M := 24
const FONT_L := 36
const FONT_XL := 48
