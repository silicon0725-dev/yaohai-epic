## Greedy Meshing（开发文档 §6.3）：把同朝向、同贴图的共面相邻面
## 合并为极大矩形四边形。与面剔除实现可切换（ChunkManager 开关），
## 两者共用 ChunkMesher 的填充缓存与查找表，边界/剔除语义一致。
##
## 与面剔除的差别：合并四边形的 UV 处于"tile 空间"（0..宽, 0..高），
## 单张图集无法直接采样重复纹理，需配合平铺着色器
##（presentation/atlas_tiling.gdshader：fract(uv) 进图集，UV2 携带
## tile 原点）。收益与代价由 debug/benchmark.gd 实测对比（§6.3）。
##
## 正确性不变量（单元测试保证）：贪心四边形总面积 == 面剔除的
## 面数（同一世界表面，只是合并方式不同）。
class_name GreedyMesher
extends RefCounted


## 输出 { vertices, normals, uvs, uv2, indices, quads }。
## 与 ChunkMesher.build_mesh_arrays 同签名、同线程安全约定。
## C# 优先（等价测试保证）：干区块 BuildGreedy；含水区块
## BuildGreedy + BuildWater 组合（水不参与贪心合并，独立半透明
## 表面——与 GD 路径同构）。C# 不可用自动回退 GDScript。
static func build_mesh_arrays(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array,
		water_levels: Variant = null
) -> Dictionary:
	var native := NativeMeshBridge.build(true, registry, chunk, neighbors)
	if not native.is_empty():
		if chunk.block_ids.has(VoxelTypes.WATER_ID):
			var water := NativeMeshBridge.build_water(chunk, neighbors, water_levels)
			if water.is_empty():
				return _build_gd(registry, chunk, neighbors, water_levels)
			native.merge(water)
		return native
	# C# 原生路径（阶段 E）：含水区块也由 C# 水通道补齐（上方已处理），
	# 走到这里的只剩 C# 不可用——GDScript 回退
	return _build_gd(registry, chunk, neighbors)


