## 只看远景壳：直接调 C# 造壳网格 + 高度调试材质 + 指定机位截图，
## 不加载世界（秒级）。用于对比"海岸是不是竖墙幕帘"。
##   godot --path . res://debug/shell_only_view.tscn
extends Node

const Bridge := preload("res://meshing/native_terrain_bridge.gd")
const DebugShader := preload("res://debug/shell_height_debug.gdshader")
const RealShader := preload("res://presentation/distant_shell.gdshader")

var _shots: Array = []
var _cam: Camera3D
var _idx := 0
var _stage := 0
var _wait := 0.0
var _tag := "v1"


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	if OS.get_environment("SHOT_TAG") != "":
		_tag = OS.get_environment("SHOT_TAG")
	var sea := 64
	var center := Vector2i(90, -234)
	Bridge.prewarm(1337, 512)
	var native = Bridge.get_native(1337, 512)
	var mesh: Mesh = native.GenerateShellMesh(center.x, center.y)
	# SURF=N：只保留第 N 个 surface（0=水面圆盘，1..4=S 级环带），
	# 用来隔离"放射状楔形扇到底是圆盘还是环带"
	var only := OS.get_environment("SURF")
	if only != "":
		var si := int(only)
		var arr: Array = mesh.surface_get_arrays(si)
		var a2: Array = []
		a2.resize(Mesh.ARRAY_MAX)
		a2[Mesh.ARRAY_VERTEX] = arr[Mesh.ARRAY_VERTEX]
		a2[Mesh.ARRAY_NORMAL] = arr[Mesh.ARRAY_NORMAL]
		a2[Mesh.ARRAY_COLOR] = arr[Mesh.ARRAY_COLOR]
		a2[Mesh.ARRAY_INDEX] = arr[Mesh.ARRAY_INDEX]
		var one := ArrayMesh.new()
		one.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)
		mesh = one
		print("ONLY surface ", si, " verts=",
				(arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	# USE_REAL=1 用真机 shader（灰板幕帘的真实颜色），2=纯色 unshaded
	# 材质（判断"放射扇"是否来自 shader/法线），否则用高度调试色
	if OS.get_environment("USE_REAL") == "3":
		mat.shader = preload("res://debug/const_unshaded.gdshader")
	elif OS.get_environment("USE_REAL") == "2":
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.albedo_color = Color(0.32, 0.40, 0.50)
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = sm
	elif OS.get_environment("USE_REAL") == "1":
		mat.shader = RealShader
		mat.set_shader_parameter("u_day", 1.0)
		mat.set_shader_parameter("u_sun_dir", Vector3(0.42, 0.78, 0.32))
	else:
		mat.shader = DebugShader
		mat.set_shader_parameter("sea_level", float(sea))
	if mat.shader != null:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# 海平面大平板（sea-3，远低于壳水面圆盘 sea-0.3 —— 曾与圆盘同高，
	# 两者共面 z-fighting 正好生成"以屏幕下方一点为心的放射楔形扇"，
	# 害我以为圆盘自己有放射伪影）。SURF 隔离模式下不加。
	if only == "":
		var water := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(9000.0, 9000.0)
		water.mesh = pm
		var wmat := StandardMaterial3D.new()
		wmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		wmat.albedo_color = Color(0.32, 0.40, 0.50)
		wmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		water.material_override = wmat
		water.position = Vector3(0.0, float(sea) - 3.0, 0.0)
		water.layers = 1 | (1 << 2)
		add_child(water)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.45, 0.62, 0.85)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	e.fog_enabled = false
	env.environment = e
	add_child(env)

	# 用户截图是"隔着一大片水(1000-2500 格)看对岸"——那里正是壳的
	# S=16/S=32 环带（原始 vs=S/2 → 8/16 格竖阶 = 灰板幕帘）
	var look := Vector3(90.0, 40.0, -234.0)
	_shots = [
		[Vector3(-900.0, 104.0, -234.0), look],
		[Vector3(-1500.0, 104.0, -234.0), look],
		[Vector3(-2200.0, 104.0, -234.0), look],
		[Vector3(-3000.0, 104.0, -234.0), look],
	]
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 70.0
	_cam.far = 16384.0
	print("MESH surfs=", mesh.get_surface_count(), " aabb=", mi.get_aabb())


func _process(delta: float) -> void:
	_wait += delta
	if _wait < 0.8:
		return
	_wait = 0.0
	if _stage == 0:
		if _idx >= _shots.size():
			print("DONE")
			get_tree().quit(0)
			return
		_cam.position = _shots[_idx][0]
		_cam.look_at(_shots[_idx][1], Vector3.UP)
		_cam.make_current()
		_stage = 1
	else:
		var path := "debug/shellonly_%s_%d.png" % [_tag, _idx]
		get_viewport().get_texture().get_image().save_png(path)
		print("SHOT ", path, " cam=", _cam.global_position)
		_idx += 1
		_stage = 0
