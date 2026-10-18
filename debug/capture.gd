## 开发辅助：渲染真实画面并截图保存（验证地形视觉效果用）。
##   godot-4 --path . res://debug/capture.tscn
## 同时输出玩家物理状态与准星的像素级检查结果。
extends Node

const OUTPUT_PATH := "res://debug/last_capture.png"


func _ready() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = main_scene.instantiate()
	add_child(main)
	# 等待流式加载安定（在途任务清零且无脏区块），超时则按现状继续
	var waited := 0
	while waited < 1500:
		await get_tree().process_frame
		waited += 1
		var manager = main.get("chunk_manager")
		if manager != null and waited >= 30 and manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	# 报告玩家物理状态（验证区块碰撞生效，玩家未坠落穿地）
	var players := main.find_children("Player", "CharacterBody3D", true, false)
	if players.is_empty():
		print("警告: 未找到 Player 节点")
	else:
		var player: CharacterBody3D = players[0]
		print("玩家状态: y=%.2f on_floor=%s velocity_y=%.2f" % [
			player.global_position.y, str(player.is_on_floor()), player.velocity.y])
	var image := get_viewport().get_texture().get_image()
	image.save_png(OUTPUT_PATH)
	print("截图已保存: ", ProjectSettings.globalize_path(OUTPUT_PATH))
	_check_crosshair(image)
	get_tree().quit(0)


## 像素级检查准星：以画面中心为原点，四个臂中点（±9px）附近
## 应各有白色像素，中心空隙（±3px）内不应出现白色。
func _check_crosshair(image: Image) -> void:
	var cx := image.get_width() / 2
	var cy := image.get_height() / 2
	var arm_points := [
		Vector2i(cx + 9, cy), Vector2i(cx - 9, cy),
		Vector2i(cx, cy + 9), Vector2i(cx, cy - 9),
	]
	var arms_found := 0
	for point in arm_points:
		if _box_has_white(image, point, 3):
			arms_found += 1
	var center_clean := not _box_has_white(image, Vector2i(cx, cy), 3)
	print("准星检查: 四臂可见 %d/4, 中心空隙干净=%s" % [
		arms_found, str(center_clean)])


func _box_has_white(image: Image, center: Vector2i, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := center.x + dx
			var y := center.y + dy
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			var c := image.get_pixel(x, y)
			if c.r > 0.85 and c.g > 0.85 and c.b > 0.85:
				return true
	return false
