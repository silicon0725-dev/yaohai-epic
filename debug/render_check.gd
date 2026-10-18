## 渲染回归检查（需要显示环境，非 headless）：
##   godot-4 --path . res://debug/render_check.tscn
## 用无光照纯白材质客观量化几何渲染覆盖率，捕捉绕序/剔除回归：
##   1) 侧面机位：默认剔除与关闭剔除的白色像素应完全一致
##      （正确绕序下，被剔除的背面本来就会被前景遮挡）。
##   2) 俯视机位：默认剔除下白色覆盖应占画面相当比例（顶面在渲染）。
## 阶段 C 起为流式加载：先等待 ChunkManager 安定（无在途任务且无
## 脏区块）再采样。机位以玩家为中心（视距圆盘绕玩家分布）。
## 任一条件不满足即报 FAIL 并以非零码退出。
## 背景：Stage A 曾因三角形绕序与 Godot 正面约定（面外侧看顺时针）
## 相反，导致"方块部分面不渲染"、能透视地形内部。
extends Node

const TOP_VIEW_MIN_RATIO := 0.30
const SETTLE_TIMEOUT_FRAMES := 1500
const SETTLE_MIN_FRAMES := 30


func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _wait_until_settled(main)

	var cam := Camera3D.new()
	add_child(cam)
	var player_pos := _player_position(main)

	var white := StandardMaterial3D.new()
	white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color = Color.WHITE
	white.disable_receive_shadows = true
	white.cull_mode = BaseMaterial3D.CULL_BACK
	# 网格实例位于 ChunkRenderer 子树下，需递归查找（动态节点无 owner）
	for child in main.find_children("*", "MeshInstance3D", true, false):
		child.material_override = white

	var failures: Array[String] = []

	# 侧面机位（玩家 +Z 方向外侧、水平看向玩家，主看垂直面）
	cam.position = player_pos + Vector3(0.0, 25.0, 100.0)
	cam.look_at(player_pos + Vector3(0.0, -5.0, 0.0), Vector3.UP)
	cam.make_current()
	await _settle_frames(3)
	var side_on := await _capture_count()
	white.cull_mode = BaseMaterial3D.CULL_DISABLED
	await _settle_frames(3)
	var side_off := await _capture_count()
	white.cull_mode = BaseMaterial3D.CULL_BACK
	# 容差：Greedy Meshing 的四边形 T 型交界在双面渲染时存在
	# 同深度 z-fighting（个位像素级，实测 3/370000）；系统性绕序
	# 错误的差异是数量级级别的（历史案例为 61%）
	if absi(side_on - side_off) > 3:
		failures.append("侧面机位剔除前后几何不一致: %d != %d（疑似绕序反转）" % [
			side_on, side_off])

	# 俯视机位（玩家正上方，主看 +Y 顶面）
	cam.position = player_pos + Vector3(0.0, 80.0, 0.001)
	cam.look_at(player_pos, Vector3.UP)
	await _settle_frames(3)
	var top_on := await _capture_count()
	var total := 1152 * 648
	if float(top_on) / float(total) < TOP_VIEW_MIN_RATIO:
		failures.append("俯视白色占比 %.1f%% 低于阈值 %.0f%%（顶面疑似被剔除）" % [
			100.0 * top_on / total, 100.0 * TOP_VIEW_MIN_RATIO])

	for failure in failures:
		print("FAIL: ", failure)
	print("结果: 侧面剔除=%d 侧面不剔除=%d 俯视剔除=%d" % [side_on, side_off, top_on])
	print("RENDER CHECK: %s" % ("PASS" if failures.is_empty() else "FAIL"))
	get_tree().quit(0 if failures.is_empty() else 1)


## 等待流式加载安定：在途任务清零且无脏区块（超时则按当前状态继续）。
func _wait_until_settled(main: Node) -> void:
	var waited := 0
	while waited < SETTLE_TIMEOUT_FRAMES:
		await get_tree().process_frame
		waited += 1
		var manager = main.get("chunk_manager")
		if manager != null and waited >= SETTLE_MIN_FRAMES and manager.is_idle():
			break


func _settle_frames(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _player_position(main: Node) -> Vector3:
	var players: Array = main.find_children(
			"Player", "CharacterBody3D", true, false)
	if players.is_empty():
		return Vector3(2.5, 20.0, 2.5)
	var player: CharacterBody3D = players[0]
	return player.global_position


func _capture_count() -> int:
	var image := get_viewport().get_texture().get_image()
	var white_count := 0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.r > 0.92 and c.g > 0.92 and c.b > 0.92:
				white_count += 1
	return white_count
