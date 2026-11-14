## 植物通道 GD/C# 对拍探针：小区块草顶+植物，逐顶点找第一处分歧
extends SceneTree


func _initialize() -> void:
	var registry = VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 42
	var world := VoxelWorld.new(config, registry)
	var chunk := ChunkData.new(Vector3i(0, 0, 0), Vector3i(4, 4, 4), 1)
	# 平铺草地 y=0，一格植物
	for z in 4:
		for x in 4:
			chunk.block_ids[z * 16 + x] = VoxelTypes.GRASS_ID
	chunk.block_ids[1 * 16 + 2 * 4 + 1] = VoxelTypes.TALL_GRASS_ID
	world.add_chunk(chunk)
	# 光照初始化（顶点色需要）
	var light := preload("res://systems/lighting/voxel_light.gd").new()
	light.world = world
	light.init_chunk_light(chunk, [])
	var neighbors: Array = []
	neighbors.resize(27)
	var gd := ChunkMesher.build_mesh_arrays(registry, chunk, neighbors)
	var bridge := preload("res://meshing/native_mesh_bridge.gd")
	var cs: Dictionary = bridge.build(false, registry, chunk, neighbors)
	var gv: PackedVector3Array = gd.get("cross_vertices", PackedVector3Array())
	var cv: PackedVector3Array = cs.get("cross_vertices", PackedVector3Array())
	print("GD verts=", gv.size(), " C# verts=", cv.size())
	var n := mini(gv.size(), cv.size())
	var diffed := false
	for i in n:
		if gv[i] != cv[i]:
			print("FIRST DIFF i=", i, " GD=", gv[i], " C#=", cv[i])
			diffed = true
			break
	if not diffed:
		print("verts all equal (n=", n, ")")
	var gu: PackedVector2Array = gd.get("cross_uvs", PackedVector2Array())
	var cu: PackedVector2Array = cs.get("cross_uvs", PackedVector2Array())
	for i in mini(gu.size(), cu.size()):
		if gu[i] != cu[i]:
			print("UV DIFF i=", i, " GD=", gu[i], " C#=", cu[i])
			break
	quit(0)
