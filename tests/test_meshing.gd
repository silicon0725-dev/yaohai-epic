## 网格构建单元测试：面剔除正确性、世界底部边界策略、
## 区块边界修改的失效传播、统一修改 API（§11.1）。
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
				Vector3i(cx, 0, 0), Vector3i(size, size, size), 1))
	return voxel_world


## 阶段 C 起网格构建接收注册表 + 27 邻域快照（线程安全签名）。
func _mesh(voxel_world: VoxelWorld, coord: Vector3i) -> Dictionary:
	var chunk: ChunkData = voxel_world.get_chunk(coord)
	return ChunkMesher.build_mesh_arrays(
			voxel_world.registry, chunk, voxel_world.collect_neighbors(coord))


func run() -> void:
	# 单个方块：恰好 6 个面
	var world := _make_world(1)
	var chunk := world.get_chunk(Vector3i(0, 0, 0))
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)
	var arrays := _mesh(world, Vector3i(0, 0, 0))
	check_eq(arrays["vertices"].size(), 24, "单方块顶点数（4x6）")
	check_eq(arrays["indices"].size(), 36, "单方块索引数（6 面 x 6 索引）")

	# 相邻方块：共享面被剔除 -> 10 面
	chunk.set_block_raw(Vector3i(2, 1, 1), VoxelTypes.STONE_ID)
	arrays = _mesh(world, Vector3i(0, 0, 0))
	check_eq(arrays["indices"].size(), 60, "相邻方块共享面被剔除")

	# 实心 3x3x3：被完全包裹的中心方块不贡献任何面 -> 54 面。
	# 区域放在 y=1..3，避开世界底部策略（y<0 视为实心）对面数的影响。
	var world2 := _make_world(1)
	var solid := world2.get_chunk(Vector3i(0, 0, 0))
	for ly in range(1, 4):
		for lz in 3:
			for lx in 3:
				solid.set_block_raw(Vector3i(lx, ly, lz), VoxelTypes.STONE_ID)
	var solid_arrays := _mesh(world2, Vector3i(0, 0, 0))
	check_eq(solid_arrays["indices"].size(), 54 * 6, "实心 3x3x3 面数（54）")

	# 世界底部边界策略：y<0 视为实心 -> (0,0,0) 方块底面被剔除
	var world3 := _make_world(1)
	var bottom := world3.get_chunk(Vector3i(0, 0, 0))
	bottom.set_block_raw(Vector3i(0, 0, 0), VoxelTypes.STONE_ID)
	var bottom_arrays := _mesh(world3, Vector3i(0, 0, 0))
	check_eq(bottom_arrays["indices"].size(), 30, "世界底部面剔除（5 面）")

	# 所有 UV 必须落在 [0,1]
	var uv_out_of_range := false
	for uv in arrays["uvs"]:
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			uv_out_of_range = true
			break
	check(not uv_out_of_range, "UV 全部位于 [0,1]")
	check(arrays["uvs"].size() == arrays["vertices"].size(), "UV 与顶点一一对应")

	# 数组可构建 ArrayMesh（headless 下验证数据合法性）
	var mesh := MeshBuilder.arrays_to_mesh(solid_arrays, null)
	check_eq(mesh.get_surface_count(), 1, "ArrayMesh 表面数")
	check(mesh.get_surface_count() > 0, "网格非空")

	# 碰撞几何与网格同源：三角形顶点数应与索引数一致（§8.3）
	var shape := ChunkCollisionBuilder.build_collision_shape(solid_arrays)
	check_eq(
		shape.get_faces().size(), solid_arrays["indices"].size(),
		"碰撞面顶点数与网格索引一致")

	# 区块边界修改的失效传播（§6.4）与统一修改 API（§8.2）
	var world4 := _make_world(2)
	var left := world4.get_chunk(Vector3i(0, 0, 0))
	var right := world4.get_chunk(Vector3i(1, 0, 0))
	left.mesh_dirty = false
	right.mesh_dirty = false
	# x=4 属于右侧区块且位于其 -X 边界
	check(
		world4.set_block(Vector3i(4, 1, 1), VoxelTypes.DIRT_ID),
		"边界方块修改成功")
	check(right.mesh_dirty, "被修改区块网格过期")
	check(right.data_modified, "被修改区块数据标记")
	check(right.edit_serial == 1, "修改推进 edit_serial（任务版本）")
	check(left.mesh_dirty, "相邻区块网格因边界修改过期")

	check(
		not world4.set_block(Vector3i(-1, 0, 0), VoxelTypes.STONE_ID),
		"未加载区块修改被拒绝")
	check(
		not world4.set_block(Vector3i(0, 4, 0), VoxelTypes.STONE_ID),
		"世界上方越界修改被拒绝")
	check(
		world4.replace_block(
			Vector3i(5, 1, 1), VoxelTypes.AIR_ID, VoxelTypes.STONE_ID),
		"replace_block 期望匹配时成功")
	check_eq(
		world4.get_block(Vector3i(5, 1, 1)), VoxelTypes.STONE_ID,
		"replace_block 生效")
	check(
		not world4.replace_block(
			Vector3i(5, 1, 1), VoxelTypes.AIR_ID, VoxelTypes.GRASS_ID),
		"replace_block 期望不匹配时失败")
	check_eq(
		world4.get_block(Vector3i(5, 1, 1)), VoxelTypes.STONE_ID,
		"失败的 replace_block 不改变世界")
