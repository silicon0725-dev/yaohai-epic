## 影子漏光 v5：固定机位（20 格）分级关闭，事后用无影参考帧
## 求出真实影子多边形，再统计多边形内部亮像素（真漏光，免疫地形干扰）。
## S1 现状全开 | S2 冠投影隐藏 | S3 +树干网格投影关 | S4 太阳投影关（参考）
extends Node

const ROOT := "user://tmp_capture_shadow5"

var main: Node
var sun: DirectionalLight3D


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	main = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 1500:
		await get_tree().process_frame
		waited += 1
		if waited >= 90 and main.chunk_manager.is_idle():
			break
	print("world ready")

	var tm: Node = main.tree_manager
	var tree = null
	for tid in tm._trees:
		tree = tm._trees[tid]["instance"]
		break
	if tree == null:
		print("NO TREE")
		get_tree().quit(1)
		return
	var origin: Vector3i = tree.origin

	sun = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()

	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	player.global_position = Vector3(origin) + flat * 20.0 + Vector3(0, 2.5, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.30
	for i in 150:
		await get_tree().process_frame
		if i > 60 and main.chunk_manager.is_idle():
			break

	# S1 现状
	await _settle()
	_shot("res://debug/shadow6_s1_full.png")

	# S2 隐藏冠投影（挂在 Tree_ 网格下，需递归找）
	var crowns: Array = tm.find_children("CrownShadow*", "", true, false)
	for c in crowns:
		c.visible = false
	print("crowns hidden: ", crowns.size())
	await _settle()
	_shot("res://debug/shadow6_s2_nocrown.png")

	# S3 树干网格投影关（叶=区块网格仍在投影）
	for c in crowns:
		c.visible = true
	var meshes := _collect(tm, "Tree_")
	for m in meshes:
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _settle()
	_shot("res://debug/shadow6_s3_leafonly.png")

	# S4 太阳投影关（参考帧）
	sun.shadow_enabled = false
	await _settle()
	_shot("res://debug/shadow6_s4_nooff.png")

	print("done")
	get_tree().quit(0)


func _settle() -> void:
	for i in 40:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _collect(tm: Node, prefix: String) -> Array:
	var out: Array = []
	for n in tm.get_children():
		if n.name.begins_with(prefix):
			out.append(n)
	return out


func _find_sun(node: Node) -> DirectionalLight3D:
	for c in node.get_children():
		if c is DirectionalLight3D:
			return c
		var r = _find_sun(c)
		if r != null:
			return r
	return null
