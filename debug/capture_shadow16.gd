## 影子代理 v2（段锥台）验证：干净距离扫描（随机世界单树），
## 每距离影/无影成对，与 u12（整格立方版）/ Forward+ 基线对比。
## 判定：影子帧 vs 参照帧的差域内不得出现规律亮斑（梯子纹）。
extends Node

const ROOT := "user://tmp_capture_shadow12"


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
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
	print("tree at ", origin)

	var sun: DirectionalLight3D = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()
	var player: PlayerController = main.player
	main.chunk_manager.focus = player

	for dist in [8.0, 14.0, 20.0, 28.0]:
		player.global_position = Vector3(origin) + flat * dist + Vector3(0, 2.5, 0)
		player.velocity = Vector3.ZERO
		player.rotation.y = atan2(flat.x, flat.z)
		player.camera.rotation.x = -0.30
		await _settle_long()
		await _settle()
		_shot("res://debug/u16_d%02d.png" % int(dist))
		sun.shadow_enabled = false
		await _settle()
		_shot("res://debug/u16_d%02d_ref.png" % int(dist))
		sun.shadow_enabled = true
	print("done")
	get_tree().quit(0)


func _settle_long() -> void:
	for i in 150:
		await get_tree().process_frame


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
