## 水在加载边界上的侧壁是否还出面（幕帘 bug 的代码级验证）。
##   godot --headless --path . -s debug/probe_water_edge.gd
extends SceneTree

const ChunkMesherS := preload("res://meshing/chunk_mesher.gd")
const Bridge := preload("res://meshing/native_terrain_bridge.gd")
const MeshBridge := preload("res://meshing/native_mesh_bridge.gd")
const VoxelTypesS := preload("res://core/voxel_types.gd")


func _init() -> void:
	# 4³ 小世界：整块灌水（顶面无空气 -> 顶面不出；四侧才是关键）
	var cfg := WorldConfig.new()
	cfg.chunk_size = 4
	cfg.chunks_y = 3
	cfg.world_seed = 7
	var registry := VoxelTypesS.build_default_registry()
	var world := VoxelWorld.new(cfg, registry)
	var chunk: ChunkData = ChunkData.new(Vector3i.ZERO, Vector3i(4, 4, 4))
	for z in 4:
		for y in 4:
			for x in 4:
				chunk.set_block_raw(Vector3i(x, y, z), VoxelTypesS.WATER_ID)
	world.add_chunk(chunk)

	# 场景 A：邻区块全缺（视距圈外 / 流式加载前沿）
	var none_neigh := world.collect_neighbors(Vector3i.ZERO)
	var cs_a: Dictionary = MeshBridge.build_water(chunk, none_neigh)
	var gd_a: Dictionary = ChunkMesherS._build_gd(registry, chunk, none_neigh)
	print("A 邻域全缺: C# 侧壁顶点=", _side_count(cs_a),
			"  顶/底=", _top_count(cs_a),
			"  | GD 侧壁顶点=", _side_count(gd_a))

	# 场景 B：+X 邻区块已加载（且也是水）—— 该侧本来就不出面；
	# -X 仍缺失，同样不该出面
	var cfg2 := WorldConfig.new()
	cfg2.chunk_size = 4
	cfg2.chunks_y = 3
	var w2 := VoxelWorld.new(cfg2, registry)
	w2.add_chunk(chunk)
	var nb: ChunkData = ChunkData.new(Vector3i(1, 0, 0), Vector3i(4, 4, 4))
	for z in 4:
		for y in 4:
			for x in 4:
				nb.set_block_raw(Vector3i(x, y, z), VoxelTypesS.WATER_ID)
	w2.add_chunk(nb)
	var one_neigh := w2.collect_neighbors(Vector3i.ZERO)
	var cs_b: Dictionary = MeshBridge.build_water(chunk, one_neigh)
	print("B +X 已加载: C# 侧壁顶点=", _side_count(cs_b),
			"  顶/底=", _top_count(cs_b))

	# 场景 C：邻区块存在但该列是空气（真正的岸边）——侧壁必须出面
	var w3 := VoxelWorld.new(cfg2, registry)
	w3.add_chunk(chunk)
	var air_nb: ChunkData = ChunkData.new(Vector3i(1, 0, 0), Vector3i(4, 4, 4))
	w3.add_chunk(air_nb)
	var air_neigh := w3.collect_neighbors(Vector3i.ZERO)
	var cs_c: Dictionary = MeshBridge.build_water(chunk, air_neigh)
	print("C +X 已加载且为空: C# 侧壁顶点=", _side_count(cs_c),
			"（应 >0）")

	var ok: bool = (_side_count(cs_a) == 0 and _side_count(cs_b) == 0
			and _side_count(cs_c) > 0 and _side_count(gd_a) == 0)
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _side_count(d: Dictionary) -> int:
	var a = d.get("water_side_vertices", PackedVector3Array())
	return a.size()


func _top_count(d: Dictionary) -> int:
	var a = d.get("water_vertices", PackedVector3Array())
	return a.size()
