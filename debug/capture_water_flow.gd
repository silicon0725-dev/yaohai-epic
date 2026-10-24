## 水流动集成演示：加载真实世界，在岸上平地造一个石碗装满源水，
## 拆掉一格碗壁放水，等待水位元胞自动机扩散，统计碗外水体并俯拍。
## （可控场景替代自然海岸挖沟——海岸沟是否凿穿到海取决于地形运气）
## 运行：godot --path . res://debug/capture_water_flow.tscn
extends Node

const ROOT := "user://tmp_capture_water_flow"


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 1200:
		await get_tree().process_frame
		waited += 1
		if waited >= 30 and main.chunk_manager.is_idle():
			break
	var player: PlayerController = main.player
	var gen: TerrainGenerator = main.generator
	var sea: int = TerrainGenerator.SEA_LEVEL

	# 找平地：出生点附近高度一致（7x7 内高差 <=1）且高于海平面的区域
	var base := Vector2i(34, 34)
	for r in 24:
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := 34 + int(round(cos(ang) * r * 4))
			var cz := 34 + int(round(sin(ang) * r * 4))
			var h := gen.column_height(cx, cz)
			if h <= sea:
				continue
			var flat := true
			for dx in range(-3, 4):
				for dz in range(-3, 4):
					if absi(gen.column_height(cx + dx, cz + dz) - h) > 1:
						flat = false
						break
				if not flat:
					break
			if flat:
				base = Vector2i(cx, cz)
				break
		if base != Vector2i(34, 34):
			break
	var ground := gen.column_height(base.x, base.y)
	print("tank base at (%d,%d) ground=%d" % [base.x, base.y, ground])

	# 石碗：7x7 边界 y=ground+1 石壁；内部 5x5 源水（无状态 = 源）
	var world: VoxelWorld = main.world
	var wy := ground + 1
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var edge := absi(dx) == 3 or absi(dz) == 3
			var pos := Vector3i(base.x + dx, wy, base.y + dz)
			if edge:
				world.set_block(pos, VoxelTypes.STONE_ID)
			else:
				world.set_block(pos, VoxelTypes.WATER_ID)
	# 碗外放水方向（+x）的平地上挖两级台阶，让水流出后有落差可下
	world.set_block(Vector3i(base.x + 4, wy, base.y), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(base.x + 5, wy, base.y), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(base.x + 5, wy - 1, base.y), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(base.x + 6, wy - 1, base.y), VoxelTypes.AIR_ID)

	var flow: WaterFlow = main.water_flow
	for i in 180:  # 挖壁前先等碗内稳定
		await get_tree().process_frame
	print("tank stable pending=%d" % flow.pending_count())

	# 拆壁前留底：碗外应当无水
	_teleport_overview(player, main, base, wy)
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/last_water_before.png")
	var before := _count_outside_water(world, base, wy)
	print("before breach: outside water=%d" % before)

	# 拆掉 +x 侧壁一格放水
	world.set_block(Vector3i(base.x + 3, wy, base.y), VoxelTypes.AIR_ID)
	print("wall breached")

	# 等扩散（0.25s/tick，最多 40s；队列清空即稳定）。期间采样 FPS
	var fps_min := 9999.0
	var fps_samples := 0
	var fps_sum := 0.0
	for i in 2400:
		await get_tree().process_frame
		if i > 60:  # 跳过拆壁瞬间的加载尖峰
			var fps := Engine.get_frames_per_second()
			fps_min = minf(fps_min, fps)
			fps_sum += fps
			fps_samples += 1
		if i % 120 == 0:
			print("t=%.0fs fps=%d pending=%d outside=%d" % [
					i / 60.0, Engine.get_frames_per_second(),
					flow.pending_count(), _count_outside_water(world, base, wy)])
		if i % 60 == 0 and flow.pending_count() == 0 and i > 120:
			break
	print("fps avg=%.0f min=%.0f (n=%d)" % [
			fps_sum / maxi(fps_samples, 1), fps_min, fps_samples])

	# 统计碗外（|dx|>3 或 |dz|>3）水格与级别分布
	var levels := {}
	var total := 0
	for dx in range(-6, 10):
		for dz in range(-6, 10):
			for dy in 4:
				var pos := Vector3i(base.x + dx, wy + 1 - dy, base.y + dz)
				if absi(dx) <= 3 and absi(dz) <= 3:
					continue  # 碗内不计
				if world.get_block(pos) == VoxelTypes.WATER_ID:
					total += 1
					var lvl := int(world.get_block_state(pos).get("level", 0))
					levels[lvl] = levels.get(lvl, 0) + 1
	print("outside water=%d levels=%s pending=%d" % [
			total, levels, flow.pending_count()])

	# 传送俯拍水箱与放水方向
	_teleport_overview(player, main, base, wy)
	for i in 400:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("res://debug/last_water_flow.png")
	print("saved")
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)


## 俯拍机位：水箱后方 4 格、水层上方 9 格，朝放水方向（+x）俯 31°。
func _teleport_overview(
		player: PlayerController, main: Node, base: Vector2i, wy: int
) -> void:
	player.global_position = Vector3(
			float(base.x) + 0.5 - 4.0, float(wy) + 9.0, float(base.y) + 0.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = -PI * 0.5
	player.camera.rotation.x = -0.55
	main.chunk_manager.focus = player


## 统计碗外水格（拆壁前后对比用）。
func _count_outside_water(world: VoxelWorld, base: Vector2i, wy: int) -> int:
	var total := 0
	for dx in range(-6, 10):
		for dz in range(-6, 10):
			for dy in 4:
				var pos := Vector3i(base.x + dx, wy + 1 - dy, base.y + dz)
				if absi(dx) <= 3 and absi(dz) <= 3:
					continue
				if world.get_block(pos) == VoxelTypes.WATER_ID:
					total += 1
	return total
