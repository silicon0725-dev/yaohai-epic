## 树叶渲染验收：找最近树叶簇，近景拍白天观感（cutout 孔洞/明暗）。
##   godot --path . res://debug/capture_leaves.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _phase := 0
var _wait := 0.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "leaves_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_setup()
				_phase = 1
				_wait = 0.0
		1:
			if _wait > 1.0:
				CaptureLib.shoot(get_viewport(), "debug/leaves_v1_day.png")
				print("DONE")
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	# 扫已加载区块找树叶簇中心
	var found := Vector3i.ZERO
	var best := -1
	for coord in main_ref.world.chunks:
		var chunk: ChunkData = main_ref.world.chunks[coord]
		var s := chunk.dimensions.x
		for i in chunk.volume():
			if chunk.block_ids[i] == VoxelTypes.LEAVES_ID:
				var z := i / (s * s)
				var rem := i - z * s * s
				var y := rem / s
				var x := rem - y * s
				var cell := Vector3i(x, y, z)
				var d: int = 24 - (absi(cell.x - 8) + absi(cell.z - 8))
				if d > best:
					best = d
					found = chunk.chunk_coord * s + cell
	print("LEAVES at ", found)
	if best < 0:
		found = Vector3i(34, 40, 34)  # 兜底：出生点附近
	var center := Vector3(found) + Vector3(0.5, 0.5, 0.5)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.position = center + Vector3(-2.5, 0.8, -2.5)
	cam.look_at(center, Vector3.UP)
	if main_ref.player != null:
		main_ref.player.global_position = cam.position
