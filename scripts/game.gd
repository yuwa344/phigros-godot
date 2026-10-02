# game.gd — 游玩主场景：谱面渲染 + 判定 + 计分 + HUD + 结算
# 坐标系与事件求值遵循 RPE 谱面格式的公开数学定义
extends Node2D

const VIEW_W := 1920.0
const VIEW_H := 1080.0
const WLEN := VIEW_W / 2.0          # 960
const HLEN := VIEW_H / 2.0          # 540
const WLEN2 := VIEW_W / 18.0        # 单轨半宽基准
# 音符流速/间距基准：公式值 H*0.6，用户偏好压缩到 0.4 倍 → H*0.24
const HLEN2 := VIEW_H * 0.6 * 0.4
const LINE_SCALE := VIEW_H / 18.75  # 横屏(W>H*0.75)时用 H/18.75 = 57.6
const NOTE_SCALE := VIEW_W / 8000.0
const NOTE_TEX_W := 989.0           # 素材 SVG 固有宽度
const JUDGE_RANGE := VIEW_W * 0.117775

# 判定窗口（秒）
const WIN_PERFECT := 0.08
const WIN_GOOD := 0.16
const WIN_BAD := 0.2
const FADE_AFTER := 0.16

# 前奏/尾奏缓冲（秒）
const LEAD_IN := 5.0
const OUTRO := 5.0
# hold 身体绘制长度缩放（用户偏好缩短 25%）
const HOLD_LEN_SCALE := 0.75



@onready var note_layer: Node2D = $NoteLayer
@onready var line_layer: Node2D = $LineLayer
@onready var hud: CanvasLayer = $HUD
@onready var music: AudioStreamPlayer = $Music
@onready var sfx: AudioStreamPlayer = $SFX

# --- 歌曲数据 ---
var song_dir: String = ""
var meta: Dictionary = {}
var difficulty: String = "IN"
var lines: Array = []
var line_nodes: Array = []
var notes: Array = []               # 全部 NoteData（打平）
var tap_notes: Array = []           # type 1
var hold_notes: Array = []          # type 3
var drag_notes: Array = []          # type 2
var flick_notes: Array = []         # type 4
var num_of_notes := 0
var offset_sec := 0.0

# --- 音符精灵 ---
var sprites := {}                   # NoteData -> Array[Sprite2D]
var tex_tap: Texture2D
var tex_drag: Texture2D
var tex_flick: Texture2D
var tex_hold_body: Texture2D
var tex_hold_head: Texture2D
var tex_click: Texture2D   # 打击特效 30 帧序列图（256x256/帧）

# --- 时钟 ---
var running := false
var chart_time := 0.0
var chart_duration := 5.0
var song_over := false

# --- 统计 ---
var score := 0
var combo := 0
var max_combo := 0
var n_perfect := 0
var n_good := 0
var n_bad := 0

# --- 输入 ---
var touches := {}                   # idx -> {pos, prev, down_chart, moved, down}
var autoplay := false
var self_test := false

# --- HUD 节点 ---
var lbl_score: Label
var lbl_combo: Label
var lbl_song: Label
var lbl_level: Label
var lbl_intro: Label
var progress: ColorRect
var progress_bg: ColorRect
var result_panel: Control
var pause_panel: Control
var fx_layer: Node2D

var _sfx_pool: Array = []          # 8 路复用，密集和弦不互相切断
var _sfx_map := {}                 # note type -> AudioStream
var _sfx_i := 0


