## 影子漏光 v15：木质 SHADOWS_ONLY 代理修复后，用户位姿复验。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld2"


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
	get_window().size = Vector2i(1727, 1164)
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
	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	player.global_position = Vector3(51.11, 15.0, -96.06)
	player.velocity = Vector3.ZERO
	player.rotation.y = -0.160614654421806
	player.camera.rotation.x = -0.67059999704361
	for i in 200:
		await get_tree().process_frame
		if i > 80 and main.chunk_manager.is_idle():
			break

	await _settle()
	_shot("res://debug/v15_fixed_s1.png")
	sun.shadow_enabled = false
	await _settle()
	_shot("res://debug/v15_fixed_ref.png")
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
