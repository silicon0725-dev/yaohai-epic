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
	_test_branch_meshing()
	_test_water_meshing()
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

	# 树叶面走 cutout 桶（独立 alpha 裁刻表面）：不进不透明索引，
	# 孤立叶方块 6 面全进 cutout；石头面数不变
	chunk.set_block_raw(Vector3i(3, 2, 1), VoxelTypes.LEAVES_ID)
	arrays = _mesh(world, Vector3i(0, 0, 0))
	check_eq(arrays["indices"].size(), 60, "叶面不进不透明桶")
	check_eq(arrays["cutout_indices"].size(), 36, "孤立树叶 6 面全进 cutout 桶")
	check_eq(arrays["vertices"].size(), 40 + 24, "叶面顶点与不透明共享同一数组（石头 10 面 + 叶 6 面）")

	# 材质必须挂在“刚添加的表面”上（surface 条件添加，序号随前面
	# 表面有无而变）——无水区块叶 surface 是 1 号，写死 3 号曾越界
	# 失效，树叶渲染成整块白
	var mat_opaque := StandardMaterial3D.new()
	var mat_cutout := StandardMaterial3D.new()
	var built_mesh := MeshBuilder.arrays_to_mesh(
			arrays.duplicate(true), mat_opaque, null, null, mat_cutout)
	check_eq(built_mesh.get_surface_count(), 2, "无水区块两表面（不透明+cutout）")
	check_eq(built_mesh.surface_get_material(1), mat_cutout,
			"cutout 材质挂在叶 surface 上（非默认白材质）")

	# 图集必须保留 alpha（RGBA8）——曾建 RGB8 并 convert 丢弃透明
	# 通道，树叶贴图的孔洞被压成不透明黑点，镂空失效
	var atlas := TextureAtlasLoader.generate_atlas_image()
	check(atlas.get_format() == Image.FORMAT_RGBA8, "图集保留 alpha 通道（RGBA8）")
	var ts: int = TextureAtlasLoader.TILE_SIZE
	# 全部 tile 必须有内容——blit_rect 要求源与图集同格式，RGB8 源
	# 曾 blit 失败变全透明空位（树干贴图消失被 scissor 裁没）
	for tile_name in TextureAtlasLoader.TILES:
		var g := TextureAtlasLoader.tile_grid(tile_name)
		var opaque := 0
		for py in ts:
			for px in ts:
				if atlas.get_pixel(g.x * ts + px, g.y * ts + py).a > 0.5:
					opaque += 1
		check(opaque > 100, "tile %s 非空（%d 不透明像素）" % [tile_name, opaque])
	var lt := TextureAtlasLoader.tile_grid("leaves")
	var holes := 0
	for py in ts:
		for px in ts:
			if atlas.get_pixel(lt.x * ts + px, lt.y * ts + py).a < 0.5:
				holes += 1
	check(holes > 50, "树叶 tile 含透明孔（%d 像素）" % holes)

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


## 动态树枝干几何：radius 1-2 十字面片（2 面）；radius 4 方形柱
##（四侧+顶+底，独立格无邻遮挡）。
func _test_branch_meshing() -> void:
	var world := _make_world(1)
	var chunk := world.get_chunk(Vector3i(0, 0, 0))
	chunk.set_block_raw(Vector3i(2, 1, 2), VoxelTypes.BRANCH_ID)
	var arrays := _mesh(world, Vector3i(0, 0, 0))
	# 树系统 v2：BRANCH 是占位（无区块几何，渲染走树实体独立网格）
	check_eq(arrays["indices"].size(), 0, "枝干占位无区块几何")


func _test_water_meshing() -> void:
	# 水柱（y 1..2，上为空气）：水-水内部面剔除，只剩表面 5 面
	#（顶面 + 四侧），顶面顶点下沉 0.875；不进不透明网格
	var world := _make_world(1)
	var chunk := world.get_chunk(Vector3i(0, 0, 0))
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.WATER_ID)
	chunk.set_block_raw(Vector3i(1, 2, 1), VoxelTypes.WATER_ID)
	var arrays := _mesh(world, Vector3i(0, 0, 0))
	check_eq(arrays["indices"].size(), 0, "水不进不透明网格")
	var water_indices: PackedInt32Array = arrays.get(
			"water_indices", PackedInt32Array())
	var side_indices: PackedInt32Array = arrays.get(
			"water_side_indices", PackedInt32Array())
	# 悬浮水柱：底面也朝空气可见 -> 底块（底+四侧）+ 顶块（顶+四侧）= 10 面。
	# 顶/底面走双面通道（2 面），四侧走背面剔除通道（8 面）
	check_eq(water_indices.size() + side_indices.size(), 60,
			"悬浮水柱 10 面（水-水内部剔除）")
	check_eq(water_indices.size(), 12, "顶/底面 2 面走双面通道")
	check_eq(side_indices.size(), 48, "四侧 8 面走背面剔除通道")

	# 顶面顶点下沉：最高顶点 y = 1 - 0.125 + z 偏移 -> 表面块 y=2 上沿 2.875
	var water_vertices: PackedVector3Array = arrays["water_vertices"]
	var max_y := -INF
	var min_y := INF
	for v in water_vertices:
		max_y = maxf(max_y, v.y)
		min_y = minf(min_y, v.y)
	check(abs(max_y - (3.0 - ChunkMesher.WATER_SURFACE_DROP)) < 0.0001,
			"表面水块上沿下沉 0.125（%.3f）" % max_y)
	check(abs(min_y - 1.0) < 0.0001, "底面不下沉")

	# 水下无面：水-固体不出面（固体自己的面隔着水可见）
	var world2 := _make_world(1)
	var chunk2 := world2.get_chunk(Vector3i(0, 0, 0))
	chunk2.set_block_raw(Vector3i(1, 0, 1), VoxelTypes.STONE_ID)
	chunk2.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.WATER_ID)
	var arrays2 := _mesh(world2, Vector3i(0, 0, 0))
	# 石头顶面（y=1）在水下仍渲染；水只有上方空气面 + 四侧
	check_eq(arrays2["indices"].size(), 30,
			"水下固体面仍渲染（石 5 面 + 与水接触面）")
	var water2: PackedInt32Array = arrays2.get(
			"water_indices", PackedInt32Array())
	var side2: PackedInt32Array = arrays2.get(
			"water_side_indices", PackedInt32Array())
	# 顶面 1 面走双面通道，四侧 4 面走背面剔除通道
	check_eq(water2.size(), 6, "水对固体不出底面（顶面单面）")
	check_eq(side2.size(), 24, "水对固体不出底面（四侧）")