func _ready() -> void:
	tex_tap = load("res://assets/images/Tap.svg")
	tex_drag = load("res://assets/images/Drag.svg")
	tex_flick = load("res://assets/images/Flick.svg")
	tex_hold_body = load("res://assets/images/HoldBody.svg")
	tex_hold_head = load("res://assets/images/HoldHead.svg")
	tex_click = load("res://assets/images/clickRaw.png")
	# 击打音效（与原版绑定一致）：0=Tap/Hold头 1=Drag 2=Flick
	_sfx_map[ChartParser.TYPE_TAP] = load("res://assets/audio/HitSong0.ogg")
	_sfx_map[ChartParser.TYPE_HOLD] = load("res://assets/audio/HitSong0.ogg")
	_sfx_map[ChartParser.TYPE_DRAG] = load("res://assets/audio/HitSong1.ogg")
	_sfx_map[ChartParser.TYPE_FLICK] = load("res://assets/audio/HitSong2.ogg")
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_pool.append(p)
	_build_hud()
	if song_dir != "":
		start_song(song_dir, meta, difficulty)


func start_song(dir: String, song_meta: Dictionary, diff: String) -> void:
	song_dir = dir
	meta = song_meta
	difficulty = diff
	offset_sec = float(meta.get("offset", 0.0))

	var chart_path := dir.path_join(meta.get("chart" + difficulty, meta.get("chartLegacy", "")))
	var f := FileAccess.open(chart_path, FileAccess.READ)
	var chart: Dictionary = JSON.parse_string(f.get_as_text())
	lines = ChartParser.parse(chart)

	# 难度区分：仓库谱面四种难度同一 JSON，按密度抽稀
	# EZ 保留 1/3、HD 保留 2/3、IN/AT 完整谱面
	match difficulty:
		"EZ":
			_thin_notes(3)
		"HD":
			_thin_notes(2)

	var line_tex_map := {}
	var lf_path := dir.path_join("line.json")
	if FileAccess.file_exists(lf_path):
		var lf := FileAccess.open(lf_path, FileAccess.READ)
		var arr: Array = JSON.parse_string(lf.get_as_text())
		if arr != null:
			for e in arr:
				if String(e.get("Chart", "")) == chart_path.get_file():
					line_tex_map[int(e["LineId"])] = e

	# 清空旧节点
	for c in line_layer.get_children():
		c.queue_free()
	for c in note_layer.get_children():
		c.queue_free()
	sprites.clear()
	notes.clear()
	tap_notes.clear()
	hold_notes.clear()
	drag_notes.clear()
	flick_notes.clear()

	for ld in lines:
		var ln := JudgeLine.new()
		var entry = line_tex_map.get(ld.line_index)
		if entry != null:
			ld.texture_path = dir.path_join(String(entry["Image"]))
			ld.image_w = float(entry.get("Horz", 1.0))
			ld.image_h = float(entry.get("Vert", 1.0))
			ld.is_dark = String(entry.get("IsDark", "0")) == "1"
		ln.setup(ld)
		line_layer.add_child(ln)
		line_nodes.append(ln)
		for nd in ld.notes:
			notes.append(nd)
			match nd.type:
				ChartParser.TYPE_TAP: tap_notes.append(nd)
				ChartParser.TYPE_DRAG: drag_notes.append(nd)
				ChartParser.TYPE_HOLD: hold_notes.append(nd)
				ChartParser.TYPE_FLICK: flick_notes.append(nd)
			_make_sprites(nd)

	notes.sort_custom(func(a, b): return a.real_time < b.real_time)
	num_of_notes = notes.size()
	chart_duration = (notes[-1].real_time if not notes.is_empty() else 2.0) + 2.0 + OUTRO
	chart_time = -LEAD_IN
	var music_path := dir.path_join(String(meta["musicFile"]))
	music.stream = load(music_path)
	music.play()
	running = true
	song_over = false
	score = 0
	combo = 0
	max_combo = 0
	n_perfect = 0
	n_good = 0
	n_bad = 0
	lbl_song.text = String(meta.get("name", "?"))
	lbl_level.text = "%s  Lv.%s" % [difficulty, meta.get(String(difficulty).to_lower() + "Ranking", "?")]


