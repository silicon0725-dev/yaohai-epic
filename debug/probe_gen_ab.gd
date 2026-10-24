extends SceneTree
const Bridge := preload("res://meshing/native_terrain_bridge.gd")
func _init() -> void:
	var config := WorldConfig.new()
	config.world_seed = 1337
	var gen := TerrainGenerator.new(config)
	var coords: Array = []
	for i in 24:
		coords.append(Vector3i((i % 6) * 2 - 6, 0, (i / 6) * 2 - 6))
	# 预热（JIT + 噪声构建 + 桥缓存）
	for c in coords:
		gen.generate_chunk(c)
	# native 稳态
	var t0 := Time.get_ticks_usec()
	for c in coords:
		gen.generate_chunk(c)
	var t_native := (Time.get_ticks_usec() - t0) / coords.size()
	# GD 真值稳态（_fill_columns_gd + _scatter_trees 原路径）
	var t1 := Time.get_ticks_usec()
	for c in coords:
		var chunk := ChunkData.new(c, Vector3i(16, 16, 16), 6)
		var origin := VoxelCoords.chunk_origin(c, 16)
		gen._fill_columns_gd(chunk, origin, 16)
		gen._scatter_trees(chunk, {})
	var t_gd := (Time.get_ticks_usec() - t1) / coords.size()
	print("gen_ab native_total=%dus gd_total=%dus" % [t_native, t_gd])
	# 拆分：纯填充 vs 树重放
	var t2 := Time.get_ticks_usec()
	for c in coords:
		Bridge.generate_chunk(1337, config.world_height_blocks(), c, 16)
	var t_fill_cs := (Time.get_ticks_usec() - t2) / coords.size()
	print("gen_ab cs_fill_only=%dus" % t_fill_cs)
	quit(0)
