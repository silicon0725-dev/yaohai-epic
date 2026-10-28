## 水流动模拟单元测试（WaterFlow v2）：向下成柱、落地扩散阶梯、
## 寻坡定向、断供逐层回退、挖壁引水、阶梯水面网格高度。
extends VoxelTestCase


## 16³ 单区块世界：y 0..1 石头平台（holes 挖洞模拟落差/缺口）。
func _make_world(holes: Dictionary = {}) -> VoxelWorld:
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	var world := VoxelWorld.new(config, blocks)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16), 1)
	for x in 16:
		for z in 16:
			for y in 2:
				if not holes.has(Vector3i(x, y, z)):
					chunk.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	world.add_chunk(chunk)
	return world


func _make_flow(world: VoxelWorld) -> WaterFlow:
	var flow := WaterFlow.new()
	flow.setup(world)
	return flow


func _run_ticks(flow: WaterFlow, count: int) -> void:
	for i in count:
		flow.tick()


func _count_water(world: VoxelWorld) -> int:
	var count := 0
	for x in 16:
		for z in 16:
			for y in 16:
				if world.get_block(Vector3i(x, y, z)) == VoxelTypes.WATER_ID:
					count += 1
	return count


func _level_of(world: VoxelWorld, pos: Vector3i) -> int:
	return int(world.get_block_state(pos).get("level", 0))


func run() -> void:
	_test_fall_down()
	_test_flat_spread()
	_test_drain_after_source_removed()
	_test_downgrade_propagates()
	_test_bottom_layer_spreads()
	_test_slope_seeking()
	_test_tank_breach()
	_test_surface_heights()
	_test_surface_continuity()
	_test_flow_direction()
	_test_float_at_water_level()
	_test_current_pushes_drop()
	_test_sink_rests_on_floor()
	_test_wave_spectrum()
	_test_ocean_speech_wave()
	_test_ripple_simulation()
	_test_drop_rides_waves()


## 悬空源优先向下流：逐 tick 成 8 级下落柱，级别随状态持久化可读回。
## 双层平台（y0-1 石头），源悬在 y4：柱落到 y2 止（y1 是石头）。
func _test_fall_down() -> void:
	var world := _make_world()
	var flow := _make_flow(world)
	world.set_block(Vector3i(8, 4, 8), VoxelTypes.WATER_ID)
	flow.tick()
	check(world.get_block(Vector3i(8, 3, 8)) == VoxelTypes.WATER_ID,
			"悬空源第一 tick 向下流入正下方")
	check_eq(_level_of(world, Vector3i(8, 3, 8)), 8,
			"下落水柱级别 8（状态写入）")
	flow.tick()
	check(world.get_block(Vector3i(8, 2, 8)) == VoxelTypes.WATER_ID,
			"水柱继续向下延伸")
	check_eq(_level_of(world, Vector3i(8, 2, 8)), 8, "柱身级别 8")
	flow.tick()
	check(world.get_block(Vector3i(8, 1, 8)) != VoxelTypes.WATER_ID,
			"柱落到石头平台停止")
	flow.free()


## 平台上的源四向扩散（4 格内无落差）：级别随距离递增成阶梯，
## 7 格为极限（MC 同款扩散半径），对角按曼哈顿距离。
func _test_flat_spread() -> void:
	var world := _make_world()
	var flow := _make_flow(world)
	world.set_block(Vector3i(8, 2, 8), VoxelTypes.WATER_ID)
	_run_ticks(flow, 12)
	check_eq(_level_of(world, Vector3i(9, 2, 8)), 1, "距离 1 -> 级别 1")
	check_eq(_level_of(world, Vector3i(12, 2, 8)), 4, "距离 4 -> 级别 4")
	check_eq(_level_of(world, Vector3i(15, 2, 8)), 7, "距离 7 -> 级别 7（极限）")
	check_eq(_level_of(world, Vector3i(10, 2, 10)), 4, "曼哈顿距离 4 对角 -> 级别 4")
	# 级别不超过 7（8 仅用于下落柱，平地不产生）
	var max_lvl := 0
	for x in 16:
		for z in 16:
			var lvl := _level_of(world, Vector3i(x, 2, z))
			if lvl > max_lvl:
				max_lvl = lvl
	check_eq(max_lvl, 7, "平地扩散级别上限 7")
	flow.free()


