## Greedy Meshing 单元测试（开发文档 §6.3、§11.1）。
## 核心不变量：贪心四边形总面积（方块面数）必须与面剔除实现完全
## 一致——两者描述同一张世界表面，只是合并方式不同。
extends VoxelTestCase


func _make_world(chunk_count_x: int) -> VoxelWorld:
	var world_config := WorldConfig.new()
	world_config.chunks_y = 1
	world_config.chunk_size = 4
	var voxel_world := VoxelWorld.new(
			world_config, VoxelTypes.build_default_registry())
	var size := world_config.chunk_size
	for cx in chunk_count_x:
		voxel_world.add_chunk(ChunkData.new(
				Vector3i(cx, 0, 0), Vector3i(size, size, size), 2))
	return voxel_world


func _mesh(voxel_world: VoxelWorld, coord: Vector3i, greedy: bool) -> Dictionary:
	var chunk: ChunkData = voxel_world.get_chunk(coord)
	if greedy:
		return GreedyMesher.build_mesh_arrays(
				voxel_world.registry, chunk, voxel_world.collect_neighbors(coord))
	return ChunkMesher.build_mesh_arrays(
			voxel_world.registry, chunk, voxel_world.collect_neighbors(coord))


## 贪心四边形总面积：每个四边形 4 顶点按序追加，取其 tile 空间
## UV 的包围盒宽高（对任意 UV 朝向成立）
func _greedy_area(arrays: Dictionary) -> int:
	var uvs: PackedVector2Array = arrays["uvs"]
	var quad_count: int = arrays["quads"]
	var area := 0
	for q in quad_count:
		var min_x := INF
		var max_x := -INF
		var min_y := INF
		var max_y := -INF
		for c in 4:
			var uv: Vector2 = uvs[q * 4 + c]
			min_x = minf(min_x, uv.x)
			max_x = maxf(max_x, uv.x)
			min_y = minf(min_y, uv.y)
			max_y = maxf(max_y, uv.y)
		area += int(round((max_x - min_x) * (max_y - min_y)))
	return area


