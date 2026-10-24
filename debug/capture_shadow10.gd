## 影子漏光 v10：SHADOWS_ONLY 在 gl_compatibility 阴影通道是否生效。
## 开阔地放 4×4×4 悬空盒：A1 投影(SHADOWS_ONLY)/A2 隐藏 — 有差异=生效。
## B1 正常投影作对照。
extends Node

const ROOT := "user://tmp_capture_shadow10"


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

	var sun: DirectionalLight3D = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()

	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	# 盒子：玩家影向 14 格外、地表上方 5 格悬空
	var gy: float = player.global_position.y
	var box_pos := player.global_position + flat * 14.0
	box_pos.y = gy + 5.0
	var box := MeshInstance3D.new()
	var am := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 0, Vector2.ZERO, 0.0, 0.0)
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 1, Vector2.ZERO, 0.0, 0.0)
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 2, Vector2.ZERO, 0.0, 0.0)
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 3, Vector2.ZERO, 0.0, 0.0)
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 4, Vector2.ZERO, 0.0, 0.0)
	TreeMeshBuilder._box(verts, norms, PackedVector2Array(), idx,
			Vector3(-2, -2, -2), Vector3(2, 2, 2), 5, Vector2.ZERO, 0.0, 0.0)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	box.mesh = am
	box.position = box_pos
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	main.add_child(box)
	print("box at ", box_pos)

	player.global_position = box_pos - flat * 18.0
	player.global_position.y = gy + 1.5
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.22
	await _settle_long()

	await _settle()
	_shot("res://debug/u10_a1_shadowsonly.png")
	box.visible = false
	await _settle()
	_shot("res://debug/u10_a2_hidden.png")
	box.visible = true
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	await _settle()
	_shot("res://debug/u10_b1_normal.png")
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
