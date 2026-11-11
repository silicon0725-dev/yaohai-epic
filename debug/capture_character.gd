## 角色系统验收演示 v2：绑定站姿 → 拳击三连（动作层大幅摆臂，
## 定帧抓 3 帧 PIL 对比证明蒙皮生效）→ 短促行走 1 帧 → 换男版模型。
## 输出 debug/char_*.png。
extends Node

const ROOT := "user://tmp_capture_char"
const SHOT_NAMES := ["char_bind_pose.png", "char_punch_a.png",
	"char_punch_b.png", "char_punch_c.png", "char_walk.png",
	"char_boy.png"]


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
	player.camera_mode = 1
	player._pitch = -0.12
	player._position_camera(1.0)
	for i in 90:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_shot(0)
	print("bind pose saved")
	# 拳击三连：0.2s 左刺 / 0.5s 右直 / 0.8s 右勾（大摆臂差异帧）
	player.avatar.play_punch()
	var frame := 0
	var shot_idx := 1
	while frame < 66:
		await get_tree().process_frame
		frame += 1
		if frame == 15 or frame == 33 or frame == 51:
			await RenderingServer.frame_post_draw
			_shot(shot_idx)
			shot_idx += 1
	print("punch shots saved")
	# 短促行走（15 帧内抓拍，避免走出平台）
	var key_w := InputEventKey.new()
	key_w.physical_keycode = KEY_W
	key_w.pressed = true
	Input.parse_input_event(key_w)
	for i in 15:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_shot(4)
	var key_w_up := InputEventKey.new()
	key_w_up.physical_keycode = KEY_W
	key_w_up.pressed = false
	Input.parse_input_event(key_w_up)
	print("walk shot saved; base=", player.avatar.animator.base_name())
	# 换男版模型（F6 路径）
	player.avatar.cycle_model()
	for i in 60:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_shot(5)
	print("boy model saved")

	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)


func _shot(index: int) -> void:
	get_viewport().get_texture().get_image().save_png(
			"res://debug/%s" % SHOT_NAMES[index])
