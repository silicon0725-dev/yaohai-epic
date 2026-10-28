## "进洞穴变暗"验收实验：从地表打 1x1 竖井到地下，再水平挖 2x2x14
## 隧道；相机置于隧道口内朝深处看（= 玩家进洞视角）。两帧对比：
## ①cave_open：洞口敞开——近处应亮、深处渐暗
## ②cave_sealed：堵死竖井口——全画面应接近纯黑（验证 ambient 被顶点色
##   压制；若仍亮则环境光泄漏进洞穴，是渲染模型问题）
## 窗口化：godot --path . res://debug/cave_dark_test.tscn
extends Node

const MOUTH := Vector3i(40, 0, 40)  # 竖井口（世界坐标，出生点附近平地）
const SHAFT_DEPTH := 8              # 竖井深（地表到隧道顶）
const TUNNEL_LEN := 14              # 隧道 +X 深
var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _ground := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = load("res://scenes/main.tscn").instantiate()
	main_ref.save_root = "user://saves/cave_dark_test"
	WorldSave.new("user://saves/cave_dark_test", null).erase_all()
	add_child(main_ref)


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 12.0 and not main_ref._loading:
			_setup()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		if _wait > 4.0:
			capture("debug/cavev1_open.png")
			_diag("open")
			_seal()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		if _wait > 4.0:
			capture("debug/cavev1_sealed.png")
			_diag("sealed")
			get_tree().quit(0)
	if _wait > 45.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	_ground = _ground_y(MOUTH.x, MOUTH.z)
	# 竖井 1x1：地表下一格到 SHAFT_DEPTH
	for dy in SHAFT_DEPTH:
		_dig(Vector3i(MOUTH.x, _ground - 1 - dy, MOUTH.z))
	# 隧道 2x2（y = ground-SHAFT_DEPTH .. +1，z = MOUTH.z .. +1）向 +X
	var ty := _ground - SHAFT_DEPTH
	for dx in TUNNEL_LEN:
		for dz in 2:
			for dy in 2:
				_dig(Vector3i(MOUTH.x + 1 + dx, ty + dy, MOUTH.z + dz))
	# 相机放隧道口内，视点贴隧道中线朝 +X 深处（玩家进洞视角）
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = Vector3(MOUTH.x + 1.5, ty + 1.0, MOUTH.z + 1.0)
	_cam.look_at(Vector3(MOUTH.x + TUNNEL_LEN, ty + 0.8, MOUTH.z + 1.0), Vector3.UP)
	print("SETUP ground=", _ground, " tunnel_y=", ty)


func _seal() -> void:
	# 堵竖井口（唯一天光入口）——隧道+竖井成为全封闭腔
	_put(Vector3i(MOUTH.x, _ground - 1, MOUTH.z), VoxelTypes.STONE_ID)
	print("SEALED mouth")


func _dig(p: Vector3i) -> void:
	var b: int = main_ref.world.get_block(p)
	if b != VoxelTypes.AIR_ID and b != VoxelTypes.BEDROCK_ID:
		main_ref.world.set_block(p, VoxelTypes.AIR_ID)


func _put(p: Vector3i, id: int) -> void:
	var ok: bool = main_ref.world.set_block(p, id)
	if not ok:
		print("SET_FAIL ", p)


func _diag(tag: String) -> void:
	# 数据层直查：隧道口/中点/深处三处天光
	var ty := _ground - SHAFT_DEPTH
	for off in [1, 7, TUNNEL_LEN]:
		var p := Vector3i(MOUTH.x + off, ty, MOUTH.z)
		var c: ChunkData = main_ref.world.chunks.get(
				VoxelCoords.world_to_chunk(p, 16))
		var v: int = -1 if c == null else c.get_sky_light(
				VoxelCoords.world_to_local(p, 16))
		print("DIAG ", tag, " x+", off, " sky=", v)


func _ground_y(x: int, z: int) -> int:
	for y in range(96, 3, -1):
		var b: int = main_ref.world.get_block(Vector3i(x, y, z))
		if b != VoxelTypes.AIR_ID and b != VoxelTypes.LEAVES_ID \
				and b != VoxelTypes.BRANCH_ID:
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


func capture(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT ", path)
