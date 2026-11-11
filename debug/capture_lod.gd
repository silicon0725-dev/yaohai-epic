## 远景壳/水面 LOD 验收：站在岸上横看水湾，三帧 A/B/C
##   godot --path . res://debug/capture_lod.tscn
## A=默认  B=隐藏远景壳  C=隐藏区块网格（只看壳）
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _shore := Vector2i.ZERO
var _look := Vector3.ZERO
var _tag := "v1"


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "lod_probe")
	if OS.get_environment("SHOT_TAG") != "":
		_tag = OS.get_environment("SHOT_TAG")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 3.0 and not main_ref._loading:
			_setup_vantage()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 4.0:  # 等区块流式补到位 + 壳重建
			_cam.make_current()
			capture("debug/lod_%s_A_default.png" % _tag)
			var shell: Node = main_ref.distant_shell
			if shell != null and shell.get_child_count() > 0:
				shell.get_child(0).visible = false
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 1.0:
			capture("debug/lod_%s_B_noshell.png" % _tag)
			var shell: Node = main_ref.distant_shell
			if shell != null and shell.get_child_count() > 0:
				shell.get_child(0).visible = true
			main_ref.chunk_renderer.visible = false
			_phase = 3
			_wait = 0.0
	elif _phase == 3:
		if _wait > 1.0:
			capture("debug/lod_%s_C_shellonly.png" % _tag)
			print("DONE shore=", _shore, " look=", _look)
			get_tree().quit(0)
	if _wait > 240.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


## 找最宽的水湾：沿岸线找一段横向水面最宽的列。
func _setup_vantage() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var best := Vector2i.ZERO
	var best_width := 0
	for cz in range(-400, 401, 8):
		var run := 0
		var run_start := 0
		for cx in range(-600, 601, 4):
			if gen.column_height(cx, cz) <= sea - 2:
				if run == 0:
					run_start = cx
				run += 1
			else:
				if run * 4 > best_width:
					best_width = run * 4
					best = Vector2i(run_start, cz)
				run = 0
		if run * 4 > best_width:
			best_width = run * 4
			best = Vector2i(run_start, cz)
	print("BAY width=", best_width, " start=", best)
	# 站在水湾东岸，向西横看
	var east := best + Vector2i(best_width + 8, 0)
	var h: int = gen.column_height(east.x, east.y)
	var y := float(maxi(h, sea)) + 3.0
	_shore = east
	_look = Vector3(best.x, float(sea), float(best.y))
	if main_ref.player != null:
		main_ref.player.global_position = Vector3(
				east.x + 0.5, y, east.y + 0.5)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 8192.0
	_cam.position = Vector3(east.x + 0.5, y, east.y + 0.5)
	_cam.look_at(_look, Vector3.UP)
	_cam.make_current()
	print("VANTAGE cam=", _cam.position, " shore_h=", h, " sea=", sea)


func capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)
