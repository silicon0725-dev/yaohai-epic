## 方块状态持久化单元测试（开发文档 §4.3、§8.2、§9.3）：
## 状态 API、朝向感知网格（两种网格器）、序列化往返与 v1 旧档兼容。
extends VoxelTestCase

const TMP_ROOT := "user://tmp_state_test"


func _make_world() -> VoxelWorld:
	var world_config := WorldConfig.new()
	world_config.chunks_y = 1
	world_config.chunk_size = 4
	var voxel_world := VoxelWorld.new(
			world_config, VoxelTypes.build_default_registry())
	voxel_world.add_chunk(ChunkData.new(
			Vector3i.ZERO, Vector3i(4, 4, 4), 2))
	return voxel_world


func run() -> void:
	var world := _make_world()
	var chunk := world.get_chunk(Vector3i.ZERO)

	# ---- 状态 API ----
	check_eq(world.get_block_state(Vector3i(1, 1, 1)), {}, "无状态返回空字典")
	check(world.set_block_state(Vector3i(1, 1, 1), "axis", "x"),
		"写入状态成功")
	check_eq(world.get_block_state(Vector3i(1, 1, 1)).get("axis", ""),
		"x", "读回状态")
	check(chunk.data_modified and chunk.save_needed, "状态写入标记待存档")
	check(chunk.edit_serial >= 1, "状态写入推进 edit_serial")
	check(world.set_block_state(Vector3i(1, 1, 1), "open", true),
		"追加第二个状态键")
	check_eq(world.get_block_state(Vector3i(1, 1, 1)).get("open", false),
		true, "多键状态共存")
	check(not world.set_block_state(Vector3i(0, 9, 0), "axis", "x"),
		"越界状态写入失败")
	check_eq(world.get_block_state(Vector3i(0, 9, 0)), {}, "越界读取为空")

	# 方块替换清空状态（防止旧状态污染新方块）
	world.set_block(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)
	check_eq(world.get_block_state(Vector3i(1, 1, 1)), {},
		"set_block 替换后状态清空")

	# 轴向推导（放置面法线 -> 方块轴向）
	check_eq(BlockPlacement.axis_for_normal(Vector3i(0, 1, 0)), "y",
		"贴顶面 -> 竖放")
	check_eq(BlockPlacement.axis_for_normal(Vector3i(0, -1, 0)), "y",
		"贴底面 -> 竖放")
	check_eq(BlockPlacement.axis_for_normal(Vector3i(1, 0, 0)), "x",
		"贴 +X 侧面 -> 沿 x 横放")
	check_eq(BlockPlacement.axis_for_normal(Vector3i(0, 0, -1)), "z",
		"贴 -Z 侧面 -> 沿 z 横放")
	check_eq(BlockPlacement.axis_for_normal(Vector3i.ZERO), "y",
		"零法线默认竖放")

	# 放置 API 自动写朝向状态
	var far_aabb := AABB(Vector3(100, 100, 100), Vector3.ONE)
	world.set_block(Vector3i(2, 1, 1), VoxelTypes.AIR_ID)
	check(
		BlockPlacement.place(world, Vector3i(2, 1, 1),
				VoxelTypes.LOG_ID, far_aabb, Vector3i(0, 1, 0)),
		"放置原木（贴顶面）成功")
	check_eq(world.get_block_state(Vector3i(2, 1, 1)).get("axis", ""),
		"y", "贴顶面放置的原木轴向为 y")
	check(
		BlockPlacement.place(world, Vector3i(2, 1, 2),
				VoxelTypes.LOG_ID, far_aabb, Vector3i(1, 0, 0)),
		"放置原木（贴侧 面）成功")
	check_eq(world.get_block_state(Vector3i(2, 1, 2)).get("axis", ""),
		"x", "贴侧面放置的原木轴向为 x")
	check(world.get_chunk(Vector3i.ZERO).mesh_dirty,
		"朝向状态写入使网格过期")

	# ---- 朝向感知网格（两种网格器）----
	# 横放原木（axis=x）：±x 端面用 log_top（tile 5），其余面 log_side（tile 6）
	var log_rect_top := AtlasUV.tile_rect(
			TextureAtlasLoader.tile_grid("log_top"), 16, 1)
	var log_rect_side := AtlasUV.tile_rect(
			TextureAtlasLoader.tile_grid("log_side"), 16, 1)
	world.set_block(Vector3i(1, 2, 1), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(1, 2, 1), VoxelTypes.LOG_ID)
	world.set_block_state(Vector3i(1, 2, 1), "axis", "x")
	for use_greedy in [false, true]:
		var chunk2: ChunkData = world.get_chunk(Vector3i.ZERO)
		var arrays := {}
		if use_greedy:
			arrays = GreedyMesher.build_mesh_arrays(
					world.registry, chunk2, world.collect_neighbors(Vector3i.ZERO))
		else:
			arrays = ChunkMesher.build_mesh_arrays(
					world.registry, chunk2, world.collect_neighbors(Vector3i.ZERO))
		check(_face_uses_tile(arrays, use_greedy, Vector3i(1, 2, 1),
				Vector3i(1, 0, 0), log_rect_top),
			"%s：+x 端面用年轮贴图" % ("贪心" if use_greedy else "面剔除"))
		check(_face_uses_tile(arrays, use_greedy, Vector3i(1, 2, 1),
				Vector3i(0, 1, 0), log_rect_side),
			"%s：顶面用树皮贴图" % ("贪心" if use_greedy else "面剔除"))

	# ---- 序列化往返（v2 含状态）----
	var registry := VoxelTypes.build_default_registry()
	var payload := ChunkSerializer.serialize(registry, chunk)
	var back := ChunkSerializer.deserialize(registry, payload, Vector3i.ZERO)
	check(back != null, "状态区块序列化往返成功")
	if back != null:
		check(back.get_state(Vector3i(1, 2, 1)).get("axis", "") == "x",
			"往返后原木轴向保留")
		check(back.get_state(Vector3i(2, 1, 1)).get("axis", "") == "y",
			"往返后竖放原木轴向保留")
		check(back.block_ids == chunk.block_ids, "往返后方块数据一致")

	# ---- v1 旧档兼容（无状态段）----
	var legacy := payload.duplicate()
	# 头部：magic u32 + 版本 u16 ——把版本字节改为 1，v1 读取路径应
	# 忽略尾部的状态段（向前兼容）
	legacy[4] = 1
	legacy[5] = 0
	var legacy_back := ChunkSerializer.deserialize(
			registry, legacy, Vector3i.ZERO)
	check(legacy_back != null, "v1 标记的旧档可读取")
	if legacy_back != null:
		check(legacy_back.block_ids == chunk.block_ids,
			"v1 旧档方块数据一致")
		check(legacy_back.sparse_block_states.is_empty(),
			"v1 旧档无状态（按预期忽略尾部段）")

	# ---- 文件级往返（WorldSave）----
	WorldSave.new(TMP_ROOT, registry).erase_all()
	var save := WorldSave.new(TMP_ROOT, registry)
	save.ensure_dirs()
	check(save.save_chunk(chunk), "含状态区块落盘成功")
	var loaded := save.load_chunk(Vector3i.ZERO)
	check(loaded != null, "含状态区块读取成功")
	if loaded != null:
		check(loaded.get_state(Vector3i(1, 2, 1)).get("axis", "") == "x",
			"文件往返后状态保留")
	save.erase_all()


