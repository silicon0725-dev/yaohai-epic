## 探针：面剔除网格器内部耗时拆分（干区块 vs 含水区块）。
extends SceneTree

const ChunkMesherS := preload("res://meshing/chunk_mesher.gd")


func _init() -> void:
	var blocks = VoxelTypes.build_default_registry()
	var config: WorldConfig = WorldConfig.new()
	var gen: TerrainGenerator = TerrainGenerator.new(config)
	# 找一个含水沿海区块 + 一个内陆干区块
	var dry: ChunkData = null
	var wet: ChunkData = null
	for r in range(40):
		var coord := Vector3i(r * 3, 0, r * 3)
		var c: ChunkData = gen.generate_chunk(coord)
		if wet == null and c.block_ids.has(VoxelTypes.WATER_ID):
			wet = c
		elif dry == null and not c.block_ids.has(VoxelTypes.WATER_ID):
			dry = c
		if wet != null and dry != null:
			break
	var world := VoxelWorld.new(config, blocks)
	for c in [dry, wet]:
		world.add_chunk(c)
	var n := 30
	for label in [["dry", dry], ["wet", wet]]:
		var chunk: ChunkData = label[1]
		if chunk == null:
			continue
		var neighbors := world.collect_neighbors(chunk.chunk_coord)
		var t_padded := 0
		var t_tables := 0
		var t_full := 0
		var t_levels := 0
		var t_wateremit := 0
		for i in n:
			var t0 := Time.get_ticks_usec()
			var padded: PackedInt32Array = ChunkMesherS.build_padded_cache(chunk, neighbors)
			t_padded += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			ChunkMesherS.build_lookup_tables(blocks)
			t_tables += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var arrays := ChunkMesherS._build_gd(blocks, chunk, neighbors)
			t_full += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var levels := ChunkMesherS.collect_water_levels_world(chunk, neighbors)
			t_levels += Time.get_ticks_usec() - t0
			var out := {}
			t0 = Time.get_ticks_usec()
			ChunkMesherS.append_water_faces(padded, chunk.dimensions.x + 2,
					out, levels, Vector3i.ZERO)
			t_wateremit += Time.get_ticks_usec() - t0
		print("split=%s padded=%dus tables=%dus full=%dus water_levels=%dus water_emit=%dus rest_loop=%dus" % [
			label[0], t_padded / n, t_tables / n, t_full / n,
			t_levels / n, t_wateremit / n,
			(t_full - t_padded - t_tables - t_levels - t_wateremit) / n])
	quit(0)
