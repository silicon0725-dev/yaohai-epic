## 沿陡岸贴水格扫一圈低机位截图：找"远景壳海岸竖墙幕帘"在真机里的样子。
##   SHOT_TAG=xxx godot --path . res://debug/capture_lod_scan.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

## 探针 debug/probe_coast_walls.gd 找到的"全陆格紧邻全水格且 hMax 高"的点
const SPOTS := [
	Vector2i(384, -1056),
	Vector2i(64, -224),
	Vector2i(1504, -1312),
]
const DISTS := [220.0, 400.0]

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _tag := "scan"
var _spot_i := 0
var _dist_i := 0
var _shot := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "lod_scan")
	if OS.get_environment("SHOT_TAG") != "":
		_tag = OS.get_environment("SHOT_TAG")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 3.0 and not main_ref._loading:
			_phase = 1
			_wait = 0.0
			_move_next()
	elif _phase == 1:
		# 等区块 + 壳重建（玩家瞬移后要重载视距圈）
		if _wait > 7.0:
			_aim()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 1.2:
			_capture()
			_phase = 0
			_wait = 0.0
			_move_next()
	if _wait > 300.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _move_next() -> void:
	if _spot_i >= SPOTS.size():
		print("DONE shots=", _shot)
		get_tree().quit(0)
		return
	var spot: Vector2i = SPOTS[_spot_i]
	if main_ref.player != null:
		main_ref.player.global_position = Vector3(
				float(spot.x), float(main_ref.generator.sea_level) + 8.0,
				float(spot.y))
	print("SPOT ", spot, " dist=", DISTS[_dist_i])


## 找一个"朝深水"的方位角当机位，低机位朝岸看
func _aim() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var spot: Vector2i = SPOTS[_spot_i]
	var dist: float = DISTS[_dist_i]
	var best_dir := Vector2(1.0, 0.0)
	var best_h := 9999
	for k in 16:
		var ang := TAU * float(k) / 16.0
		var dir := Vector2(cos(ang), sin(ang))
		var px := int(round(spot.x + dir.x * dist))
		var pz := int(round(spot.y + dir.y * dist))
		var h: int = gen.column_height(px, pz)
		if h < best_h:
			best_h = h
			best_dir = dir
	var cam_pos := Vector3(spot.x + best_dir.x * dist, float(sea) + 12.0,
			spot.y + best_dir.y * dist)
	var top := Vector3(float(spot.x), float(gen.column_height(spot.x, spot.y)) + 6.0,
			float(spot.y))
	if _cam == null:
		_cam = Camera3D.new()
		add_child(_cam)
		_cam.fov = 70.0
		_cam.far = 8192.0
	_cam.position = cam_pos
	_cam.look_at(top, Vector3.UP)
	_cam.make_current()
	print("  cam=", cam_pos, " target=", top, " water_h=", best_h)


func _capture() -> void:
	var path := "debug/scan_%s_%d.png" % [_tag, _shot]
	CaptureLib.shoot(get_viewport(), path)
	print("  SHOT ", path)
	_shot += 1
	_dist_i += 1
	if _dist_i >= DISTS.size():
		_dist_i = 0
		_spot_i += 1
