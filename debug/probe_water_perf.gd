## B1 回归探针（审查二轮）：3×3 水源溃坝的 tick 耗时（开光照）。
## 基线（块级脏集合化前）：p50 137.8ms / p90 493.9 / max 950.4ms，
## 12 tick 合计 2613.6ms，光照占 95.6%——目标 p50 <25ms / max <60ms。
## 用法：<exe> --headless --path . -s debug/probe_water_perf.gd
extends SceneTree

const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")


func _init() -> void:
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	var world := VoxelWorld.new(config, blocks)
	# 5×5×3 块：y∈[0,2) 石底，其余空气（源在中央块）
	for cx in 5:
		for cz in 5:
			for cy in 3:
				var chunk := ChunkData.new(
						Vector3i(cx - 2, cy, cz - 2),
						Vector3i(16, 16, 16), 1)
				for x in 16:
					for z in 16:
						for y in 2:
							chunk.set_block_raw(Vector3i(x, y, z),
									VoxelTypes.STONE_ID)
				world.add_chunk(chunk)
	# 光照（B1 的放大器就是它——必须开）
	var light: Node = VoxelLightScript.new()
	light.setup(world)
	for coord in world.chunks.keys():
		var chunk_l: ChunkData = world.chunks[coord]
		var nbs := []
		for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			nbs.append(world.get_chunk(coord + d))
		light.init_chunk_light(chunk_l, nbs)
	# 3×3 水源在中央块上空（无 level 状态 = 无限源——带状态会被
	# 扩散消耗排干，曾误写成有限高压水全消失，sanity 抓到）
	var flow := WaterFlow.new()
	flow.setup(world)
	for dx in 3:
		for dz in 3:
			world.set_block(Vector3i(24 + dx, 2, 24 + dz),
					VoxelTypes.WATER_ID, false)
	# 模拟循环：每 tick 计时（tick 后跑一帧光照 drain 的等效量——
	# headless SceneTree 无自动 _process，用 flush 显式计入该帧成本）
	var samples: Array[float] = []
	var total_changes := 0
	for i in 12:
		var t0 := Time.get_ticks_usec()
		flow.tick()
		light.flush()  # 把本 tick 攒下的光照脏块全部算完（最坏帧成本）
		samples.append((Time.get_ticks_usec() - t0) * 0.001)
	samples.sort()
	var p50: float = samples[6]
	var p90: float = samples[int(12 * 0.9) - 1]
	var mx: float = samples[11]
	var sum: float = 0.0
	for s in samples:
		sum += s
	print("water_tick_ms p50=%.1f p90=%.1f max=%.1f total_12=%.1f" % [
			p50, p90, mx, sum])
	# sanity：溃坝确实扩散过（末态水格数远超 9 格源，防"水没流"假绿）
	var water_cells := 0
	for chunk_w in world.chunks.values():
		if chunk_w.has_water:
			for idx in chunk_w.block_ids.size():
				if chunk_w.block_ids[idx] == VoxelTypes.WATER_ID:
					water_cells += 1
	print("water_cells_final=%d (源 9)" % water_cells)
	print("B1_TARGET: p50<25 and max<60 and water>50 -> %s" % (
			"PASS" if p50 < 25.0 and mx < 60.0 and water_cells > 50
			else "FAIL"))
	light.free()
	flow.free()
	quit(0)
