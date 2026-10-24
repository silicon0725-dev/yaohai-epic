## 树系统验收演示：找一棵树 → 截图初始态 → 砍主干 → 等倒树落地
## → 截图结果态。输出 debug/trees_before.png / trees_after.png。
extends Node

const ROOT := "user://tmp_capture_trees"


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 1200:
		await get_tree().process_frame
		waited += 1
		if waited >= 60 and main.chunk_manager.is_idle():
			break
	print("world ready")

	# 找最近的一棵树（TreeManager 实体）
	var tm: Node = main.tree_manager
	var tree = null
	for tid in tm._trees:
		tree = tm._trees[tid]["instance"]
		break
	if tree == null:
		print("NO TREE FOUND")
		get_tree().quit(1)
		return
	var origin: Vector3i = tree.origin
	print("tree at %s, branches %d" % [origin, tree.cell_to_branch.size()])

	# 传送俯拍
	var player: PlayerController = main.player
	player.global_position = Vector3(
			float(origin.x) - 8.0, float(origin.y) + 10.0,
			float(origin.z) - 8.0)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI * 0.75
	player.camera.rotation.x = -0.5
	main.chunk_manager.focus = player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/trees_before.png")
	print("before saved")

	# 砍主干底部（树根上一格——切断整树）
	var cut := Vector3i(origin.x, origin.y + 1, origin.z)
	main.world.set_block(cut, VoxelTypes.AIR_ID)
	tm.on_branch_broken(cut)
	print("trunk cut at %s" % cut)

	# 等倒树（5 秒物理 + 落地）
	for i in 360:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/trees_after.png")
	print("after saved; remaining branches: %d; falling: %d" % [
			tree.cell_to_branch.size(), tm._falling.size()])
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