## 校验指定方块指定朝向的面落在给定 tile 矩形内。
## 面剔除：按顶点位置过滤；贪心：按四边形基点过滤。
## 匹配规则：法线一致 + 位于目标平面 + 另两轴覆盖目标方块格。
func _face_uses_tile(
		arrays: Dictionary,
		greedy: bool,
		block_pos: Vector3i,
		normal: Vector3i,
		rect: Rect2
) -> bool:
	# Rect2.has_point 不含右/下边界，而面远角 UV 恰在边界上：
	# 统一外扩微小容差做包含判断
	var tolerant := rect.grow(0.001)
	var vertices: PackedVector3Array = arrays["vertices"]
	var normals: PackedVector3Array = arrays["normals"]
	var uvs: PackedVector2Array = arrays["uvs"]
	var uv2s: PackedVector2Array = arrays.get("uv2", PackedVector2Array())
	var normal_axis := 0 if normal.x != 0 else (1 if normal.y != 0 else 2)
	var plane := float(block_pos[normal_axis]) \
			+ (1.0 if normal[normal_axis] > 0 else 0.0)
	for i in vertices.size():
		var n: Vector3 = normals[i]
		if n != Vector3(normal):
			continue
		if greedy and i % 4 != 0:
			continue  # 贪心只看每个四边形的基点顶点
		var v: Vector3 = vertices[i]
		if absf(v[normal_axis] - plane) > 0.001:
			continue  # 不在目标平面上
		if greedy:
			if not _covers_cell(v, vertices[i + 2], block_pos, normal_axis):
				continue
			return tolerant.has_point(uv2s[i])
		else:
			var in_cell := true
			for a in 3:
				if a == normal_axis:
					continue
				if v[a] < float(block_pos[a]) - 0.001 \
						or v[a] > float(block_pos[a] + 1) + 0.001:
					in_cell = false
					break
			if not in_cell:
				continue
			return tolerant.has_point(uvs[i])
	return false


func _covers_cell(
		corner_a: Vector3, corner_b: Vector3, block_pos: Vector3i, normal_axis: int
) -> bool:
	for a in 3:
		if a == normal_axis:
			continue
		var low := minf(corner_a[a], corner_b[a])
		var high := maxf(corner_a[a], corner_b[a])
		if float(block_pos[a]) < low - 0.001 or float(block_pos[a]) > high + 0.001:
			return false
	return true