func run() -> void:
	# ---- 单个方块：6 面，贪心 6 个 1x1 四边形 ----
	var world := _make_world(1)
	var chunk := world.get_chunk(Vector3i(0, 0, 0))
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)
	var naive := _mesh(world, Vector3i(0, 0, 0), false)
	var greedy := _mesh(world, Vector3i(0, 0, 0), true)
	check_eq(naive["indices"].size() / 6, 6, "面剔除：单方块 6 面")
	check_eq(greedy["quads"], 6, "贪心：单方块 6 个四边形")
	check_eq(_greedy_area(greedy), 6, "面积一致：单方块")

	# ---- 相邻方块：共享面剔除，面积仍一致 ----
	chunk.set_block_raw(Vector3i(2, 1, 1), VoxelTypes.STONE_ID)
	naive = _mesh(world, Vector3i(0, 0, 0), false)
	greedy = _mesh(world, Vector3i(0, 0, 0), true)
	check_eq(_greedy_area(greedy), naive["indices"].size() / 6,
		"面积一致：相邻方块")
	check(greedy["quads"] <= naive["indices"].size() / 6,
		"四边形数不超过面数")

	# ---- 实心 3x3x3（y=1..3 避开世界底部策略）：54 面 ----
	var world2 := _make_world(1)
	var solid := world2.get_chunk(Vector3i(0, 0, 0))
	for ly in range(1, 4):
		for lz in 3:
			for lx in 3:
				solid.set_block_raw(Vector3i(lx, ly, lz), VoxelTypes.STONE_ID)
	var naive2 := _mesh(world2, Vector3i(0, 0, 0), false)
	var greedy2 := _mesh(world2, Vector3i(0, 0, 0), true)
	check_eq(naive2["indices"].size() / 6, 54, "面剔除：3x3x3 共 54 面")
	check_eq(_greedy_area(greedy2), 54, "面积一致：3x3x3")
	check_eq(greedy2["quads"], 6, "贪心：3x3x3 合并为 6 个 3x3 四边形")
	check_eq(greedy2["vertices"].size(), 24, "贪心：3x3x3 仅 24 顶点（面剔除为 216）")

	# ---- 世界底部策略：y<0 视为实心，面积一致 ----
	var world3 := _make_world(1)
	world3.get_chunk(Vector3i(0, 0, 0)).set_block_raw(
			Vector3i(0, 0, 0), VoxelTypes.STONE_ID)
	var naive3 := _mesh(world3, Vector3i(0, 0, 0), false)
	var greedy3 := _mesh(world3, Vector3i(0, 0, 0), true)
	check_eq(_greedy_area(greedy3), naive3["indices"].size() / 6,
		"面积一致：世界底部剔除")

	# ---- 混合材质表面不跨 tile 合并：草顶/沙顶相邻 ----
	var world4 := _make_world(1)
	var mixed := world4.get_chunk(Vector3i(0, 0, 0))
	for lz in 2:
		for lx in 2:
			var id := VoxelTypes.GRASS_ID if lx == 0 else VoxelTypes.SAND_ID
			mixed.set_block_raw(Vector3i(lx, 1, lz), id)
	var naive4 := _mesh(world4, Vector3i(0, 0, 0), false)
	var greedy4 := _mesh(world4, Vector3i(0, 0, 0), true)
	check_eq(_greedy_area(greedy4), naive4["indices"].size() / 6,
		"面积一致：混合材质")
	# 顶面被贴图差异分成两半，不能合并为单个 2x2
	check(greedy4["quads"] > 6, "不同贴图的表面不合并")

	# ---- 输出结构完整性 ----
	check_eq(greedy4["vertices"].size(), greedy4["quads"] * 4, "顶点数 = 4x四边形")
	check_eq(greedy4["indices"].size(), greedy4["quads"] * 6, "索引数 = 6x四边形")
	check_eq(greedy4["uvs"].size(), greedy4["vertices"].size(), "UV 一一对应")
	check_eq(greedy4["uv2"].size(), greedy4["vertices"].size(), "UV2 一一对应")
	var uv2: PackedVector2Array = greedy4["uv2"]
	var uv2_valid := true
	for value in uv2:
		if value.x < 0.0 or value.x > 1.0 or value.y < 0.0 or value.y > 1.0:
			uv2_valid = false
			break
	check(uv2_valid, "UV2（tile 原点）位于 [0,1]")

	# ---- 真实地形上的面积一致性（强集成不变量）----
	var config := WorldConfig.new()
	config.world_seed = 1337
	var real_world := VoxelWorld.new(config, VoxelTypes.build_default_registry())
	var generator := TerrainGenerator.new(config)
	for cz in 3:
		for cx in 3:
			for cy in config.chunks_y:
				real_world.add_chunk(
						generator.generate_chunk(Vector3i(cx, cy, cz)))
	var total_naive := 0
	var total_area := 0
	var total_quads := 0
	for coord in real_world.chunks:
		# 枝干细面（十字/窄柱）面积不等于单位面，面积等价只对
		# 标准方块区块成立——含枝区块跳过（两种网格器对它都回退
		# 同一 naive 路径，等价性由路径共享保证）
		var ch: ChunkData = real_world.get_chunk(coord)
		if ch != null and (ch.block_ids.has(VoxelTypes.BRANCH_ID) 				or ch.block_ids.has(VoxelTypes.LEAVES_ID)):
			continue
		var n := _mesh(real_world, coord, false)
		var g := _mesh(real_world, coord, true)
		total_naive += n["indices"].size() / 6
		total_area += _greedy_area(g)
		total_quads += g["quads"]
	check_eq(total_area, total_naive, "真实地形：贪心总面积 == 面剔除面数")
	check(total_quads < total_naive,
		"真实地形：贪心四边形数少于面数（%d < %d）" % [total_quads, total_naive])
