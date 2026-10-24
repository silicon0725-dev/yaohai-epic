## 砍枝复现：取景一棵树 → 砍侧枝中间格 → 定时截图（0.3/1/2.5/6 秒）
## + 逐阶段打印倒伏刚体状态（诊断瞬隐/穿地）。
extends Node

const ROOT := "user://tmp_capture_chop"


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
	print("tree at %s cells=%d branches=%d" % [
			origin, tree.cell_to_branch.size(), tree.branches.size()])

	# 找一根 ≥4 格的水平枝，切中间格（B 段 ≥2 走倒伏刚体）
	var cut := Vector3i.ZERO
	for bid in tree.branches:
		var n: TreeInstance.BranchNode = tree.branches[bid]
		if n.parent_id == tree.root_branch_id and n.axis_step().y == 0:
			var cs: Array = n.cells()
			if cs.size() >= 4:
				cut = cs[int(cs.size() / 2)]
				print("plank %s..%s (%d cells), cut %s" % [
						n.start_cell, n.end_cell, cs.size(), cut])
				break
	if cut == Vector3i.ZERO:
		print("NO SUITABLE PLANK")
		get_tree().quit(1)
		return

	# 取景：站在切口外看向树
	var player: PlayerController = main.player
	var cam_pos := Vector3(cut) + Vector3(4.0, 2.0, 4.0)
	player.global_position = cam_pos
	player.velocity = Vector3.ZERO
	var look := Vector3(cut) + Vector3(0.5, 0.0, 0.5)
	player.rotation.y = atan2(look.x - cam_pos.x, look.z - cam_pos.z) + PI
	player.camera.rotation.x = -0.25
	main.chunk_manager.focus = player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/chop_before.png")
	print("before saved")

	# 砍（BRANCH 占位 → AIR，信号驱动砍伐管线）
	main.world.set_block(cut, VoxelTypes.AIR_ID)
	tm.on_branch_broken(cut)
	print("cut done: falling=%d" % tm._falling.size())

	# 定时截图 + 刚体追踪
	var marks := [18, 60, 150, 360]
	var names := ["chop_t03", "chop_t1", "chop_t25", "chop_t6"]
	for k in marks.size():
		var target: int = marks[k]
		while waited < 10000 and target > 0:
			await get_tree().process_frame
			target -= 1
		for body in tm._falling.keys():
			print("  t=%s body pos=%s vel=%s" % [
					names[k], body.global_position, body.linear_velocity])
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(
				"res://debug/%s.png" % names[k])
		print("%s saved; tree cells=%d falling=%d" % [
				names[k], tree.cell_to_branch.size(), tm._falling.size()])

	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