func _thin_notes(keep: int) -> void:
	# 按全局时间顺序等比抽稀，EZ/HD 与 IN/AT 拉开难度差距
	var all: Array = []
	for ld in lines:
		for nd in ld.notes:
			all.append(nd)
	all.sort_custom(func(a, b): return a.real_time < b.real_time)
	for i in all.size():
		if i % keep != 0:
			var ld: ChartParser.LineData = lines[all[i].line_index]
			ld.notes.erase(all[i])


func _make_sprites(nd: ChartParser.NoteData) -> void:
	var arr: Array = []
	match nd.type:
		ChartParser.TYPE_TAP:
			var s := Sprite2D.new()
			s.texture = tex_tap
			note_layer.add_child(s)
			arr.append(s)
		ChartParser.TYPE_DRAG:
			var s := Sprite2D.new()
			s.texture = tex_drag
			note_layer.add_child(s)
			arr.append(s)
		ChartParser.TYPE_FLICK:
			var s := Sprite2D.new()
			s.texture = tex_flick
			note_layer.add_child(s)
			arr.append(s)
		ChartParser.TYPE_HOLD:
			var body := Sprite2D.new()
			body.texture = tex_hold_body
			body.centered = false
			note_layer.add_child(body)
			var head := Sprite2D.new()
			head.texture = tex_hold_head
			note_layer.add_child(head)
			arr.append(body)
			arr.append(head)
	if arr.is_empty():
		return
	for s in arr:
		s.scale = Vector2(NOTE_SCALE, NOTE_SCALE)
	sprites[nd] = arr


func _process(delta: float) -> void:
	if not running:
		return
	if DisplayServer.get_name() == "headless":
		# headless 下 Dummy 音频驱动不走混音，用增量时钟兜底
		chart_time += delta
	else:
		var mix := music.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
		chart_time = maxf(mix - offset_sec - LEAD_IN, chart_time)
	_update_world()
	_update_hud()
	var ended := chart_time >= chart_duration
	if not song_over and ended:
		_finish_song()


func _update_world() -> void:
	var out_tw := 0.0
	for i in line_nodes.size():
		var ln: JudgeLine = line_nodes[i]
		ln.evaluate(chart_time, VIEW_W, VIEW_H)
		ln.draw_self(VIEW_W, VIEW_H, LINE_SCALE, out_tw)
	for nd in notes:
		_update_note(nd)
	if autoplay:
		_do_autoplay()
	_do_judging()


# --- 音符位置计算（与 RPE 公开数学一致） ---
func _note_pos(nd: ChartParser.NoteData, line: JudgeLine) -> Vector2:
	var dx: float
	var cosr: float
	var sinr: float
	if nd.above:
		dx = WLEN2 * nd.position_x
		cosr = line.cosr
		sinr = line.sinr
	else:
		dx = -WLEN2 * nd.position_x
		cosr = -line.cosr
		sinr = -line.sinr
	var dy: float
	if nd.type == ChartParser.TYPE_HOLD and nd.real_time < chart_time:
		# hold 按住期间头钉在判定线上
		dy = (nd.real_time - chart_time) * nd.speed * HLEN2
	else:
		dy = (nd.floor_position - line.pos_y) * nd.speed * HLEN2
	var x := line.ox + dx * cosr + dy * sinr
	var y := line.oy + dx * sinr - dy * cosr
	return Vector2(x, y)


