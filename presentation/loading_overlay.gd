## 加载界面 v2（用户 2026-10-24 指定动画）：等距立方体线框，
## 小方块从上方逐个坠落填充 4×4×4 网格；填满后整体变纯白，
## 快速放大吞没屏幕，随后淡出进入游戏。纯代码 _draw 绘制，
## 零 UI 资源依赖。无 class_name（全局类缓存坑——调用方 preload）。
## 层序：_bg（深色底）< _cube（动画）< _text_layer（标题/状态/提示，
## 保证坠落方块从文字后经过）；放大时文字随 _bg 一起淡出。
extends CanvasLayer

signal finished

const BG_COLOR := Color(0.05, 0.07, 0.12)
const TEXT_COLOR := Color(0.88, 0.90, 0.94)
const SUB_COLOR := Color(0.55, 0.60, 0.68)

var _status_label: Label
var _bg: ColorRect
var _text_layer: Control
var _cube: CubeFill
var _finishing := false


func _ready() -> void:
	layer = 100
	var vp := get_viewport().get_visible_rect().size
	_bg = ColorRect.new()
	_bg.color = BG_COLOR
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	_cube = CubeFill.new()
	_cube.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_cube)
	_cube.zoom_started.connect(_on_cube_zoom_started)
	_cube.screen_covered.connect(_on_cube_screen_covered)
	_cube.completed.connect(_on_cube_completed)

	_text_layer = Control.new()
	_text_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_text_layer)

	var title := Label.new()
	title.text = "瑶海 EPIC"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", TEXT_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size = Vector2(400, 60)
	title.position = Vector2(vp.x * 0.5 - 200, vp.y * 0.16)
	_text_layer.add_child(title)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 17)
	_status_label.add_theme_color_override("font_color", TEXT_COLOR)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.size = Vector2(520, 24)
	_status_label.position = Vector2(vp.x * 0.5 - 260, vp.y * 0.55 + 140)
	_text_layer.add_child(_status_label)

	var tip := Label.new()
	tip.text = "WASD 移动 · 空格跳跃 · 左键挖掘 · 右键放置"
	tip.add_theme_font_size_override("font_size", 15)
	tip.add_theme_color_override("font_color", SUB_COLOR)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.size = Vector2(440, 22)
	tip.position = Vector2(vp.x * 0.5 - 220, vp.y - 64)
	_text_layer.add_child(tip)

	set_progress(0.0, "正在唤醒世界…")


## pct 0..1；phase_text 状态行（"生成地形与构建网格… 123/324"）
func set_progress(pct: float, phase_text: String) -> void:
	if _finishing:
		return
	_status_label.text = phase_text
	_cube.set_fill_progress(pct)


## 收尾序列：补齐并落完剩余方块 → 变白 → 放大吞屏 → 淡出 → finished。
func finish() -> void:
	if _finishing:
		return
	_finishing = true
	_cube.request_finish()


func _on_cube_zoom_started() -> void:
	# 白立方开始膨胀：文字快速淡出（快于膨胀，避免被白块"穿过"）。
	# 蓝底不在这里动——必须保持不透明直到白块铺满屏幕（用户实测：
	# 提前淡出会在白块铺满前露出游戏画面）
	var tw := create_tween()
	tw.tween_property(_text_layer, "modulate:a", 0.0, 0.15)


func _on_cube_screen_covered() -> void:
	# 白块已铺满全屏：蓝底在其后已不可见，此刻隐藏，
	# FADE 淡出白块时透出的才是游戏画面（若蓝底仍在会先透出蓝再跳变）
	_bg.visible = false
	_text_layer.visible = false


func _on_cube_completed() -> void:
	finished.emit()
	queue_free()


