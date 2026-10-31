extends SceneTree
const NativeMeshBridge := preload("res://meshing/native_mesh_bridge.gd")
func _initialize():
	await process_frame
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.chunks_y = 1
	config.chunk_size = 4
	var world := VoxelWorld.new(config, registry)
	world.add_chunk(ChunkData.new(Vector3i.ZERO, Vector3i(4, 4, 4), 2))
	world.set_block(Vector3i(0, 1, 0), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(0, 2, 0), VoxelTypes.TORCH_ID)
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(2, 2, 2), VoxelTypes.TORCH_ID)
	world.set_block(Vector3i(3, 1, 1), VoxelTypes.TORCH_ID)
	var light: Node = load("res://systems/lighting/voxel_light.gd").new()
	light.setup(world)
	var six := []
	for d in [Vector3i(1,0,0),Vector3i(-1,0,0),Vector3i(0,1,0),
			Vector3i(0,-1,0),Vector3i(0,0,1),Vector3i(0,0,-1)]:
		six.append(world.get_chunk(Vector3i.ZERO + d))
	light.init_chunk_light(world.chunks[Vector3i.ZERO], six)
	var nb := world.collect_neighbors(Vector3i.ZERO)
	for greedy in [false, true]:
		var cs: Dictionary = NativeMeshBridge.build(greedy, registry,
				world.chunks[Vector3i.ZERO], nb)
		var gd: Dictionary
		if greedy:
			gd = GreedyMesher._build_gd(registry, world.chunks[Vector3i.ZERO], nb)
		else:
			gd = ChunkMesher._build_gd(registry, world.chunks[Vector3i.ZERO], nb)
		print("=== greedy=", greedy)
		for key in ["vertices", "uvs", "normals", "indices", "colors",
				"cross_vertices", "cross_uvs", "cross_normals",
				"cross_indices", "cross_colors"]:
			var a = cs.get(key, null)
			var b = gd.get(key, null)
			if a == null and b == null:
				continue
			if a == b:
				print("  %s 一致 (%d)" % [key, a.size()])
			else:
				var n := mini(a.size(), b.size())
				var first := -1
				for i in n:
					if a[i] != b[i]:
						first = i
						break
				print("  %s 不一致! cs=%d gd=%d 首差[%d]: cs=%s gd=%s" % [
						key, a.size(), b.size(), first,
						str(a[first]) if first >= 0 else "-", 
						str(b[first]) if first >= 0 else "-"])
	quit(0)
