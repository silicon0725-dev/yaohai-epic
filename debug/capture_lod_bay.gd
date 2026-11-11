## 隔大片水看对岸 LOD 的低机位截图（复现用户"幕帘"视角）。
##   SHOT_TAG=xxx godot --path . res://debug/capture_lod_bay.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

## 岸边点（地图 debug/probe_map.gd 挑的：西北大水体的东岸）
const SHORE := Vector2i(-940, -2300)
const DISTS := [120.0, 300.0]

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _tag := "bay"
var _i := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "lod_bay")
	if OS.get_environment("SHOT_TAG") != "":
		_tag = OS.get_environment("SHOT_TAG")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 3.0 and not main_ref._loading:
			if main_ref.player != null:
				main_ref.player.global_position = Vector3(
						float(SHORE.x), float(main_ref.generator.sea_level) + 8.0,
						float(SHORE.y))
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 12.0:
			_aim()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 1.5:
			_capture()
			_phase = 0
			_wait = 0.0
			_i += 1
			if _i >= DISTS.size():
				print("DONE")
				get_tree().quit(0)
	if _wait > 300.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


## 取"最深水"的方位当朝岸方向：机位放在水面上、朝对岸看
func _aim() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var best_dir := Vector2(-1.0, 0.0)
	var best_h := 9999
	for k in 16:
		var ang := TAU * float(k) / 16.0
		var dir := Vector2(cos(ang), sin(ang))
		var h: int = gen.column_height(
				int(round(SHORE.x + dir.x * 260.0)),
				int(round(SHORE.y + dir.y * 260.0)))
		if h < best_h:
			best_h = h
			best_dir = dir
	var dist: float = DISTS[_i]
	var cam_pos := Vector3(SHORE.x + best_dir.x * dist, float(sea) + 16.0,
			SHORE.y + best_dir.y * dist)
	var far := Vector3(SHORE.x + best_dir.x * 1500.0, float(sea) + 60.0,
			SHORE.y + best_dir.y * 1500.0)
	if _cam == null:
		_cam = Camera3D.new()
		add_child(_cam)
		_cam.fov = 75.0
		_cam.far = 8192.0
	_cam.position = cam_pos
	_cam.look_at(far, Vector3.UP)
	_cam.make_current()
	print("  cam=", cam_pos, " dir=", best_dir, " water_h=", best_h)


func _capture() -> void:
	var path := "debug/bay_%s_%d.png" % [_tag, _i]
	CaptureLib.shoot(get_viewport(), path)
	print("  SHOT ", path)
