extends Control

func _ready() -> void:
	# 加载欢迎界面
	show_welcome_screen()

func show_welcome_screen() -> void:
	# 清除现有子节点
	for child in get_children():
		child.queue_free()
	
	# 加载欢迎界面
	var welcome_scene = preload("res://scenes/game_welcome.tscn")
	var game_welcome = welcome_scene.instantiate()
	add_child(game_welcome)
