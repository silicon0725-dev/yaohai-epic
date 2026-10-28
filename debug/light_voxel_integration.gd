## 体素光照渲染级集成验证（光照阶段 2）：固定机位三态对比——
## ①地表基线 ②向下挖 5 格深坑（坑壁/坑底应显著暗于地表，MC 深黑）
## ③封顶（坑内接近全黑）。窗口化运行：
##   godot --path . res://debug/light_voxel_integration.tscn
extends Node

const DIGGER := Vector3i(40, 0, 40)  # 世界坐标（出生点附近平地）
var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = load("res://scenes/main.tscn").instantiate()
	# 隔离存档：保证每次运行同一初始地形（累积挖掘会污染实验；
	# 残留目录先擦除——运行内挖掘会在退出时写盘）
	main_ref.save_root = "user://saves/lightx_test"
	WorldSave.new("user://saves/lightx_test", null).erase_all()
	add_child(main_ref)


func _process(delta: float) -> void:
	_wait += delta
	# 等加载完成 + 流式安定
	if _phase == 0:
		if _wait > 12.0 and not main_ref._loading:
			_setup_camera()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		# 安定两拍后截基线，再挖坑（5 深 × 3×3）
		if _wait > 2.0:
			capture("debug/lightx3_surface.png")
			_dig_hole()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 2.5:
			capture("debug/lightx3_pit.png")
			_seal_top()
			_phase = 3
			_wait = 0.0
	elif _phase == 3:
		if _wait > 2.5:
			capture("debug/lightx3_sealed.png")
			# 数据层直查：封顶后坑内中心格天光（应为 0——减光回收）
			var p := Vector3i(DIGGER.x, _pit_top_y - 4, DIGGER.z)
			var cpos := VoxelCoords.world_to_chunk(p, 16)
			var cchunk = main_ref.world.chunks.get(cpos)
			var clocal := VoxelCoords.world_to_local(p, 16)
			print("DIAG2 sealed sky=", null if cchunk == null else cchunk.get_sky_light(clocal),
					" block_id=", main_ref.world.get_block(p),
					" mesh_dirty=", null if cchunk == null else cchunk.mesh_dirty)
			_phase = 4
			_wait = 0.0
	elif _phase == 4:
		if _wait > 3.5:
			capture("debug/lightx3_sealed2.png")
			get_tree().quit(0)
	if _wait > 45.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup_camera() -> void:
	# 俯视 55° 机位正对挖掘点，坑内可见
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	var ground_y := _ground_y(DIGGER.x, DIGGER.z)
	_cam.position = Vector3(
			DIGGER.x - 6.0, ground_y + 9.0, DIGGER.z + 10.0)
	_cam.look_at(Vector3(DIGGER.x, ground_y - 2.0, DIGGER.z), Vector3.UP)


func _ground_y(x: int, z: int) -> int:
	# 开阔地面：从上向下找第一个非空格且其下 3 格连续非空（跳过
	# 树冠/细枝的悬浮格——树叶团内部有空隙，会误判地面）
	for y in range(96, 3, -1):
		var b: int = main_ref.world.get_block(Vector3i(x, y, z))
		if b != VoxelTypes.AIR_ID and b != VoxelTypes.LEAVES_ID \
				and b != VoxelTypes.BRANCH_ID:
			# 检查其下 3 格连续实心（真地表）
			var solid_below := true
			for k in 3:
				var bk: int = main_ref.world.get_block(
						Vector3i(x, y - 1 - k, z))
				if bk == VoxelTypes.AIR_ID or bk == VoxelTypes.WATER_ID:
					solid_below = false
					break
			if solid_below:
				return y + 1
	return 64


var _pit_top_y := 0  # 挖掘前的地表（封顶用——挖后 _ground_y 已返回坑底）


func _dig_hole() -> void:
	var gy := _ground_y(DIGGER.x, DIGGER.z)
	_pit_top_y = gy
	for dx in 5:
		for dz in 5:
			for dy in 7:
				var pos := Vector3i(
						DIGGER.x - 2 + dx, gy - 1 - dy, DIGGER.z - 2 + dz)
				var b: int = main_ref.world.get_block(pos)
				if b != VoxelTypes.AIR_ID and b != VoxelTypes.BEDROCK_ID:
					main_ref.world.set_block(pos, VoxelTypes.AIR_ID)
	print("DUG at ground_y=", gy)
	# 诊断：挖掘点所在区块的 dirty/状态与 set_block 返回值
	var test_pos := Vector3i(DIGGER.x, gy - 3, DIGGER.z)
	var ok: bool = main_ref.world.set_block(test_pos, VoxelTypes.AIR_ID)
	var cc := VoxelCoords.world_to_chunk(test_pos, 16)
	var cdata = main_ref.world.chunks.get(cc)
	print("DIAG set_ok=", ok, " chunk=", cc,
			" dirty=", null if cdata == null else cdata.mesh_dirty,
			" state=", null if cdata == null else cdata.state)


func _seal_top() -> void:
	# 封在挖掘前地表高度（坑口）
	for dx in 5:
		for dz in 5:
			main_ref.world.set_block(
					Vector3i(DIGGER.x - 2 + dx, _pit_top_y, DIGGER.z - 2 + dz),
					VoxelTypes.STONE_ID)
	print("SEALED")


func capture(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT ", path)
