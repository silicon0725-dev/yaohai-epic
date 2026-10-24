## 影子漏光 v6：加载用户真实存档（副本！），围绕玩家附近的树
## 做距离机位扫描（10/16/22 格，顺影向看树），每帧配无影参考帧。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld"


func _ready() -> void:
	_copy_save()
	main_run()


func _copy_save() -> void:
	var d := DirAccess.open("user://saves")
	if d.dir_exists_absolute(ROOT):
		# 清旧副本
		var old := DirAccess.open(ROOT)
		for f in old.get_files():
			old.remove(f)
		var oc := DirAccess.open(ROOT + "/chunks")
		if oc:
			for f in oc.get_files():
				oc.remove(f)
		d.remove(ROOT + "/chunks")
		d.remove(ROOT)
		d = DirAccess.open("user://saves")
	d.make_dir_recursive_absolute(ROOT)
	d.copy_absolute(SRC + "/world.json", ROOT + "/world.json")
	d.make_dir_recursive_absolute(ROOT + "/chunks")
	var sc := DirAccess.open(SRC + "/chunks")
	var tc := DirAccess.open(ROOT + "/chunks")
	var n := 0
	for f in sc.get_files():
		tc.copy_absolute(sc.get_current_dir() + "/" + f, tc.get_current_dir() + "/" + f)
		n += 1
	print("copied ", n, " chunk files")


func main_run() -> void:
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

	var tm: Node = main.tree_manager
	var ppos := Vector3(-151.3, 14.0, -7.1)
	# 找玩家附近最近的 5 棵树
	var cands: Array = []
	for tid in tm._trees:
		var t = tm._trees[tid]["instance"]
		cands.append([Vector3(t.origin).distance_to(ppos), t])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	var trees: Array = []
	for c in cands.slice(0, 5):
		trees.append(c[1])
		print("tree dist %.1f origin %s" % [c[0], c[1].origin])

	var sun: DirectionalLight3D = _find_sun(main)
	var ld := -sun.global_transform.basis.z.normalized()
	var flat := Vector3(ld.x, 0.0, ld.z).normalized()

	var player: PlayerController = main.player
	main.chunk_manager.focus = player
	var idx := 0
	for tree in trees:
		idx += 1
		var origin: Vector3i = tree.origin
		for dist in [10.0, 16.0, 22.0]:
			player.global_position = Vector3(origin) + flat * dist + Vector3(0, 2.5, 0)
			player.velocity = Vector3.ZERO
			player.rotation.y = atan2(flat.x, flat.z)
			player.camera.rotation.x = -0.25
			for i in 150:
				await get_tree().process_frame
				if i > 60 and main.chunk_manager.is_idle():
					break
			await _settle()
			_shot("res://debug/u_sh_t%d_d%02d.png" % [idx, int(dist)])
			sun.shadow_enabled = false
			await _settle()
			_shot("res://debug/u_ref_t%d_d%02d.png" % [idx, int(dist)])
			sun.shadow_enabled = true
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
