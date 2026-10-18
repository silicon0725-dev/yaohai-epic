## 地形生成单元测试：固定种子确定性、生成版本、地层规则（§11.1）。
extends VoxelTestCase


func _make_config() -> WorldConfig:
	var world_config := WorldConfig.new()
	world_config.world_seed = 20241017
	world_config.chunks_y = 3
	return world_config


func run() -> void:
	var world_config := _make_config()
	var generator := TerrainGenerator.new(world_config)

	# 确定性：同种子 + 同坐标 -> 完全一致的方块数组
	var first := generator.generate_chunk(Vector3i(1, 0, 2))
	var second := TerrainGenerator.new(world_config).generate_chunk(Vector3i(1, 0, 2))
	check(
		first.block_ids == second.block_ids,
		"相同种子与坐标生成结果一致")

	# 不同种子应产生不同地形
	var other_config := _make_config()
	other_config.world_seed = 999
	var other := TerrainGenerator.new(other_config).generate_chunk(Vector3i(1, 0, 2))
	check(first.block_ids != other.block_ids, "不同种子产生不同地形")

	check_eq(
		first.generation_version, TerrainGenerator.GENERATOR_VERSION,
		"区块记录生成算法版本")
	check_eq(TerrainGenerator.GENERATOR_VERSION, 2,
		"生成算法已升级到 v2（沙地 + 矿物）")

	# 地层规则（v2）：表层草/沙随高度分区，其下泥土/砂岩各 3 层，
	# 深处为石头或矿物，y=0 基岩
	var world := VoxelWorld.new(world_config, VoxelTypes.build_default_registry())
	for cy in 3:
		for cz in 3:
			for cx in 3:
				world.add_chunk(generator.generate_chunk(Vector3i(cx, cy, cz)))
	check_eq(world.chunk_count(), 27, "区块数量")

	var violations := 0
	for x in [0, 17, 40]:
		for z in [0, 23, 41]:
			var height := generator.column_height(x, z)
			var sandy := height <= TerrainGenerator.SAND_MAX_HEIGHT
			# 地表之上必须是空气
			if world.get_block(Vector3i(x, height + 1, z)) != VoxelTypes.AIR_ID:
				violations += 1
			if world.get_block(Vector3i(x, 0, z)) != VoxelTypes.BEDROCK_ID:
				violations += 1
			# 表层与表下层按草区/沙区正确选材
			var expected_surface := VoxelTypes.SAND_ID if sandy else VoxelTypes.GRASS_ID
			var expected_layer := VoxelTypes.SANDSTONE_ID if sandy else VoxelTypes.DIRT_ID
			if world.get_block(Vector3i(x, height, z)) != expected_surface:
				violations += 1
			for depth in [1, 2, 3]:
				if height >= depth + 1 \
						and world.get_block(Vector3i(x, height - depth, z)) != expected_layer:
					violations += 1
			# 深处只允许石头或矿物
			for y in [2, 5, 9]:
				if y <= height - TerrainGenerator.ORE_SURFACE_MARGIN:
					var deep: int = world.get_block(Vector3i(x, y, z))
					if deep != VoxelTypes.STONE_ID \
							and deep != VoxelTypes.COAL_ORE_ID \
							and deep != VoxelTypes.IRON_ORE_ID:
						violations += 1
	check_eq(violations, 0, "地层规则（空气/基岩/表层/表下层/深层）")

	# 世界顶部必须完全是空气（防"填满到天花板"回归）
	var top_violations := 0
	for x in [0, 17, 40]:
		for z in [0, 23, 41]:
			if world.get_block(Vector3i(x, 46, z)) != VoxelTypes.AIR_ID:
				top_violations += 1
	check_eq(top_violations, 0, "世界顶部为空气")

	# 固定种子下世界确实存在矿物（确定性，不随机波动）
	var coal := 0
	var iron := 0
	for coord in world.chunks:
		var ore_chunk: ChunkData = world.chunks[coord]
		for i in ore_chunk.block_ids.size():
			if ore_chunk.block_ids[i] == VoxelTypes.COAL_ORE_ID:
				coal += 1
			elif ore_chunk.block_ids[i] == VoxelTypes.IRON_ORE_ID:
				iron += 1
	check(coal > 0, "世界存在煤矿（本种子下 %d 格）" % coal)
	check(iron > 0, "世界存在铁矿（本种子下 %d 格）" % iron)
