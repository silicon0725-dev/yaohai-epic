## 影子漏光复现：真实主场景（默认太阳阴影参数）俯拍树影。
## A=默认参数；B=normal_bias=0 + bias=0.02；C=B + 4 splits + 60m。
## 对照三图定位：枝影"一节一节漏光"是阴影参数（偏置推穿细枝）
## 还是网格真透光（则 A/B/C 三图漏光一致）。
extends Node

const ROOT := "user://tmp_capture_shadow"

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
	print("sun rot %s bias %s normal_bias %s mode %d max_dist %s" % [
			sun.rotation_degrees, sun.shadow_bias, sun.shadow_normal_bias,
			sun.directional_shadow_mode, sun.directional_shadow_max_distance])
	print("light dir %s" % -sun.global_transform.basis.z.normalized())

	# 俯拍：相机在树斜上方垂直下看，树体与地面投影同框
	var player: PlayerController = main.player
	player.global_position = Vector3(
			float(origin.x) + 6.5, float(origin.y) + 11.0,
			float(origin.z) + 6.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI * 0.75
	player.camera.rotation.x = -1.0
	main.chunk_manager.focus = player
	for i in 240:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break
	await RenderingServer.frame_post_draw
	_shot("res://debug/shadow_a_default.png")

	# B：去法线偏置 + 降深度偏置
	sun.shadow_normal_bias = 0.0
	sun.shadow_bias = 0.02
	await _settle()
	_shot("res://debug/shadow_b_bias0.png")

	# C：B + 近距 4 级分割（提阴影贴图对细枝的分辨率）
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 60.0
	await _settle()
	_shot("res://debug/shadow_c_splits.png")
	print("done")
	get_tree().quit(0)


func _settle() -> void:
	for i in 30:
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
