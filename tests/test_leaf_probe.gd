## 树叶顶点色探针：生成世界找树叶格，同步重建网格，dump 树叶面的
## COLOR（rgba）——判定"不受光照"是网格数据问题还是渲染问题。
extends VoxelTestCase


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	# 真实生成器世界（树叶需要地形生成产出）。v8 大陆波长 4096 格，
	# 固定小窗可能整片落在海洋/低地无树列——先扫 has_tree_at 找
	# 有效树列（草地 + 海拔 > 8），再以其所在区块为中心生成（含
	# 上一层，叶冠可跨 y 层）
	var config := WorldConfig.new()
	config.world_seed = 1337
	var generator := TerrainGenerator.new(config)
	var blocks := VoxelTypes.build_default_registry()
	var world := VoxelWorld.new(config, blocks)
	var tree_col := Vector2i(-1, -1)
	for wx in range(-240, 240):
		for wz in range(-240, 240):
			if not TreeGenerator.has_tree_at(1337, Vector2i(wx, wz)):
				continue
			var prof: Dictionary = generator.column_profile(wx, wz)
			if int(prof["height"]) > 8 and not prof["sandy"] \
					and not prof["rocky"]:
				tree_col = Vector2i(wx, wz)
				break
		if tree_col.x >= 0:
			break
	check(tree_col.x >= 0, "种子 1337 存在有效树列")
	if tree_col.x < 0:
		return
	var center := Vector3i(
			VoxelCoords.floordiv(tree_col.x, config.chunk_size),
			VoxelCoords.floordiv(int(generator.column_profile(
					tree_col.x, tree_col.y)["height"]) + 2,
					config.chunk_size),
			VoxelCoords.floordiv(tree_col.y, config.chunk_size))
	for cy in 2:
		for cz in 2:
			for cx in 2:
				var chunk: ChunkData = generator.generate_chunk(
						center + Vector3i(cx, cy, cz))
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