static func _build_gd(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array,
		water_levels: Variant = null
) -> Dictionary:
	assert(chunk.dimensions.x == chunk.dimensions.y
			and chunk.dimensions.y == chunk.dimensions.z, "仅支持立方体区块")
	var s := chunk.dimensions.x
	var tables := ChunkMesher.build_lookup_tables(registry)
	var solid_by_id: PackedByteArray = tables["solid"]
	var occludes_by_id: PackedByteArray = tables["occludes"]
	var textures_by_id: Array = tables["textures"]
	var padded := ChunkMesher.build_padded_cache(chunk, neighbors)

	# 每方块每朝向（axis 0..2，正/负）的图集 tile 下标
	var tile_lookup := _build_tile_lookup(textures_by_id)

	var ps := s + 2
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var quads := 0
	# 体素光照 → 顶点色（角点平滑光照采样用，见 _emit_quad）
	var light_padded := ChunkMesher.build_light_padded(chunk, neighbors)
	# 无状态区块走纯查表快路径（_face_tile 内的 get_state 分支与
	# is_empty 查询在 4096 格 × 6 面主循环里是纯开销）
	var has_states := not chunk.sparse_block_states.is_empty()

	# 轴循环：U/V 取循环序（x: u=y,v=z；y: u=z,v=x；z: u=x,v=y），
	# 保证 cross(U, V) 恒指向 +axis（绕序规则见 _emit_quad）
	var mask := PackedInt32Array()
	mask.resize(s * s)
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		# padded 一维布局 stride（曾 _padded_index 每格分配 Array[3]
		# ——4096 格 × 17 边界 × 3 轴 × 2 端是贪心网格的最大 GC 源）
		var strides := [1, ps, ps * ps]
		var stride_axis: int = strides[axis]
		var stride_u: int = strides[u_axis]
		var stride_v: int = strides[v_axis]
		var tile_rows: Array = tile_lookup
		for boundary in s + 1:
			# boundary k：padded 位置 k（内侧/下方单元）与 k+1（外侧/上方单元）
			# 之间的面，四边形位于块坐标平面 k
			var has_any := false
			# 只有属于区块内真实方块的面才发射：padded 边界外的
			# 单元（含 y<0 的虚拟基岩）只作为遮挡源，不产生面
			var a_real := boundary >= 1
			var b_real := boundary <= s - 1
			var base_a := boundary * stride_axis
			var base_b := (boundary + 1) * stride_axis
			for v in s:
				var row := v * s
				var v_off := (v + 1) * stride_v
				for u in s:
					var idx_a := base_a + v_off + (u + 1) * stride_u
					var idx_b := base_b + v_off + (u + 1) * stride_u
					var a: int = padded[idx_a]
					var b: int = padded[idx_b]
					var encoded := 0
					# 水不进不透明贪心网格（独立半透明表面，见文末水通道）
					if a == VoxelTypes.WATER_ID or b == VoxelTypes.WATER_ID:
						mask[row + u] = 0
						continue
					# 枝占位不作发射方（区块无枝几何，渲染走树实体——与
					# 面剔除同语义；占位对邻居透明由 occludes 表承担）。
					# 曾缺此判定：贪心模式下 BRANCH 占位被渲染成实心块
					if a_real and a != VoxelTypes.BRANCH_ID \
							and solid_by_id[a] == 1 and occludes_by_id[b] == 0:
						# a 的 +axis 面（状态感知贴图，§4.3）
						if has_states:
							var local_a := Vector3i.ZERO
							local_a[axis] = boundary - 1
							local_a[u_axis] = u
							local_a[v_axis] = v
							encoded = _face_tile(chunk, textures_by_id,
									tile_rows, a, local_a, axis, true) + 1
						else:
							encoded = int(tile_rows[a][axis * 2]) + 1
					elif b_real and b != VoxelTypes.BRANCH_ID \
							and solid_by_id[b] == 1 and occludes_by_id[a] == 0:
						if has_states:
							var local_b := Vector3i.ZERO
							local_b[axis] = boundary
							local_b[u_axis] = u
							local_b[v_axis] = v
							encoded = -(_face_tile(chunk, textures_by_id,
									tile_rows, b, local_b, axis, false) + 1)
						else:
							encoded = -(int(tile_rows[b][axis * 2 + 1]) + 1)
					mask[row + u] = encoded
					if encoded != 0:
						has_any = true
			if not has_any:
				continue
			# 极大矩形合并
			for v0 in s:
				var u0 := 0
				while u0 < s:
					var m: int = mask[u0 + v0 * s]
					if m == 0:
						u0 += 1
						continue
					var u1 := u0 + 1
					while u1 < s and mask[u1 + v0 * s] == m:
						u1 += 1
					var v1 := v0 + 1
					while v1 < s:
						var row_matches := true
						var u_check := u0
						while u_check < u1:
							if mask[u_check + v1 * s] != m:
								row_matches = false
								break
							u_check += 1
						if not row_matches:
							break
						v1 += 1
					for vv in range(v0, v1):
						for uu in range(u0, u1):
							mask[uu + vv * s] = 0
					var positive := m > 0
					var tile_index: int = (m if positive else -m) - 1
					quads += 1
					# 面外层：positive（a 的 +axis 面）= boundary+1；
					# negative（b 的 -axis 面）= boundary
					var layer: int = boundary + 1 if positive else boundary
					var op_base: int = layer * stride_axis \
							+ stride_u + stride_v
					_emit_quad(axis, positive, boundary, u0, v0, u1, v1,
							tile_index, vertices, normals, uvs, uv2s,
							indices, colors, light_padded,
							op_base, stride_u, stride_v)
					u0 = u1
	var result := {
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"uv2": uv2s,
		"colors": colors,
		"indices": indices,
		"quads": quads,
	}
	# 水走独立半透明表面（与面剔除同一条水通道，不参与贪心合并）
	var wc := chunk.chunk_coord
	var wd := chunk.dimensions
	ChunkMesher.append_water_faces(padded, ps, result,
			water_levels if water_levels != null
					else ChunkMesher.collect_water_levels_world(chunk, neighbors),
			Vector3i(wc.x * wd.x, wc.y * wd.y, wc.z * wd.z))
	return result


