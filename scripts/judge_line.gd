# judge_line.gd — 判定线运行时：按 chart time 求值三个事件轨道 + 流速位置
class_name JudgeLine
extends Node2D

var data: ChartParser.LineData
var custom_tex: Texture2D = null

# 每帧求值结果
var ox: float = 540.0          # 屏幕位置
var oy: float = 960.0
var rot: float = 0.0           # 弧度（顺时针，同 canvas 坐标系）
var alpha: float = 1.0
var pos_y: float = 0.0         # 线当前 floorPosition
var cosr: float = 1.0
var sinr: float = 0.0
var disappear_tw := 0.0        # 结束淡出系数（0..1）


func setup(line_data: ChartParser.LineData) -> void:
	data = line_data
	if line_data.texture_path != "":
		if ResourceLoader.exists(line_data.texture_path):
			custom_tex = load(line_data.texture_path)


static func _find(events: Array, t: float, out: Array) -> bool:
	# 找覆盖 t 的事件；返回是否命中。out[0]=事件 out[1]=插值t2
	for e in events:
		if t < e.start_rt:
			return false
		if t > e.end_rt:
			continue
		var span: float = e.end_rt - e.start_rt
		out[0] = e
		out[1] = 0.0 if span <= 0.0 else (t - e.start_rt) / span
		return true
	return false


func evaluate(t: float, view_w: float, view_h: float) -> void:
	var box: Array = [null, 0.0]
	if _find(data.disappear_events, t, box):
		var e: ChartParser.DisappearEvent = box[0]
		var t2: float = box[1]
		var a: float = e.start * (1.0 - t2) + e.end * t2
		alpha = clampf(a, 0.0, 1.0)
	else:
		alpha = 0.0 if not data.disappear_events.is_empty() else 1.0

	if _find(data.move_events, t, box):
		var m: ChartParser.MoveEvent = box[0]
		var t2: float = box[1]
		ox = view_w * (m.start * (1.0 - t2) + m.end * t2)
		oy = view_h * (1.0 - (m.start2 * (1.0 - t2) + m.end2 * t2))
	elif not data.move_events.is_empty():
		# -999999 起始事件兜底：取第一个事件起点
		ox = view_w * data.move_events[0].start
		oy = view_h * (1.0 - data.move_events[0].start2)
	else:
		ox = view_w * 0.5
		oy = view_h * 0.5

	if _find(data.rotate_events, t, box):
		var r: ChartParser.RotateEvent = box[0]
		var t2: float = box[1]
		rot = deg_to_rad(r.start_deg * (1.0 - t2) + r.end_deg * t2)
	elif not data.rotate_events.is_empty():
		rot = deg_to_rad(data.rotate_events[0].start_deg)
	else:
		rot = 0.0
	cosr = cos(rot)
	sinr = sin(rot)

	if _find(data.speed_events, t, box):
		var s: ChartParser.SpeedEvent = box[0]
		pos_y = (t - s.start_rt) * s.value + s.floor_position
	elif not data.speed_events.is_empty():
		pos_y = data.speed_events[0].floor_position


func draw_self(view_w: float, view_h: float, line_scale: float, out_tw: float) -> void:
	if alpha <= 0.001:
		return
	position = Vector2(ox, oy)
	rotation = rot
	modulate = Color(1, 1, 1, alpha)
	var tw := 1.0 - out_tw
	if custom_tex != null:
		var img_h: float
		if data.image_h > 0.0:
			img_h = line_scale * 18.75 * data.image_h
		else:
			img_h = view_h * -data.image_h
		var img_w: float = img_h * custom_tex.get_width() / custom_tex.get_height() * data.image_w
		queue_redraw_marker(img_w, img_h, tw)
	else:
		# 默认白线：长 lineScale*18.75*3（用户偏好 3 倍长度），厚 lineScale*0.15
		queue_redraw_marker(line_scale * 18.75 * 3.0 * tw, line_scale * 0.15, 1.0)


var _draw_w := 100.0
var _draw_h := 4.0


func queue_redraw_marker(w: float, h: float, _tw: float) -> void:
	_draw_w = w
	_draw_h = h
	queue_redraw()


func _draw() -> void:
	if custom_tex != null:
		draw_texture_rect(custom_tex, Rect2(-_draw_w / 2.0, -_draw_h / 2.0, _draw_w, _draw_h), false)
		return
	var col := Color(1.0, 1.0, 1.0, 1.0)
	var glow := Color(0.6, 0.9, 1.0, 0.35)
	draw_rect(Rect2(-_draw_w / 2.0, -_draw_h / 2.0 - _draw_h * 0.8, _draw_w, _draw_h * 2.6), glow)
	draw_rect(Rect2(-_draw_w / 2.0, -_draw_h / 2.0, _draw_w, _draw_h), col)
