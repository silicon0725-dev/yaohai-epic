## 射线检测与交互单元测试（开发文档 §11.1、§8.1、§8.2）。
extends VoxelTestCase


func _make_world() -> VoxelWorld:
	var world_config := WorldConfig.new()
	world_config.chunks_y = 1
	world_config.chunk_size = 4
	var voxel_world := VoxelWorld.new(
			world_config, VoxelTypes.build_default_registry())
	voxel_world.add_chunk(ChunkData.new(
			Vector3i.ZERO, Vector3i(4, 4, 4), 1))
	return voxel_world


func run() -> void:
	var world := _make_world()
	var chunk := world.get_chunk(Vector3i.ZERO)
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)

	# +Z 方向命中：从方块前方穿过一格空气命中
	var hit := VoxelRaycast.raycast(
			world, Vector3(1.5, 1.5, -0.5), Vector3(0, 0, 1), 10.0)
	check(hit.hit, "+Z 射线命中")
	check_eq(hit.block_pos, Vector3i(1, 1, 1), "+Z 命中方块坐标")
	check_eq(hit.normal, Vector3i(0, 0, -1), "+Z 进入面法线")
	check(abs(hit.distance - 1.5) < 0.0001, "+Z 命中距离 1.5")

	# 射程截断
	var short_hit := VoxelRaycast.raycast(
			world, Vector3(1.5, 1.5, -0.5), Vector3(0, 0, 1), 1.0)
	check(not short_hit.hit, "超出射程返回未命中")

	# +X 方向命中
	var hit_x := VoxelRaycast.raycast(
			world, Vector3(-0.5, 1.5, 1.5), Vector3(1, 0, 0), 10.0)
	check(hit_x.hit, "+X 射线命中")
	check_eq(hit_x.block_pos, Vector3i(1, 1, 1), "+X 命中方块坐标")
	check_eq(hit_x.normal, Vector3i(-1, 0, 0), "+X 进入面法线")

	# -Y 方向命中（顶面）
	var hit_down := VoxelRaycast.raycast(
			world, Vector3(1.5, 3.5, 1.5), Vector3(0, -1, 0), 10.0)
	check(hit_down.hit, "-Y 射线命中")
	check_eq(hit_down.block_pos, Vector3i(1, 1, 1), "-Y 命中方块坐标")
	check_eq(hit_down.normal, Vector3i(0, 1, 0), "-Y 进入面法线（顶面）")

	# 45° 斜向射线（并列步进轴的确定性偏好：x 优先）
	var hit_diag := VoxelRaycast.raycast(
			world, Vector3(0.5, 1.5, 0.5), Vector3(1, 0, 1), 10.0)
	check(hit_diag.hit, "45° 射线命中")
	check_eq(hit_diag.block_pos, Vector3i(1, 1, 1), "45° 命中方块坐标")
	check(abs(hit_diag.distance - 0.7071) < 0.001, "45° 命中距离 sqrt(0.5)")

	# 起点在实心方块内
	var hit_inside := VoxelRaycast.raycast(
			world, Vector3(1.5, 1.5, 1.5), Vector3(0, 0, 1), 10.0)
	check(hit_inside.hit, "起点在方块内命中")
	check_eq(hit_inside.distance, 0.0, "起点在方块内距离为 0")
	check_eq(hit_inside.normal, Vector3i.ZERO, "起点在方块内法线为零")

	# 朝空旷方向
	var miss := VoxelRaycast.raycast(
			world, Vector3(1.5, 3.5, 1.5), Vector3(0, 1, 0), 10.0)
	check(not miss.hit, "朝空气方向未命中")

	# 零方向向量不崩溃
	var zero_dir := VoxelRaycast.raycast(
			world, Vector3(1.5, 1.5, 0.5), Vector3.ZERO, 10.0)
	check(not zero_dir.hit, "零方向向量安全返回未命中")

	# ---- 挖掘（§8.2 + 物品层：掉落规则）----
	var items := ItemTypes.build_default_item_registry(world.registry)
	check(BlockMining.can_mine(VoxelTypes.STONE_ID, world.registry), "石头可挖掘")
	check(not BlockMining.can_mine(VoxelTypes.BEDROCK_ID, world.registry), "基岩不可挖掘")
	check(not BlockMining.can_mine(VoxelTypes.AIR_ID, world.registry), "空气不可挖掘")
	var stone_drops := BlockMining.mine(world, Vector3i(1, 1, 1), items, true)
	check(not stone_drops.is_empty(), "挖掘石头成功（掉圆石）")
	check_eq(
		world.get_block(Vector3i(1, 1, 1)), VoxelTypes.AIR_ID, "挖掘后为空气")
	check(chunk.mesh_dirty, "挖掘后网格标记过期")
	check(chunk.collision_dirty, "挖掘后碰撞标记过期")
	check(BlockMining.mine(world, Vector3i(1, 1, 1), items).is_empty(),
		"重复挖掘空气失败")

	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.BEDROCK_ID)
	check(BlockMining.mine(world, Vector3i(1, 1, 1), items).is_empty(),
		"基岩挖掘被拒绝")
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)

	# ---- 放置（§8.2）----
	var far_aabb := AABB(Vector3(100.0, 100.0, 100.0), Vector3.ONE)
	var aim := VoxelRaycast.raycast(
			world, Vector3(1.5, 1.5, -0.5), Vector3(0, 0, 1), 10.0)
	check(aim.hit, "交互射线命中")
	var target: Vector3i = aim.block_pos + aim.normal
	check_eq(target, Vector3i(1, 1, 0), "放置目标为命中面相邻格")
	check(
		BlockPlacement.place(world, target, VoxelTypes.DIRT_ID, far_aabb),
		"放置泥土成功")
	check_eq(
		world.get_block(Vector3i(1, 1, 0)), VoxelTypes.DIRT_ID, "放置后可读回")
	check(
		not BlockPlacement.place(
			world, Vector3i(1, 1, 0), VoxelTypes.STONE_ID, far_aabb),
		"非空气格放置被拒绝")
	# 玩家 AABB 覆盖 (0,1,0)：与其重叠的放置必须失败
	var player_aabb := AABB(Vector3(0.6, 0.6, 0.6), Vector3.ONE)
	check(
		not BlockPlacement.place(
			world, Vector3i(0, 1, 0), VoxelTypes.STONE_ID, player_aabb),
		"与玩家碰撞体重叠的放置被拒绝")
	check(
		not BlockPlacement.place(
			world, Vector3i(-1, 1, 0), VoxelTypes.STONE_ID, far_aabb),
		"世界外放置被拒绝")
	check(
		not BlockPlacement.place(
			world, Vector3i(2, 1, 0), VoxelTypes.AIR_ID, far_aabb),
		"放置空气被拒绝")
