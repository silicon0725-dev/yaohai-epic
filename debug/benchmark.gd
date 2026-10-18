## 阶段 E 基准套件（开发文档 §10.3、§6.3、§4.1）：
##   godot-4 --headless --path . -s debug/benchmark.gd
## headless 可重复测量（固定种子，取 3 次中位数）：
##   1. 区块生成吞吐（16^3，192 区块）
##   2. 网格构建：面剔除 vs Greedy Meshing（时间/面数/顶点）
##   3. 单区块重网格延迟（编辑一个方块后的重建成本代理）
##   4. 存档写入/读取吞吐（修改过的区块，含压缩）
##   5. 区块尺寸对比：16^3（8x8 列 x2 层）vs 32^3（4x4 列 x1 层），
##      同等世界体积（128x128x32）——32^3 为"垂直大区块"候选的立方体代理
## 注意：统计输出使用成员变量（GDScript lambda 按值捕获局部变量）。
extends SceneTree

const SEED_VALUE := 1337
const REPEATS := 3

# lambda 输出通道（成员变量可跨 lambda 写入）
var stat_faces := 0
var stat_verts := 0
var stat_quads := 0


func _init() -> void:
	print("=== 体素内核基准（Godot %s，%d 核，调试构建）===" % [
		Engine.get_version_info().string, OS.get_processor_count()])
	var registry := VoxelTypes.build_default_registry()

	# ---- 1. 生成吞吐 ----
	var config := WorldConfig.new()
	config.world_seed = SEED_VALUE
	var world := VoxelWorld.new(config, registry)
	var generator := TerrainGenerator.new(config)
	var gen_time := _median(func() -> int:
		world.chunks.clear()
		var started := Time.get_ticks_msec()
		for cz in 8:
			for cx in 8:
				for cy in config.chunks_y:
					world.add_chunk(generator.generate_chunk(Vector3i(cx, cy, cz)))
		return Time.get_ticks_msec() - started)
	print("生成    : %d ms / 192 区块 16^3（%.2f ms/区块）" % [
		gen_time, float(gen_time) / 192.0])

	# ---- 2. 面剔除 vs Greedy ----
	var naive_time := _median(func() -> int:
		stat_faces = 0
		stat_verts = 0
		var started := Time.get_ticks_msec()
		for coord in world.chunks:
			var chunk: ChunkData = world.chunks[coord]
			var arrays := ChunkMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
			stat_faces += arrays["indices"].size() / 6
			stat_verts += arrays["vertices"].size()
		return Time.get_ticks_msec() - started)
	var naive_faces := stat_faces
	var naive_verts := stat_verts
	var greedy_time := _median(func() -> int:
		stat_quads = 0
		stat_verts = 0
		var started := Time.get_ticks_msec()
		for coord in world.chunks:
			var chunk: ChunkData = world.chunks[coord]
			var arrays := GreedyMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
			stat_quads += arrays["quads"]
			stat_verts += arrays["vertices"].size()
		return Time.get_ticks_msec() - started)
	print("面剔除  : %d ms, %d 面, %d 顶点" % [naive_time, naive_faces, naive_verts])
	print("贪心    : %d ms, %d 四边形, %d 顶点（面 %.1f%%，顶点 %.1f%%）" % [
		greedy_time, stat_quads, stat_verts,
		100.0 * stat_quads / naive_faces, 100.0 * stat_verts / naive_verts])

	# ---- 3. 单区块重网格延迟（编辑重建成本代理）----
	var sample_coords: Array = world.chunks.keys().slice(0, 24)
	var remesh_time := _median(func() -> int:
		var started := Time.get_ticks_msec()
		for coord in sample_coords:
			var chunk: ChunkData = world.chunks[coord]
			ChunkMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
		return Time.get_ticks_msec() - started)
	print("重网格  : %d ms / 24 区块（%.2f ms/区块，编辑延迟代理）" % [
		remesh_time, float(remesh_time) / 24.0])

	# ---- 4. 存档吞吐 ----
	var save := WorldSave.new("user://tmp_benchmark", registry)
	save.erase_all()
	save.ensure_dirs()
	var saved_chunks: Array = []
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		var copy := ChunkData.new(chunk.chunk_coord, chunk.dimensions, 2)
		copy.block_ids = chunk.block_ids.duplicate()
		copy.set_block(Vector3i(1, 1, 1), VoxelTypes.BRICKS_ID)  # 标记为已修改
		saved_chunks.append(copy)
	var save_time := _median(func() -> int:
		var started := Time.get_ticks_msec()
		for chunk in saved_chunks:
			save.save_chunk(chunk)
		return Time.get_ticks_msec() - started)
	var load_time := _median(func() -> int:
		var started := Time.get_ticks_msec()
		for chunk in saved_chunks:
			save.load_chunk(chunk.chunk_coord)
		return Time.get_ticks_msec() - started)
	print("存档写  : %d ms / %d 区块（%.2f ms/区块，zstd+原子写）" % [
		save_time, saved_chunks.size(), float(save_time) / saved_chunks.size()])
	print("存档读  : %d ms / %d 区块（%.2f ms/区块）" % [
		load_time, saved_chunks.size(), float(load_time) / saved_chunks.size()])
	save.erase_all()

	# ---- 5. 区块尺寸对比（16^3 vs 32^3，同体积）----
	var small_config := WorldConfig.new()
	small_config.world_seed = SEED_VALUE
	small_config.chunk_size = 16
	small_config.chunks_y = 2
	var small := _run_sized(small_config, registry, 8)
	var big_config := WorldConfig.new()
	big_config.world_seed = SEED_VALUE
	big_config.chunk_size = 32
	big_config.chunks_y = 1
	var big := _run_sized(big_config, registry, 4)
	print("16^3    : 生成 %d ms, 网格 %d ms, %d 面, %d 区块" % [
		small["gen"], small["mesh"], small["faces"], small["count"]])
	print("32^3    : 生成 %d ms, 网格 %d ms, %d 面, %d 区块（垂直大区块的立方体代理）" % [
		big["gen"], big["mesh"], big["faces"], big["count"]])
	quit(0)


func _run_sized(config: WorldConfig, registry: VoxelRegistry, columns: int) -> Dictionary:
	var world := VoxelWorld.new(config, registry)
	var generator := TerrainGenerator.new(config)
	var gen := _median(func() -> int:
		world.chunks.clear()
		var started := Time.get_ticks_msec()
		for cz in columns:
			for cx in columns:
				for cy in config.chunks_y:
					world.add_chunk(generator.generate_chunk(Vector3i(cx, cy, cz)))
		return Time.get_ticks_msec() - started)
	var mesh := _median(func() -> int:
		stat_faces = 0
		var started := Time.get_ticks_msec()
		for coord in world.chunks:
			var chunk: ChunkData = world.chunks[coord]
			var arrays := ChunkMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
			stat_faces += arrays["indices"].size() / 6
		return Time.get_ticks_msec() - started)
	return {"gen": gen, "mesh": mesh, "faces": stat_faces, "count": world.chunks.size()}


func _median(action: Callable) -> int:
	var samples: Array[int] = []
	for i in REPEATS:
		samples.append(int(action.call()))
	samples.sort()
	return samples[samples.size() / 2]
