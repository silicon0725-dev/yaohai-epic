## 相机模式验收：四态各拍一帧（PIL 测角色在画面的位置区分）+
## 遮挡收缩/回弹数值验证（玩家背后立墙 → 距离收缩；拆墙 → 回弹）。
## 输出 debug/cam_*.png。
extends Node

const ROOT := "user://tmp_capture_cam"


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 60 and main.chunk_manager.is_idle():
			break
	print("world ready")

	var player: Node = main.player
	player._pitch = -0.1
	var shots := ["cam_behind.png", "cam_front.png",
			"cam_shoulder.png", "cam_first.png"]
	# 背后 → 面前 → 越肩 → 第一人称（各稳定 45 帧拍一帧）
	for mode in 4:
		player.camera_mode = mode
		player._position_camera(1.0)
		for i in 45:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(
				"res://debug/" + shots[mode])
		print("mode %d dist=%.2f" % [mode, player._cam_dist])
	# 第二人称俯仰两态：低机位/高机位——人物都应居中（look_at 锁定）。
	# 先找一个前方开阔的朝向（前方 2~5m 无地形遮挡，避免相机被收缩）
	var open_yaw := 0.0
	for k8 in 8:
		var yaw8 := k8 * TAU / 8.0
		var d8 := Vector3(-sin(yaw8), 0.0, -cos(yaw8))
		var clear := true
		for dist8 in [2.0, 3.5, 5.0]:
			for dy8 in [0.0, 1.0]:
				var c8: Vector3 = player.global_position + d8 * dist8 + Vector3(0, dy8, 0)
				if main.world.get_block(Vector3i(floori(c8.x), floori(c8.y), floori(c8.z))) != VoxelTypes.AIR_ID:
					clear = false
		if clear:
			open_yaw = yaw8
			break
	player.rotation.y = open_yaw
	player.avatar._body_yaw = open_yaw
	for i in 15:
		await get_tree().process_frame
	player.camera_mode = 2
	for k in 2:
		player._pitch = -0.45 if k == 0 else 0.45
		player._position_camera(1.0)
		for i in 30:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(
				"res://debug/cam_front_%s.png" % ("low" if k == 0 else "high"))
		var tag := "low" if k == 0 else "high"
		print("front %s pitch=%+.2f cam=(%.1f, %.1f, %.1f) eye_y=%.1f dist=%.2f" % [
				tag, player._pitch, player.camera.global_position.x,
				player.camera.global_position.y,
				player.camera.global_position.z,
				player.global_position.y + 0.7, player._cam_dist])
	player._pitch = -0.1

	# ---- 遮挡收缩/回弹（背后模式）----
	player.camera_mode = 1
	player._pitch = -0.1
	for i in 45:
		await get_tree().process_frame
	print("occl baseline dist=%.2f (want≈%.2f)" % [
			player._cam_dist, player.CAM_DIST[1]])
	# 眼位向后 1.2m 立一堵 3 高石墙（隔开眼位与期望机位 3.2m）
	var eye: Vector3 = player.global_position + Vector3(0, 0.7, 0)
	var back_dir: Vector3 = player.global_transform.basis.z  # 玩家后方
	var wall_base := eye + back_dir.normalized() * 1.2
	for dy in 2:
		for dx in 2:
			var p := Vector3i(
					floori(wall_base.x) - 1 + dx,
					floori(eye.y) - 1 + dy,
					floori(wall_base.z) - 1 + dx)
			main.world.set_block(p, VoxelTypes.STONE_ID)
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/cam_occluded.png")
	print("occl walled dist=%.2f (expect≈0.9-1.2)" % player._cam_dist)
	# 手动探测：眼位→机位方向的射线与墙格实际值
	var probe_dir: Vector3 = (player.camera.global_position
			- eye).normalized()
	var probe: Dictionary = VoxelRaycast.raycast(main.world, eye, probe_dir, 3.4)
	print("probe after wall: hit=%s dist=%.2f" % [probe.hit, probe.distance])
	var wcell := Vector3i(floori(wall_base.x), floori(eye.y) - 1, floori(wall_base.z))
	print("wall cell block=", main.world.get_block(wcell))
	# 拆墙回弹（3m/s，3.2m 约 1.1s）
	for dy in 2:
		for dx in 2:
			var p := Vector3i(
					floori(wall_base.x) - 1 + dx,
					floori(eye.y) - 1 + dy,
					floori(wall_base.z) - 1 + dx)
			main.world.set_block(p, VoxelTypes.AIR_ID)
	for i in 90:
		await get_tree().process_frame
	print("occl cleared dist=%.2f (expect≈3.2 recovered)" % player._cam_dist)
	var probe2: Dictionary = VoxelRaycast.raycast(main.world, eye,
			(player.camera.global_position - eye).normalized(), 3.4)
	print("probe after clear: hit=%s dist=%.2f cell=%s" % [
			probe2.hit, probe2.distance,
			main.world.get_block(Vector3i(floori(wall_base.x),
					floori(eye.y) - 1, floori(wall_base.z)))])

	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
