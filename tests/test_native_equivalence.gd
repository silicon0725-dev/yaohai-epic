## C# 原生网格器等价性测试：同一输入下 C# 与 GDScript 输出完全一致。
## 原生不可用时跳过（不算失败——纯 GDScript 环境是合法运行形态）。
extends VoxelTestCase


func run() -> void:
	if not NativeMeshBridge.available():
		print("[SKIP] C# 原生网格器不可用，跳过等价测试（纯 GDScript 模式）")
		return

	var registry := VoxelTypes.build_default_registry()

	# ---- 构造多组测试世界 ----
	var worlds: Array[Dictionary] = []

	# 1. 单方块
	var w1 := _make_world()
	w1.get_chunk(Vector3i.ZERO).set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)
	worlds.append({"world": w1, "coord": Vector3i.ZERO, "label": "单方块"})

	# 2. 实心 3x3x3（y=1..3）
	var w2 := _make_world()
	for ly in range(1, 4):
		for lz in 3:
			for lx in 3:
				w2.get_chunk(Vector3i.ZERO).set_block_raw(
					Vector3i(lx, ly, lz), VoxelTypes.STONE_ID)
	worlds.append({"world": w2, "coord": Vector3i.ZERO, "label": "3x3x3 实心"})

	# 3. 混合材质 + 朝向状态
	var w3 := _make_world()
	w3.set_block(Vector3i(1, 2, 1), VoxelTypes.LOG_ID)
	w3.set_block_state(Vector3i(1, 2, 1), "axis", "x")
	w3.set_block(Vector3i(2, 2, 1), VoxelTypes.GRASS_ID)
	w3.set_block(Vector3i(1, 2, 2), VoxelTypes.BRICKS_ID)
	w3.set_block_state(Vector3i(1, 2, 2), "axis", "z")  # 砖无朝向，但验证状态不干扰
	worlds.append({"world": w3, "coord": Vector3i.ZERO, "label": "混合材质+状态"})

	# 4. 真实地形区块
	var config := WorldConfig.new()
	config.world_seed = 1337
	var w4 := VoxelWorld.new(config, registry)
	var generator := TerrainGenerator.new(config)
	for cz in 2:
		for cx in 2:
			for cy in config.chunks_y:
				w4.add_chunk(generator.generate_chunk(Vector3i(cx, cy, cz)))
	worlds.append({"world": w4, "coord": Vector3i(0, 0, 0), "label": "真实地形"})
	worlds.append({"world": w4, "coord": Vector3i(1, 1, 0), "label": "真实地形(边界)"})

	# ---- 逐世界对比 C# 与 GDScript 输出 ----
	for entry in worlds:
		var world: VoxelWorld = entry["world"]
		var coord: Vector3i = entry["coord"]
		var label: String = entry["label"]
		var chunk: ChunkData = world.get_chunk(coord)
		var neighbors := world.collect_neighbors(coord)

		for greedy in [false, true]:
			var mode := "贪心" if greedy else "面剔除"
			var native_result: Dictionary
			var gd_result: Dictionary
			if greedy:
				native_result = NativeMeshBridge.build(true, registry, chunk, neighbors)
				gd_result = GreedyMesher._build_gd(registry, chunk, neighbors)
			else:
				native_result = NativeMeshBridge.build(false, registry, chunk, neighbors)
				gd_result = ChunkMesher._build_gd(registry, chunk, neighbors)

			check(not native_result.is_empty(),
				"%s %s：原生结果非空" % [label, mode])
			if native_result.is_empty():
				continue

			check(native_result["vertices"] == gd_result["vertices"],
				"%s %s：顶点一致" % [label, mode])
			check(native_result["normals"] == gd_result["normals"],
				"%s %s：法线一致" % [label, mode])
			check(native_result["indices"] == gd_result["indices"],
				"%s %s：索引一致" % [label, mode])
			check(native_result["uvs"] == gd_result["uvs"],
				"%s %s：UV 一致" % [label, mode])
			if greedy:
				check(native_result["uv2"] == gd_result["uv2"],
					"%s 贪心：UV2 一致" % label)
			check(native_result["quads"] == gd_result["quads"],
				"%s 贪心：四边形数一致" % label)

	# ---- 水世界用例：C# BuildWater 与 GDScript append_water_faces 的
	# water_* 8 数组逐字节等价（角点高度/岸衰减/双通道分流/组合门面）----
	var w5 := _make_world()
	var c5: ChunkData = w5.get_chunk(Vector3i.ZERO)
	# 源水（无状态）+ 流动级 + 下落柱（8）+ 邻固体 + 区块边界角点
	c5.set_block_raw(Vector3i(0, 1, 0), VoxelTypes.WATER_ID)
	c5.set_block_raw(Vector3i(1, 1, 0), VoxelTypes.WATER_ID)
	c5.set_block_state(Vector3i(1, 1, 0), "level", 2)
	c5.set_block_raw(Vector3i(1, 2, 0), VoxelTypes.WATER_ID)
	c5.set_block_state(Vector3i(1, 2, 0), "level", 8)
	c5.set_block_raw(Vector3i(2, 1, 0), VoxelTypes.STONE_ID)
	c5.set_block_raw(Vector3i(0, 1, 1), VoxelTypes.WATER_ID)
	c5.set_block_state(Vector3i(0, 1, 1), "level", 3)
	c5.set_block_raw(Vector3i(3, 1, 3), VoxelTypes.WATER_ID)
	c5.set_block_state(Vector3i(3, 1, 3), "level", 1)
	var water_cases: Array[Dictionary] = [
		{"world": w5, "coord": Vector3i.ZERO, "label": "水世界(4³)"},
	]
	# 真实含水 16³（自然海岸：跨邻域角点/岸衰减全覆盖）
	var w6_config := WorldConfig.new()
	w6_config.world_seed = 77
	var w6 := VoxelWorld.new(w6_config, registry)
	var gen6 := TerrainGenerator.new(w6_config)
	for r in range(80):
		var cc := Vector3i(r * 4, 0, r * 4)
		var cand: ChunkData = gen6.generate_chunk(cc)
		if cand.block_ids.has(VoxelTypes.WATER_ID):
			w6.add_chunk(cand)
			water_cases.append({"world": w6, "coord": cc, "label": "真实含水(16³)"})
			break
	for entry in water_cases:
		var wworld: VoxelWorld = entry["world"]
		var wcoord: Vector3i = entry["coord"]
		var wlabel: String = entry["label"]
		var wchunk: ChunkData = wworld.get_chunk(wcoord)
		var wneigh := wworld.collect_neighbors(wcoord)
		var cs_water: Dictionary = NativeMeshBridge.build_water(wchunk, wneigh)
		var gd_naive := ChunkMesher._build_gd(registry, wchunk, wneigh)
		check(not cs_water.is_empty(), "%s：水 C# 结果非空" % wlabel)
		if cs_water.is_empty():
			continue
		var wkeys := ["water_vertices", "water_normals", "water_indices",
				"water_colors", "water_side_vertices", "water_side_normals",
				"water_side_indices", "water_side_colors"]
		var any_water := false
		for wkey in wkeys:
			var gd_arr = gd_naive.get(wkey, PackedInt32Array())
			if gd_arr.size() > 0:
				any_water = true
			check(cs_water[wkey] == gd_arr,
					"%s：%s 一致（%d vs %d）" % [
						wlabel, wkey, cs_water[wkey].size(), gd_arr.size()])
		check(any_water, "%s：GD 水面非空（用例有效性）" % wlabel)
		# 组合门面：整体输出（C# opaque+water vs GD 全程）等价
		var cs_combo := ChunkMesher.build_mesh_arrays(registry, wchunk, wneigh)
		for wkey in wkeys:
			check(cs_combo.get(wkey, PackedInt32Array()) == gd_naive.get(
					wkey, PackedInt32Array()),
					"%s：门面组合 %s 一致" % [wlabel, wkey])
		# 贪心门面组合（贪心 opaque 不含水，水全来自 build_water）
		var cs_greedy := GreedyMesher.build_mesh_arrays(registry, wchunk, wneigh)
		var gd_greedy := GreedyMesher._build_gd(registry, wchunk, wneigh)
		for wkey in wkeys:
			check(cs_greedy.get(wkey, PackedInt32Array()) == gd_greedy.get(
					wkey, PackedInt32Array()),
					"%s：贪心门面组合 %s 一致" % [wlabel, wkey])

	print("[INFO] 等价测试覆盖 %d 个世界 x 2 种网格器 + %d 个水通道用例" % [
		worlds.size(), water_cases.size()])


func _make_world() -> VoxelWorld:
	var config := WorldConfig.new()
	config.chunks_y = 1
	config.chunk_size = 4
	var world := VoxelWorld.new(config, VoxelTypes.build_default_registry())
	world.add_chunk(ChunkData.new(Vector3i.ZERO, Vector3i(4, 4, 4), 2))
	return world