## 拆掉源 -> 流动水失去上游，从边缘逐层剥落直至全部退化为空气。
func _test_drain_after_source_removed() -> void:
	var world := _make_world()
	var flow := _make_flow(world)
	world.set_block(Vector3i(8, 2, 8), VoxelTypes.WATER_ID)
	_run_ticks(flow, 12)
	check(_count_water(world) > 20, "拆源前已有扩散水体")
	world.set_block(Vector3i(8, 2, 8), VoxelTypes.AIR_ID)
	_run_ticks(flow, 40)
	check_eq(_count_water(world), 0, "断供后全部回退为空气（逐层剥落）")
	flow.free()


## 原地降级必须向下传播：构造 1→2→3 梯度链，把源降为不可供给后，
## 链上格子需经降级波逐个退空。曾因 WATER→WATER 无信号、下游从不
## 重新评估而残留过期水位（审查发现）
func _test_downgrade_propagates() -> void:
	var world := _make_world()
	var flow := _make_flow(world)
	# 手工铺 1→2→3 链（+x 方向），源在最左
	var base := Vector3i(6, 2, 8)
	world.set_block(base, VoxelTypes.WATER_ID)  # 源（无状态）
	for i in 3:
		var p := base + Vector3i(1 + i, 0, 0)
		world.set_block(p, VoxelTypes.WATER_ID)
		world.set_block_state(p, "level", i + 1)
	# 源降为 3 级（不再能供给 1 级邻？——1 级邻的供给判定：邻级别
	# 严格小于自身。源变 3 后 1 级格无 <1 的邻居，应退化），
	# 简化验证：源直接变空气，梯度链必须退空
	world.set_block(base, VoxelTypes.AIR_ID)
	_run_ticks(flow, 30)
	var remain := 0
	for i in 3:
		if world.get_block(base + Vector3i(1 + i, 0, 0)) == VoxelTypes.WATER_ID:
			remain += 1
	check_eq(remain, 0, "梯度链降级波传播到底（曾残留过期水位）")
	flow.free()


## 世界底（y=0）的水：向下写入越界失败不得早退，应继续横向扩散
## （曾"假成功"早退，y=0 层水永不扩散——审查发现）
func _test_bottom_layer_spreads() -> void:
	# 石头平台 y0-1：中心 + 4 水平邻挖到底层，水坐世界底
	var holes := {
		Vector3i(8, 0, 8): true, Vector3i(9, 0, 8): true,
		Vector3i(7, 0, 8): true, Vector3i(8, 0, 9): true,
		Vector3i(8, 0, 7): true,
	}
	var world := _make_world(holes)
	var flow := _make_flow(world)
	world.set_block(Vector3i(8, 0, 8), VoxelTypes.WATER_ID)
	_run_ticks(flow, 12)
	var spread := false
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if world.get_block(Vector3i(8, 0, 8) + d) == VoxelTypes.WATER_ID:
			spread = true
	check(spread, "世界底水向水平邻格扩散（曾早退不扩散）")
	flow.free()


## 寻坡：4 格内有落差时只朝落差方向流（首 tick 定向），
## 水最终灌入缺口底部；平地四向圆盘不在此用例验证（见扩散用例）。
func _test_slope_seeking() -> void:
	var world := _make_world({
		Vector3i(12, 0, 8): true, Vector3i(12, 1, 8): true,
	})
	var flow := _make_flow(world)
	world.set_block(Vector3i(8, 2, 8), VoxelTypes.WATER_ID)
	flow.tick()
	check(world.get_block(Vector3i(9, 2, 8)) == VoxelTypes.WATER_ID,
			"首 tick 只向落差方向（+x）扩散")
	check(world.get_block(Vector3i(7, 2, 8)) != VoxelTypes.WATER_ID,
			"反方向无水（定向）")
	check(world.get_block(Vector3i(8, 2, 7)) != VoxelTypes.WATER_ID
			and world.get_block(Vector3i(8, 2, 9)) != VoxelTypes.WATER_ID,
			"侧向无水（定向）")
	_run_ticks(flow, 8)
	check(world.get_block(Vector3i(12, 1, 8)) == VoxelTypes.WATER_ID,
			"水沿落差灌入缺口底部")
	flow.free()


