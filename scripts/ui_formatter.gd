extends Node
class_name UIFormatter

# UI 格式化工具类
# 统一处理所有 UI 显示格式，避免格式化逻辑分散

# 格式化维修效率显示
static func format_repair_efficiency(value: float) -> String:
	return "维修 %.1f" % value
