extends Node
class_name FactoryParent

signal spawned(node: Node2D)                 # 成功产出一个实例时发射
signal alive_count_changed(alive: int)       # 当前存活数量发生变化时发射

# 工厂状态
enum FactoryStatus {
	IDLE,       # 初始/结束后状态
	RUNNING,    # 正在运行
	PAUSED      # 暂停中
}

var _status: FactoryStatus = FactoryStatus.IDLE

# —— 状态控制接口 ——
# 开始：初始化并启动
func start() -> void:
	if _status != FactoryStatus.IDLE:
		return
	_status = FactoryStatus.RUNNING
	_on_factory_start()

# 暂停：临时停止生产
func pause() -> void:
	if _status != FactoryStatus.RUNNING:
		return
	_status = FactoryStatus.PAUSED
	_on_factory_pause()

# 继续：从暂停恢复
func continue_work() -> void:
	if _status != FactoryStatus.PAUSED:
		return
	_status = FactoryStatus.RUNNING
	_on_factory_continue()

# 结束：永久停止并清理
func over() -> void:
	if _status == FactoryStatus.IDLE:
		return
	_status = FactoryStatus.IDLE
	_on_factory_over()

# 状态查询
func is_running() -> bool:
	return _status == FactoryStatus.RUNNING

func is_paused() -> bool:
	return _status == FactoryStatus.PAUSED

# —— 子类重写的回调 ——
func _on_factory_start() -> void:
	pass

func _on_factory_pause() -> void:
	pass

func _on_factory_continue() -> void:
	pass

func _on_factory_over() -> void:
	pass
