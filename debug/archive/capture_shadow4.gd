## 影子漏光 v4：距离扫描。同机位角度（顺影向看树），距离 8/14/20/28
## 格各拍一帧，自动统计影子带内亮缝段数——找到漏光出现的距离。
extends Node

const ROOT := "user://tmp_capture_shadow4"

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

	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	for dist in [8.0, 14.0, 20.0, 28.0]:
		player.global_position = Vector3(origin) + flat * dist + Vector3(0, 2.5, 0)
		player.velocity = Vector3.ZERO
		player.rotation.y = atan2(flat.x, flat.z)
		player.camera.rotation.x = -0.30
		for i in 120:
			await get_tree().process_frame
			if i > 40 and main.chunk_manager.is_idle():
				break
		await RenderingServer.frame_post_draw
		_shot("res://debug/shadow5_d%02d.png" % int(dist))

	# 近距对照：阴影收近 40m（若有效=分辨率问题实锤）
	player.global_position = Vector3(origin) + flat * 20.0 + Vector3(0, 2.5, 0)
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.30
	sun.directional_shadow_max_distance = 40.0
	await _settle()
	_shot("res://debug/shadow5_d20_md40.png")
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
