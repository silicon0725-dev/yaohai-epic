## 植物对拍 v2：复现 test_native_equivalence"真实地形"用例（生成+光照+对比）
extends SceneTree


func _initialize() -> void:
	var registry = VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 1337
	var world := VoxelWorld.new(config, registry)
	var gen := TerrainGenerator.new(config)
	for cz in 2:
		for cx in 2:
			for cy in config.chunks_y:
				world.add_chunk(gen.generate_chunk(Vector3i(cx, cy, cz)))
	var chunk: ChunkData = world.get_chunk(Vector3i(0, 0, 0))
	var light := preload("res://systems/lighting/voxel_light.gd").new()
	light.world = world
	light.init_chunk_light(chunk, [])
	var neighbors: Array = world.collect_neighbors(Vector3i(0, 0, 0))
	var gd := ChunkMesher._build_gd(registry, chunk, neighbors)
	var bridge := preload("res://meshing/native_mesh_bridge.gd")
	var cs: Dictionary = bridge.build(false, registry, chunk, neighbors)
	var gv: PackedVector3Array = gd.get("cross_vertices", PackedVector3Array())
	var cv: PackedVector3Array = cs.get("cross_vertices", PackedVector3Array())
	print("GD verts=", gv.size(), " C# verts=", cv.size())
	# 索引也必须逐位一致（B8b 三角洞教训：等价测试曾只比顶点，
	# 双对角线索引洞两侧同错测不出来）
	var gi: PackedInt32Array = gd.get("cross_indices", PackedInt32Array())
	var ci: PackedInt32Array = cs.get("cross_indices", PackedInt32Array())
	if gi.size() != ci.size():
		print("IDX SIZE DIFF GD=", gi.size(), " C#=", ci.size())
	else:
		var idx_diff := 0
		for k in gi.size():
			if gi[k] != ci[k]:
				idx_diff += 1
		print("cross_indices diff=", idx_diff, " n=", gi.size())
	# hash 逐盐对拍（真实地形全部草顶格）
	var TS := preload("res://systems/trees/tree_scatter.gd")
	var nt = preload("res://meshing/native_terrain_bridge.gd").get_native(1, 64)
	var found := 0
	for wz in 32:
		for wx in 32:
			for i in 3:
				var args := [
					[wx, wz, 911],
					[wx * 4 + i, wz * 3 - i, 912 + i],
					[wx * 7 - i, wz * 5 + i, 921 + i],
					[wx * 2 + i, wz * 9 + i, 931 + i],
					[wx * 6 + i, wz + i, 941],
				]
				for arg in args:
					var g: float = TS.hash01(arg[0], arg[1], arg[2])
					var c: float = nt.Hash01I(arg[0], arg[1], arg[2])
					if absf(g - c) > 1e-12:
						print("HASH DIFF args=", arg, " GD=", g, " C#=", c)
						found += 1
						if found > 3:
							break
				if found > 3:
					break
			if found > 3:
				break
		if found > 3:
			break
	if found == 0:
		print("hash blade-args all equal")
	# 高精度打印疑似边界参数（j=44 格 wx=3 wz=0 i=1 的 rD）
	var TS2 := preload("res://systems/trees/tree_scatter.gd")
	var nt2 = preload("res://meshing/native_terrain_bridge.gd").get_native(1, 64)
	var a0: int = 3 * 6 + 1
	var b0: int = 0 + 1
	print("rD GD=", TS2.hash01(a0, b0, 941), " C#=", nt2.Hash01I(a0, b0, 941))
	print("rN GD=", TS2.hash01(3, 0, 911), " C#=", nt2.Hash01I(3, 0, 911))
	var diffed := false
	for i in mini(gv.size(), cv.size()):
		if gv[i] != cv[i]:
			print("FIRST DIFF i=", i, " GD=", gv[i], " C#=", cv[i])
			diffed = true
			for j in range(maxi(i - 12, 0), mini(i + 12, gv.size())):
				print("  j=", j, " GD=", gv[j], " C#=", cv[j])
			break
	if not diffed:
		print("verts equal n=", mini(gv.size(), cv.size()))
	quit(0)
