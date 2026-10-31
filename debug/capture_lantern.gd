## 提灯实机验收：暗室挖洞 -> BlockPlacement 落地放置（玩家同链路）
## -> 实体出现（Pastoral 模型或程序化回退）+ 方块光 15 照亮房间。
## 窗口化：godot --path . res://debug/capture_lantern.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _fps: Array[float] = []
var _lantern_pos := Vector3i.ZERO
var _outdoor_pos := Vector3i.ZERO


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "lantern_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_dig_room()
				_phase = 1
				_wait = 0.0
		1:
			# 等重网格 + 光照全部安定（黑暗基准帧——is_idle 消除时序歧义）
			if _wait > 2.5 and main_ref.chunk_manager.is_idle():
				_setup_cam()
				CaptureLib.shoot(get_viewport(), "debug/lantern_v1_dark.png")
				_phase = 2
				_wait = 0.0
		2:
			if _wait > 0.3:
				var ok := BlockPlacement.place(main_ref.world, _lantern_pos,
						VoxelTypes.LANTERN_ID,
						AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
						Vector3i.UP)
				print("LANTERN place=", ok)
				_phase = 3
				_wait = 0.0
		3:
			if _wait > 2.0 and main_ref.chunk_manager.is_idle():
				# 等延迟实体 + 方块光传播 + 重网格安定（一次性，立即推进）
				_phase = 4
				print("LANTERN ents=", main_ref.lantern_renderer.count())
				# 光照真值：本格/邻格的方块光
				var world: VoxelWorld = main_ref.world
				var s: int = world.config.chunk_size
				for p in [_lantern_pos, _lantern_pos + Vector3i(0, 1, 0),
						_lantern_pos + Vector3i(1, 0, 0)]:
					var coord := VoxelCoords.world_to_chunk(p, s)
					var chunk: ChunkData = world.chunks.get(coord)
					if chunk == null:
						print("LIGHT ", p, " chunk null")
						continue
					var local := VoxelCoords.world_to_local(p, s)
					print("LIGHT ", p, " block=",
							chunk.get_block_light(local), " sky=",
							chunk.get_sky_light(local))
				CaptureLib.shoot(get_viewport(), "debug/lantern_v1_lit.png")
				_phase = 4
				_wait = 0.0
		4:
			# 户外直射阳光相位：岸点放第二支提灯，验证日光下不发白
			if _wait > 0.5:
				var shore := CaptureLib.find_shore_from(main_ref.generator,
						CaptureLib.find_water_column(main_ref.generator, 2))
				_outdoor_pos = Vector3i(shore.x + 3,
						main_ref.generator.column_height(shore.x + 3,
						shore.y + 3) + 1, shore.y + 3)
				var ok := BlockPlacement.place(main_ref.world, _outdoor_pos,
						VoxelTypes.LANTERN_ID,
						AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
						Vector3i.UP)
				print("OUTDOOR place=", ok)
				_cam.position = Vector3(_outdoor_pos) + Vector3(-1.6, 1.2, -1.6)
				_cam.look_at(Vector3(_outdoor_pos) + Vector3(0.5, 0.3, 0.5),
						Vector3.UP)
				_phase = 5
				_wait = 0.0
		5:
			if _wait > 1.5:
				# 部位精确投影：模型局部点（1/16 格）→ 屏幕坐标
				var base := Vector3(_outdoor_pos) + Vector3(0.5, 0.0, 0.5)
				var parts := [
						["cap_top", Vector3(0.0, 0.625, 0.0)],
						["body_mid", Vector3(0.0, 0.3125, 0.0)],
						["base", Vector3(0.0, 0.0625, 0.0)],
						["handle", Vector3(0.0, 0.8125, 0.0)]]
				for part in parts:
					print("PT %s %s" % [part[0],
							_cam.unproject_position(base + part[1])])
				CaptureLib.shoot(get_viewport(), "debug/lantern_v1_sun.png")
				print("FPS ", CaptureLib.fps_summary(_fps))
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _physics_process(_delta: float) -> void:
	if _phase >= 2:
		_fps.append(Engine.get_frames_per_second())


## 复刻 capture_torch 的暗室：地表下 7 格挖 7x7x4 房间
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
	_lantern_pos = Vector3i(col.x, floor_y, col.y)
	print("DIG col=", col, " floor=", floor_y)


func _setup_cam() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = Vector3(_lantern_pos) + Vector3(-2.2, 1.4, -2.2)
	_cam.look_at(Vector3(_lantern_pos) + Vector3(0.5, 0.3, 0.5), Vector3.UP)
	if main_ref.player != null:
		main_ref.player.global_position = _cam.position
