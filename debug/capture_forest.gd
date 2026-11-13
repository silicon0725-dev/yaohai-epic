## 森林带验收（阶段 2+2.5）：真树密度观感（近景）+ 远景壳
## 树烘壳绿带（远眺）。种子 1337 的最湿区=(800,-2200)（探针
## density 0.0218≈上限）。输出 debug/forest_{near,high,far}.png。
extends Node

const ROOT := "user://tmp_capture_forest"
const FOREST := Vector2(800.0, -2200.0)


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	# 传送森林带中心（列地表由地形决定——先加载一小圈拿地表高度）
	var player: Node3D = main.player
	player.global_position = Vector3(FOREST.x, 120.0, FOREST.y)
	main.chunk_manager.focus = player
	for i in 300:
		await get_tree().process_frame
		if i > 90 and main.chunk_manager.is_idle():
			break
	var tg := TerrainGenerator.new(WorldConfig.new())
	var surf := 0.0
	for x in 4:
		for z in 4:
			var p: Dictionary = tg.column_profile(
					int(FOREST.x) + x * 4, int(FOREST.y) + z * 4)
			surf = maxf(surf, float(p["height"]))
	print("forest surface≈", surf)

	var cam := Camera3D.new()
	cam.fov = 75.0
	add_child(cam)
	await get_tree().process_frame
	cam.current = true

	# 1) 近景：人视角站林中（验真树密度/树形群体观感）
	cam.global_position = Vector3(FOREST.x, surf + 3.0, FOREST.y)
	cam.look_at(Vector3(FOREST.x + 8.0, surf + 6.0, FOREST.y + 4.0),
			Vector3.UP)
	await _settle(main, cam)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/forest_near.png")
	print("near saved")

	# 2) 高空俯瞰（真树群+远处壳衔接，朝湿区山方向）
	cam.global_position = Vector3(FOREST.x, surf + 45.0, FOREST.y + 20.0)
	cam.look_at(Vector3(FOREST.x + 480.0, surf, FOREST.y - 360.0),
			Vector3.UP)
	await _settle(main, cam)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/forest_high.png")
	print("high saved")

	# 3) 远眺：朝 1800 格外的湿区山（(2240,-3280) 方向 precip 0.59/
	# 密度 0.016——原 +400/-300 方向 600-1200 格是干旱带，秃山是真秃）
	cam.global_position = Vector3(FOREST.x, surf + 60.0, FOREST.y)
	cam.look_at(Vector3(FOREST.x + 1440.0, surf + 10.0, FOREST.y - 1080.0),
			Vector3.UP)
	await _settle(main, cam)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/forest_far.png")
	print("far saved")

	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)


## 稳态等待：chunk 空闲（瞬移后稳态判定必须 is_idle，历史坑：
## 只等 15s < 加载 24s）+ 壳重建节奏（REBUILD_STEP 64 格跨步触发）
## + 时钟钉正午（首轮验收拍进傍晚/夜——壳 lum×u_day 压暗体系下
## 烘色不可辨，判读失效）
func _settle(main: Node, cam: Camera3D) -> void:
	main.chunk_manager.focus = cam
	main._time_of_day = 0.25
	for i in 900:
		await get_tree().process_frame
		if i > 240 and main.chunk_manager.is_idle():
			break
