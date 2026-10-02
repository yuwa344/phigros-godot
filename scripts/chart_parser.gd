# chart_parser.gd — RPE (Re:Phigros Emulator) 谱面格式解析器
# 支持 formatVersion 3，向下兼容 v1/v2 的事件坐标换算
# 时间单位换算: 秒 = beats / bpm * 1.875
class_name ChartParser

const BEAT_UNIT := 1.875

const TYPE_TAP := 1
const TYPE_DRAG := 2
const TYPE_HOLD := 3
const TYPE_FLICK := 4


class NoteData:
	extends RefCounted
	var type: int = 1
	var real_time: float = 0.0        # 判定时刻（秒）
	var position_x: float = 0.0       # 半轨单位，范围约 -6..6
	var real_hold_time: float = 0.0   # hold 时长（秒）
	var speed: float = 1.0            # 所在判定线流速
	var floor_position: float = 0.0   # 线内累计位移
	var above: bool = true            # true=notesAbove, false=notesBelow
	var line_index: int = 0
	# 运行时状态
	var status := 0        # 0=未判定 1=Perfect 2=Good 3=Bad/Miss 4=按住中 5=已打过头忽略
	var hold_idx := -1     # 正按住它的 touch index
	var fade_start := -1.0 # miss 后开始淡出的 chart time
	var head_grade := 1    # hold 头部等级（1=Perfect 2=Good），尾部完成时计一次
	var tick_acc := 0.0    # 按住期间节奏点特效计时


class SpeedEvent:
	extends RefCounted
	var start_rt: float
	var end_rt: float
	var floor_position: float
	var value: float


class MoveEvent:
	extends RefCounted
	var start_rt: float
	var end_rt: float
	var start: float
	var end: float      # x: 0..1
	var start2: float
	var end2: float     # y: 0..1


class RotateEvent:
	extends RefCounted
	var start_rt: float
	var end_rt: float
	var start_deg: float
	var end_deg: float


class DisappearEvent:
	extends RefCounted
	var start_rt: float
	var end_rt: float
	var start: float
	var end: float      # alpha


class LineData:
	extends RefCounted
	var bpm: float = 120.0
	var line_index: int = 0
	var speed_events: Array = []
	var move_events: Array = []
	var rotate_events: Array = []
	var disappear_events: Array = []
	var notes: Array = []            # 全部 NoteData
	var texture_path: String = ""    # 自定义判定线贴图
	var image_w: float = 1.0
	var image_h: float = 0.008
	var is_dark: bool = false

	static func _sort_by_start(a, b) -> bool:
		return a.start_rt < b.start_rt


# 把事件时间(beats)换算成秒
static func _rt(beat: float, bpm: float) -> float:
	return beat / bpm * BEAT_UNIT


static func parse(chart: Dictionary) -> Array:
	var lines: Array = []
	var version := int(chart.get("formatVersion", 3))
	var line_list: Array = chart.get("judgeLineList", [])
	for li in line_list.size():
		var raw: Dictionary = line_list[li]
		var ld := LineData.new()
		ld.line_index = li
		ld.bpm = float(raw.get("bpm", 120.0))
		var bpm := ld.bpm

		for e in raw.get("speedEvents", []):
			var se := SpeedEvent.new()
			se.start_rt = _rt(float(e["startTime"]), bpm)
			se.end_rt = _rt(float(e["endTime"]), bpm)
			se.floor_position = float(e.get("floorPosition", 0.0))
			se.value = float(e["value"])
			ld.speed_events.append(se)
		# floorPosition 缺失时（v1/v2）重算
		var acc := 0.0
		for se in ld.speed_events:
			if se.floor_position == 0.0 and acc != 0.0:
				se.floor_position = acc
			acc = se.floor_position + (se.end_rt - se.start_rt) * se.value

		for e in raw.get("judgeLineMoveEvents", []):
			var me := MoveEvent.new()
			me.start_rt = _rt(float(e["startTime"]), bpm)
			me.end_rt = _rt(float(e["endTime"]), bpm)
			var s := float(e["start"])
			var en := float(e["end"])
			if version == 1:
				me.start = floor(s / 1e3) / 880.0
				me.end = floor(en / 1e3) / 880.0
				me.start2 = fmod(s, 1e3) / 520.0
				me.end2 = fmod(en, 1e3) / 520.0
			elif version == 2:
				me.start = s / 1e3
				me.end = en / 1e3
				me.start2 = fmod(s, 1e3) / 520.0
				me.end2 = fmod(en, 1e3) / 520.0
			else:
				me.start = s
				me.end = en
				me.start2 = float(e.get("start2", 0.0))
				me.end2 = float(e.get("end2", 0.0))
			ld.move_events.append(me)

		for e in raw.get("judgeLineRotateEvents", []):
			var re := RotateEvent.new()
			re.start_rt = _rt(float(e["startTime"]), bpm)
			re.end_rt = _rt(float(e["endTime"]), bpm)
			re.start_deg = float(e["start"])
			re.end_deg = float(e["end"])
			ld.rotate_events.append(re)

		for e in raw.get("judgeLineDisappearEvents", []):
			var de := DisappearEvent.new()
			de.start_rt = _rt(float(e["startTime"]), bpm)
			de.end_rt = _rt(float(e["endTime"]), bpm)
			de.start = float(e["start"])
			de.end = float(e["end"])
			ld.disappear_events.append(de)

		var note_arrs := [
			[raw.get("notesAbove", []), true],
			[raw.get("notesBelow", []), false],
		]
		for na in note_arrs:
			for n in na[0]:
				var nd := NoteData.new()
				nd.type = int(n["type"])
				nd.position_x = float(n["positionX"])
				nd.above = na[1]
				nd.line_index = li
				nd.real_time = _rt(float(n["time"]), bpm)
				nd.real_hold_time = _rt(float(n.get("holdTime", 0.0)), bpm)
				# 求所在速度事件 → speed 与 floorPosition
				var t := nd.real_time
				var fp := 0.0
				var sp := 1.0
				var found := false
				for se in ld.speed_events:
					if t >= se.start_rt and t < se.end_rt:
						sp = se.value
						fp = se.floor_position + (t - se.start_rt) * se.value
						found = true
						break
				if not found and not ld.speed_events.is_empty():
					var last = ld.speed_events[ld.speed_events.size() - 1]
					sp = last.value
					fp = last.floor_position + (t - last.start_rt) * last.value
				nd.speed = sp
				nd.floor_position = fp
				ld.notes.append(nd)

		ld.speed_events.sort_custom(LineData._sort_by_start)
		ld.move_events.sort_custom(LineData._sort_by_start)
		ld.rotate_events.sort_custom(LineData._sort_by_start)
		ld.disappear_events.sort_custom(LineData._sort_by_start)
		lines.append(ld)
	return lines
