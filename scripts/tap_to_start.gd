# tap_to_start.gd — 启动页：Logo + "点 击 屏 幕 开 始" + 循环 BGM + 上升气泡
# 复刻原版 tapToStart 页面：点击后黑场过渡进入选曲
extends Control

signal finished

const VIEW_W := 1920.0
const VIEW_H := 1080.0

var _started := false
var _music: AudioStreamPlayer
var _bubble_timer: Timer
var _fade_rect: ColorRect
var _logo: TextureRect
var _tap_label: Label


func _ready() -> void:
	var font := load("res://assets/fonts/shs_saira.ttf")

	# 关键：整页鼠标穿透，否则 Control 默认 STOP 会在 GUI 阶段吞掉点击，
	# _unhandled_input 永远收不到事件
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 背景 + 毛玻璃（模拟原版 backdrop-filter: blur(15px)）
	var bg := TextureRect.new()
	bg.texture = load("res://assets/images/InitialBackground.png")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var blur := ColorRect.new()
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blur.color = Color(0.85, 0.88, 0.92, 0.25)
	add_child(blur)

	# Logo（高度 20%，居中）
	_logo = TextureRect.new()
	_logo.texture = load("res://assets/images/Phigros.png")
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var logo_h := VIEW_H * 0.2
	var logo_w := logo_h * 4.4  # Phigros.png 约为 4.4:1
	_logo.size = Vector2(logo_w, logo_h)
	_logo.position = Vector2(VIEW_W / 2.0 - logo_w / 2.0, VIEW_H / 2.0 - logo_h - 40)
	add_child(_logo)

	# "点 击 屏 幕 开 始"
	_tap_label = Label.new()
	_tap_label.text = "点 击 屏 幕 开 始"
	_tap_label.add_theme_font_override("font", font)
	_tap_label.add_theme_font_size_override("font_size", 44)
	_tap_label.add_theme_color_override("font_color", Color.WHITE)
	_tap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tap_label.position = Vector2(VIEW_W / 2.0 - 400, VIEW_H / 2.0 + 70)
	_tap_label.size = Vector2(800, 70)
	add_child(_tap_label)

	# BGM 循环
	var stream: AudioStreamMP3 = load("res://assets/audio/TouchToStart0.mp3")
	stream.loop = true
	_music = AudioStreamPlayer.new()
	_music.stream = stream
	_music.volume_db = -6.0
	add_child(_music)
	_music.play()

	# 气泡生成器：每 2s 一个，12s 升到顶
	_bubble_timer = Timer.new()
	_bubble_timer.wait_time = 2.0
	_bubble_timer.timeout.connect(_spawn_bubble)
	add_child(_bubble_timer)
	_bubble_timer.start()

	# 黑场过渡层（点击后淡入）
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade_rect)

	# Logo 呼吸动画
	var tw := create_tween().set_loops()
	tw.tween_property(_logo, "modulate:a", 0.75, 1.4).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_logo, "modulate:a", 1.0, 1.4).set_trans(Tween.TRANS_SINE)


func _spawn_bubble() -> void:
	var b := Bubble.new()
	var bottom_frac := randf() * 100.0
	if bottom_frac >= 50.0:
		bottom_frac -= 35.0
	b.position = Vector2(randf() * VIEW_W, VIEW_H * (1.0 - bottom_frac / 100.0))
	add_child(b)


func _unhandled_input(event: InputEvent) -> void:
	if _started:
		return
	var tapped := false
	if event is InputEventScreenTouch and event.pressed:
		tapped = true
	elif event is InputEventMouseButton and event.pressed:
		tapped = true
	elif event is InputEventKey and event.pressed:
		tapped = true
	if tapped:
		_go()


func _go() -> void:
	_started = true
	_bubble_timer.stop()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_fade_rect, "color:a", 1.0, 0.5)
	tw.tween_property(_music, "volume_db", -40.0, 0.5)
	tw.chain().tween_callback(func():
		_music.stop()
		finished.emit()
	)


class Bubble:
	extends Node2D
	# 原版 keyframes: 0%:0 → 20%:.8 → 50%:1 → 75%:.6 → 95%:0，12s 升到顶
	const LIFE := 12.0
	var _life := 0.0

	func _process(delta: float) -> void:
		_life += delta
		if _life >= LIFE:
			queue_free()
			return
		var t := _life / LIFE
		var a: float
		if t < 0.2:
			a = t / 0.2 * 0.8
		elif t < 0.5:
			a = 0.8 + (t - 0.2) / 0.3 * 0.2
		elif t < 0.75:
			a = 1.0 - (t - 0.5) / 0.25 * 0.4
		elif t < 0.95:
			a = 0.6 - (t - 0.75) / 0.2 * 0.6
		else:
			a = 0.0
		modulate = Color(1, 1, 1, a)
		position.y -= delta * (get_viewport_rect().size.y + 100.0) / LIFE
		queue_redraw()

	func _draw() -> void:
		draw_circle(Vector2.ZERO, 7.5, Color(1, 1, 1, 0.85))
		draw_circle(Vector2.ZERO, 11.0, Color(1, 1, 1, 0.12))
