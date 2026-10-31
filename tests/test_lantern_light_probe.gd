## 提灯放置后网格顶点色探针：set_block → 光照失效 → 重网格后，
## 地面顶点色应变为暖亮（方块光 14 的 BSL 暖色调制）。
extends VoxelTestCase


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	var world := make_world(4, [Vector3i.ZERO])
	activate_light(world, Vector3i.ZERO)
	# 封闭石室（4³ 块内）：地面 y=0 全封 + 顶盖 y=3 全封，室内 y=1..2。
	# 天光被顶盖截断 → 室内天光 0，方块光贡献不被天光淹没
	for x in range(0, 4):
		for z in range(0, 4):
			world.set_block(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
			world.set_block(Vector3i(x, 3, z), VoxelTypes.STONE_ID)
	var chunk: ChunkData = world.chunks.get(Vector3i.ZERO)
	check_eq(chunk.get_sky_light(Vector3i(2, 1, 2)), 0, "室内天光 0")
	check_eq(chunk.get_block_light(Vector3i(2, 1, 1)), 0, "放置前无光")
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.LANTERN_ID)
	check_eq(chunk.get_block_light(Vector3i(2, 1, 1)), 14, "放置后地面邻格光 14")

	# 重网格（与游戏 _commit_mesh 同路径），取颜色数组
	var arrays := ChunkMesher.build_mesh_arrays(world.registry, chunk,
			world.collect_neighbors(Vector3i.ZERO), null)
	var colors: PackedColorArray = arrays["colors"]
	var verts: PackedVector3Array = arrays["vertices"]
	check(colors.size() == verts.size(), "顶点色与顶点同数")
	# 诊断：y 分布直方图
	var ys := {}
	for v in verts:
		ys[v.y] = int(ys.get(v.y, 0)) + 1
	print("LANTERN_PROBE y分布=", ys, " 总顶点=", verts.size())
	# 找地面顶面（y=1 平面）的顶点：光 14 → 顶点色应暖亮（r 通道高）
	var warm_count := 0
	var dark_count := 0
	var samples := []
	for i in verts.size():
		var v := verts[i]
		if absf(v.y - 1.0) < 0.01:
			var c := colors[i]
			if samples.size() < 6:
				samples.append("%s->(%0.2f,%0.2f,%0.2f)" % [v, c.r, c.g, c.b])
			if c.r > 0.5 and c.r > c.b + 0.1:
				warm_count += 1
			elif c.r < 0.2:
				dark_count += 1
	print("LANTERN_PROBE y=3 顶点 暖亮=", warm_count, " 暗=", dark_count)
	for s in samples:
		print("  ", s)
	check(warm_count > 0, "地面顶点色被方块光点亮（暖亮 %d 个）" % warm_count)
