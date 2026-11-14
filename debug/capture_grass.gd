## 植被 B5 草场截图：找平坦草地，三机位（平视草浪/近距叶簇/俯拍
## 密度）验收 GG 真默认（64 片/格、32 格大区噪声、高草×3、满宽叶形）。
extends Node

const ROOT := "user://tmp_capture_grass"

func snap(main: Node, player: PlayerController, pname: String,
		pos: Vector3, pitch: float, yaw: float, frames: int) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = yaw
	player.camera.rotation.x = pitch
	main.chunk_manager.focus = player
	for i in frames:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/last_grass_%s.png" % pname)

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
	# 找平坦草地：螺旋扫出生区，顶块是草方块且 3x3 邻居高度差 <=1
	var sea: int = TerrainGenerator.SEA_LEVEL
	var spot := Vector2i(34, 34)
	var found := false
	for radius in [12, 24, 48, 80, 120, 176]:
		if found:
			break
		for a in 64:
			var ang := TAU * a / 64.0
			var cx := 34 + int(round(cos(ang) * radius))
			var cz := 34 + int(round(sin(ang) * radius))
			var prof := gen.column_profile(cx, cz)
			var h0: int = prof["height"]
			# 非岩非沙的低地草地（profile 免加载判定；出生区整片
			# 高山台地——首战 h=158/164 两次假草地教训）
			if h0 <= sea + 2 or h0 > sea + 35 \
					or prof["rocky"] or prof["sandy"]:
				continue
			var flat := true
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					if absi(gen.column_height(cx + dx, cz + dz) - h0) > 1:
						flat = false
			if flat:
				spot = Vector2i(cx, cz)
				found = true
				break
	var h := gen.column_height(spot.x, spot.y)
	print("meadow at (%d,%d) h=%d found=%s" % [spot.x, spot.y, h, found])

	var fx := float(spot.x) + 0.5
	var fz := float(spot.y) + 0.5
	# 机位 a：站在草中平视（眼高 1.7，微俯 0.18）——看草浪/密度/高草
	await snap(main, player, "a", Vector3(fx, float(h) + 1.7, fz), -0.18, 0.6, 240)
	# 机位 b：近距俯看脚前草叶（pitch -0.6）——看叶形/叶宽/地毯覆盖
	await snap(main, player, "b", Vector3(fx, float(h) + 1.7, fz), -0.6, 0.6, 90)
	# 机位 c：升 8 格俯拍草场——看 32 格大区高度斑块对比
	await snap(main, player, "c", Vector3(fx, float(h) + 8.0, fz), -0.5, 0.6, 90)
	print("saved")
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