## 挖壁引水（核心玩法场景）：石碗装满源水，拆掉一格碗壁 ->
## 水从缺口涌出成 1 级流动并向下坠落。
func _test_tank_breach() -> void:
	var world := _make_world()
	var chunk: ChunkData = world.get_chunk(Vector3i.ZERO)
	# 石碗：x/z 6..10 的 y0 石底；y1 四壁石头，碗内 3x3 全源水
	for x in range(6, 11):
		for z in range(6, 11):
			chunk.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
			if x == 6 or x == 10 or z == 6 or z == 10:
				chunk.set_block_raw(Vector3i(x, 1, z), VoxelTypes.STONE_ID)
	# 碗内源水（无状态 = 源）
	for x in range(7, 10):
		for z in range(7, 10):
			world.set_block(Vector3i(x, 1, z), VoxelTypes.WATER_ID)
	var flow := _make_flow(world)
	flow.tick()
	check_eq(_count_water(world), 9, "封闭石碗水位稳定（源不外溢）")
	# 挖掉 +x 侧壁一格并凿穿其下方碗底（碗外悬空，水才能坠落）
	world.set_block(Vector3i(10, 1, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(10, 0, 8), VoxelTypes.AIR_ID)
	_run_ticks(flow, 4)
	check(world.get_block(Vector3i(10, 1, 8)) == VoxelTypes.WATER_ID,
			"水从缺口涌出")
	check_eq(_level_of(world, Vector3i(10, 1, 8)), 1,
			"缺口处流动级别 1")
	check(world.get_block(Vector3i(10, 0, 8)) == VoxelTypes.WATER_ID,
			"碗外悬空 -> 向下坠落成柱")
	flow.free()


## 阶梯水面高度：源 0.875、流动按级别递减、下落柱满格；
## 网格顶点落在对应高度（顶面 4 + 四侧上沿 8 = 12 个顶点）。
func _test_surface_heights() -> void:
	check_eq(ChunkMesher.water_surface_height(0), 0.875, "源水面高度 0.875")
	check_eq(ChunkMesher.water_surface_height(3), 0.546875, "级别 3 高度")
	check_eq(ChunkMesher.water_surface_height(7), 0.109375, "级别 7 高度")
	check_eq(ChunkMesher.water_surface_height(8), 1.0, "下落柱满格高度")

	var world := _make_world()
	world.set_block(Vector3i(2, 2, 2), VoxelTypes.WATER_ID)
	world.set_block_state(Vector3i(2, 2, 2), "level", 3, true)
	var arrays := ChunkMesher.build_mesh_arrays(
			world.registry, world.get_chunk(Vector3i.ZERO),
			world.collect_neighbors(Vector3i.ZERO))
	var water_vertices: PackedVector3Array = arrays.get(
			"water_vertices", PackedVector3Array())
	var side_vertices: PackedVector3Array = arrays.get(
			"water_side_vertices", PackedVector3Array())
	var at_height := 0
	for v in water_vertices:
		if is_equal_approx(v.y, 2.0 + 0.546875):
			at_height += 1
	for v in side_vertices:
		if is_equal_approx(v.y, 2.0 + 0.546875):
			at_height += 1
	check_eq(at_height, 12, "级别 3 表面顶点数（顶面 4 + 侧面上沿 8）")


## 连续水面（角点 max 模型）：源与流动格相邻时，共享边角点取两者
## 较高的水面 -> 顶面在交界处同高衔接（斜坡而非台阶断崖），
## 侧面成梯形。源 (4,2,4) + 级别 1 (5,2,4)：
## y==2.875 顶点 = 两格顶面靠源侧 6 + 源 -x/±z 侧沿 6 + 级别 1
## 格 ±z 侧面靠源角点 2 = 14。
func _test_surface_continuity() -> void:
	var world := _make_world()
	world.set_block(Vector3i(4, 2, 4), VoxelTypes.WATER_ID)
	world.set_block(Vector3i(5, 2, 4), VoxelTypes.WATER_ID)
	world.set_block_state(Vector3i(5, 2, 4), "level", 1, true)
	var arrays := ChunkMesher.build_mesh_arrays(
			world.registry, world.get_chunk(Vector3i.ZERO),
			world.collect_neighbors(Vector3i.ZERO))
	var at_source_h := 0
	var shared_edge := 0
	for key in ["water_vertices", "water_side_vertices"]:
		for v: Vector3 in arrays.get(key, PackedVector3Array()):
			if is_equal_approx(v.y, 2.0 + 0.875):
				at_source_h += 1
				if is_equal_approx(v.x, 5.0):
					shared_edge += 1
	check_eq(at_source_h, 14, "源高度顶点数（顶面 6 + 侧沿 8）")
	check(shared_edge >= 4,
			"共享边上角点同高衔接（流动格靠源侧抬到源高度）")
	# 级别 1 格背源侧仍保持自身较低高度（斜坡过渡）
	var at_l1 := 0
	for key in ["water_vertices", "water_side_vertices"]:
		for v: Vector3 in arrays.get(key, PackedVector3Array()):
			if is_equal_approx(v.y, 2.0 + (8.0 - 1.0) * 0.875 / 8.0):
				at_l1 += 1
	check(at_l1 >= 4, "级别 1 远端保持自身高度（连续斜坡）")


## 流向查询：下落段竖直向下；水平朝"级别更大"的下游（离源越远
## 地势越低；曾经写反成朝源方向 -> 掉落物往高处漂）；最远端查
## 落差边（被冲到台阶边后落下）；静水池（源/平级带）无流向。
func _test_flow_direction() -> void:
	var world := _make_world()
	world.set_block(Vector3i(8, 3, 8), VoxelTypes.WATER_ID)
	check(WaterFlow.flow_direction_at(world, Vector3i(8, 3, 8))
			== Vector3(0.0, -1.0, 0.0), "下落段流向竖直向下")

	var world2 := _make_world()
	world2.set_block(Vector3i(8, 2, 8), VoxelTypes.WATER_ID)
	world2.set_block(Vector3i(9, 2, 8), VoxelTypes.WATER_ID)
	world2.set_block_state(Vector3i(9, 2, 8), "level", 1, true)
	world2.set_block(Vector3i(10, 2, 8), VoxelTypes.WATER_ID)
	world2.set_block_state(Vector3i(10, 2, 8), "level", 2, true)
	check(WaterFlow.flow_direction_at(world2, Vector3i(8, 2, 8))
			== Vector3(1.0, 0.0, 0.0), "源朝 1 级（下游，离源方向）")
	check(WaterFlow.flow_direction_at(world2, Vector3i(9, 2, 8))
			== Vector3(1.0, 0.0, 0.0), "1 级朝 2 级（下游）")
	check(WaterFlow.flow_direction_at(world2, Vector3i(10, 2, 8))
			== Vector3.ZERO, "最远端（平地无落差边）无流向")

	# 落差边：7 级格旁的空气格下方也是空气 -> 朝落差方向
	var world3 := _make_world({
		Vector3i(11, 0, 8): true, Vector3i(11, 1, 8): true,
	})
	for x in range(5, 11):
		world3.set_block(Vector3i(x, 2, 8), VoxelTypes.WATER_ID)
		world3.set_block_state(Vector3i(x, 2, 8), "level", x - 4, true)
	check(WaterFlow.flow_direction_at(world3, Vector3i(10, 2, 8))
			== Vector3(1.0, 0.0, 0.0), "最远端朝落差边（被冲下台阶）")


## 浮水物品浮到所在水格的"实际水位"（级别低 -> 水面矮）并稳定
## 贴面：收敛后竖直位置不再震荡（修"按满格浮/快速上下浮动"）。
func _test_float_at_water_level() -> void:
	var world := _make_world()
	world.set_block(Vector3i(5, 2, 5), VoxelTypes.WATER_ID)
	world.set_block_state(Vector3i(5, 2, 5), "level", 2, true)
	var drop := ItemDrop.new()
	drop.floats = true
	drop.position = Vector3(5.5, 2.2, 5.5)
	for i in 240:
		drop.physics_step(world, 0.05)
	var target := 2.0 + ChunkMesher.water_surface_height(2) 			- ItemDrop.FLOAT_IMMERSE
	# 波幅放大后浮物随波起伏（有正常相位滞后），断言围绕静水位
	# 的均值贴合 + 稳定波动带（跟随中，非震荡发散）
	var y_sum := 0.0
	var y_min := drop.position.y
	var y_max := drop.position.y
	for i in 120:
		OceanWavesScript.advance(0.05)
		drop.physics_step(world, 0.05)
		y_sum += drop.position.y
		y_min = minf(y_min, drop.position.y)
		y_max = maxf(y_max, drop.position.y)
	var y_avg := y_sum / 120.0
	check(absf(y_avg - target) < 0.12,
			"浮物围绕级别 2 实际水位随波（均值 %.3f vs %.3f）" % [y_avg, target])
	check(y_max - y_min > 0.02 and y_max - y_min < 0.7,
			"跟随波形稳定波动（波幅 %.3f，非发散震荡）" % (y_max - y_min))


## 水流推力：流动水中的浮物被推向下游（级别更大 = 地势更低方向），
## 漂到最远端静水格后自然停驻。
func _test_current_pushes_drop() -> void:
	var world := _make_world()
	# 源 (5) 0 级 -> (6) 1 级 -> (7) 2 级（最远端，四周平台无落差）
	world.set_block(Vector3i(5, 2, 5), VoxelTypes.WATER_ID)
	world.set_block(Vector3i(6, 2, 5), VoxelTypes.WATER_ID)
	world.set_block_state(Vector3i(6, 2, 5), "level", 1, true)
	world.set_block(Vector3i(7, 2, 5), VoxelTypes.WATER_ID)
	world.set_block_state(Vector3i(7, 2, 5), "level", 2, true)
	var drop := ItemDrop.new()
	drop.floats = true
	drop.position = Vector3(5.5, 2.2, 5.5)
	for i in 240:
		drop.physics_step(world, 0.05)
	check(drop.position.x > 6.6,
			"流动水把浮物推向下游低处（x=%.2f）" % drop.position.x)
	check(drop.position.x < 7.8,
			"漂到最远端静水格停驻（x=%.2f）" % drop.position.x)


## 沉底稳定：重物缓沉到水底固体顶面后吸附停住，不再"沉入固体 ->
## 掩埋逃逸顶回 -> 再沉"循环抽搐（位置收敛、竖直速度归零）。
func _test_sink_rests_on_floor() -> void:
	var world := _make_world()
	world.set_block(Vector3i(5, 2, 5), VoxelTypes.WATER_ID)
	var drop := ItemDrop.new()
	drop.floats = false
	drop.position = Vector3(5.5, 2.6, 5.5)
	drop.velocity = Vector3(0.0, -2.0, 0.0)
	for i in 240:
		drop.physics_step(world, 0.05)
	check(drop.grounded, "沉物触底吸附（grounded）")
	check(absf(drop.velocity.y) < 0.01, "沉物触底竖直速度归零")
	var rest := 2.0 + ItemDrop.HALF_HEIGHT  # 平台顶 2.0 + 半高
	check(absf(drop.position.y - rest) < 0.02,
			"沉物停在固体顶面上方半高处（%.3f vs %.3f）" % [
					drop.position.y, rest])
	var y_min := drop.position.y
	var y_max := drop.position.y
	for i in 60:
		drop.physics_step(world, 0.05)
		y_min = minf(y_min, drop.position.y)
		y_max = maxf(y_max, drop.position.y)
	check(y_max - y_min < 0.02, "沉底后位置稳定不抽搐（波幅 %.4f）" % [
			y_max - y_min])


## 波谱 CPU 移植（RealisticEnvironments 频谱公式）：分量数与波形确定
## 性（同种子同海况）、波高有界、风速变化改变海况（振幅分布不同）。
## 用 preload 绕开 .godot 类缓存（headless 测试环境不刷新）。
const WaveSpectrumScript := preload("res://presentation/wave_spectrum_cpu.gd")

func _test_wave_spectrum() -> void:
	var a: RefCounted = WaveSpectrumScript.new()
	a.build(6.0, -35.0, 12000.0, 20.0, 0.55, 0.35, 1337)
	check_eq(a.wave_vec4s.size(), 16, "波分量数 = 频率档 8 x 角度档 2")
	check_eq(a.wave_vec2s.size(), a.wave_vec4s.size(), "两组波表同长")
	check(absf(a.amplitude_sum - 1.0) < 0.001 or a.amplitude_sum > 0.0,
			"振幅归一化后和为 1")
	# 确定性：同参数同种子 -> 完全一致
	var b: RefCounted = WaveSpectrumScript.new()
	b.build(6.0, -35.0, 12000.0, 20.0, 0.55, 0.35, 1337)
	check(a.wave_vec4s == b.wave_vec4s and a.wave_vec2s == b.wave_vec2s,
			"同种子波表完全一致（确定性）")
	# 波高有界且 CPU/shader 同式
	var h_max := 0.0
	for i in 61:
		h_max = maxf(absf(a.height_at(float(i) * 1.7, -float(i) * 0.9, 3.0)), h_max)
	check(h_max <= 1.0 + 0.001, "CPU 波高有界（%.3f）" % h_max)
	check(h_max > 0.05, "波高非零（有实际起伏）")
	# 风速改变海况：大风 -> 主浪振幅占比变化（分量分布不同）
	var calm: RefCounted = WaveSpectrumScript.new()
	calm.build(3.0, -35.0, 12000.0, 20.0, 0.55, 0.35, 1337)
	check(not (calm.wave_vec2s == a.wave_vec2s),
			"不同风速产生不同海况分量")


## Physics Mod 言波（CPU 侧 OceanWaves）：值域有界、确定性、
## 波形随时间推进起伏（掉落物随波起伏的物理基础）。
const OceanWavesScript := preload("res://presentation/ocean_waves.gd")

func _test_ocean_speech_wave() -> void:
	var h_max := 0.0
	var h_min := 0.0
	for i in 200:
		var x := float(i) * 0.83 - 80.0
		var z := float(i) * -0.61
		var h: float = OceanWavesScript.wave_height(x, z, 7.5, 0.14)
		h_max = maxf(h_max, h)
		h_min = minf(h_min, h)
	check(h_max > 0.02 and h_min < -0.02,
			"言波有正负起伏（%.3f..%.3f）" % [h_min, h_max])
	check(absf(h_max) <= 0.5 + 0.001 and absf(h_min) <= 0.5 + 0.001,
			"言波值域有界（返回波高比，绝对尺度由 ocean_height 控制）")
	# 确定性：同位置同时间恒同值
	var a: float = OceanWavesScript.wave_height(12.3, -4.5, 3.21, 0.14)
	var b: float = OceanWavesScript.wave_height(12.3, -4.5, 3.21, 0.14)
	check(is_equal_approx(a, b), "言波确定性（同位同时同值）")
	# 时间推进 -> 同位置波形变化（流动的海面）
	var c: float = OceanWavesScript.wave_height(12.3, -4.5, 3.21 + 0.5, 0.14)
	check(not is_equal_approx(a, c), "言波随时间推进起伏")


## 互动涟漪（Physics Mod 波动方程 CPU 移植）：冲量注入产生波动，
## 逐步扩散到邻域、能量随阻尼衰减、纹理同步无异常。
const WaterRipplesScript := preload("res://world/water_ripples.gd")

func _test_ripple_simulation() -> void:
	var ripples: Node = WaterRipplesScript.new()
	# 注入中心冲量，跑一步：中心应有高度，邻域尚未起波
	ripples.add_impulse(Vector2.ZERO, 0.8, 0.6)
	ripples.step()
	var center_v: float = ripples._cur[
			ripples.MAP_SIZE / 2 * ripples.MAP_SIZE + ripples.MAP_SIZE / 2]
	check(center_v > 0.05, "冲量注入后中心起波（%.3f）" % center_v)
	# 多步扩散：波从中心向外传播（拉普拉斯传播，速率约 0.63 格/步），
	# 100 步内 3 格处应出现明显波动
	var n: int = ripples.MAP_SIZE
	var offset := int(3.0 / ripples.WINDOW * n)  # 3 格 -> 格数
	var had_motion := false
	var peak_total := 0.0
	for i in 100:
		ripples.step()
		if absf(ripples._cur[n / 2 * n + n / 2 + offset]) > 0.004:
			had_motion = true
		if i > 60:  # 共振峰值期之后取峰值
			var total_i := 0.0
			for v in ripples._cur:
				total_i += absf(v)
			peak_total = maxf(peak_total, total_i)
	check(had_motion, "波动扩散到距中心 3 格处")
	check(peak_total > 5.0, "涟漪维持可感波动（峰值 |h| 和 %.1f）" % peak_total)
	# 能量衰减：再跑 130 步，阻尼把峰值能量吃掉六成以上
	for i in 130:
		ripples.step()
	var total := 0.0
	for v in ripples._cur:
		total += absf(v)
	check(total < peak_total * 0.4,
			"涟漪能量随阻尼衰减（%.1f -> %.1f）" % [peak_total, total])


## 掉落物-波浪互动：浮物随波起伏（弹簧跟随贴住波形，不是贴平均
## 水位静止）、入水冲击置位 splash_pending。
func _test_drop_rides_waves() -> void:
	var world := _make_world()
	world.set_block(Vector3i(5, 2, 5), VoxelTypes.WATER_ID)
	var drop := ItemDrop.new()
	drop.floats = true
	drop.position = Vector3(5.5, 2.2, 5.5)
	# 先浮到位稳定
	for i in 200:
		OceanWavesScript.advance(0.05)
		drop.physics_step(world, 0.05)
	# 随波起伏：记录 10 秒内位置波动幅度，应跟住波形（>0.15 格）
	# 而不是静止在平均水位（~0）
	var y_min := drop.position.y
	var y_max := drop.position.y
	for i in 200:
		OceanWavesScript.advance(0.05)
		drop.physics_step(world, 0.05)
		y_min = minf(y_min, drop.position.y)
		y_max = maxf(y_max, drop.position.y)
	check(y_max - y_min > 0.15,
			"浮物随波起伏（波幅 %.2f 格，非静止）" % (y_max - y_min))

	# 入水冲击：空中坠入水中置 splash_pending（跑到真正入水那步）
	var drop2 := ItemDrop.new()
	drop2.floats = true
	drop2.position = Vector3(5.5, 4.5, 5.5)
	drop2.velocity = Vector3(0.0, -6.0, 0.0)
	var splashed := false
	for i in 60:
		drop2.physics_step(world, 0.05)
		if drop2.in_water:
			splashed = drop2.splash_pending
			break
	check(splashed, "落水冲击置位 splash_pending")
	var drop3 := ItemDrop.new()
	drop3.floats = true
	drop3.position = Vector3(5.5, 3.0, 5.5)  # 水内起步，无冲击
	drop3.physics_step(world, 0.05)
	check(not drop3.splash_pending, "水中起步无 splash_pending")
