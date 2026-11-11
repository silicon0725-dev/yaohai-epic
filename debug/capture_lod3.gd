## 远景壳/水 LOD 近景四联诊断（同一机位）：
##   A 原始            B 隐藏远景壳     C 壳高度调试色    D 壳+区块水都隐藏
##   godot --path . res://debug/capture_lod3.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")
const DebugShader := preload("res://debug/shell_height_debug.gdshader")

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
	elif _phase >= 1 and _phase <= 4:
		if _wait > (4.0 if _phase == 1 else 1.0):
			_do_phase(_phase)
			_phase += 1
			_wait = 0.0
	elif _phase == 5:
		print("DONE")
		get_tree().quit(0)
	if _wait > 240.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _do_phase(p: int) -> void:
	var shell_mi: Node = _shell_mi()
	match p:
		1:
			_cam.make_current()
			_capture("debug/lod3_%s_A_raw.png" % _tag)
			print("player=", main_ref.player.global_position,
					" shell_center=", main_ref.distant_shell._center)
		2:
			if shell_mi != null:
				shell_mi.visible = false
			_capture("debug/lod3_%s_B_noshell.png" % _tag)
		3:
			if shell_mi != null:
				shell_mi.visible = true
				var m := ShaderMaterial.new()
				m.shader = DebugShader
				m.set_shader_parameter("sea_level",
						float(main_ref.generator.sea_level))
				shell_mi.material_override = m
			_capture("debug/lod3_%s_C_height.png" % _tag)
		4:
			if shell_mi != null:
				shell_mi.visible = false
			_hide_chunk_water()
			_capture("debug/lod3_%s_D_nowater.png" % _tag)
		_:
			pass


func _shell_mi() -> Node:
	var shell: Node = main_ref.distant_shell
	if shell == null or shell.get_child_count() == 0:
		return null
	return shell.get_child(0)


## 区块水是 RenderingServer 直接建的 instance（不是子节点），
## 只能按 entry 里的 water_inst 关显示。
func _hide_chunk_water() -> void:
	var cr = main_ref.chunk_renderer
	var entries: Dictionary = cr._entries
	var n := 0
	for key in entries:
		var e: Dictionary = entries[key]
		if e.has("water_inst"):
			RenderingServer.instance_set_visible(e.water_inst, false)
			n += 1
	print("HID water instances=", n)


func _setup_vantage() -> void:
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var shore := Vector2i.ZERO
	var found := false
	for cz in range(-300, 301, 6):
		for cx in range(-300, 301, 6):
			var h: int = gen.column_height(cx, cz)
			if h <= sea + 3 or h >= sea + 40:
				continue
			if gen.column_height(cx - 40, cz) <= sea - 4:
				shore = Vector2i(cx, cz)
				found = true
				break
		if found:
			break
	print("SHORE=", shore)
	var target_y := float(gen.column_height(shore.x, shore.y))
	var cam_pos := Vector3(shore.x - 120.0, float(sea) + 18.0,
			shore.y + 60.0)
	if main_ref.player != null:
		main_ref.player.global_position = Vector3(
				shore.x - 40.0, float(sea) + 6.0, shore.y)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 75.0
	_cam.far = 8192.0
	_cam.position = cam_pos
	_cam.look_at(Vector3(shore.x - 20.0, target_y + 10.0, shore.y), Vector3.UP)
	_cam.make_current()
	print("VANTAGE cam=", cam_pos, " target=", shore, " h=", target_y)


func _capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)
