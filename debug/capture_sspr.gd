## 水面反射验收（镜像投影法）：岸边机位看开阔水面，三档强度 + 关闭
## + 陡俯角帧（复现"低头倒影偏移翻转"回归）。共 6 帧 + 帧时间采样。
## 窗口化：godot --path . res://debug/capture_sspr.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _fps_samples: Array[float] = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "sspr_test")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 12.0 and not main_ref._loading:
			_setup()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 2.5:
			if main_ref.water_reflection.mirror_cam != null:
				var mt: Transform3D = main_ref.water_reflection.mirror_cam.global_transform
				print("MIRROR origin=", mt.origin, " basis=", mt.basis.x,
						" | ", mt.basis.y, " | ", mt.basis.z)
			if main_ref.water_reflection.viewport != null:
				var vp_tex: ViewportTexture = main_ref.water_reflection.viewport.get_texture()
				var rti: Image = vp_tex.get_image()
				var px_sum := 0.0
				var n_px := 0
				for yy in range(0, rti.get_height(), 16):
					for xx in range(0, rti.get_width(), 16):
						px_sum += rti.get_pixel(xx, yy).get_luminance()
						n_px += 1
				print("RT size=", rti.get_size(), " 亮度均值≈",
						px_sum / max(n_px, 1))
				rti.save_png("debug/bsl_v1_rt.png")
				var sky_lum := 0.0
				var mid_lum := 0.0
				var n_sky := 0
				var n_mid := 0
				for yy in range(0, rti.get_height() / 4, 8):
					for xx in range(0, rti.get_width(), 8):
						sky_lum += rti.get_pixel(xx, yy).get_luminance()
						n_sky += 1
				for yy in range(rti.get_height() * 3 / 8,
						rti.get_height() * 5 / 8, 8):
					for xx in range(0, rti.get_width(), 8):
						mid_lum += rti.get_pixel(xx, yy).get_luminance()
						n_mid += 1
				print("RT 天空亮度=", sky_lum / max(n_sky, 1),
						" 中部景物亮度=", mid_lum / max(n_mid, 1))
			capture("debug/bsl_v1_s10.png")
			print("FPS_ON ", _fps_summary())
			_fps_samples.clear()
			_set_strength(2.0)
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 0.8:
			capture("debug/bsl_v1_s20.png")
			_set_strength(3.5)
			_phase = 3
			_wait = 0.0
	elif _phase == 3:
		if _wait > 0.8:
			capture("debug/bsl_v1_s35.png")
			_set_strength(0.0)
			_phase = 4
			_wait = 0.0
	elif _phase == 4:
		if _wait > 1.0:
			capture("debug/bsl_v1_off.png")
			print("FPS_OFF ", _fps_summary())
			_fps_samples.clear()
			_set_strength(0.7)
			# 低头机位：看向机位前下方近处水面（俯角约 -55°），
			# 复现"低头到一定程度倒影偏移翻转"
			var eye := _cam.global_position
			var fwd := -_cam.global_transform.basis.z
			var flat := Vector3(fwd.x, 0.0, fwd.z).normalized()
			_cam.look_at(eye + flat * 3.0 + Vector3(0.0, -4.5, 0.0),
					Vector3.UP)
			_phase = 5
			_wait = 0.0
	elif _phase == 5:
		if _wait > 1.2:
			if main_ref.water_reflection.mirror_cam != null:
				var mt2: Transform3D = main_ref.water_reflection.mirror_cam.global_transform
				var nan_bad := not (mt2.basis.x.is_finite()
						and mt2.basis.y.is_finite()
						and mt2.basis.z.is_finite())
				print("STEEP MIRROR nan=", nan_bad, " basis=", mt2.basis.x,
						" | ", mt2.basis.y, " | ", mt2.basis.z)
				var f3 := -_cam.global_transform.basis.z
				print("主相机 forward=", f3, " 俯角(deg)=",
						rad_to_deg(-asin(clampf(f3.y, -1.0, 1.0))))
			capture("debug/bsl_v1_steep.png")
			print("FPS_STEEP ", _fps_summary())
			_fps_samples.clear()
			_set_strength(0.0)
			_phase = 6
			_wait = 0.0
	elif _phase == 6:
		if _wait > 1.0:
			capture("debug/bsl_v1_steep_off.png")
			get_tree().quit(0)
	if _wait > 45.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _physics_process(_delta: float) -> void:
	if _phase >= 1:
		_fps_samples.append(Engine.get_frames_per_second())


func _setup() -> void:
	# 水点/岸点扫描走公共库（capture_lib）；机位：复现玩家岸边站位，
	# 眼高 1.7 格平视水面（画面下缘带前景地面，检验遮挡剔除）
	var water := CaptureLib.find_water_column(main_ref.generator, 2)
	var shore := CaptureLib.find_shore_from(main_ref.generator, water)
	var eye_y := float(main_ref.generator.column_height(shore.x, shore.y)) + 1.7
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = Vector3(float(shore.x) + 0.5, eye_y, float(shore.y) + 0.5)
	_cam.look_at(Vector3(water.x + 3.0, 6.9, water.y + 3.0), Vector3.UP)
	var surf := WaterFlow.water_surface_at(main_ref.world,
			Vector3i(water.x, TerrainGenerator.SEA_LEVEL, water.y))
	print("SETUP water_at=", water, " shore=", shore, " eye_y=", eye_y,
			" 浮力水面=", surf, " 反射平面=", main_ref.water_reflection.water_h)


func _set_strength(v: float) -> void:
	for mat in [main_ref.chunk_renderer.water_material,
			main_ref.chunk_renderer.water_side_material]:
		if mat != null:
			mat.set_shader_parameter("sspr_strength", v)


func capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)


func _fps_summary() -> String:
	return CaptureLib.fps_summary(_fps_samples)
