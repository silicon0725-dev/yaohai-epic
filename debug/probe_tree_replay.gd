extends SceneTree
const TreeGen := preload("res://systems/trees/tree_generator.gd")
const Species := preload("res://systems/trees/tree_species.gd")
func _init() -> void:
	# 1) has_tree_at 判定扫描成本（每区块 576 次，走 -8..24 网格）
	var t0 := Time.get_ticks_usec()
	var hits := 0
	for i in 40:
		var ox := i * 16 - 320
		for wx in range(ox - 4, ox + 16 + 4):
			for wz in range(-4, 16 + 4):
				if TreeGen.has_tree_at(1337, Vector2i(wx, wz)):
					hits += 1
	var t_hash := (Time.get_ticks_usec() - t0) / 40
	# 2) 每棵树的重放成本（generate + leaf_cells，不含网格）
	var sp: TreeSpecies = Species.new()
	t0 = Time.get_ticks_usec()
	var n := 0
	for i in 200:
		var origin := Vector3i(500 + i * 3, 20, 500 + i * 7)
		if not TreeGen.has_tree_at(1337, Vector2i(origin.x, origin.z)):
			continue
		var tree = TreeGen.generate(sp, 1337, origin)
		TreeGen.leaf_cells(tree)
		n += 1
	var t_tree := 0
	if n > 0:
		t_tree = (Time.get_ticks_usec() - t0) / n
	print("tree_replay hash_scan_us_per_chunk=%d hits_per_40=%d replay_us_per_tree=%d (n=%d)" % [
		t_hash, hits, t_tree, n])
	quit(0)
