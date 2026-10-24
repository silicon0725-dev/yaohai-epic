## C# 原生地形生成等价测试：同一 (seed, coord) 下 C# 与 GDScript
## 输出逐字节一致（ids + 列剖面 + 树占位终态）。原生不可用跳过。
extends VoxelTestCase

const NativeTerrainBridge := preload("res://meshing/native_terrain_bridge.gd")


func run() -> void:
	if not NativeTerrainBridge.available():
		print("[SKIP] C# 原生地形不可用，跳过等价测试（纯 GDScript 模式）")
		return
	var mismatches := 0
	var checked_chunks := 0
	var heights_mismatch := 0
	# 多种子 × 多区块（含负坐标、跨层 y、含水海岸、山地）
	for seed in [1, 1337, 20241017, 77, 99991]:
		var config := WorldConfig.new()
		config.world_seed = seed
		var gen := TerrainGenerator.new(config)
		for r in 6:
			var coord := Vector3i(r * 5 - 8, r % config.chunks_y, (17 - r * 7))
			# C# 路径（generate_chunk 内部自动选择；显式禁用 native 拿 GD 真值
			# 不可行——桥静态探测，改用直接调原生+GD 填充对照）
			var native := NativeTerrainBridge.generate_chunk(
					seed, config.world_height_blocks(), coord, config.chunk_size)
			check(not native.is_empty(), "seed %d 原生结果非空" % seed)
			if native.is_empty():
				continue
			checked_chunks += 1
			# GD 真值：列剖面 + 填充（_fill_columns_gd 与 C# 的对照面）
			var chunk := ChunkData.new(coord,
					Vector3i(config.chunk_size, config.chunk_size,
							config.chunk_size), 6)
			var origin := VoxelCoords.chunk_origin(coord, config.chunk_size)
			gen._fill_columns_gd(chunk, origin, config.chunk_size)
			var ids: PackedInt32Array = native["ids"]
			var gd_ids: PackedInt32Array = chunk.block_ids
			if ids.size() != gd_ids.size():
				mismatches += 1
				check(false, "seed %d %s：ids 长度（%d vs %d）" % [
					seed, coord, ids.size(), gd_ids.size()])
				continue
			var diff := 0
			for i in ids.size():
				if ids[i] != gd_ids[i]:
					diff += 1
			if diff > 0:
				mismatches += 1
				check(false, "seed %d %s：ids 逐字节（%d 格差异）" % [
					seed, coord, diff])
			# 列剖面数组
			var heights: PackedInt32Array = native["heights"]
			var sandy: PackedByteArray = native["sandy"]
			var rocky: PackedByteArray = native["rocky"]
			var prof_diff := 0
			for lz in config.chunk_size:
				for lx in config.chunk_size:
					var p := gen.column_profile(origin.x + lx, origin.z + lz)
					var pidx := lz * config.chunk_size + lx
					if heights[pidx] != p["height"] \
							or (sandy[pidx] == 1) != p["sandy"] \
							or (rocky[pidx] == 1) != p["rocky"]:
						prof_diff += 1
			if prof_diff > 0:
				heights_mismatch += 1
				check(false, "seed %d %s：列剖面（%d 列差异）" % [
					seed, coord, prof_diff])
	check(checked_chunks >= 25, "等价覆盖区块数足够（%d）" % checked_chunks)
	check(mismatches == 0, "C#/GD ids 全部逐字节一致（%d/%d 区块不一致）" % [
		mismatches, checked_chunks])
	check(heights_mismatch == 0, "C#/GD 列剖面全部一致（%d 区块不一致）" % [
		heights_mismatch])
	# 端到端：generate_chunk（native 路径）与 GD 回退路径的完整终态
	#（含树占位与 states）一致——用 VOXEL_NO_NATIVE 的方式不可行，
	# 直接比对两实例：一个走默认（native 可用）、一个注入禁用标志。
	# 禁用方式：临时环境变量会影响静态缓存，改为构造后直接调
	# _fill_columns_gd + _scatter_trees 模拟 GD 全程。
	for seed in [1337, 77]:
		var config := WorldConfig.new()
		config.world_seed = seed
		var gen := TerrainGenerator.new(config)
		for coord in [Vector3i(3, 0, -2), Vector3i(-5, 1, 4)]:
			var chunk_native: ChunkData = gen.generate_chunk(coord)
			var chunk_gd := ChunkData.new(coord,
					Vector3i(config.chunk_size, config.chunk_size,
							config.chunk_size), 6)
			var origin := VoxelCoords.chunk_origin(coord, config.chunk_size)
			gen._fill_columns_gd(chunk_gd, origin, config.chunk_size)
			gen._scatter_trees(chunk_gd, {})
			check(chunk_native.block_ids == chunk_gd.block_ids,
					"seed %d %s：完整终态 ids 一致（含树占位）" % [seed, coord])
			var n_states := 0
			for k in chunk_gd.sparse_block_states:
				if chunk_native.sparse_block_states.get(k, {}) != chunk_gd.sparse_block_states[k]:
					n_states += 1
			check(n_states == 0, "seed %d %s：radius 状态一致（%d 差异）" % [
				seed, coord, n_states])
	print("[INFO] 原生地形等价覆盖 %d 区块" % checked_chunks)
