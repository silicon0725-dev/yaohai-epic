## 探针：C# vs GDScript 网格器 A/B（同输入，含桥接成本）。
extends SceneTree

const NativeBridgeS := preload("res://meshing/native_mesh_bridge.gd")
const GreedyMesherS := preload("res://meshing/greedy_mesher.gd")
const ChunkMesherS := preload("res://meshing/chunk_mesher.gd")


func _init() -> void:
	print("native_available=", NativeBridgeS.available())
	var blocks = VoxelTypes.build_default_registry()
	var config: WorldConfig = WorldConfig.new()
	var gen: TerrainGenerator = TerrainGenerator.new(config)
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
	var n := 20
	for label in [["dry", dry], ["wet", wet]]:
		var chunk: ChunkData = label[1]
		if chunk == null:
			continue
		var neighbors := world.collect_neighbors(chunk.chunk_coord)
		var t_greedy_gd := 0
		var t_greedy_cs := 0
		var t_cull_gd := 0
		var t_cull_cs := 0
		var t_bridge_only := 0
		for i in n:
			var t0 := Time.get_ticks_usec()
			GreedyMesherS._build_gd(blocks, chunk, neighbors)
			t_greedy_gd += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var r1 = NativeBridgeS.build(true, blocks, chunk, neighbors)
			t_greedy_cs += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			ChunkMesherS._build_gd(blocks, chunk, neighbors)
			t_cull_gd += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var r2 = NativeBridgeS.build(false, blocks, chunk, neighbors)
			t_cull_cs += Time.get_ticks_usec() - t0
		print("ab=%s greedy_gd=%dus greedy_cs(含桥)=%dus cull_gd=%dus cull_cs(含桥)=%dus" % [
			label[0], t_greedy_gd / n, t_greedy_cs / n, t_cull_gd / n, t_cull_cs / n])
	quit(0)
