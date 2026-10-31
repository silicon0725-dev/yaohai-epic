## 树叶顶点色探针：生成世界找树叶格，同步重建网格，dump 树叶面的
## COLOR（rgba）——判定"不受光照"是网格数据问题还是渲染问题。
extends VoxelTestCase


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	# 真实生成器世界（树叶需要地形生成产出；seed 1337 有树）
	var config := WorldConfig.new()
	config.world_seed = 1337
	var generator := TerrainGenerator.new(config)
	var blocks := VoxelTypes.build_default_registry()
	var world := VoxelWorld.new(config, blocks)
	for cz in 2:
		for cx in 2:
			var chunk: ChunkData = generator.generate_chunk(
					Vector3i(cx, 2, cz))
			world.add_chunk(chunk)
	var light: Node = preload("res://systems/lighting/voxel_light.gd").new()
	tree_root.add_child(light)
	light.setup(world)
	# 找一格树叶
	var target := Vector3i(-1, -1, -1)
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		var s := chunk.dimensions.x
		for i in chunk.volume():
			if chunk.block_ids[i] == VoxelTypes.LEAVES_ID:
				var z := i / (s * s)
				var rem := i - z * s * s
				var y := rem / s
				var x := rem - y * s
				target = coord * s + Vector3i(x, y, z)
				break
		if target.x >= 0:
			break
	print("LEAF_PROBE leaf at ", target)
	if target.x < 0:
		check(false, "生成世界无树叶")
		return
	var lcoord := VoxelCoords.world_to_chunk(target, config.chunk_size)
	var lchunk: ChunkData = world.chunks.get(lcoord)
	var local := VoxelCoords.world_to_local(target, config.chunk_size)
	print("LEAF_PROBE light sky=", lchunk.get_sky_light(local),
			" block=", lchunk.get_block_light(local))
	var arrays := ChunkMesher.build_mesh_arrays(world.registry, lchunk,
			world.collect_neighbors(lcoord), null)
	var verts: PackedVector3Array = arrays["vertices"]
	var cols: PackedColorArray = arrays["colors"]
	var shown := 0
	for i in verts.size():
		if Vector3i(verts[i]).distance_squared_to(
				Vector3(local)) < 2.0 and shown < 6:
			var c := cols[i]
			print("LEAF_PROBE v=", verts[i], " rgba=(%0.3f,%0.3f,%0.3f,%0.3f)"
					% [c.r, c.g, c.b, c.a])
			shown += 1
