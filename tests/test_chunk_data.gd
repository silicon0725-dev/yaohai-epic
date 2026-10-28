## ChunkData 单元测试：索引换算、越界保护、修改标记（§11.1）。
extends VoxelTestCase


func run() -> void:
	var chunk := ChunkData.new(Vector3i(1, -2, 3), Vector3i(4, 4, 4), 7)
	check_eq(chunk.volume(), 64, "区块体积")
	check_eq(chunk.generation_version, 7, "记录生成版本")
	check_eq(chunk.chunk_coord, Vector3i(1, -2, 3), "记录区块坐标")
	check_eq(
		chunk.get_block(Vector3i(0, 0, 0)), VoxelTypes.AIR_ID, "初始为空气")

	check(chunk.set_block(Vector3i(2, 1, 3), VoxelTypes.STONE_ID), "合法 set_block")
	check_eq(
		chunk.get_block(Vector3i(2, 1, 3)), VoxelTypes.STONE_ID, "写入后读回")
	check(chunk.data_modified, "数据修改标记")
	check(chunk.save_needed, "待存档标记")

	check(not chunk.set_block(Vector3i(4, 0, 0), 1), "x 越界写入被拒绝")
	check(not chunk.set_block(Vector3i(0, -1, 0), 1), "负局部坐标写入被拒绝")
	check_eq(chunk.get_block(Vector3i(5, 0, 0)), -1, "越界读取返回 -1")

	# 索引覆盖每个格子（读写往返）
	var chunk2 := ChunkData.new(Vector3i.ZERO, Vector3i(4, 4, 4), 0)
	for ly in 4:
		for lz in 4:
			for lx in 4:
				chunk2.set_block_raw(
					Vector3i(lx, ly, lz), 1 + ((lx + ly + lz) % 4))
	check(not chunk2.data_modified, "生成器填充不标记玩家修改")
	for ly in 4:
		for lz in 4:
			for lx in 4:
				check_eq(
					chunk2.get_block(Vector3i(lx, ly, lz)),
					1 + ((lx + ly + lz) % 4),
					"索引往返: %d,%d,%d" % [lx, ly, lz])

	# 角格修改标脏对角区块（水面角点 2x2 采样跨对角——曾只标 6 面，
	# 对角区块水面角点错位/裂缝；审查发现）
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.chunk_size = 4
	var world := VoxelWorld.new(config, blocks)
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			world.add_chunk(ChunkData.new(
					Vector3i(cx, 0, cz), Vector3i(4, 4, 4), 0))
	# 清全部脏标记后改 (0,0) 角格
	for coord in world.chunks:
		world.chunks[coord].mesh_dirty = false
	world.set_block(Vector3i(0, 1, 0), VoxelTypes.STONE_ID)
	var diag := world.get_chunk(Vector3i(-1, 0, -1))
	var face := world.get_chunk(Vector3i(-1, 0, 0))
	var far := world.get_chunk(Vector3i(1, 0, 1))
	check(diag != null and diag.mesh_dirty, "角格修改标脏对角区块")
	check(face != null and face.mesh_dirty, "面邻区块照常标脏")
	check(far != null and not far.mesh_dirty, "远区块不标脏")
