## 日夜循环验收：同一露天机位正午 vs 午夜（u_day 天光系数、太阳/
## 月亮、天空/环境插值），并验证午夜火把周域仍暖亮（日夜循环的
## 核心收益——方块光通道不被 u_day 压暗）。窗口化：
##   godot --path . res://debug/capture_daynight.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _eye := Vector3.ZERO
var _look := Vector3.ZERO
var _torch_pos := Vector3i.ZERO


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "daynight_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_setup()
				_phase = 1
				_wait = 0.0
		1:
			# 正午（t=0.25）
			if _wait > 1.5:
				main_ref._time_of_day = 0.25
				_phase = 2
				_wait = 0.0
		2:
			if _wait > 1.0:
				CaptureLib.shoot(get_viewport(), "debug/daynight_v1_noon.png")
				# 午夜 + 身边一支火把
				main_ref._time_of_day = 0.75
				var ok := BlockPlacement.place(main_ref.world, _torch_pos,
						VoxelTypes.TORCH_ID,
						AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
						Vector3i.UP)
				print("TORCH night place=", ok)
				_phase = 3
				_wait = 0.0
		3:
			# 等方块光传播 + 实体生成 + 重网格安定
			if _wait > 2.5 and main_ref.chunk_manager.is_idle():
				CaptureLib.shoot(get_viewport(), "debug/daynight_v1_midnight_torch.png")
				# 无火把对照：拉远机位看整体夜色
				_cam.position = _eye + Vector3(0.0, 6.0, 10.0)
				_cam.look_at(_look, Vector3.UP)
				_phase = 4
				_wait = 0.0
		4:
			if _wait > 1.5:
				CaptureLib.shoot(get_viewport(), "debug/daynight_v1_midnight_far.png")
				# 材质/光照真值：u_day 实际值、shader 路径、火把周域光
				var m: Material = main_ref.chunk_renderer.material
				print("MAT ", m.get_class(), " shader=",
						(m as ShaderMaterial).shader.resource_path,
						" u_day=",
						(m as ShaderMaterial).get_shader_parameter("u_day"))
				var s: int = main_ref.world.config.chunk_size
				var coord := VoxelCoords.world_to_chunk(_torch_pos, s)
				var chunk: ChunkData = main_ref.world.chunks.get(coord)
				var local := VoxelCoords.world_to_local(_torch_pos, s)
				print("TORCHLIGHT torch=", chunk.get_block_light(local),
						" below=", chunk.get_block_light(
								local + Vector3i(0, -1, 0)))
				print("DONE t=", main_ref._time_of_day)
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	var shore := CaptureLib.find_shore_from(main_ref.generator,
			CaptureLib.find_water_column(main_ref.generator, 2))
	var gx := shore.x + 5
	var gz := shore.y + 5
	var gy: int = main_ref.generator.column_height(gx, gz) + 1
	_eye = Vector3(gx - 1.8, gy + 1.3, gz - 1.8)
	_look = Vector3(gx + 0.5, gy + 0.1, gz + 0.5)
	# 火把位：向上找空气格（岸边斜坡 column_height+1 未必是空气）
	_torch_pos = Vector3i(gx + 2, gy, gz)
	var world: VoxelWorld = main_ref.world
	while _torch_pos.y < gy + 6 and world.get_block(_torch_pos) != VoxelTypes.AIR_ID:
		_torch_pos.y += 1
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = _eye
	_cam.look_at(_look, Vector3.UP)
	if main_ref.player != null:
		main_ref.player.global_position = _eye
