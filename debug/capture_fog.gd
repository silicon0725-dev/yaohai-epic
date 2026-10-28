## 洞口光束验收：挖"天窗洞"（1x1 竖井 + 5x5x3 洞室），相机在洞内
## 朝开口方向，开/关体积雾 A/B + FPS。窗口化：
##   godot --path . res://debug/capture_fog.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _fps: Array[float] = []
var _mouth := Vector3i.ZERO
var _surf := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "fog_test")


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 12.0 and not main_ref._loading:
			_dig_cave()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 2.5:  # 等重网格 + 检测器重扫（0.5s 节流）
			_setup_cam()
			main_ref.cave_fog._dirty = true
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 2.0:  # 等时间重投影历史收敛（0.9 权重需几帧）
			capture("debug/fog_v6_on.png")
			print("FPS_ON ", _fps_summary())
			_fps.clear()
			main_ref._environment.volumetric_fog_enabled = false
			for v in main_ref.cave_fog._volumes:
				v.visible = false
			_phase = 3
			_wait = 0.0
	elif _phase == 3:
		if _wait > 1.0:
			capture("debug/fog_v6_off.png")
			# 确定性暗室：洞口旁挖 10 深竖井并封顶（天光 BFS 归零）
			var world: VoxelWorld = main_ref.world
			var shaft := _mouth + Vector3i(2, 0, 2)
			for y in range(_surf - 12, _surf + 1):
				world.set_block(Vector3i(shaft.x, y, shaft.z), VoxelTypes.AIR_ID)
			# 井底横向 2 格容身
			world.set_block(shaft + Vector3i(1, -12, 0), VoxelTypes.AIR_ID)
			world.set_block(shaft + Vector3i(2, -12, 0), VoxelTypes.AIR_ID)
			# 封顶（留 2 格岩层，天光不直射）
			for y in range(_surf + 1, _surf + 3):
				world.set_block(Vector3i(shaft.x, y, shaft.z), VoxelTypes.STONE_ID)
			if main_ref.player != null:
				main_ref.player.global_position = Vector3(
						shaft.x + 1.5, _surf - 11.5, shaft.z + 0.5)
			_cam.position = main_ref.player.global_position
			_cam.look_at(_cam.position + Vector3(1.0, -0.3, 0.0), Vector3.UP)
			_phase = 4
			_wait = 0.0
	elif _phase == 4:
		if _wait > 2.5:
			var wc: VoxelWorld = main_ref.world
			var pcell := Vector3i(
					floori(main_ref.player.global_position.x),
					floori(main_ref.player.global_position.y),
					floori(main_ref.player.global_position.z))
			var wchunk: ChunkData = wc.chunks.get(VoxelCoords.world_to_chunk(
					pcell, main_ref.config.chunk_size))
			print("洞内光照 sky=", wchunk.get_sky_light(VoxelCoords.world_to_local(
					pcell, main_ref.config.chunk_size)),
					" 适应后 exposure=", main_ref._exposure)
			capture("debug/fog_v6_adapt.png")
			# 关适应对照（MAX_LIFT=1.0 即恒定曝光 1.0）
			main_ref.EXPOSURE_MAX_LIFT = 1.0
			main_ref._exposure = 1.0
			main_ref._environment.tonemap_exposure = 1.0
			_phase = 5
			_wait = 0.0
	elif _phase == 5:
		if _wait > 1.0:
			capture("debug/fog_v6_adapt_off.png")
			# 洞内看光束（复现玩家视角）：隧道中段朝洞口逆光、玩家同位
			# （眼适应生效）——能量补偿后的观感验收帧
			main_ref.EXPOSURE_MAX_LIFT = 2.2
			var into2 := Vector3(-0.707, 0.0, 0.707)
			var vol0: FogVolume = main_ref.cave_fog._volumes[0]
			_cam.position = vol0.position + into2 * 5.0 + Vector3(0, -1.0, 0)
			_cam.look_at(vol0.position + Vector3(0, 1.0, 0), Vector3.UP)
			if main_ref.player != null:
				main_ref.player.global_position = _cam.position
			_phase = 6
			_wait = 0.0
	elif _phase == 6:
		if _wait > 2.5:
			print("洞内逆光 exposure=", main_ref._exposure)
			capture("debug/fog_v6_beam_inside.png")
			print("FPS_OFF ", _fps_summary())
			get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _physics_process(_delta: float) -> void:
	if _phase >= 2:
		_fps.append(Engine.get_frames_per_second())


func _dig_cave() -> void:
	# 找高山体列（保证隧道全程在山体内、洞口向阳）
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
	# 水平隧道沿太阳传播方向（-x,+z 对角）凿进山体：3x3 截面、长 10。
	# 太阳 55° 仰角直接灌进洞口——竖直天窗的光全打井壁（v1 失败教训）
	var cy := surf - 3
	var axis := Vector3i(-1, 0, 1)  # 太阳传播方向（对角整数步）
	var perp := Vector3i(1, 0, 1)   # 截面横向
	var mouth := Vector3i(col.x, cy, col.y)
	for i in 11:
		var c := mouth + axis * i
		for w in range(-1, 2):
			for y in range(-1, 2):
				world.set_block(c + perp * w + Vector3i(0, y, 0),
						VoxelTypes.AIR_ID)
	_mouth = mouth
	_surf = surf
	print("DIG col=", col, " surf=", surf, " 隧道口=", mouth,
			" 轴=", axis, " y=", cy)


func _setup_cam() -> void:
	# 相机在洞口外（向阳侧）逆光看隧道内部——光束在洞内雾上成形
	var cf: Node = main_ref.cave_fog
	var n: int = cf.active_count()
	print("CAVEFOG volumes=", n)
	var center_l := Vector3.ZERO
	if n > 0:
		var v0: FogVolume = cf._volumes[0]
		center_l = v0.position
		print("  v0 center=", v0.position, " size=", v0.size)
		_cam = Camera3D.new()
		add_child(_cam)
		_cam.make_current()
		# 洞口外 6 格、略高于隧道轴，看向隧道深处
		var into := Vector3(-0.707, 0.0, 0.707)
		_cam.position = center_l - into * 6.0 + Vector3(0.0, 1.5, 0.0)
		_cam.look_at(center_l + into * 4.0, Vector3.UP)
	else:
		print("  未检测到洞口簇——检测失败")
		get_tree().quit(1)
	# 玩家挪到洞口附近让检测器保持这块区域活跃
	if main_ref.player != null:
		main_ref.player.global_position = center_l + Vector3(0, 4.0, 0)


func capture(path: String) -> void:
	CaptureLib.shoot(get_viewport(), path)


func _fps_summary() -> String:
	return CaptureLib.fps_summary(_fps)
