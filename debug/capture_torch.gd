## 火把验收（实体渲染管线）：洞室端到端放置（相机射线->raycast->
## BlockPlacement）+ 掉落物 + 露天地面放置。窗口化：
##   godot --path . res://debug/capture_torch.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _fps: Array[float] = []
var _room_center := Vector3.ZERO
var _torch_pos: Array[Vector3i] = []
var _e2e_done := false
var _outdoor_pos := Vector3i.ZERO
var _outdoor_eye := Vector3.ZERO


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "torch_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_dig_room()
				_phase = 1
				_wait = 0.0
		1:
			if _wait > 2.5:  # 等重网格 + 光照稳定
				_setup_cam()
				_phase = 2
				_wait = 0.0
		2:
			if not _e2e_done:
				_e2e_done = true
				_place_indoor_via_raycast()
			if _wait > 2.0:  # 等延迟生成 + 曝光适应
				print("TORCH_ENTS indoor=", main_ref.torch_renderer.count())
				CaptureLib.shoot(get_viewport(), "debug/torch_v12_on.png")
				var fwd := -_cam.global_transform.basis.z
				main_ref.drop_manager.spawn_drop(main_ref.registry.id_for_name(
						"core:torch"), 1, _cam.position + fwd * 2.0
						+ Vector3(0, -0.3, 0), Vector3.ZERO)
				_phase = 3
				_wait = 0.0
		3:
			if _wait > 1.5:
				CaptureLib.shoot(get_viewport(), "debug/torch_v12_drop.png")
				print("FPS_ON ", CaptureLib.fps_summary(_fps))
				_fps.clear()
				_setup_outdoor()
				_phase = 4
				_wait = 0.0
		4:
			if _wait > 1.2:
				var ook := BlockPlacement.place(main_ref.world, _outdoor_pos,
						VoxelTypes.TORCH_ID,
						AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
						Vector3i.UP)
				print("OUTDOOR place=", ook, " ents=",
						main_ref.torch_renderer.count())
				_cam.position = _outdoor_eye
				_cam.look_at(Vector3(_outdoor_pos) + Vector3(0.5, 0.4, 0.5),
						Vector3.UP)
				_phase = 5
				_wait = 0.0
		5:
			if _wait > 1.5:
				CaptureLib.shoot(get_viewport(), "debug/torch_v12_outdoor.png")
				# 绕到火把另一侧近景（曾 -x 面角点笔误退化成斜缝三角）
				_cam.position = Vector3(_outdoor_pos.x - 0.9,
						float(_outdoor_pos.y) + 0.55, _outdoor_pos.z - 0.9)
				_cam.look_at(Vector3(_outdoor_pos) + Vector3(0.5, 0.35, 0.5),
						Vector3.UP)
				# 火焰中心/炭头投影坐标（PIL 精确裁剪用）
				var base := Vector3(_outdoor_pos) + Vector3(0.5, 0.0, 0.5)
				print("UNPROJECT flame=",
						_cam.unproject_position(base + Vector3(0.0, 0.78, 0.0)),
						" head=",
						_cam.unproject_position(base + Vector3(0.0, 0.66, 0.0)))
				_phase = 6
				_wait = 0.0
		6:
			if _wait > 1.0:
				CaptureLib.shoot(get_viewport(), "debug/torch_v12_close.png")
				print("FPS_OFF ", CaptureLib.fps_summary(_fps))
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _physics_process(_delta: float) -> void:
	if _phase >= 2:
		_fps.append(Engine.get_frames_per_second())


func _dig_room() -> void:
	var col := Vector2i(34, 34)
	var best_h := 0
	for r in range(3, 30):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := int(34 + cos(ang) * r * 6.0)
			var cz := int(34 + sin(ang) * r * 6.0)
			var h: int = main_ref.generator.column_height(cx, cz)
			if h > best_h:
				best_h = h
				col = Vector2i(cx, cz)
		if best_h > TerrainGenerator.SEA_LEVEL + 10:
			break
	var world: VoxelWorld = main_ref.world
	var surf := 0
	for y in range(world.config.world_height_blocks() - 1, -1, -1):
		if main_ref.registry.is_solid(world.get_block(Vector3i(col.x, y, col.y))):
			surf = y
			break
	var floor_y := surf - 7
	for wx in range(col.x - 3, col.x + 4):
		for wz in range(col.y - 3, col.y + 4):
			for wy in range(floor_y, floor_y + 4):
				world.set_block(Vector3i(wx, wy, wz), VoxelTypes.AIR_ID)
	_room_center = Vector3(col.x + 0.5, floor_y + 1.5, col.y + 0.5)
	# 落地位（floor_y：下方 floor_y-1 是实体山体）
	_torch_pos = [
		Vector3i(col.x - 2, floor_y, col.y - 2),
		Vector3i(col.x + 2, floor_y, col.y + 2),
	]
	print("DIG col=", col, " surf=", surf, " floor=", floor_y)


func _setup_cam() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = _room_center + Vector3(-2.2, 0.4, -2.2)
	_cam.look_at(_room_center + Vector3(1.6, -0.4, 1.6), Vector3.UP)
	if main_ref.player != null:
		main_ref.player.global_position = _cam.position


## 端到端复刻玩家链路（_try_place 同款）：相机射线 -> 射线检测 ->
## 放置。落地两支
func _place_indoor_via_raycast() -> void:
	var placed := 0
	for tp in _torch_pos:
		_cam.look_at(Vector3(tp) + Vector3(0.5, 0.3, 0.5), Vector3.UP)
		var hit: Dictionary = VoxelRaycast.raycast(main_ref.world,
				_cam.global_position, -_cam.global_transform.basis.z, 8.0)
		if not hit.hit:
			print("RAYCAST MISS ", tp)
			continue
		var ok := BlockPlacement.place(main_ref.world,
				hit.block_pos + hit.normal, VoxelTypes.TORCH_ID,
				AABB(Vector3(1000, 1000, 1000), Vector3.ONE), hit.normal)
		print("PLACE ", tp, " ok=", ok)
		if ok:
			placed += 1
	print("PLACED ", placed, "/", _torch_pos.size())
	_cam.position = _room_center + Vector3(-2.2, 0.4, -2.2)
	_cam.look_at(_room_center + Vector3(1.6, -0.4, 1.6), Vector3.UP)


## 露天机位：岸点陆地上一支（用户主场景）
func _setup_outdoor() -> void:
	var shore := CaptureLib.find_shore_from(main_ref.generator,
			CaptureLib.find_water_column(main_ref.generator, 2))
	_outdoor_pos = Vector3i(shore.x + 2,
			main_ref.generator.column_height(shore.x + 2, shore.y + 2) + 1,
			shore.y + 2)
	var gy := float(_outdoor_pos.y)
	_outdoor_eye = Vector3(_outdoor_pos.x + 1.6, gy + 1.2,
			_outdoor_pos.z + 1.6)
	if main_ref.player != null:
		main_ref.player.global_position = _outdoor_eye
