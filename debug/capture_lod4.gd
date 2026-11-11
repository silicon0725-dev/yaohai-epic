## LOD 海岸幕帘复现/验收：站在近岸水边低机位，隔着 300-1200 格宽
## 的水面看对岸（对岸必然由远景壳绘制）。
##   godot --path . res://debug/capture_lod4.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")
const LOG_PATH := "user://lod4_progress.txt"

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _tag := "v1"
var _shore := Vector2i.ZERO
var _far := Vector2i.ZERO


func _log(msg: String) -> void:
	print(msg)
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f != null:
		f.store_line("%.1f %s" % [Time.get_ticks_msec() / 1000.0, msg])
		f.close()


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	_log("boot")
	main_ref = CaptureLib.boot_isolated(self, "lod_probe")
	if OS.get_environment("SHOT_TAG") != "":
		_tag = OS.get_environment("SHOT_TAG")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 3.0 and not main_ref._loading:
			_log("loading done, scan...")
			_setup_vantage()
			_log("scan done")
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 6.0:
			_cam.make_current()
			_log("capture A")
			_capture("debug/lod4_%s_A_raw.png" % _tag)
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 1.0:
			var mi := _shell_mi()
			if mi != null:
				mi.visible = false
			_log("capture B")
			_capture("debug/lod4_%s_B_noshell.png" % _tag)
			_phase = 3
			_wait = 0.0
	elif _phase == 3:
		if _wait > 1.0:
			_log("DONE")
			get_tree().quit(0)
	if _wait > 300.0:
		_log("TIMEOUT phase=%d" % _phase)
		get_tree().quit(1)


func _shell_mi() -> Node:
	var shell: Node = main_ref.distant_shell
	if shell == null or shell.get_child_count() == 0:
		return null
	return shell.get_child(0)


## 找一条 300-1200 格宽的水道：从水列出发沿 -X 走到对岸，记录近岸/对岸。
func _setup_vantage() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var best_w := 0
	var best := Vector2i.ZERO
	var best_far := Vector2i.ZERO
	for cz in range(-640, 641, 32):
		var run := 0
		for cx in range(704, -705, -8):
			var h: int = gen.column_height(cx, cz)
			if h <= sea - 3:
				run += 8
			else:
				if run > best_w and run >= 300 and run <= 1200:
					best_w = run
					best = Vector2i(cx + run, cz)
					best_far = Vector2i(cx, cz)
				run = 0
	_log("WATERWAY width=%d near=%s far=%s" % [best_w, best, best_far])
	_shore = best
	_far = best_far
	if best_w <= 0:
		_log("NO WATERWAY")
		get_tree().quit(2)
		return
	var near_h: int = max(gen.column_height(_shore.x, _shore.y), sea + 1)
	var eye := Vector3(float(_shore.x) + 6.0, float(near_h) + 3.0,
			float(_shore.y))
	var far_y := float(sea) + 20.0
	if main_ref.player != null:
		main_ref.player.global_position = Vector3(
				float(_shore.x) + 8.0, float(max(near_h, sea + 1)) + 1.0,
				float(_shore.y))
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 8192.0
	_cam.position = eye
	_cam.look_at(Vector3(float(_far.x), far_y, float(_far.y)), Vector3.UP)
	_cam.make_current()
	_log("VANTAGE eye=%s far=%s near_h=%d sea=%d" % [eye, _far, near_h, sea])


func _capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)
