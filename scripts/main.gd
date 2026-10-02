# main.gd — 根节点：选曲 ↔ 游玩 场景切换
extends Node

var select_scene: Control
var tap_page: Control

func _ready() -> void:
	var game := $Game
	var sel := preload("res://scripts/song_select.gd").new()
	sel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(sel)
	select_scene = sel
	sel.visible = false
	sel.on_start = func(dir, meta, diff):
		game.song_dir = dir
		game.meta = meta
		game.difficulty = diff
		game.start_song(dir, meta, diff)
		sel.visible = false

	# 启动页：点击后进入选曲
	var tap := preload("res://scripts/tap_to_start.gd").new()
	tap.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(tap)
	tap_page = tap
	tap.finished.connect(func():
		tap.visible = false
		select_scene.visible = true
	)

	if OS.get_cmdline_user_args().has("--selftest"):
		_selftest()
	elif OS.get_cmdline_user_args().has("--shot"):
		_shot_test()
	elif OS.get_cmdline_user_args().has("--inputtest"):
		_inputtest()


func _inputtest() -> void:
	await get_tree().create_timer(1.0).timeout
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_LEFT
	m.pressed = true
	m.position = Vector2(100, 100)
	m.global_position = Vector2(100, 100)
	Input.parse_input_event(m)
	await get_tree().create_timer(1.2).timeout
	print("[INPUTTEST] tap_page=%s select=%s" % [tap_page.visible, select_scene.visible])
	get_tree().quit()


func _shot_test() -> void:
	var game := $Game
	game.autoplay = true
	# 自动化运行：禁用 UI 节点，防止桌面误点干扰截图
	tap_page.process_mode = Node.PROCESS_MODE_DISABLED
	select_scene.process_mode = Node.PROCESS_MODE_DISABLED
	tap_page.visible = false
	select_scene.visible = false
	await get_tree().create_timer(0.5).timeout
	get_viewport().get_texture().get_image().save_png("res://../shot_select.png")
	var f := FileAccess.open("res://songs/sample/meta.json", FileAccess.READ)
	var meta: Dictionary = JSON.parse_string(f.get_as_text())
	game.start_song("res://songs/sample", meta, "IN")
	select_scene.visible = false
	var marks := []
	for i in 10:
		marks.append(6.0 + i * 0.5)
	var last := 0.0
	for t in marks:
		await get_tree().create_timer(t - last).timeout
		last = t
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://../shot_%ds.png" % int(t))
		print("[SHOT] saved at %ds" % int(t))
	get_tree().quit()


func _selftest() -> void:
	var game := $Game
	game.self_test = true
	game.autoplay = true
	tap_page.visible = false
	Engine.time_scale = 20.0
	var diff := "IN"
	for a in OS.get_cmdline_user_args():
		if a in ["EZ", "HD", "AT"]:
			diff = a
	var f := FileAccess.open("res://songs/sample/meta.json", FileAccess.READ)
	var meta: Dictionary = JSON.parse_string(f.get_as_text())
	game.start_song("res://songs/sample", meta, diff)


func show_song_select() -> void:
	var game := $Game
	for c in game.note_layer.get_children():
		c.queue_free()
	for c in game.line_layer.get_children():
		c.queue_free()
	select_scene.visible = true
