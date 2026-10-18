## Stage C 世界统计（headless 冒烟检查，开发文档 §11 手工验收辅助）：
##   godot-4 --headless --path . -s debug/world_stats.gd
## 生成 6x6 列（0..95 x 0..95，种子 1337）并网格化，输出面数统计。
## 注意：生成算法 v2（沙地 + 矿物）起地形已变化，
## Stage B 时代的 19994 面锚点仅适用于 v1 地形，历史参考。
extends SceneTree

const WORLD_SEED := 1337
const COLUMNS := 6


func _init() -> void:
	var config := WorldConfig.new()
	config.world_seed = WORLD_SEED
	var world := VoxelWorld.new(config, VoxelTypes.build_default_registry())
	var generator := TerrainGenerator.new(config)

	var started := Time.get_ticks_msec()
	for cz in COLUMNS:
		for cx in COLUMNS:
			for cy in config.chunks_y:
				world.add_chunk(generator.generate_chunk(Vector3i(cx, cy, cz)))
	var gen_ms := Time.get_ticks_msec() - started

	started = Time.get_ticks_msec()
	var faces := 0
	var non_empty_chunks := 0
	for chunk_coord in world.chunks:
		var chunk: ChunkData = world.chunks[chunk_coord]
		var arrays := ChunkMesher.build_mesh_arrays(
				world.registry, chunk, world.collect_neighbors(chunk_coord))
		var chunk_faces: int = arrays["indices"].size() / 6
		faces += chunk_faces
		if chunk_faces > 0:
			non_empty_chunks += 1
	var mesh_ms := Time.get_ticks_msec() - started

	print("区域: %d x %d 列（每列 %d 区块，每区块 %d^3）" % [
		COLUMNS, COLUMNS, config.chunks_y, config.chunk_size])
	print("种子: %d  生成版本: %d" % [
		config.world_seed, TerrainGenerator.GENERATOR_VERSION])
	print("区块总数: %d（含可见几何: %d）" % [
		world.chunk_count(), non_empty_chunks])
	print("可见面总数: %d（生成 v%d 地形）" % [
		faces, TerrainGenerator.GENERATOR_VERSION])
	print("耗时: 生成 %d ms，网格构建 %d ms（同步，主线程）" % [gen_ms, mesh_ms])
	quit(0)
