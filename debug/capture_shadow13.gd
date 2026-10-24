## 影子漏光 v13：用用户存档的精确位姿（51.1,15.0,-96.1, yaw -0.1606,
## pitch -0.6706）复现"树干旁条纹影"，再分级归因。
## 度量改用"影子多边形内亮占比"（不要求封闭——用户看到的是开放亮缝）。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld2"


func _ready() -> void:
	var d := DirAccess.open("user://saves")
	if d.dir_exists_absolute(ROOT):
		var old := DirAccess.open(ROOT)
		for f in old.get_files():
			old.remove(f)
		var oc := DirAccess.open(ROOT + "/chunks")
		if oc:
			for f in oc.get_files():
				oc.remove(f)
		d.remove(ROOT + "/chunks")
		d.remove(ROOT)
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

	var tm: Node = main.tree_manager
	var crowns: Array = tm.find_children("CrownShadow*", "", true, false)
	var woods: Array = []
	for n in tm.get_children():
		if n.name.begins_with("Tree_"):
			woods.append(n)
	print("crowns=", crowns.size(), " woods=", woods.size())

	await _settle()
	_shot("res://debug/v13_s1_full.png")

	for c in crowns:
		c.visible = false
	await _settle()
	_shot("res://debug/v13_s2_nocrown.png")
	for c in crowns:
		c.visible = true

	for wd in woods:
		wd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _settle()
	_shot("res://debug/v13_s3_nowood.png")

	for c in crowns:
		c.visible = false
	await _settle()
	_shot("res://debug/v13_s4_neither.png")
	for wd in woods:
		wd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for c in crowns:
		c.visible = true

	sun.shadow_enabled = false
	await _settle()
	_shot("res://debug/v13_s5_ref.png")
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
