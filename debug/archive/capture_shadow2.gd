## 影子漏光复现 v2：玩家实际视角（中景、地面高度）看树影。
## v1 近距俯拍验证了偏置修复，但用户游玩距离更远——compatibility
## 渲染器阴影图集小，细枝在中距被贴图分辨率"打散"。
## S1=当前配置（复现）；S2=+max_distance 60；S3=+图集 4096/24bit；
## S4=+blur 0。
extends Node

const ROOT := "user://tmp_capture_shadow2"

var main: Node
var sun: DirectionalLight3D


func _ready() -> void:
	print("proj size=", ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/size"),
		" 16bits=", ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/16_bits"))
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

	# 中景机位：站在影子一侧、距树 14 格、视线顺着影子望向树
	var player: PlayerController = main.player
	player.global_position = Vector3(origin) + flat * 14.0 + Vector3(0, 2.0, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.22
	main.chunk_manager.focus = player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	_shot("res://debug/shadow3_fixed.png")
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
