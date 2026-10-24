## 开发辅助：地面掉落实体视觉截图（需要显示环境）：
##   godot-4 --path . res://debug/capture_drops.tscn
## 在玩家面前撒一组展示掉落（方块物品 + 像素画材料/工具），
## 等待落地与浮动动画稳定后截图到 debug/last_capture_drops.png。
## 使用隔离存档目录，结束即清理。
extends Node

const OUTPUT_PATH := "res://debug/last_capture_drops.png"
const ISOLATED_SAVE_ROOT := "user://tmp_capture_drops"


func _ready() -> void:
	# 先清残留（历史运行的退出保存可能重新落盘过），保证干净开局
	WorldSave.new(
			ISOLATED_SAVE_ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ISOLATED_SAVE_ROOT
	add_child(main)
	# 等待流式加载安定（与 capture.gd 相同策略），超时按现状继续
	var waited := 0
	while waited < 1500:
		await get_tree().process_frame
		waited += 1
		var manager = main.get("chunk_manager")
		if manager != null and waited >= 30 and manager.is_idle():
			break
	var player: PlayerController = main.get("player")
	var drop_manager: DropManager = main.get("drop_manager")
	if player == null or drop_manager == null:
		print("FAIL: 主场景缺玩家或掉落管理器")
		get_tree().quit(1)
		return

	# 搭一段三级台阶地形（用户反馈的坡地/台阶场景，验证贴地修正）
	var forward := -player.global_transform.basis.z
	var vox_world: VoxelWorld = main.world
	var origin := Vector3i(
			floori(player.global_position.x),
			floori(player.global_position.y),
			floori(player.global_position.z))
	var forward_i := Vector3i(
			int(round(forward.normalized().x)), 0,
			int(round(forward.normalized().z)))
	var side := Vector3i(forward_i.z, 0, -forward_i.x)
	var ground_y := origin.y - 1
	for step in 3:
		var patch := origin + forward_i * (4 + step * 2)
		for fill in step + 2:
			for a in 3:
				for b in 5:
					vox_world.set_block(
							patch + forward_i * (a - 1) + side * (b - 2)
									+ Vector3i(0, ground_y + 1 + fill, 0),
							VoxelTypes.GRASS_ID)

	# 台阶上撒展示掉落（方块/平面混布在台阶边缘）
	var items := player.item_registry
	var base := player.global_position + forward.normalized() * 4.5
	base.y = player.global_position.y + 2.5
	var showcase := [
		["core:dirt", 1], ["core:stone", 1], ["core:coal", 3],
		["core:wooden_pickaxe", 1], ["core:stick", 8], ["core:cobblestone", 5],
	]
	for i in showcase.size():
		var entry: Array = showcase[i]
		drop_manager.spawn_drop(
				items.id_for_name(entry[0]), entry[1],
				base + Vector3(cos(i * 1.05) * 1.1, i * 0.35, sin(i * 1.05) * 1.1),
				Vector3.ZERO, 30.0)
	# 第一张：空中翻滚中途（约 0.4s，方块正在转）
	for i in 24:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var air_image := get_viewport().get_texture().get_image()
	air_image.save_png("res://debug/last_capture_drops_air.png")
	# 第二张：落地后姿态冻结（歪着停在地上）
	for i in 300:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(OUTPUT_PATH)
	print("截图已保存: ", ProjectSettings.globalize_path(OUTPUT_PATH))
	print("掉落实体数: %d（应为 6）" % drop_manager.drop_count())
	# 退出钩子（ChunkManager._exit_tree 的退出保存）会在 erase 之后重新
	# 落盘污染隔离目录——先停用存档系统再释放与清理
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	WorldSave.new(
			ISOLATED_SAVE_ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