func _update_note(nd: ChartParser.NoteData) -> void:
	if not sprites.has(nd):
		return
	var line: JudgeLine = line_nodes[nd.line_index]
	var pos := _note_pos(nd, line)
	var dy: float
	if nd.type == ChartParser.TYPE_HOLD and nd.real_time < chart_time:
		dy = (nd.real_time - chart_time) * nd.speed * HLEN2
	else:
		dy = (nd.floor_position - line.pos_y) * nd.speed * HLEN2

	# 透明度：线前可见、过线淡出、miss 慢速淡出
	var a := 1.0
	var gray := false
	if nd.type == ChartParser.TYPE_HOLD and nd.status == 3:
		# 漏掉/断掉的 hold：立即变灰 + 半透明，直到尾部随时间缩没
		a = 0.38
		gray = true
	elif nd.fade_start >= 0.0:
		a = clampf(1.0 - (chart_time - nd.fade_start) / 0.5, 0.0, 1.0)
	elif nd.real_time > chart_time:
		a = 1.0 if dy > -0.001 * HLEN2 else 0.0
		if nd.type == ChartParser.TYPE_HOLD and nd.speed == 0.0:
			a = 0.45 if a > 0.0 else 0.0
	else:
		if nd.type == ChartParser.TYPE_HOLD and nd.status == 4:
			a = 1.0
		else:
			a = maxf(1.0 - (chart_time - nd.real_time) / FADE_AFTER, 0.0)
	a *= line.alpha

	var arr: Array = sprites[nd]
	# 音符局部坐标系：below 音符用镜像帧（旋转 +π），身体/贴图方向随之翻转
	var nrot := line.rot if nd.above else line.rot + PI
	match nd.type:
		ChartParser.TYPE_HOLD:
			var body: Sprite2D = arr[0]
			var head: Sprite2D = arr[1]
			# hold 身长：用户偏好整体缩短 25%
			var len_px: float = nd.speed * nd.real_hold_time * HLEN2 * HOLD_LEN_SCALE
			var base_scale := NOTE_SCALE
			var col := Color(0.55, 0.55, 0.55, a) if gray else Color(1, 1, 1, a)
			if nd.real_time > chart_time:
				# 未打到：头在锚点，身体沿局部 -y 方向伸展（below 音符自动朝下）
				head.position = pos
				head.rotation = nrot
				head.modulate = col
				body.scale = Vector2(base_scale, len_px / (1900.0 * base_scale))
				body.position = pos - Vector2(0, len_px).rotated(nrot) - Vector2(NOTE_TEX_W * base_scale / 2.0, 0).rotated(nrot)
				body.rotation = nrot
				body.modulate = col
			else:
				# 按住中/漏掉：身体顶端固定于尾端，底端随时间收缩
				var remain: float = (nd.real_time + nd.real_hold_time - chart_time) * nd.speed * HLEN2
				remain = maxf(remain, 0.0)
				var end_pos := pos - Vector2(0, len_px).rotated(nrot)
				body.scale = Vector2(base_scale, remain / (1900.0 * base_scale))
				body.position = end_pos - Vector2(NOTE_TEX_W * base_scale / 2.0, 0).rotated(nrot)
				body.rotation = nrot
				body.modulate = col
				head.visible = false
		_:
			var s: Sprite2D = arr[0]
			s.position = pos
			s.rotation = nrot
			s.modulate = Color(1, 1, 1, a)


# --- 判定 ---
func _do_judging() -> void:
	# Drag：过线自动 Perfect
	for nd in drag_notes:
		if nd.status == 0 and chart_time >= nd.real_time:
			_judge(nd, 1)
	# Flick：过线且任意 touch 有位移 → Perfect；超时 miss
	for nd in flick_notes:
		if nd.status == 0:
			var d: float = chart_time - nd.real_time
			if d > WIN_BAD:
				_miss(nd)
			elif d >= -WIN_GOOD:
				for t in touches.values():
					if t["moved"] and t["pos"].distance_to(_note_pos(nd, line_nodes[nd.line_index])) <= JUDGE_RANGE * 1.6:
						_judge(nd, 1)
						break
	# Tap：超时 miss
	for nd in tap_notes:
		if nd.status == 0 and chart_time - nd.real_time > WIN_BAD:
			_miss(nd)
	# Hold：头超时 miss；按住中检查提前松手（autoplay 下由 autoplay 自己收尾）
	for nd in hold_notes:
		if nd.status == 0 and chart_time - nd.real_time > WIN_BAD:
			_miss(nd)
		elif nd.status == 4 and not autoplay:
			var end_t: float = nd.real_time + nd.real_hold_time
			if not touches.has(nd.hold_idx) and chart_time < end_t - 0.2:
				# 原版语义：尾部前 0.2s 内松手不算断
				nd.status = 3
				n_bad += 1
				combo = 0
				nd.fade_start = chart_time
			elif chart_time >= end_t - 0.2:
				_complete_hold(nd)
			else:
				# 按住中节奏点特效（原版约 30000/bpm ms 一次）
				nd.tick_acc += get_process_delta_time()
				if nd.tick_acc >= 0.15:
					nd.tick_acc = 0.0
					_spawn_fx(nd, 1)
	# 汇总分数
	_update_score()


