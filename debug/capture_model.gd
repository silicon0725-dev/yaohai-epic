## MC/Blockbench 模型加载实机演示：从 Pastoral 材质包加载提灯与
## 紫水晶簇的 3D 盒件模型（elements JSON），在露天场景旁实体渲染，
## 与火把同框对比。窗口化：
##   godot --path . res://debug/capture_model.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")
const McModelLoader := preload("res://presentation/mc_model_loader.gd")

## Pastoral 包 assets/minecraft 目录（外部路径——包不入库，许可隔离）
const PACK_DIR := "F:/pastoral_inspect/pack/assets/minecraft"

var main_ref: Node
var _cam: Camera3D
var _phase := 0
var _wait := 0.0
var _base := Vector3.ZERO


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "model_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_setup()
				_phase = 1
				_wait = 0.0
		1:
			if _wait > 1.5:
				CaptureLib.shoot(get_viewport(), "debug/model_v1_a.png")
				_cam.position = _base + Vector3(2.2, 1.4, 2.2)
				_cam.look_at(_base + Vector3(0.5, 0.3, 0.5), Vector3.UP)
				_phase = 2
				_wait = 0.0
		2:
			if _wait > 0.8:
				CaptureLib.shoot(get_viewport(), "debug/model_v1_b.png")
				print("DONE ents ok")
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	var shore := CaptureLib.find_shore_from(main_ref.generator,
			CaptureLib.find_water_column(main_ref.generator, 2))
	var col_h: int = main_ref.generator.column_height(shore.x + 4, shore.y + 4)
	_base = Vector3(shore.x + 4, col_h + 1, shore.y + 4)
	# 三个实体：包模型提灯 / 包模型紫水晶簇 / 火把（对照）
	for spec in [
		["models/block/lantern.json", Vector3i(0, 0, 0)],
		["models/block/amethyst_cluster.json", Vector3i(0, 0, 2)],
	]:
		var mesh: ArrayMesh = McModelLoader.build_mesh(PACK_DIR, spec[0])
		if mesh == null:
			print("MODEL FAIL ", spec[0])
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = _base + Vector3(spec[1])
		add_child(mi)
		var mat: StandardMaterial3D = mesh.surface_get_material(0)
		print("MODEL OK ", spec[0], " surfaces=", mesh.get_surface_count(),
				" aabb=", mesh.get_aabb(),
				" albedo=", mat.albedo_texture != null
						and mat.albedo_texture.get_width() > 0,
				" transparency=", mat.transparency)
	var ok := BlockPlacement.place(main_ref.world, Vector3i(_base) + Vector3i(4, 0, 0),
			VoxelTypes.TORCH_ID, AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
			Vector3i.UP)
	print("TORCH place=", ok)
	if main_ref.player != null:
		main_ref.player.global_position = _base + Vector3(-1.6, 1.2, -1.6)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = _base + Vector3(-1.2, 1.2, -1.2)
	_cam.look_at(_base + Vector3(0.5, 0.2, 1.0), Vector3.UP)
