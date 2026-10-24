## 探针：打印锥台版阴影网格的图元 AABB 尺寸分布（前 12 个 + 分类统计）。
extends SceneTree

const TreeGenScript := preload("res://systems/trees/tree_generator.gd")
const SpeciesScript := preload("res://systems/trees/tree_species.gd")
const MeshBuilderScript := preload("res://systems/trees/tree_mesh_builder.gd")


func _init() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var tree = TreeGenScript.generate(sp, 2000, Vector3i(0, 30, 7))
	var mesh: ArrayMesh = MeshBuilderScript.build_shadow_mesh(tree)
	var arrays: Array = mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	print("verts=", vs.size(), " boxes=", vs.size() / 24)
	var stats := {}
	@warning_ignore("integer_division")
	for b in vs.size() / 24:
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for j in 24:
			var v: Vector3 = vs[b * 24 + j]
			mn = mn.min(v)
			mx = mx.max(v)
		var size := mx - mn
		var key := "x=%.2f y=%.2f z=%.2f" % [size.x, size.y, size.z]
		stats[key] = int(stats.get(key, 0)) + 1
		if b < 12:
			print("box %d size %s" % [b, key])
	print("--- 统计 ---")
	for k in stats:
		print("%s  x%d" % [k, stats[k]])
	quit(0)