func _complete_hold(nd: ChartParser.NoteData) -> void:
	# 尾部完成：整个 hold 只在这里计一次（等级取头部判定）
	nd.status = 1
	if nd.head_grade == 2:
		n_good += 1
	else:
		n_perfect += 1
	combo += 1
	max_combo = maxi(max_combo, combo)
	nd.fade_start = chart_time
	_spawn_fx(nd, nd.head_grade)


func _on_touch_down(idx: int, pos: Vector2) -> void:
	if OS.get_cmdline_user_args().has("--inputtest"):
		var vp := get_viewport()
		print("[TOUCH] raw=%s final_inv=%s canvas_inv=%s screen_inv=%s" % [
			pos,
			vp.get_final_transform().affine_inverse() * pos,
			vp.get_canvas_transform().affine_inverse() * pos,
			vp.get_screen_transform().affine_inverse() * pos])
	touches[idx] = {
		"pos": pos, "prev": pos, "moved": false,
		"down_chart": chart_time, "down": true
	}
	# 找最近的 Tap / Hold 头
	var best: ChartParser.NoteData = null
	var best_d := 1e9
	for nd in tap_notes:
		if nd.status != 0:
			continue
		var dt: float = chart_time - nd.real_time
		if absf(dt) > WIN_BAD:
			continue
		var dist := pos.distance_to(_note_pos(nd, line_nodes[nd.line_index]))
		if dist <= JUDGE_RANGE and dist < best_d:
			best_d = dist
			best = nd
	for nd in hold_notes:
		if nd.status != 0:
			continue
		var dt: float = chart_time - nd.real_time
		if absf(dt) > WIN_BAD:
			continue
		var dist := pos.distance_to(_note_pos(nd, line_nodes[nd.line_index]))
		if dist <= JUDGE_RANGE and dist < best_d:
			best_d = dist
			best = nd
	if best != null:
		var dt: float = absf(chart_time - best.real_time)
		var st := 1 if dt <= WIN_PERFECT else 2
		if best.type == ChartParser.TYPE_HOLD:
			# 原版语义：hold 头只定等级+起始，不计数不进连击；尾部完成时计一次
			best.head_grade = st
			best.status = 4
			best.hold_idx = idx
			best.fade_start = -1.0
			_play_hit_sound(best.type)
			_spawn_fx(best, st)
		else:
			_judge(best, st)


func _on_touch_move(idx: int, pos: Vector2) -> void:
	if not touches.has(idx):
		return
	var t: Dictionary = touches[idx]
	if t["pos"].distance_to(pos) > 24.0:
		t["moved"] = true
	t["prev"] = t["pos"]
	t["pos"] = pos


func _on_touch_up(idx: int) -> void:
	touches.erase(idx)


func _judge(nd: ChartParser.NoteData, st: int) -> void:
	if st == 3:
		_miss(nd)
		return
	nd.status = st
	if st == 1:
		n_perfect += 1
	else:
		n_good += 1
	combo += 1
	max_combo = maxi(max_combo, combo)
	nd.fade_start = -1.0
	_play_hit_sound(nd.type)
	_spawn_fx(nd, st)


