## t3 树冠体素真相：leaf_cells/leaf_shadow_cells 各格在世界里的实际方块。
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld"
const TREE_ORIGIN := Vector3i(-132, 10, -18)


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

	var tm: Node = main.tree_manager
	var target = null
	for tid in tm._trees:
		var t = tm._trees[tid]["instance"]
		if t.origin == TREE_ORIGIN:
			target = t
			break
	if target == null:
		print("TREE NOT MANAGED (replaying from generator)")
		target = TreeGenerator.generate(TreeSpecies.new(), 1337, TREE_ORIGIN)
	print("origin=", target.origin, " branches=", target.branches.size())

	var visual := {}
	for c in TreeGenerator.leaf_cells(target):
		visual[c] = true
	var shadow := TreeGenerator.leaf_shadow_cells(target)
	print("leaf_cells=", visual.size(), " shadow_cells=", shadow.size())

	var world: VoxelWorld = main.world
	var leaf_ok := 0
	var mismatch := {}      # block_id -> count（生成器说叶，世界不是叶）
	var air_leaf_cells: Array[Vector3i] = []
	for c in shadow:
		var bid: int = world.get_block(c)
		if visual.has(c):
			if bid == VoxelTypes.LEAVES_ID:
				leaf_ok += 1
			else:
				mismatch[bid] = mismatch.get(bid, 0) + 1
				if bid == VoxelTypes.AIR_ID and air_leaf_cells.size() < 12:
					air_leaf_cells.append(c)
	print("leaf_ok=", leaf_ok, " mismatch=", mismatch)
	print("sample AIR-under-leaf-cells=", air_leaf_cells)
	get_tree().quit(0)
