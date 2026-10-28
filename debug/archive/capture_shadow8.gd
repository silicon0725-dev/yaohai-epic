## 影子漏光 v8：验证"cutout 叶面在阴影通道被 alpha-discard"假设。
## t3 视图：S1 现状 | S2 区块网格 material_override=不透明（阴影面全实心）
## | S3 无影参考。S2 漏光≈0 → 假设成立。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld"
const CAM_TREE := Vector3(-132, 10, -18)


func _ready() -> void:
	if not DirAccess.dir_exists_absolute(ROOT):
		var d := DirAccess.open("user://saves")
		d.make_dir_recursive_absolute(ROOT)
		d.copy_absolute(SRC + "/world.json", ROOT + "/world.json")
		d.make_dir_recursive_absolute(ROOT + "/chunks")
		var sc := DirAccess.open(SRC + "/chunks")
		var tc := DirAccess.open(ROOT + "/chunks")
		for f in sc.get_files():
			tc.copy_absolute(sc.get_current_dir() + "/" + f, tc.get_current_dir() + "/" + f)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 120 and main.chunk_manager.is_idle():
			break
	print("world ready")

	var sun: DirectionalLight3D = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()
	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	player.global_position = Vector3(CAM_TREE) + flat * 10.0 + Vector3(0, 2.5, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(flat.x, flat.z)
	player.camera.rotation.x = -0.25
	for i in 200:
		await get_tree().process_frame
		if i > 80 and main.chunk_manager.is_idle():
			break

	var chunks: Array = []
	for n in main.chunk_renderer.get_children():
		if n.name.begins_with("Chunk_"):
			chunks.append(n)
	print("chunks=", chunks.size())

	await _settle()
	_shot("res://debug/u8_s1_full.png")

	var opaque := StandardMaterial3D.new()
	opaque.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for c in chunks:
		c.material_override = opaque
	await _settle()
	_shot("res://debug/u8_s2_opaquechunk.png")

	for c in chunks:
		c.material_override = null
	sun.shadow_enabled = false
	await _settle()
	_shot("res://debug/u8_s3_ref.png")
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