func _miss(nd: ChartParser.NoteData) -> void:
	nd.status = 3
	n_bad += 1
	combo = 0
	nd.fade_start = chart_time


func _play_hit_sound(type: int = ChartParser.TYPE_TAP) -> void:
	if not _sfx_map.has(type):
		return
	var p: AudioStreamPlayer = _sfx_pool[_sfx_i % _sfx_pool.size()]
	_sfx_i += 1
	p.stream = _sfx_map[type]
	p.pitch_scale = 1.0
	p.play()


func _update_score() -> void:
	var s := int(1e6 * (n_perfect * 0.9 + n_good * 0.585 + max_combo * 0.1) / maxf(num_of_notes, 1.0))
	s = mini(s, 1000000)
	if s != score:
		score = s
		lbl_score.text = "%07d" % score


func _do_autoplay() -> void:
	for nd in tap_notes:
		if nd.status == 0 and chart_time >= nd.real_time:
			_judge(nd, 1)
	for nd in hold_notes:
		if nd.status == 0 and chart_time >= nd.real_time:
			nd.status = 4
			nd.head_grade = 1
		if nd.status == 4 and chart_time >= nd.real_time + nd.real_hold_time - 0.2:
			_complete_hold(nd)
	for nd in flick_notes:
		if nd.status == 0 and chart_time >= nd.real_time:
			_judge(nd, 1)


# --- 特效 ---
# 原版 clickRaw 序列帧：30 帧 / 0.5s，Perfect 黄 #fce491、Good 绿 #97f79d
const FX_PERFECT := Color(0.988, 0.894, 0.569, 0.88)
const FX_GOOD := Color(0.659, 0.969, 0.616, 0.9)

func _spawn_fx(nd: ChartParser.NoteData, grade: int = 1) -> void:
	if not sprites.has(nd) or tex_click == null:
		return
	var line: JudgeLine = line_nodes[nd.line_index]
	var pos := _note_pos(nd, line)
	var s := Sprite2D.new()
	s.texture = tex_click
	s.vframes = 30
	s.frame = 0
	s.position = pos
	s.scale = Vector2(NOTE_SCALE * 6.0, NOTE_SCALE * 6.0)
	s.modulate = FX_PERFECT if grade <= 1 else FX_GOOD
	note_layer.add_child(s)
	var tw := s.create_tween()
	tw.tween_method(func(f: float): s.frame = int(f), 0.0, 29.0, 0.5)
	tw.tween_callback(s.queue_free)


