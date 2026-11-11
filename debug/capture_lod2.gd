## 远景壳 LOD 分级着色验收：同屏 5 个 surface 各用不同颜色，定位"灰幕帘"来自哪一级
##   godot --path . res://debug/capture_lod2.tscn
## 颜色：S=4 青 / S=8 绿 / S=16 黄 / S=32 品红 / 水面盘 深蓝
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")
const LEVEL_COLORS := [
	Color(0.15, 0.85, 0.95),  # 0 水面盘
	Color(0.95, 0.25, 0.20),  # 1 S=4
	Color(0.25, 0.95, 0.30),  # 2 S=8
	Color(0.98, 0.90, 0.20),  # 3 S=16
	Color(0.90, 0.25, 0.95),  # 4 S=32
]

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
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
		if _wait > 4.0:
			_cam.make_current()
			_capture("debug/lod2_%s_A_shell.png" % _tag)
			_paint_levels()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 0.6:
			_capture("debug/lod2_%s_B_levels.png" % _tag)
			print("DONE")
			get_tree().quit(0)
	if _wait > 240.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


## 站在海湾东岸的高处，向西横看对岸
func _setup_vantage() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var best := Vector2i.ZERO
	var best_w := 0
	for cz in range(-300, 301, 8):
		var run := 0
		var run_start := 0
		for cx in range(-300, 301, 4):
			var wet: bool = gen.column_height(cx, cz) <= sea - 2
			if wet:
				if run == 0:
					run_start = cx
				run += 1
			else:
				var w := run * 4
				if w >= 80 and w <= 320 and w > best_w:
					best_w = w
					best = Vector2i(run_start, cz)
				run = 0
	if best_w == 0:
		best = Vector2i(0, 0)
		best_w = 120
	print("BAY width=", best_w, " start=", best)
	var east := best + Vector2i(best_w + 8, 0)
	var h: int = gen.column_height(east.x, east.y)
	var y := float(maxi(h, sea)) + 12.0
	if main_ref.player != null:
		main_ref.player.global_position = Vector3(east.x + 0.5, y, east.y + 0.5)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 8192.0
	_cam.position = Vector3(east.x + 0.5, y, east.y + 0.5)
	_cam.look_at(Vector3(best.x, float(sea), float(best.y)), Vector3.UP)
	_cam.make_current()
	print("VANTAGE cam=", _cam.position, " shore_h=", h, " sea=", sea)


func _paint_levels() -> void:
	var shell: Node = main_ref.distant_shell
	if shell == null or shell.get_child_count() == 0:
		return
	var mi = shell.get_child(0)
	if mi.mesh == null:
		return
	for i in range(mini(mi.mesh.get_surface_count(), LEVEL_COLORS.size())):
		var m := StandardMaterial3D.new()
		m.albedo_color = LEVEL_COLORS[i]
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		mi.set_surface_override_material(i, m)
		var arr: Array = mi.mesh.surface_get_arrays(i)
		print("surface ", i, " verts=", (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())


func _capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)
