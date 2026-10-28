extends SceneTree
const NativeMeshBridge := preload("res://meshing/native_mesh_bridge.gd")

func _init():
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 77
	var world := VoxelWorld.new(config, registry)
	var gen := TerrainGenerator.new(config)
	var coord: Vector3i
	for r in range(80):
		var cc := Vector3i(r * 4, 0, r * 4)
		var cand: ChunkData = gen.generate_chunk(cc)
		if cand.block_ids.has(VoxelTypes.WATER_ID):
			world.add_chunk(cand)
			coord = cc
			break
	var chunk: ChunkData = world.get_chunk(coord)
	var neigh := world.collect_neighbors(coord)
	var cs: Dictionary = NativeMeshBridge.build_water(chunk, neigh)
	var gd: Dictionary = ChunkMesher._build_gd(registry, chunk, neigh)
	for key in ["water_colors", "water_side_colors"]:
		var a: PackedColorArray = cs[key]
		var b: PackedColorArray = gd.get(key, PackedColorArray())
		print(key, " cs=", a.size(), " gd=", b.size())
		var n := mini(a.size(), b.size())
		var shown := 0
		for i in n:
			if a[i] != b[i]:
				print("  [%d] cs=(%.6f,%.3f,%.3f,%.3f) gd=(%.6f,%.3f,%.3f,%.3f)" % [
						i, a[i].r, a[i].g, a[i].b, a[i].a,
						b[i].r, b[i].g, b[i].b, b[i].a])
				shown += 1
				if shown >= 8:
					break
		print("  差异总数（前 %d 中）=%d" % [n, shown])
	quit(0)
