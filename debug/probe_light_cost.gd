## 光照成本探针：全量初始化 ms/块 与增量 BFS（挖掘/放置）耗时。
## headless：godot --headless --path . -s debug/probe_light_cost.gd
## 采样真实地形区块（与 perf 基准同 seed），各测 3 轮取中位。
extends SceneTree

const CHUNK := 16


func _init() -> void:
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 1337
	var world := VoxelWorld.new(config, registry)
	var generator := TerrainGenerator.new(config)
	var light: Node = load("res://systems/lighting/voxel_light.gd").new()
	# setup 连接 block_changed——增量路径必须经信号驱动（曾漏 setup，
	# 增量计时全部失真为纯 set_block 成本）
	light.setup(world)

	# 生成 3x3 列（真实地形，含树/水）
	var coords: Array[Vector3i] = []
	for cz in 3:
		for cy in config.chunks_y:
			for cx in 3:
				var coord := Vector3i(cx, cy, cz)
				world.add_chunk(generator.generate_chunk(coord))
				coords.append(coord)
	print("区块数 %d（3x3 列）" % coords.size())

	# 1) 全量初始化（含邻块种子；逐块计时）
	var times: Array[float] = []
	for coord in coords:
		var six := _six(world, coord)
		var t0 := Time.get_ticks_usec()
		light.init_chunk_light(world.get_chunk(coord), six)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	print("init_chunk_light: p50=%.2fms max=%.2fms（n=%d）" % [
			times[times.size() / 2], times[-1], times.size()])

	# 2) 增量：挖开/堵回一串格（中心块洞穴场景）
	var dig_ms: Array[float] = []
	for i in 30:
		var pos := Vector3i(24 - 16 + 8, 40, 24 - 16 + 8) + Vector3i(i % 3, i / 3 % 3, i / 9)
		var t0 := Time.get_ticks_usec()
		world.set_block(pos, VoxelTypes.AIR_ID)
		dig_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		world.set_block(pos, VoxelTypes.STONE_ID)
	dig_ms.sort()
	print("增量 set_block(挖+堵): p50=%.3fms max=%.3fms（n=%d，含存档/失效开销）" % [
			dig_ms[dig_ms.size() / 2], dig_ms[-1], dig_ms.size()])
	quit(0)


func _six(world: VoxelWorld, coord: Vector3i) -> Array:
	var dirs := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	var out := []
	for d in dirs:
		out.append(world.get_chunk(coord + d))
	return out
