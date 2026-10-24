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
static func build_mesh_arrays(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
) -> Dictionary:
	# C# 原生路径（阶段 E）：可用时优先，不可用自动回退 GDScript。
	# A/B 基准（192 区块，本机 2 核）：62.2 → 25.9 ms/区块，C# 胜 2.4×，
	# 算法足够重，收益盖过跨语言装箱开销（面剔除则相反，走 GDScript）。
	# C# 实现不认识水（v4）：含水区块回退 GD 路径补水面通道
	if not chunk.block_ids.has(VoxelTypes.WATER_ID):
		var native_result := NativeMeshBridge.build(true, registry, chunk, neighbors)
		if not native_result.is_empty():
			return native_result
	return _build_gd(registry, chunk, neighbors)


static func _build_gd(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
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
	var indices := PackedInt32Array()
	var quads := 0

	# 轴循环：U/V 取循环序（x: u=y,v=z；y: u=z,v=x；z: u=x,v=y），
	# 保证 cross(U, V) 恒指向 +axis（绕序规则见 _emit_quad）
	var mask := PackedInt32Array()
	mask.resize(s * s)
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		for boundary in s + 1:
			# boundary k：padded 位置 k（内侧/下方单元）与 k+1（外侧/上方单元）
			# 之间的面，四边形位于块坐标平面 k
			var has_any := false
			# 只有属于区块内真实方块的面才发射：padded 边界外的
			# 单元（含 y<0 的虚拟基岩）只作为遮挡源，不产生面
			var a_real := boundary >= 1
			var b_real := boundary <= s - 1
			for v in s:
				for u in s:
					var idx_a := _padded_index(ps, axis, boundary, u_axis, v_axis, u, v)
					var idx_b := _padded_index(ps, axis, boundary + 1, u_axis, v_axis, u, v)
					var a: int = padded[idx_a]
					var b: int = padded[idx_b]
					var encoded := 0
					# 水不进不透明贪心网格（独立半透明表面，见文末水通道）
					if a == VoxelTypes.WATER_ID or b == VoxelTypes.WATER_ID:
						mask[u + v * s] = 0
						continue
					if a_real and solid_by_id[a] == 1 and occludes_by_id[b] == 0:
						# a 的 +axis 面（状态感知贴图，§4.3）
						var local_a := Vector3i.ZERO
						local_a[axis] = boundary - 1
						local_a[u_axis] = u
						local_a[v_axis] = v
						encoded = _face_tile(chunk, textures_by_id, tile_lookup,
								a, local_a, axis, true) + 1
					elif b_real and solid_by_id[b] == 1 and occludes_by_id[a] == 0:
						var local_b := Vector3i.ZERO
						local_b[axis] = boundary
						local_b[u_axis] = u
						local_b[v_axis] = v
						encoded = -(_face_tile(chunk, textures_by_id, tile_lookup,
								b, local_b, axis, false) + 1)
					mask[u + v * s] = encoded
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
					_emit_quad(axis, positive, boundary, u0, v0, u1, v1,
							tile_index, vertices, normals, uvs, uv2s, indices)
					u0 = u1
	var result := {
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"uv2": uv2s,
		"indices": indices,
		"quads": quads,
	}
	# 水走独立半透明表面（与面剔除同一条水通道，不参与贪心合并）
	var wc := chunk.chunk_coord
	var wd := chunk.dimensions
	ChunkMesher.append_water_faces(padded, ps, result,
			ChunkMesher.collect_water_levels_world(chunk, neighbors),
			Vector3i(wc.x * wd.x, wc.y * wd.y, wc.z * wd.z))
	return result


## padded 一维布局：x + ps*y + ps*ps*z。
## axis_pos / u / v 均为填充坐标（0..s+1 / 1..s），调用方直接传位置。
## 面的图集 tile 下标：无状态方块走预查表（快路径）；
## 带 axis 状态的方块按朝向解析端面/侧面（与面剔除实现共用规则）。
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


static func _padded_index(
		ps: int, axis: int, axis_pos: int,
		u_axis: int, v_axis: int, u: int, v: int
) -> int:
	var coords := [0, 0, 0]
	coords[axis] = axis_pos
	coords[u_axis] = u + 1
	coords[v_axis] = v + 1
	return coords[0] + ps * coords[1] + ps * ps * coords[2]


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
		indices: PackedInt32Array
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
		# tile 空间 UV：顶/底面直接用参数；侧面水平取水平轴、
		# 竖直取"上边界 - y"保证贴图不倒置
		if axis == 1:
			uvs.append(Vector2(pu - u0, pv - v0))
		elif axis == 0:
			uvs.append(Vector2(pv - v0, u1 - pu))
		else:
			uvs.append(Vector2(pu - u0, v1 - pv))
	indices.append_array(PackedInt32Array([
		base, base + 2, base + 1,
		base, base + 3, base + 2,
	]))
