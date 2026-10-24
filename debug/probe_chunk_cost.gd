## 探针：单区块管线各环节耗时（generate / 面剔除 / 贪心 GD 路径）。
extends SceneTree

const ChunkMesherS := preload("res://meshing/chunk_mesher.gd")
const GreedyMesherS := preload("res://meshing/greedy_mesher.gd")


func _init() -> void:
	var blocks = VoxelTypes.build_default_registry()
	var config: WorldConfig = WorldConfig.new()
	var gen: TerrainGenerator = TerrainGenerator.new(config)
	var t_gen := 0
	var t_cull := 0
	var t_greedy := 0
	var n := 24
	var chunks: Array = []
	for i in n:
		var coord := Vector3i((i % 6) * 2 - 6, 0, (i / 6) * 2 - 6)
		var t0 := Time.get_ticks_usec()
		var chunk: ChunkData = gen.generate_chunk(coord)
		t_gen += Time.get_ticks_usec() - t0
		chunk.state = 4  # ACTIVE
		chunks.append(chunk)
	var world := VoxelWorld.new(config, blocks)
	for c in chunks:
		world.add_chunk(c)
	for i in n:
		var chunk: ChunkData = chunks[i]
		var neighbors := world.collect_neighbors(chunk.chunk_coord)
		var t0 := Time.get_ticks_usec()
		ChunkMesherS.build_mesh_arrays(blocks, chunk, neighbors)
		t_cull += Time.get_ticks_usec() - t0
	for i in n:
		var chunk: ChunkData = chunks[i]
		var neighbors := world.collect_neighbors(chunk.chunk_coord)
		var t0 := Time.get_ticks_usec()
		GreedyMesherS._build_gd(blocks, chunk, neighbors)
		t_greedy += Time.get_ticks_usec() - t0
	print("per_chunk_us generate=%d cull_mesh=%d greedy_gd=%d" % [
		t_gen / n, t_cull / n, t_greedy / n])
	quit(0)
