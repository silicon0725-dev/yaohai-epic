## 影子漏光复现 v3：用户真实机位——玩家站在树旁（5-6 格），
## 太阳在背后侧，影子拉向脚前（大掠射角把深度断缝拉成长亮线）。
## S1=当前修复状态；S2=树网格 cast off（只留冠投影，看枝干贡献）；
## S3=冠投影也 off（只留区块叶块）。
extends Node

const ROOT := "user://tmp_capture_shadow3"

var main: Node
var sun: DirectionalLight3D


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	main = load("res://scenes/main.tscn").instantiate()
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
	print("tree at %s cells %d" % [origin, tree.cell_to_branch.size()])

	sun = _find_sun(main)
	if sun == null:
		print("NO SUN")
		get_tree().quit(1)
		return
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()
	print("light dir %s flat %s" % [ld, flat])

	# 用户机位：树旁 5.5 格、影子拉向脚前、平视略俯
	var player: PlayerController = main.player
	player.global_position = Vector3(origin) + flat * 5.5 + Vector3(0, 1.5, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.18
	main.chunk_manager.focus = player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	_shot("res://debug/shadow4_usercam.png")

	# S2：树网格本体停止投影（只留冠投影+叶块）
	var crown_nodes: Array = []
	for tid in tm._trees:
		var mn = tm._trees[tid]["mesh_node"]
		if mn == null:
			continue
		mn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for ch in mn.get_children():
			if ch.name == "CrownShadow":
				crown_nodes.append(ch)
	await _settle()
	_shot("res://debug/shadow4_treenomesh.png")

	# S3：冠投影也关（只留区块叶块投影）
	for ch in crown_nodes:
		ch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _settle()
	_shot("res://debug/shadow4_leavesonly.png")
	print("done")
	get_tree().quit(0)


func _settle() -> void:
	for i in 40:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _find_sun(node: Node) -> DirectionalLight3D:
	for c in node.get_children():
		if c is DirectionalLight3D:
			return c
		var r = _find_sun(c)
		if r != null:
			return r
	return null