# --- HUD ---
func _build_hud() -> void:
	var font := load("res://assets/fonts/shs_saira.ttf")

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	hud.add_child(bg_layer)
	var bg := TextureRect.new()
	bg.texture = load("res://assets/images/InitialBackground.png")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_layer.add_child(bg)
	# 背景毛玻璃（屏幕采样模糊，音符在世界层保持清晰）
	var blur := ColorRect.new()
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
void fragment() {
	vec2 ps = SCREEN_PIXEL_SIZE * 5.0;
	vec4 s = texture(screen_tex, SCREEN_UV) * 4.0;
	s += texture(screen_tex, SCREEN_UV + vec2(ps.x, 0.0));
	s += texture(screen_tex, SCREEN_UV - vec2(ps.x, 0.0));
	s += texture(screen_tex, SCREEN_UV + vec2(0.0, ps.y));
	s += texture(screen_tex, SCREEN_UV - vec2(0.0, ps.y));
	s += texture(screen_tex, SCREEN_UV + ps);
	s += texture(screen_tex, SCREEN_UV - ps);
	s += texture(screen_tex, SCREEN_UV + vec2(ps.x, -ps.y));
	s += texture(screen_tex, SCREEN_UV + vec2(-ps.x, ps.y));
	COLOR = vec4(s.rgb / 12.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	blur.material = mat
	bg_layer.add_child(blur)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_layer.add_child(dim)

	progress_bg = ColorRect.new()
	progress_bg.color = Color(1, 1, 1, 0.15)
	progress_bg.position = Vector2(0, 0)
	progress_bg.size = Vector2(VIEW_W, 6)
	hud.add_child(progress_bg)
	progress = ColorRect.new()
	progress.color = Color(1, 1, 1, 0.85)
	progress.position = Vector2(0, 0)
	progress.size = Vector2(0, 6)
	hud.add_child(progress)

	lbl_score = _mk_label(font, 74, HORIZONTAL_ALIGNMENT_RIGHT)
	lbl_score.position = Vector2(VIEW_W - 560, 26)
	lbl_score.size = Vector2(520, 90)
	lbl_score.text = "0000000"
	hud.add_child(lbl_score)

	lbl_combo = _mk_label(font, 100, HORIZONTAL_ALIGNMENT_CENTER)
	lbl_combo.position = Vector2(VIEW_W / 2.0 - 300, 30)
	lbl_combo.size = Vector2(600, 120)
	hud.add_child(lbl_combo)

	lbl_song = _mk_label(font, 44, HORIZONTAL_ALIGNMENT_LEFT)
	lbl_song.position = Vector2(70, VIEW_H - 96)
	lbl_song.size = Vector2(900, 60)
	hud.add_child(lbl_song)

	lbl_level = _mk_label(font, 44, HORIZONTAL_ALIGNMENT_RIGHT)
	lbl_level.position = Vector2(VIEW_W - 400, VIEW_H - 160)
	lbl_level.size = Vector2(330, 60)
	hud.add_child(lbl_level)

	fx_layer = Node2D.new()
	hud.add_child(fx_layer)

	lbl_intro = _mk_label(font, 64, HORIZONTAL_ALIGNMENT_CENTER)
	lbl_intro.position = Vector2(0, VIEW_H * 0.32)
	lbl_intro.size = Vector2(VIEW_W, 160)
	lbl_intro.modulate.a = 0.0
	hud.add_child(lbl_intro)

	_build_pause_panel(font)


func _mk_label(font: Font, size: int, align: int) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.horizontal_alignment = align
	return l


func _update_hud() -> void:
	lbl_combo.text = str(combo) if combo > 2 else ""
	lbl_combo.visible = combo > 2
	var frac := 0.0
	var len_stream := music.stream.get_length() if music.stream else 1.0
	frac = clampf(music.get_playback_position() / len_stream, 0.0, 1.0)
	progress.size.x = VIEW_W * frac
	# 前奏 5s：歌名淡入淡出
	if chart_time < -1.0:
		var t := clampf((chart_time + LEAD_IN) / 2.0, 0.0, 1.0)
		lbl_intro.text = "%s\n%s  %s" % [String(meta.get("name", "")), String(meta.get("artist", "")), difficulty]
		lbl_intro.modulate.a = t * t * (3.0 - 2.0 * t)
	else:
		lbl_intro.modulate.a = maxf(lbl_intro.modulate.a - get_process_delta_time() * 2.0, 0.0)


func _build_pause_panel(font: Font) -> void:
	pause_panel = Control.new()
	pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_panel.visible = false
	hud.add_child(pause_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(dim)
	_mk_menu_button(pause_panel, font, "继续", Vector2(0, -140), _toggle_pause)
	_mk_menu_button(pause_panel, font, "重新开始", Vector2(0, 0), _restart)
	_mk_menu_button(pause_panel, font, "退出选曲", Vector2(0, 140), _quit_to_select)


func _mk_menu_button(parent: Control, font: Font, text: String, offset: Vector2, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 52)
	b.position = Vector2(VIEW_W / 2.0 - 220, VIEW_H / 2.0 - 60 + offset.y)
	b.size = Vector2(440, 110)
	b.pressed.connect(cb)
	parent.add_child(b)


func _toggle_pause() -> void:
	if song_over:
		return
	var paused := not get_tree().paused
	get_tree().paused = paused
	pause_panel.visible = paused
	if paused:
		music.stream_paused = true
	else:
		music.stream_paused = false


func _restart() -> void:
	get_tree().paused = false
	pause_panel.visible = false
	music.stop()
	start_song(song_dir, meta, difficulty)


func _quit_to_select() -> void:
	get_tree().paused = false
	running = false
	music.stop()
	var main := get_parent()
	if main.has_method("show_song_select"):
		main.show_song_select()


# --- 输入 ---
func _input(event: InputEvent) -> void:
	if OS.get_cmdline_user_args().has("--inputtest"):
		if event is InputEventScreenTouch or event is InputEventMouseButton or event is InputEventScreenDrag:
			print("[IN] ", event.get_class(), " pos=", event.get("position"), " pressed=", event.get("pressed"))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_touch_down(event.index, event.position)
		else:
			_on_touch_up(event.index)
	elif event is InputEventScreenDrag:
		_on_touch_move(event.index, event.position)
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				_toggle_pause()
			KEY_P:
				autoplay = not autoplay
			KEY_R:
				_restart()


# --- 结算 ---
func _finish_song() -> void:
	song_over = true
	running = false
	var acc := 0.0
	if num_of_notes > 0:
		acc = (n_perfect + n_good * 0.65) / num_of_notes * 100.0
	if self_test:
		var judged := n_perfect + n_good + n_bad
		print("[SELFTEST] notes=%d judged=%d perfect=%d good=%d bad=%d maxcombo=%d score=%d" % [
			num_of_notes, judged, n_perfect, n_good, n_bad, max_combo, score])
		get_tree().quit()
		return
	var rank := "F"
	if n_bad == 0 and n_good == 0 and n_perfect >= num_of_notes and num_of_notes > 0:
		rank = "φ"
	elif n_bad == 0 and acc >= 95.0:
		rank = "V"
	elif acc >= 90.0:
		rank = "S"
	elif acc >= 82.0:
		rank = "A"
	elif acc >= 70.0:
		rank = "B"
	else:
		rank = "C"

	var font := load("res://assets/fonts/shs_saira.ttf")
	result_panel = Control.new()
	result_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.add_child(result_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_panel.add_child(dim)

	var title := _mk_label(font, 96, HORIZONTAL_ALIGNMENT_CENTER)
	title.text = {"φ": "ALL PERFECT", "V": "FULL COMBO", "S": "GAME OVER"}.get(rank, "GAME OVER")
	if rank == "φ" or rank == "V":
		title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	title.position = Vector2(0, VIEW_H * 0.18)
	title.size = Vector2(VIEW_W, 120)
	result_panel.add_child(title)

	var score_l := _mk_label(font, 140, HORIZONTAL_ALIGNMENT_CENTER)
	score_l.text = "%07d  %s" % [score, rank]
	score_l.position = Vector2(0, VIEW_H * 0.3)
	score_l.size = Vector2(VIEW_W, 180)
	result_panel.add_child(score_l)

	var stats := _mk_label(font, 56, HORIZONTAL_ALIGNMENT_CENTER)
	stats.text = "Perfect %d   Good %d   Bad %d\nMax Combo %d\n准确率 %.2f%%" % [
		n_perfect, n_good, n_bad, max_combo, acc]
	stats.position = Vector2(0, VIEW_H * 0.45)
	stats.size = Vector2(VIEW_W, 300)
	result_panel.add_child(stats)

	_mk_menu_button(result_panel, font, "再来一次", Vector2(0, -160), _restart)
	_mk_menu_button(result_panel, font, "返回选曲", Vector2(0, 40), _quit_to_select)


func _exit_tree() -> void:
	get_tree().paused = false
