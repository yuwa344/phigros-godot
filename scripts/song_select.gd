# song_select.gd — 选曲界面：扫描 songs/ 目录下的 meta.json
extends Control

const DIFFS := ["EZ", "HD", "IN", "AT"]
var songs: Array = []           # [{dir, meta}]
var selected := 0
var diff_selected := "IN"
var on_start: Callable = Callable()

var list_box: VBoxContainer
var lbl_title: Label
var lbl_detail: Label
var diff_buttons: Array = []
var btn_start: Button


func _ready() -> void:
	_scan_songs()
	_build_ui()
	_refresh()


func _scan_songs() -> void:
	songs.clear()
	var dir := DirAccess.open("res://songs")
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			var mf := "res://songs/%s/meta.json" % name
			if FileAccess.file_exists(mf):
				var f := FileAccess.open(mf, FileAccess.READ)
				var m = JSON.parse_string(f.get_as_text())
				if m is Dictionary:
					songs.append({"dir": "res://songs/" + name, "meta": m})
		name = dir.get_next()
	dir.list_dir_end()


func _build_ui() -> void:
	var font := load("res://assets/fonts/shs_saira.ttf")

	var bg := TextureRect.new()
	bg.texture = load("res://assets/images/InitialBackground.png")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.z_index = -1
	add_child(bg)

	lbl_title = Label.new()
	lbl_title.text = "Phigros"
	lbl_title.add_theme_font_override("font", font)
	lbl_title.add_theme_font_size_override("font_size", 96)
	lbl_title.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl_title.position = Vector2(90, 60)
	lbl_title.size = Vector2(800, 120)
	add_child(lbl_title)

	lbl_detail = Label.new()
	lbl_detail.add_theme_font_override("font", font)
	lbl_detail.add_theme_font_size_override("font_size", 40)
	lbl_detail.add_theme_color_override("font_color", Color.WHITE)
	lbl_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_detail.position = Vector2(90, 220)
	lbl_detail.size = Vector2(860, 420)
	add_child(lbl_detail)

	list_box = VBoxContainer.new()
	list_box.position = Vector2(1010, 70)
	list_box.size = Vector2(820, 660)
	list_box.add_theme_constant_override("separation", 14)
	add_child(list_box)

	var diff_row := HBoxContainer.new()
	diff_row.position = Vector2(1010, 780)
	diff_row.size = Vector2(820, 96)
	diff_row.add_theme_constant_override("separation", 24)
	add_child(diff_row)
	for d in DIFFS:
		var b := Button.new()
		b.text = d
		b.custom_minimum_size = Vector2(187, 90)
		b.add_theme_font_override("font", font)
		b.add_theme_font_size_override("font_size", 46)
		b.pressed.connect(_on_diff.bind(d))
		diff_row.add_child(b)
		diff_buttons.append(b)

	btn_start = Button.new()
	btn_start.text = "开 始"
	btn_start.add_theme_font_override("font", font)
	btn_start.add_theme_font_size_override("font_size", 56)
	btn_start.position = Vector2(90, 780)
	btn_start.size = Vector2(500, 130)
	btn_start.pressed.connect(_on_start)
	add_child(btn_start)

	var hint := Label.new()
	hint.text = "Esc 暂停  |  P 自动演示  |  R 重开"
	hint.add_theme_font_override("font", font)
	hint.add_theme_font_size_override("font_size", 30)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(90, 1000)
	hint.size = Vector2(500, 44)
	add_child(hint)


func _on_diff(d: String) -> void:
	diff_selected = d
	_refresh()


func _on_song(i: int) -> void:
	selected = i
	_refresh()


func _on_start() -> void:
	if songs.is_empty() or not on_start.is_valid():
		return
	visible = false
	var s: Dictionary = songs[selected]
	on_start.call(s["dir"], s["meta"], diff_selected)


func _refresh() -> void:
	for c in list_box.get_children():
		c.queue_free()
	var font := load("res://assets/fonts/shs_saira.ttf")
	for i in songs.size():
		var m: Dictionary = songs[i]["meta"]
		var b := Button.new()
		var ranks: Array = []
		for key in ["ezRanking", "hdRanking", "inRanking", "atRanking"]:
			if m.get(key, 0) > 0:
				ranks.append(str(int(m[key])))
		b.text = "%s\n%s / %s" % [String(m.get("name", "?")), String(m.get("artist", "?")), " ".join(ranks)]
		b.custom_minimum_size = Vector2(800, 130)
		b.add_theme_font_override("font", font)
		b.add_theme_font_size_override("font_size", 36)
		var idx := i
		b.pressed.connect(_on_song.bind(idx))
		if i == selected:
			b.modulate = Color(0.6, 0.9, 1.0)
		list_box.add_child(b)

	if not songs.is_empty():
		var m: Dictionary = songs[selected]["meta"]
		lbl_detail.text = "%s\n%s\n曲绘 %s\n谱面设计 %s" % [
			String(m.get("name", "?")), String(m.get("artist", "?")),
			String(m.get("illustrator", "?")), String(m.get("chartDesigner", "?"))]
	# 难度 tab：选中填充高亮，并显示对应等级
	var rank_keys := {"EZ": "ezRanking", "HD": "hdRanking", "IN": "inRanking", "AT": "atRanking"}
	var m2: Dictionary = {} if songs.is_empty() else songs[selected]["meta"]
	for i in diff_buttons.size():
		var d: String = DIFFS[i]
		var sel := d == diff_selected
		var sb := StyleBoxFlat.new()
		sb.corner_radius_top_left = 12
		sb.corner_radius_top_right = 12
		sb.corner_radius_bottom_left = 12
		sb.corner_radius_bottom_right = 12
		if sel:
			sb.bg_color = Color(0.16, 0.45, 0.85)
			diff_buttons[i].add_theme_stylebox_override("normal", sb)
			diff_buttons[i].add_theme_color_override("font_color", Color.WHITE)
		else:
			sb.bg_color = Color(1, 1, 1, 0.08)
			diff_buttons[i].add_theme_stylebox_override("normal", sb)
			diff_buttons[i].add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
		var rank := int(m2.get(rank_keys[d], 0))
		diff_buttons[i].text = d if rank <= 0 else "%s\n%d" % [d, rank]
