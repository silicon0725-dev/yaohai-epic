## 树形近景验收（v2 生成器）：找一棵树 → 相机拉到 6 格侧拍整树
## → 砍主干 → 等倒伏 → 拍落地。输出 debug/treev2_close_*.png。
## （capture_trees 的 -8,+10 俯拍太远：树冠糊成植被层、倒树不可辨，
## 视觉验收无效——picture-looking 判读结论）
extends Node

const ROOT := "user://tmp_capture_treev2"


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
	# 找孤立树（±8 格内无其他树根——背景树冠粘连让判读失效，
	# picture-looking 两轮结论）
	var tree = null
	var origins := []
	for tid in tm._trees:
		origins.append((tm._trees[tid]["instance"] as TreeInstance).origin)
	for tid in tm._trees:
		var cand: TreeInstance = tm._trees[tid]["instance"]
		var isolated := true
		for o in origins:
			if o != cand.origin and (o as Vector3i).distance_to(cand.origin) < 16.0:
				isolated = false
				break
		if isolated:
			tree = cand
			break
	if tree == null and not tm._trees.is_empty():
		tree = tm._trees[tm._trees.keys()[0]]["instance"]
	if tree == null:
		print("NO TREE FOUND")
		get_tree().quit(1)
		return
	var origin: Vector3i = tree.origin
	print("tree at %s, branches %d" % [origin, tree.cell_to_branch.size()])

	# 近景侧拍：自建相机直接 look_at 目标树（player 相机受控制器
	# 逻辑/姿态重置干扰，两轮背对树实锤）
	var cam := Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	await get_tree().process_frame
	cam.current = true
	var tree_mid := Vector3(float(origin.x), float(origin.y) + 6.0,
			float(origin.z))
	cam.global_position = Vector3(
			float(origin.x) - 7.5, float(origin.y) + 8.0,
			float(origin.z) - 7.5)
	cam.look_at(tree_mid, Vector3.UP)
	main.chunk_manager.focus = main.player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	# 砍前再校一次（期间无鼠标输入，姿态稳定）
	cam.look_at(tree_mid, Vector3.UP)
	print('CAM pos=', cam.global_position, ' current=', cam.is_current(),
		' viewport_cam=', get_viewport().get_camera_3d())
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/treev2_close_before.png")
	print("before saved")

	# 砍一根侧枝（用户场景：砍枝后剩余树应网格重建——被砍枝干从
	# 剩余树 mesh 消失）。硬证据：mesh_node instance id 前后变化
	var branch_cut := Vector3i.ZERO
	for c in tree.cell_to_branch:
		if tree.cell_to_branch[c] != tree.root_branch_id:
			branch_cut = c
			break
	if branch_cut != Vector3i.ZERO:
		var old_mid: int = main.tree_manager._trees[
				tree.tree_id]["mesh_node"].get_instance_id()
		var branches_before: int = tree.branches.size()
		main.world.set_block(branch_cut, VoxelTypes.AIR_ID)
		tm.on_branch_broken(branch_cut)
		for i in 5:
			await get_tree().process_frame
		var entry: Dictionary = main.tree_manager._trees.get(tree.tree_id, {})
		var new_mid: int = -1
		if not entry.is_empty() and entry["mesh_node"] != null:
			new_mid = (entry["mesh_node"] as Node).get_instance_id()
		print("branch cut at %s: branches %d->%d, mesh_node %d->%d (%s)" % [
				branch_cut, branches_before, tree.branches.size(),
				old_mid, new_mid,
				"rebuilt" if new_mid != old_mid else "NOT REBUILT"])
		# 仰视机位（树冠下方朝上拍）：横向枝末端突出/收缩从下往上看
		# 最明显（用户实机报告视角）
		cam.global_position = Vector3(
				float(origin.x) + 3.0, float(origin.y) + 3.0,
				float(origin.z) + 3.0)
		cam.look_at(Vector3(float(origin.x), float(origin.y) + 11.0,
				float(origin.z)), Vector3.UP)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(
				"res://debug/treev2_branch_cut.png")
		print("branch-cut saved")
		# 回近景机位继续倒树流程
		cam.global_position = Vector3(
				float(origin.x) - 7.5, float(origin.y) + 8.0,
				float(origin.z) - 7.5)
		cam.look_at(tree_mid, Vector3.UP)

	# 玩家放树正南 10 格：倒向 -Z（对照方向——应倒平或垂下坡）
	main.player.global_position = Vector3(float(origin.x),
			float(origin.y) + 3.0, float(origin.z) + 10.0)
	# 砍第二格 y+1（用户场景：砍非底端——铰链在断口、整树下坠
	# 闭合断口→地面空隙；此前铰链钉地面线+无下坠=侧枝上扬"跳一格"）
	var cut := Vector3i(origin.x, origin.y + 1, origin.z)
	print("cut cell=", cut, " ground_top_y=", origin.y)
	main.world.set_block(cut, VoxelTypes.AIR_ID)
	tm.on_branch_broken(cut)
	print("trunk cut at %s" % cut)

	# 断口特写（砍后 3 帧、树仍近竖直）：树干底端应终止于 B0 格底
	#（砍口年轮可见、与树桩间是被砍空格）——root_drop 下探半格盒
	# 曾悬在断口=底部多余半格，落地结算消失=实机"往上跳"错觉
	for i in 3:
		await get_tree().process_frame
	cam.global_position = Vector3(float(origin.x) - 4.0,
			float(origin.y) + 3.5, float(origin.z) - 4.0)
	cam.look_at(Vector3(float(origin.x) + 0.5, float(origin.y) + 1.5,
			float(origin.z) + 0.5), Vector3.UP)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/treev2_anim_start_base.png")
	print("base closeup saved")

	# 动画倒伏轨迹采样（DT 碰撞反馈式：旋转→回弹→落地全过程），
	# 每 20 帧打印 ang/vel/landed；landed（停稳）即拍落地帧。
	# 前 12 帧逐帧打印动画树世界 AABB（用户实机"刚开始跳起半格"
	# ——精确量化动画开始时树体上/下移动）
	var anim_holder: Node3D = null
	for h in main.tree_manager._falling_anims:
		anim_holder = h
	for i in 12:
		await get_tree().process_frame
		if anim_holder != null and is_instance_valid(anim_holder):
			var mn_y := 1e9
			var mx_y := -1e9
			for sub in anim_holder.get_children():
				if sub is MeshInstance3D:
					var ab: AABB = (sub as MeshInstance3D).get_aabb()
					var t: Transform3D = (sub as MeshInstance3D).global_transform
					for corner in 8:
						var wp: Vector3 = t * ab.get_endpoint(corner)
						mn_y = minf(mn_y, wp.y)
						mx_y = maxf(mx_y, wp.y)
			var st: Dictionary = main.tree_manager._falling_anims[
					anim_holder]
			print("AABB f%d y=[%.3f..%.3f] drop=%.3f ang=%.2f" % [
					i, mn_y, mx_y, float(st["drop"]),
					rad_to_deg(float(st["ang"]))])
	var traced := 0
	for i in 300:
		await get_tree().process_frame
		traced = i
		if i % 20 == 0:
			for a in main.tree_manager._falling_anims:
				print("TRACE i=", i, " ang=", snapi3(rad_to_deg(float(
						main.tree_manager._falling_anims[a]["ang"]))),
					" vel=", snapi3(float(main.tree_manager._falling_anims[a]["vel"]) * 100.0),
					" drop=", snapi3(float(main.tree_manager._falling_anims[a]["drop"])),
					" landed=", main.tree_manager._falling_anims[a]["landed"])
		var any_airborne := false
		for a in main.tree_manager._falling_anims:
			if not bool(main.tree_manager._falling_anims[a]["landed"]):
				any_airborne = true
		if not any_airborne:
			print("LANDED at frame ", i, " anims=", main.tree_manager._falling_anims.size())
			break
	print("trace done, frames=", traced)
	cam.global_position = Vector3(
			float(origin.x) - 12.0, float(origin.y) + 16.0,
			float(origin.z) - 12.0)
	cam.look_at(Vector3(float(origin.x), float(origin.y) + 2.0,
			float(origin.z)), Vector3.UP)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/treev2_anim_landed.png")
	print("landed saved; remaining branches: %d; falling: %d" % [
			tree.cell_to_branch.size(), tm._falling.size()])
	# 溶解中特写：settle 1s + dissolve ~0.65s——倒树应呈颗粒状缺失
	# （抖动透明，非 alpha 渐变）
	await get_tree().create_timer(1.45).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://debug/treev2_dissolving.png")
	print("dissolving saved; anims=", tm._falling_anims.size())
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)


func snapi3(v: float) -> int:
	return int(round(v * 100.0))