## 等距立方体填充动画（内部类，避免新全局 class_name 的缓存坑）。
## 绘制坐标以立方体中心为原点，经 draw_set_transform 完成放大。
class CubeFill:
	extends Control

	signal zoom_started
	signal screen_covered
	signal completed

	const N := 4            # 4×4×4 = 64 个体素
	const CELL := 26.0      # 单体素边长（px）
	const TOTAL := N * N * N
	const SPAWN_INTERVAL := 0.05   # 常规落下间隔（s）——错峰瀑布
	const SPAWN_INTERVAL_FAST := 0.03  # 收尾补齐间隔（s）
	const FALL_TIME := 0.30        # 单块坠落时长（s）
	const MAX_AIR := 5             # 常规同时在飞上限（稳态 5/0.3≈17 块/s ≥ 加载速率）
	const MAX_AIR_FAST := 12       # 收尾补齐并发（64 块最慢 ~1.3s 补完）
	const SPAWN_HEIGHT := 6.0      # 坠落起始高度（格）
	const WHITE_TIME := 0.14       # 填满→整体变白
	const ZOOM_TIME := 0.30        # 变白→放大吞屏
	const FADE_TIME := 0.45        # 全白→淡出

	# 等距单位方向（屏幕 y 向下）：+x 右下、+y 左下、+z 上
	const AX := Vector2(0.866, 0.5)
	const AY := Vector2(-0.866, 0.5)
	const AZ := Vector2(0.0, -1.0)

	const BASE := Color(0.30, 0.75, 0.45)
	const OUTLINE := Color(0.05, 0.07, 0.12)
	const WIRE := Color(0.88, 0.90, 0.94, 0.55)

	const PHASE_FILL := 0
	const PHASE_WHITE := 1
	const PHASE_ZOOM := 2
	const PHASE_FADE := 3

	var _order: Array[Vector3i] = []   # 坠落顺序：底层先、层内随机（定种子）
	var _landed: Array[Vector3i] = []
	var _falling: Array[Dictionary] = []
	var _spawned := 0
	var _target_filled := 0
	var _finishing := false
	var _spawn_timer := 0.0
	var _phase := PHASE_FILL
	var _phase_t := 0.0
	var _zoom_target := 8.0

	func _ready() -> void:
		var vp := get_viewport().get_visible_rect().size
		# 放大到投影包围盒盖过全屏（宽 1.732·边长，高 2·边长）再留 25%
		var edge := float(N) * CELL
		_zoom_target = maxf(vp.x / (1.732 * edge), vp.y / (2.0 * edge)) * 1.25
		var rng := RandomNumberGenerator.new()
		rng.seed = 20261024
		for z in N:
			var layer: Array[Vector3i] = []
			for x in N:
				for y in N:
					layer.append(Vector3i(x, y, z))
			layer.shuffle()
			_order.append_array(layer)

	func set_fill_progress(pct: float) -> void:
		_target_filled = clampi(int(round(pct * TOTAL)), 0, TOTAL)

	func request_finish() -> void:
		_finishing = true
		_target_filled = TOTAL

	func _process(delta: float) -> void:
		_phase_t += delta
		if _phase == PHASE_FILL:
			_step_fill(delta)
			if _finishing and _spawned >= TOTAL and _falling.is_empty():
				_phase = PHASE_WHITE
				_phase_t = 0.0
		elif _phase == PHASE_WHITE:
			if _phase_t >= WHITE_TIME:
				_phase = PHASE_ZOOM
				_phase_t = 0.0
				zoom_started.emit()
		elif _phase == PHASE_ZOOM:
			if _phase_t >= ZOOM_TIME:
				_phase = PHASE_FADE
				_phase_t = 0.0
				screen_covered.emit()
		elif _phase == PHASE_FADE:
			self_modulate = Color(1.0, 1.0, 1.0,
					1.0 - clampf(_phase_t / FADE_TIME, 0.0, 1.0))
			if _phase_t >= FADE_TIME:
				set_process(false)
				completed.emit()
				return
		queue_redraw()

	## 错峰瀑布：限速节流保持"一个接一个"的节奏，允许少量并发
	## 在飞追赶真实进度（串行 64 块需 5s+，比加载还慢会拖长收尾）
	func _step_fill(delta: float) -> void:
		_spawn_timer -= delta
		# 进度曲线尾段猛拉（active 数后程才爬满）或收尾时缺口大：
		# 自动切高速档追赶，动画始终咬住真实进度
		var rushing: bool = _finishing or _target_filled - _spawned > MAX_AIR
		var interval := SPAWN_INTERVAL_FAST if rushing else SPAWN_INTERVAL
		var max_air := MAX_AIR_FAST if rushing else MAX_AIR
		while _spawned < _target_filled and _falling.size() < max_air:
			if _spawn_timer > 0.0:
				break
			_falling.append({"cell": _order[_spawned], "t": 0.0})
			_spawned += 1
			# += 而非 =：加载期主线程帧率低（预算放宽），长帧内连发
			# 追回欠账，spawn 速率恒为 1/interval 不被帧率钳制
			_spawn_timer += interval
		var i := _falling.size() - 1
		while i >= 0:
			var f: Dictionary = _falling[i]
			f["t"] = float(f["t"]) + delta / FALL_TIME
			if float(f["t"]) >= 1.0:
				_landed.append(f["cell"])
				_falling.remove_at(i)
			i -= 1

	func _draw() -> void:
		var rect := get_viewport().get_visible_rect().size
		var center := Vector2(rect.x * 0.5, rect.y * 0.55)
		# 变白度：FILL 为 0（绿色体素），WHITE 内 0→1，ZOOM/FADE 恒 1。
		# 曾写成"非 WHITE 恒 1"——填充期全程纯白，绿色瀑布不可见
		var wt := 0.0
		if _phase == PHASE_WHITE:
			wt = clampf(_phase_t / WHITE_TIME, 0.0, 1.0)
		elif _phase != PHASE_FILL:
			wt = 1.0
		var sc := 1.0
		if _phase == PHASE_ZOOM:
			var k := clampf(_phase_t / ZOOM_TIME, 0.0, 1.0)
			sc = 1.0 + (_zoom_target - 1.0) * k * k
		elif _phase == PHASE_FADE:
			sc = _zoom_target
		draw_set_transform(center, 0.0, Vector2(sc, sc))
		_draw_wireframe(wt)
		# 落定方块按深度排序（先远后近、同深先低后高）
		var cells := _landed.duplicate()
		cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			return (a.x + a.y) * 100 + a.z < (b.x + b.y) * 100 + b.z)
		for cell in cells:
			_draw_voxel(_cell_center(cell), wt)
		# 飞行中的方块最后画（永远可见）
		for f in _falling:
			var t := float(f["t"])
			var drop := SPAWN_HEIGHT * CELL * (1.0 - t * t)
			_draw_voxel(_cell_center(f["cell"]) + AZ * drop, wt)

	func _cell_center(cell: Vector3i) -> Vector2:
		var half := float(N - 1) * 0.5
		return AX * ((cell.x - half) * CELL) \
				+ AY * ((cell.y - half) * CELL) \
				+ AZ * ((cell.z - half) * CELL)

	func _draw_wireframe(wt: float) -> void:
		var h := float(N) * CELL * 0.5
		var color := WIRE.lerp(Color.WHITE, wt)
		var c := {}
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					c["%d%d%d" % [int(sx), int(sy), int(sz)]] = \
							AX * (h * sx) + AY * (h * sy) + AZ * (h * sz)
		var edges := [
			["-1-1-1", "1-1-1"], ["1-1-1", "11-1"], ["11-1", "-11-1"],
			["-11-1", "-1-1-1"],
			["-1-11", "1-11"], ["1-11", "111"], ["111", "-111"],
			["-111", "-1-11"],
			["-1-1-1", "-1-11"], ["1-1-1", "1-11"],
			["11-1", "111"], ["-11-1", "-111"],
		]
		for e in edges:
			draw_line(c[e[0]], c[e[1]], color, 2.0)

	func _draw_voxel(p: Vector2, wt: float) -> void:
		var u := CELL * 0.5
		var top := [ \
				p + AX * -u + AY * -u + AZ * u, \
				p + AX * u + AY * -u + AZ * u, \
				p + AX * u + AY * u + AZ * u, \
				p + AX * -u + AY * u + AZ * u]
		var right := [ \
				p + AX * u + AY * -u + AZ * u, \
				p + AX * u + AY * u + AZ * u, \
				p + AX * u + AY * u + AZ * -u, \
				p + AX * u + AY * -u + AZ * -u]
		var left := [ \
				p + AX * -u + AY * u + AZ * u, \
				p + AX * u + AY * u + AZ * u, \
				p + AX * u + AY * u + AZ * -u, \
				p + AX * -u + AY * u + AZ * -u]
		_face(top, _face_color(1.0, wt), wt)
		_face(right, _face_color(0.66, wt), wt)
		_face(left, _face_color(0.45, wt), wt)

	func _face(points: Array, color: Color, wt: float) -> void:
		var pts := PackedVector2Array(points)
		draw_polygon(pts, PackedColorArray([color]))
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, OUTLINE.lerp(Color.WHITE, wt), 1.0)

	func _face_color(mult: float, wt: float) -> Color:
		return (BASE * mult).lerp(Color.WHITE, wt)
