## v3 地形视觉截图：扫描出生区找最高峰，传送玩家俯瞰拍摄。
extends Node

const ROOT := "user://tmp_capture_terrain"

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
	# 找水陆交界：一半邻居高于海面、一半低于海面的列（海岸线）
	var sea: int = TerrainGenerator.SEA_LEVEL
	var shore := Vector2i(34, 34)
	var best_mix := -1.0
	var peak_h := sea
	for radius in [4, 8, 12, 16]:
		for a in 32:
			var ang := TAU * a / 32.0
			var cx := 34 + int(round(cos(ang) * radius * 16))
			var cz := 34 + int(round(sin(ang) * radius * 16))
			var land := 0
			var water := 0
			for d in 8:
				var ang2 := TAU * d / 8.0
				var nx := cx + int(round(cos(ang2) * 6))
				var nz := cz + int(round(sin(ang2) * 6))
				if gen.column_height(nx, nz) > sea:
					land += 1
				else:
					water += 1
			var mix := float(mini(land, water)) / 8.0
			if mix > best_mix and gen.column_height(cx, cz) > sea:
				best_mix = mix
				shore = Vector2i(cx, cz)
	if best_mix <= 0.0:
		for a in 32:
			var ang := TAU * a / 32.0
			var cx := 34 + int(round(cos(ang) * 8 * 16))
			var cz := 34 + int(round(sin(ang) * 8 * 16))
			if gen.column_height(cx, cz) > sea:
				shore = Vector2i(cx, cz)
				break
	peak_h = gen.column_height(shore.x, shore.y)
	print("shore at (%d,%d) height=%d mix=%.2f" % [shore.x, shore.y, peak_h, best_mix])
	# 找最近的水列确定拍摄朝向
	var water_dir := Vector2(1, 0)
	for d in 12:
		var ang := TAU * d / 12.0
		var nx := shore.x + int(round(cos(ang) * 8))
		var nz := shore.y + int(round(sin(ang) * 8))
		if gen.column_height(nx, nz) <= TerrainGenerator.SEA_LEVEL:
			water_dir = Vector2(cos(ang), sin(ang))
			break
	# 拍摄点：岸边后方 10 格、海面上方 12 格，较陡俯角让水面占满画面主体
	var peak := Vector2i(
			shore.x - int(round(water_dir.x * 10.0)),
			shore.y - int(round(water_dir.y * 10.0)))
	# 传送到海岸上空俯瞰
	player.global_position = Vector3(
			float(peak.x) + 0.5,
			float(TerrainGenerator.SEA_LEVEL) + 12.0,
			float(peak.y) + 0.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(-water_dir.x, -water_dir.y)
	player.camera.rotation.x = -0.55
	main.chunk_manager.focus = player
	for i in 400:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	# ---- 水面诊断：水格方块 ID + 渲染器水面面数 + 相机最终变换 ----
	for dist in [4, 8, 16]:
		var probe := Vector3i(
				shore.x + int(round(water_dir.x * dist)),
				TerrainGenerator.SEA_LEVEL,
				shore.y + int(round(water_dir.y * dist)))
		print("probe dist=%d pos=(%d,%d,%d) block=%d" % [
				dist, probe.x, probe.y, probe.z,
				main.world.get_block(probe)])
	var total_water_faces := 0
	var chunks_with_water := 0
	for node in main.chunk_renderer.get_children():
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.mesh.get_surface_count() >= 2:
			chunks_with_water += 1
			total_water_faces += mi.mesh.surface_get_arrays(1)[Mesh.ARRAY_INDEX].size() / 6
	print("renderer water_chunks=%d water_faces=%d mat=%s" % [
			chunks_with_water, total_water_faces,
			main.chunk_renderer.water_material != null])
	print("cam pos=%s yaw=%.2f pitch=%.2f fwd=%s" % [
			player.camera.global_position, player.rotation.y,
			player.camera.rotation.x,
			-player.camera.global_transform.basis.z])
	var image := get_viewport().get_texture().get_image()
	image.save_png("res://debug/last_terrain.png")
	# 波纹动画验证：0.5s 后再拍一帧，两帧水面区域应有差异（波纹
	# 在流动）而陆地不变
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/last_terrain_b.png")
	# 贴水面平视机位：站在水面上方朝开阔水面看（机位在水里而非岸上，
	# 否则画面近景是岸边雪地不是水面）
	player.global_position = Vector3(
			float(shore.x) + 0.5 + water_dir.x * 6.0,
			float(TerrainGenerator.SEA_LEVEL) + 1.8,
			float(shore.y) + 0.5 + water_dir.y * 6.0)
	player.camera.rotation.x = -0.04
	for i in 120:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/last_terrain_c.png")
	# ---- 网格级洞检测：俯拍视野中心区块的表面水格逐格顶面覆盖 ----
	var sea0: int = TerrainGenerator.SEA_LEVEL
	var cam_chunk := VoxelCoords.world_to_chunk(
			Vector3i(floori(player.camera.global_position.x),
					0,
					floori(player.camera.global_position.z)),
			main.world.config.chunk_size)
	var checked := 0
	var holes_report := 0
	var has_water_chunk := 0
	for dcx in range(-2, 3):
		for dcz in range(-2, 2):
			var cc := Vector3i(cam_chunk.x + dcx, 0, cam_chunk.y + dcz)
			var ch0: ChunkData = main.world.get_chunk(cc)
			if ch0 != null and ch0.block_ids.has(VoxelTypes.WATER_ID):
				has_water_chunk += 1
			var ch: ChunkData = main.world.get_chunk(cc)
			if ch == null or not ch.block_ids.has(VoxelTypes.WATER_ID):
				continue
			var arr := ChunkMesher.build_mesh_arrays(main.world.registry,
					ch, main.world.collect_neighbors(cc))
			var wv: PackedVector3Array = arr.get(
					"water_vertices", PackedVector3Array())
			var wi: PackedInt32Array = arr.get(
					"water_indices", PackedInt32Array())
			var origin_x := cc.x * 16
			var origin_z := cc.z * 16
			for lx in 16:
				for lz in 16:
					if ch.get_block(Vector3i(lx, sea0, lz)) != VoxelTypes.WATER_ID:
						continue
					# 表面水格：上方空气
					if ch.get_block(Vector3i(lx, sea0 + 1, lz)) == VoxelTypes.WATER_ID:
						continue
					checked += 1
					# 网格顶点是区块局部坐标，测试点也用局部
					var cx := float(lx) + 0.5
					var cz := float(lz) + 0.5
					var covered := false
					for t in range(0, wi.size(), 3):
						var a: Vector3 = wv[wi[t]]
						var b: Vector3 = wv[wi[t + 1]]
						var c: Vector3 = wv[wi[t + 2]]
						var v0 := Vector2(b.x - a.x, b.z - a.z)
						var v1 := Vector2(c.x - a.x, c.z - a.z)
						var v2 := Vector2(cx - a.x, cz - a.z)
						var d00 := v0.dot(v0)
						var d01 := v0.dot(v1)
						var d11 := v1.dot(v1)
						var d20 := v2.dot(v0)
						var d21 := v2.dot(v1)
						var den := d00 * d11 - d01 * d01
						if absf(den) < 1e-9:
							continue
						var u := (d11 * d20 - d01 * d21) / den
						var v := (d00 * d21 - d01 * d20) / den
						if u >= -0.01 and v >= -0.01 and u + v <= 1.01:
							covered = true
							break
					if not covered:
						holes_report += 1
						if holes_report <= 5:
							print("HOLE at world (%d, %d, %d)" % [
									origin_x + lx, sea0, origin_z + lz])
	print("mesh check: water chunks %d, surface cells %d, missing top %d" % [
			has_water_chunk, checked, holes_report])

	# 侧视岸壁机位（诊断几何起伏）：贴水面高度正对岸边，几何起伏
	# 表现为水线在岸壁上的高度波动（颜色判读不可靠，看轮廓）
	player.global_position = Vector3(
			float(shore.x) + 0.5 - water_dir.x * 4.0,
			float(TerrainGenerator.SEA_LEVEL) + 1.2,
			float(shore.y) + 0.5 - water_dir.y * 4.0)
	player.rotation.y = atan2(water_dir.x, water_dir.y)
	player.camera.rotation.x = 0.0
	for i in 120:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/last_terrain_d.png")
	print("saved")
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
