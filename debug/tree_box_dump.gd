## 诊断探针：dump 一棵树网格的全部 AABB 盒，肉眼核对断口。
extends SceneTree

const TreeGenScript := preload("res://systems/trees/tree_generator.gd")
const SpeciesScript := preload("res://systems/trees/tree_species.gd")
const MeshBuilderScript := preload("res://systems/trees/tree_mesh_builder.gd")


func _init() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var tree = TreeGenScript.generate(sp, 1000, Vector3i(0, 30, 7))
	var trunk = tree.branches[tree.root_branch_id]
	print("trunk: start=%s end=%s r=%d->%d" % [trunk.start_cell, trunk.end_cell,
			trunk.radius_start, trunk.radius_end])
	for bid in tree.branches:
		var n: TreeInstance.BranchNode = tree.branches[bid]
		if bid == tree.root_branch_id:
			continue
		print("  branch %d: parent=%d %s -> %s r=%d->%d axis=%s" % [bid, n.parent_id,
				n.start_cell, n.end_cell, n.radius_start, n.radius_end, n.axis_step()])

	var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
	var arrays: Array = mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	@warning_ignore("integer_division")
	var box_count := vs.size() / 24
	print("boxes total: %d" % box_count)
	for b in box_count:
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for j in 24:
			var v: Vector3 = vs[b * 24 + j]
			mn = mn.min(v)
			mx = mx.max(v)
		# 只打印 y∈[4,9]（侧枝层附近）
		if mn.y >= 3.5 and mn.y <= 9.5:
			print("box %2d: (%.3f, %.3f, %.3f) .. (%.3f, %.3f, %.3f)" % [b,
					mn.x, mn.y, mn.z, mx.x, mx.y, mx.z])
	quit(0)
