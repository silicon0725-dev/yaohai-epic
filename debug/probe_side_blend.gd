## 草坡融合 + 侧面过渡变体的确定性判定探针：
## 手造两级草台阶（低台只铺半幅 x），断言三类面的 tile：
##   1. 斜下是草的暴露面 → 顶面 tile（满绿 blend）
##   2. 与 blend 面交界的土面 → 对应侧垂带变体（u1 侧）
##   3. 远离交界的土面 → 原版 grass_side
## 贪心与面剔除两条管线各验一遍（等价红线之外的"判定正确性"）。
## 按索引三角形取面中心定位；naive 用 UV 均值（=tile 中心）识别
## tile，贪心 UV 是平铺空间 → 用 UV2 原点（=tile 左下角）识别。
extends SceneTree

const S := 16


func _init() -> void:
	print("probe start")
	var failures := 0
	var registry: VoxelRegistry = VoxelTypes.build_default_registry()
	for mode in ["naive", "greedy"]:
		var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(S, S, S))
		# 基座
		for z in S:
			for x in S:
				chunk.set_block(Vector3i(x, 0, z), VoxelTypes.DIRT_ID)
		# 高台（z=0..3）y=1..3 草；低台（z=4..7）仅 x=0..3 铺 y=1 草
		for z in 4:
			for x in S:
				for y in range(1, 4):
					chunk.set_block(Vector3i(x, y, z), VoxelTypes.GRASS_ID)
		for z in range(4, 8):
			for x in 4:
				chunk.set_block(Vector3i(x, 1, z), VoxelTypes.GRASS_ID)
		var result: Dictionary
		# 27 槽 null 邻居（缺失=空气；判定面全在区块内部不受边界影响）
		var nb27: Array = []
		nb27.resize(27)
		if mode == "naive":
			# 面剔除也走 GD 内部路径（外层 build_mesh_arrays 优先 C#
			# 需要 26 邻居打包——手造单区块没有；C# 等价由全量测试保证）
			result = ChunkMesher._build_gd(registry, chunk, nb27)
		else:
			result = GreedyMesher._build_gd(registry, chunk, nb27)
		var verts: PackedVector3Array = result["vertices"]
		var indices: PackedInt32Array = result["indices"]
		var uvs: PackedVector2Array = result["uvs"]
		var uv2s: PackedVector2Array = result.get(
				"uv2", PackedVector2Array())
		var inv_c := 1.0 / TextureAtlasLoader.COLS
		var inv_r := 1.0 / TextureAtlasLoader.ROWS
		var tile_origin := {}
		for tname in ["grass_top", "grass_side", "grass_side_u0",
				"grass_side_u1", "grass_side_u01"]:
			var g := TextureAtlasLoader.tile_grid(tname)
			tile_origin[tname] = Vector2(
					float(g.x) * inv_c, float(g.y) * inv_r)
		# 面（三角形）中心 → tile 名。z=4 平面上的 +Z 面按 (x,y) 收集
		# quad（三角形）→ tile 名 + x 覆盖区间（贪心会把同 tile 相邻面
		# 合并成大 quad——中心定位法失效，改"检查点被哪个 quad 覆盖"）
		var quads_found: Array = []
		for t in range(0, indices.size(), 3):
			var a := verts[indices[t]]
			var b := verts[indices[t + 1]]
			var c := verts[indices[t + 2]]
			# 面片顶点 z 恒 4（+Z 面），排除其他朝向误判
			if absf(a.z - 4.0) > 0.001 or absf(b.z - 4.0) > 0.001 \
					or absf(c.z - 4.0) > 0.001:
				continue
			var uv_avg: Vector2
			if mode == "naive":
				uv_avg = (uvs[indices[t]] + uvs[indices[t + 1]]
						+ uvs[indices[t + 2]]) / 3.0
			else:
				uv_avg = (uv2s[indices[t]] + uv2s[indices[t + 1]]
						+ uv2s[indices[t + 2]]) / 3.0
			var tname_hit := ""
			for tname in tile_origin:
				var o: Vector2 = tile_origin[tname]
				var hit := false
				if mode == "naive":
					hit = o.x <= uv_avg.x and uv_avg.x < o.x + inv_c \
							and o.y <= uv_avg.y and uv_avg.y < o.y + inv_r
				else:
					hit = absf(uv_avg.x - o.x) < 1e-4 \
							and absf(uv_avg.y - o.y) < 1e-4
				if hit:
					tname_hit = tname
					break
			if tname_hit != "":
				quads_found.append([
						minf(a.x, minf(b.x, c.x)), maxf(a.x, maxf(b.x, c.x)),
						minf(a.y, minf(b.y, c.y)), tname_hit])
		var checks := [
			# x=0..3 的 y=2 面：斜下 (x,1,z=4) 是草 → 满绿
			[1.5, "grass_top", "blend 满绿面"],
			[3.5, "grass_top", "blend 满绿面"],
			# x=4 的 y=2 面：斜下是 dirt；x 小侧邻 x=3 blend → u0 侧带
			#（f=4 面 u 随 x 增：u0=世界 x 小=观察者屏幕左）
			[4.5, "grass_side_u0", "交界 u0 垂带"],
			# x=8 的 y=2 面：两侧都无 blend → 原版土面
			[8.5, "grass_side", "普通草侧面"],
		]
		for ck in checks:
			var got := "<无面>"
			for q in quads_found:
				if q[0] <= ck[0] and ck[0] < q[1] and absf(q[2] - 2.0) < 0.01:
					got = q[3]
					break
			if got != ck[1]:
				print("[FAIL] %s %s @x=%.1f: 期望 %s 得 %s"
						% [mode, ck[2], ck[0], ck[1], got])
				failures += 1
			else:
				print("[PASS] %s %s @x=%.1f = %s"
						% [mode, ck[2], ck[0], got])
	print("=== 草坡融合判定探针: %s ===" % (
			"全过" if failures == 0 else "%d 项失败" % failures))
	quit(1 if failures > 0 else 0)
