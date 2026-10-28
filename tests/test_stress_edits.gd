## 编辑与网格 worker 并发的压力回归：主线程随机改水/放挖方块的
## 同时派发网格任务。水位表快照化之前，worker 遍历
## sparse_block_states Dictionary 与主线程水位 tick 增删并发是
## 哈希表损坏的崩溃向量（审查发现）；本套件做无崩溃 + 终态确定性
## 两项断言。
extends VoxelTestCase


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入（runner 需设置 suite.tree_root）")
		return
	var config := WorldConfig.new()
	config.world_seed = 77
	var registry := VoxelTypes.build_default_registry()
	var world := VoxelWorld.new(config, registry)
	var gen := TerrainGenerator.new(config)
	var renderer := ChunkRenderer.new()
	renderer.setup(world, null)
	tree_root.add_child(renderer)
	var manager := ChunkManager.new()
	tree_root.add_child(manager)
	manager.setup(world, registry, gen, renderer)

	# 近原点加载 4 列（_is_wanted 以原点为焦点中心，保证任务被采纳）
	var columns := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	for c in columns:
		manager.load_column_now(c)
	# 选一个含水列（保证 sparse 水位字典非空参与压力）
	var water_col: Vector2i = columns[0]
	for c in columns:
		var found := false
		for y in 16:
			if world.get_block(Vector3i(c.x * 16 + 8, y, c.y * 16 + 8)) \
					== VoxelTypes.WATER_ID:
				water_col = c
				found = true
				break
		if found:
			break

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var chunk_coords: Array[Vector3i] = []
	for c in columns:
		for y in config.chunks_y:
			chunk_coords.append(Vector3i(c.x, y, c.y))

	# 压力主体：派发任务（worker 开跑）→ 立即在主线程密集改写
	# 水位状态与方块（sparse 字典增删）→ 回收完成者，循环
	for round_i in 40:
		for cc in chunk_coords:
			if world.has_chunk(cc):
				manager._enqueue_mesh(cc)
		for j in 25:
			var c: Vector2i = columns[rng.randi_range(0, columns.size() - 1)]
			var pos := Vector3i(
					c.x * 16 + rng.randi_range(0, 15),
					rng.randi_range(1, 14),
					c.y * 16 + rng.randi_range(0, 15))
			match rng.randi_range(0, 2):
				0:
					world.set_block(pos, VoxelTypes.WATER_ID, false)
					world.set_block_state(pos, "level",
							rng.randi_range(1, 8), true)
				1:
					world.set_block(pos, VoxelTypes.AIR_ID, false)
				_:
					world.set_block(pos, VoxelTypes.STONE_ID, false)
		manager._poll_jobs()
	# 全部任务回收（预算限流：逐个 wait + poll 直到在册清空）
	for i in 600:
		if manager.is_idle():
			break
		if manager._mesh_jobs.size() > 0:
			WorkerThreadPool.wait_for_task_completion(
					manager._mesh_jobs.keys()[0])
		elif manager._gen_jobs.size() > 0:
			WorkerThreadPool.wait_for_task_completion(
					manager._gen_jobs.keys()[0])
		manager._poll_jobs()
	check(true, "并发压力 40 轮无崩溃（worker 与水位 tick 并发）")

	# 终态确定性：同数据两次构建逐字节一致（hash 比对）
	var c0 := Vector3i(water_col.x, 0, water_col.y)
	var chunk: ChunkData = world.get_chunk(c0)
	if chunk != null:
		var nb := world.collect_neighbors(c0)
		var a := ChunkMesher.build_mesh_arrays(registry, chunk, nb)
		var b := ChunkMesher.build_mesh_arrays(registry, chunk, nb)
		check(a.hash() == b.hash(), "终态确定性：两次构建一致")
	manager.free()
	renderer.free()
