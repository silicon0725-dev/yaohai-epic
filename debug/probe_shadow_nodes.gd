## 探针：确认 WoodShadow/CrownShadow 节点真实创建与几何规模。
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
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 120 and main.chunk_manager.is_idle():
			break

	var tm: Node = main.tree_manager
	var woods: Array = []
	for n in tm.get_children():
		if n.name.begins_with("Tree_"):
			woods.append(n)
	print("tree nodes: ", woods.size())
	var t0: MeshInstance3D = woods[0]
	print("tree[0] children:")
	for ch in t0.get_children():
		var info := "  %s cast=%d" % [ch.name, ch.cast_shadow]
		if ch is MeshInstance3D and ch.mesh != null:
			var arr = ch.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			info += " surfaces=%d verts=%d" % [ch.mesh.get_surface_count(), verts.size()]
			var aabb: AABB = ch.mesh.get_aabb()
			info += " aabb=%s" % aabb
		print(info)
	get_tree().quit(0)
