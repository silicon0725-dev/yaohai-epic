## 时间轴控件：clip 块横排（名+倍速角标+修剪标记）+ 事件带 + 秒刻度 +
## 播放头；接收动作拖放（追加）、点击 seek、Del 删选中块。
extends Control

signal seek_requested(t: float)
signal clip_appended(clip_name: String)
signal clip_selected(index: int)

const COLOR_BG := Color(0.09, 0.09, 0.11)
const COLOR_TRACK := Color(0.14, 0.14, 0.17)
const COLOR_CLIP := Color(0.18, 0.42, 0.65)
const COLOR_CLIP_SEL := Color(0.28, 0.58, 0.85)
const COLOR_TRIM := Color(0.95, 0.55, 0.15)   # 修剪角标（入/出点非全段）
const COLOR_EVENT := Color(0.85, 0.3, 0.45)   # 事件带
const COLOR_HEAD := Color(0.95, 0.75, 0.2)
const COLOR_TEXT := Color(0.75, 0.75, 0.78)
const PX_PER_SEC := 90.0
const TRACK_Y := 22.0
const TRACK_H := 30.0
const EVENT_H := 5.0

var model  # anim_editor_model（弱类型防 parse 卡）
var selected := -1
var _scroll := 0.0   # 秒（横向滚动偏移）


func _init() -> void:
	custom_minimum_size = Vector2(0, 104)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	if model != null:
		_connect_model()


func set_model(m) -> void:
	model = m
	if is_inside_tree():
		_connect_model()
	queue_redraw()


func _connect_model() -> void:
	if not model.queue_changed.is_connected(queue_redraw):
		model.queue_changed.connect(queue_redraw)
		model.playhead_moved.connect(queue_redraw)


# ---- 拖放接收：动作名 → 追加队列 ----

func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("clip") and data.has("length")


func _drop_data(_pos: Vector2, data: Variant) -> void:
	clip_appended.emit(String(data["clip"]))


# ---- 交互：点击 seek / 选中块 / 删除 ----

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var hit := _clip_at_x(event.position.x)
			if hit >= 0:
				selected = hit
				clip_selected.emit(hit)
			else:
				selected = -1
			seek_requested.emit(_x_to_time(event.position.x))
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll = maxf(_scroll - 0.4, 0.0)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll += 0.4
			queue_redraw()
	elif event is InputEventKey and event.pressed \
			and event.keycode == KEY_DELETE and selected >= 0:
		var idx := selected
		selected = -1
		model.remove_at(idx)


func _clip_at_x(x: float) -> int:
	if model == null or model.queue.is_empty():
		return -1
	var acc: float = -_scroll
	for i in model.queue.size():
		var w: float = model.item_length(model.queue[i]) * PX_PER_SEC
		if x >= acc and x < acc + w:
			return i
		acc += w
	return -1


func _x_to_time(x: float) -> float:
	var total: float = model.total_length() if model != null else 0.0
	return clampf((x - 8.0) / PX_PER_SEC + _scroll, 0.0, total)


func _time_to_x(t: float) -> float:
	return 8.0 + (t - _scroll) * PX_PER_SEC


func _draw() -> void:
	if model == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	# 刻度带（顶部 16px）
	var total: float = model.total_length()
	draw_rect(Rect2(0, 0, size.x, 16), COLOR_TRACK)
	var t := ceilf(_scroll * 2.0) / 2.0
	while t <= total and _time_to_x(t) < size.x:
		var x := _time_to_x(t)
		var major := fmod(t, 1.0) < 0.01
		draw_line(Vector2(x, 0), Vector2(x, 16),
				COLOR_TEXT if major else COLOR_TEXT * Color(0.5, 0.5, 0.5))
		if major:
			draw_string(ThemeDB.fallback_font, Vector2(x + 3, 13),
					"%.0f" % t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_TEXT)
		t += 0.5
	# clip 轨道 + 事件带
	draw_rect(Rect2(0, TRACK_Y, size.x, TRACK_H + EVENT_H + 8), COLOR_TRACK)
	var acc := 0.0
	for i in model.queue.size():
		var item: Dictionary = model.queue[i]
		var len_i: float = model.item_length(item)
		var x0 := _time_to_x(acc)
		var x1 := _time_to_x(acc + len_i)
		if x1 > 0 and x0 < size.x:
			var cx0 := maxf(x0, 0)
			var r := Rect2(Vector2(cx0 + 1, TRACK_Y + 2),
					Vector2(maxf(x1 - cx0 - 2, 4), TRACK_H - 4))
			draw_rect(r, COLOR_CLIP_SEL if i == selected else COLOR_CLIP)
			var label := String(item["clip"]).get_file()
			if float(item["speed"]) != 1.0:
				label += " ×%.2g" % float(item["speed"])
			draw_string(ThemeDB.fallback_font,
					r.position + Vector2(4, TRACK_H * 0.66),
					label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, 11,
					COLOR_TEXT)
			# 修剪角标：入点/出点偏离全段时两端画橙条
			var src_len: float = float(item.get("src_length", item["t1"]))
			if float(item["t0"]) > 1e-3:
				draw_rect(Rect2(r.position, Vector2(3, r.size.y)), COLOR_TRIM)
			if float(item["t1"]) < src_len - 1e-3:
				draw_rect(Rect2(Vector2(r.end.x - 3, r.position.y),
						Vector2(3, r.size.y)), COLOR_TRIM)
			# 事件带（块下方）
			var spd: float = maxf(float(item["speed"]), 0.05)
			for ev in item.get("events", []):
				var e0 := acc + (float(ev["t0"]) - float(item["t0"])) / spd
				var e1 := acc + (float(ev["t1"]) - float(item["t0"])) / spd
				var ex0 := maxf(_time_to_x(e0), cx0)
				var ex1 := minf(_time_to_x(e1), x1)
				if ex1 > ex0:
					draw_rect(Rect2(Vector2(ex0, TRACK_Y + TRACK_H + 3),
							Vector2(maxf(ex1 - ex0, 2), EVENT_H)), COLOR_EVENT)
		acc += len_i
	# 播放头
	var hx := _time_to_x(model.playhead)
	if hx >= 0 and hx <= size.x:
		draw_line(Vector2(hx, 0), Vector2(hx, size.y), COLOR_HEAD, 1.5)
		draw_circle(Vector2(hx, 18), 4.0, COLOR_HEAD)
	# 底部状态字
	draw_string(ThemeDB.fallback_font, Vector2(8, size.y - 6),
			"%.2fs / %.2fs%s" % [model.playhead, total,
			"  [循环]" if model.looping else ""],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_TEXT)