## 面的图集 tile 下标：无状态方块走预查表（快路径——主循环已内联，
## 本函数仅服务稀疏状态区块）；带 axis 状态的方块按朝向解析端面/侧面
##（与面剔除实现共用规则）。
static func _face_tile(
		chunk: ChunkData, textures_by_id: Array, tile_lookup: Array,
		block_id: int, local: Vector3i, face_axis: int, positive: bool
) -> int:
	if not chunk.sparse_block_states.is_empty():
		var state: Dictionary = chunk.get_state(local)
		if not state.is_empty():
			var normal := Vector3i.ZERO
			normal[face_axis] = 1 if positive else -1
			return TextureAtlasLoader.TILES.find(ChunkMesher.effective_tile_name(
					textures_by_id[block_id], state, normal))
	return tile_lookup[block_id][face_axis * 2 + (0 if positive else 1)]


static func _build_tile_lookup(textures_by_id: Array) -> Array:
	var lookup := []
	lookup.resize(textures_by_id.size())
	for block_id in textures_by_id.size():
		var textures: Dictionary = textures_by_id[block_id]
		var slots := PackedInt32Array()
		slots.resize(6)
		for axis in 3:
			for positive in 2:
				var kind := "side"
				if axis == 1:
					kind = "top" if positive == 1 else "bottom"
				var tile_name: String = textures.get(kind, textures.get("side", ""))
				slots[axis * 2 + (0 if positive == 1 else 1)] = \
						TextureAtlasLoader.TILES.find(tile_name)
		lookup[block_id] = slots
	return lookup


## 绕序与 UV 约定：
## - 角点按 cross(U, V) = +axis 排列，正朝向用 (u0v0,u1v0,u1v1,u0v1)，
##   负朝向交换 B/D；索引 (0,2,1)(0,3,2) 与面剔除实现的
##   "Godot 正面 = 面外侧看顺时针"一致；
## - UV 处于 tile 空间（0..宽, 0..高），配合平铺着色器；
##   侧面贴图保持竖直方向（贴图 v 向下 = 世界 -y）。
static func _emit_quad(
		axis: int, positive: bool, boundary: int,
		u0: int, v0: int, u1: int, v1: int, tile_index: int,
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array,
		colors: PackedColorArray, light_padded: PackedByteArray,
		op_base: int, stride_u: int, stride_v: int
) -> void:
	var normal := Vector3.ZERO
	normal[axis] = 1.0 if positive else -1.0
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	@warning_ignore("integer_division")
	var tile := Vector2i(tile_index % TextureAtlasLoader.COLS,
			tile_index / TextureAtlasLoader.COLS)
	var rect := AtlasUV.tile_rect(
			tile, TextureAtlasLoader.COLS, TextureAtlasLoader.ROWS)
	# 参数空间的四角（u, v）
	var corner_params: Array[Vector2i] = [
		Vector2i(u0, v0), Vector2i(u1, v0), Vector2i(u1, v1), Vector2i(u0, v1)]
	if not positive:
		corner_params = [
			Vector2i(u0, v0), Vector2i(u0, v1), Vector2i(u1, v1), Vector2i(u1, v0)]
	var base := vertices.size()
	for param in corner_params:
		var pu: int = param.x
		var pv: int = param.y
		var pos := Vector3.ZERO
		pos[axis] = boundary
		pos[u_axis] = pu
		pos[v_axis] = pv
		vertices.append(pos)
		normals.append(normal)
		uv2s.append(rect.position)
		# 角点平滑光照：面外层 2x2 四格（角点两侧格 = pu-1..pu × pv-1..pv；
		# 低角（==u0/v0）取 -1 方向，与面剔除 corner 分量规则一致）
		var op_index := op_base + pu * stride_u + pv * stride_v
		colors.append(ChunkMesher.vertex_light_color(light_padded, 0,
				op_index, stride_u, stride_v,
				0 if pu == u0 else 1, 0 if pv == v0 else 1))
		# tile 空间 UV：顶/底面直接用参数；侧面水平取水平轴、
		# 竖直取"上边界 - y"保证贴图不倒置
		if axis == 1:
			uvs.append(Vector2(pu - u0, pv - v0))
		elif axis == 0:
			uvs.append(Vector2(pv - v0, u1 - pu))
		else:
			uvs.append(Vector2(pu - u0, v1 - pv))
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
