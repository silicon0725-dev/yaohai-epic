## 武器验收截图：DMC 阎魔刀拔刀（idle/攻击帧）+ 收刀（on_torso 挂躯干）。
## 判读刀柄是否贴拳心、轴向是否合理、鞘挂腰位置/穿地。
extends Node

const ROOT := "user://tmp_capture_weapon"
const SHOTS := ["wp_holster.png", "wp_armed_idle.png", "wp_armed_side.png",
		"wp_atk1.png", "wp_atk2.png", "wp_atk3.png", "wp_atk4.png"]


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
	print("world ready; dmc=", main.player.avatar._weapon_dmc)
	var player: Node = main.player
	player.camera_mode = 1  # 第三人称背后
	player._pitch = -0.08
	player._position_camera(1.0)
	for i in 90:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_shot(0)  # 收刀（默认 holstered=鞘挂躯干）
	print("holster saved")
	# F7 拔刀 → idle（第二人称面前近摄：刀/手/鞘关系特写）
	player.avatar.set_armed(true)
	for i in 45:
		await get_tree().process_frame
	player.camera_mode = 2  # 第二人称面前
	player._pitch = 0.05
	player._position_camera(1.0)
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_shot(1)
	print("armed idle saved (front close)")
	# 3/4 侧视：判读鞘前后倾/刀握持（正面机位分不出前后）
	player.camera_mode = 1
	player._pitch = -0.05
	player._position_camera(1.0)
	await get_tree().create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	_shot(2)
	print("armed side saved")
	# 攻击两段（直接调 avatar.attack——曾模拟左键没触发；正面机位多帧
	# 覆盖两段，判读肩部不被长发挡）
	player.camera_mode = 2
	player._pitch = 0.05
	player._position_camera(1.0)
	for i in 5:
		await get_tree().process_frame
	var frame := 0
	var shot_idx := 3
	var marks := {4: 3, 12: 4, 24: 5, 36: 6}
	player.avatar.attack()
	while frame < 48:
		await get_tree().process_frame
		frame += 1
		if frame == 10:
			player.avatar.attack()  # 缓冲接第二段
		if marks.has(frame):
			await RenderingServer.frame_post_draw
			_shot(marks[frame])
	print("attack frames saved")
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)


func _shot(index: int) -> void:
	get_viewport().get_texture().get_image().save_png(
			"res://debug/%s" % SHOTS[index])
