## 可见面剔除网格构建（开发文档 §6.1、§6.2）。
## 只为不被相邻不透明方块完全遮挡的面生成几何，每个区块输出
## 单一网格表面（Stage A 只有不透明类别，§6.5 透明材质后置）。
## Greedy Meshing 是阶段 E 的对比项，不作为 MVP 前置条件。
##
## 线程安全（§10.1）：本函数为纯计算，只读取传入的区块数据与
## 27 邻域引用（由主线程经 VoxelWorld.collect_neighbors 快照），
## 不触碰场景树与世界字典，可在 WorkerThreadPool 上运行。
## 主线程在提交结果时比对邻区块 edit_serial，数据已变化的
## 过期结果会被丢弃（§4.4）。
##
## 边界策略（§6.4）：邻区块缺失（null）按空气处理——y<0 除外，
## 视为实心（世界底部面不渲染）。邻区块数据到达后由
## ChunkManager 把相邻区块标记为脏并重新网格化。
##
## 顶点使用区块内局部坐标，渲染节点定位在区块原点。
class_name ChunkMesher
extends RefCounted

## 每个面 4 个角点沿外轮廓排列（几何参考：cross(v1-v0, v2-v1) = 外法线），
## corner_uvs 中 v=0 对应贴图上方（草侧贴图的草皮条带在方块顶部）。
## 注意：Godot 光栅化的"正面"是从面外侧看呈顺时针（实测验证，
## 见 debug/render_check.gd），因此下方发射三角形时使用与角点顺序
## 相反的索引绕序，否则所有面都会被背面剔除。
const FACES := [
	{
		"normal": Vector3i(1, 0, 0),
		"corners": [Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1)],
		"corner_uvs": [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
		"face_kind": "side",
	},
	{
		"normal": Vector3i(-1, 0, 0),
		"corners": [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)],
		"corner_uvs": [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
		"face_kind": "side",
	},
	{
		"normal": Vector3i(0, 1, 0),
		"corners": [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
		"corner_uvs": [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)],
		"face_kind": "top",
	},
	{
		"normal": Vector3i(0, -1, 0),
		"corners": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
		"corner_uvs": [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
		"face_kind": "bottom",
	},
	{
		"normal": Vector3i(0, 0, 1),
		"corners": [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)],
		"corner_uvs": [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
		"face_kind": "side",
	},
	{
		"normal": Vector3i(0, 0, -1),
		"corners": [Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)],
		"corner_uvs": [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
		"face_kind": "side",
	},
]


## 按数值 ID 预查注册表属性（供热循环使用，GreedyMesher 共用）。
static func build_lookup_tables(registry: VoxelRegistry) -> Dictionary:
	var block_count := registry.block_count()
	var solid_by_id := PackedByteArray()
	var occludes_by_id := PackedByteArray()
	solid_by_id.resize(block_count)
	occludes_by_id.resize(block_count)
	var textures_by_id: Array = []
	textures_by_id.resize(block_count)
	for id in block_count:
		solid_by_id[id] = 1 if registry.is_solid(id) else 0
		occludes_by_id[id] = 1 if registry.occludes(id) else 0
		textures_by_id[id] = registry.definition_for_id(id).get("textures", {})
	return {
		"solid": solid_by_id,
		"occludes": occludes_by_id,
		"textures": textures_by_id,
	}


## (s+2)^3 填充缓存：区块本体直拷；1 格边界从 27 邻域快照解析
##（缺失按空气，y<0 按实心，见类注释中的边界策略）。
## GreedyMesher 与本类的网格构建共用该缓存。
static func build_padded_cache(chunk: ChunkData, neighbors: Array) -> PackedInt32Array:
	var s := chunk.dimensions.x
	var ps := s + 2
	var padded := PackedInt32Array()
	padded.resize(ps * ps * ps)
	var ids := chunk.block_ids
	for z in s:
		for y in s:
			var src_row := z * s * s + y * s
			var dst_row := (z + 1) * ps * ps + (y + 1) * ps + 1
			for x in s:
				padded[dst_row + x] = ids[src_row + x]
	for pz in ps:
		for py in ps:
			var interior_row := pz >= 1 and pz <= s and py >= 1 and py <= s
			for px in ps:
				if interior_row and px >= 1 and px <= s:
					continue  # 内部已由直拷填充
				var a := px - 1
				var b := py - 1
				var c := pz - 1
				var dx := 0
				var dy := 0
				var dz := 0
				var la := a
				var lb := b
				var lc := c
				if la < 0:
					dx = -1
					la = s - 1
				elif la >= s:
					dx = 1
					la = 0
				if lb < 0:
					dy = -1
					lb = s - 1
				elif lb >= s:
					dy = 1
					lb = 0
				if lc < 0:
					dz = -1
					lc = s - 1
				elif lc >= s:
					dz = 1
					lc = 0
				var neighbor: ChunkData = neighbors[
						(dz + 1) * 9 + (dy + 1) * 3 + (dx + 1)]
				var border_id := VoxelTypes.AIR_ID
				if neighbor != null:
					border_id = neighbor.block_ids[la + s * lb + s * s * lc]
				elif chunk.chunk_coord.y * s + b < 0:
					border_id = VoxelTypes.BEDROCK_ID
				padded[px + py * ps + pz * ps * ps] = border_id
	return padded


## 状态感知的面贴图选择（§4.3 方块状态）：带 "axis" 状态的方块
##（如横放原木）垂直于轴向的端面用 top 贴图（年轮），其余用 side。
## 无状态方块走常规 top/side/bottom 规则。
static func effective_tile_name(
		textures: Dictionary, state: Dictionary, face_normal: Vector3i
) -> String:
	var kind := "side"
	if face_normal.y > 0:
		kind = "top"
	elif face_normal.y < 0:
		kind = "bottom"
	if state.has("axis") and textures.has("top") and textures.has("side"):
		var axis_index := 1
		var axis_string := String(state["axis"])
		if axis_string == "x":
			axis_index = 0
		elif axis_string == "z":
			axis_index = 2
		var face_axis := 1
		if face_normal.x != 0:
			face_axis = 0
		elif face_normal.z != 0:
			face_axis = 2
		kind = "top" if face_axis == axis_index else "side"
	return String(textures.get(kind, textures.get("side", "")))


## 输出 { vertices, normals, uvs, indices }（Packed*Array）。
## neighbors 为 VoxelWorld.collect_neighbors 的 27 元素快照
##（index = (dz+1)*9 + (dy+1)*3 + (dx+1)，缺失为 null）。
## 当前仅支持立方体区块（配置使用 16^3 候选值，§4.1）。
## C# 优先（等价测试 test_native_equivalence 保证逐字节一致；
## A/B 干区块 4.6ms vs GD 20.6ms，湿区块 C# opaque+水通道组合）。
## 水侧 C# 不可用时整体回退 GD（水/不透明必须同源实现，避免混搭
## 出两套等价面）。无 C# 环境（未 dotnet build）自动回退。
static func build_mesh_arrays(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
) -> Dictionary:
	var native := NativeMeshBridge.build(false, registry, chunk, neighbors)
	if not native.is_empty():
		if chunk.block_ids.has(VoxelTypes.WATER_ID):
			var water := NativeMeshBridge.build_water(chunk, neighbors)
			if water.is_empty():
				return _build_gd(registry, chunk, neighbors)
			native.merge(water)
		return native
	return _build_gd(registry, chunk, neighbors)


## 共享只读空状态（热循环 per-block 曾构造 {} 4096 次/区块——
## 仅 is_empty() 判断与 effective_tile_name 只读消费，共享安全）
const EMPTY_STATE := {}


static func _build_gd(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
) -> Dictionary:
	assert(chunk.dimensions.x == chunk.dimensions.y
			and chunk.dimensions.y == chunk.dimensions.z, "Stage A 仅支持立方体区块")
	var s := chunk.dimensions.x
	var tables := build_lookup_tables(registry)
	var solid_by_id: PackedByteArray = tables["solid"]
	var occludes_by_id: PackedByteArray = tables["occludes"]
	var textures_by_id: Array = tables["textures"]
	var padded := build_padded_cache(chunk, neighbors)

	# 六个邻居在填充缓存中的下标偏移（与 FACES 顺序一一对应）。
	var ps := s + 2
	var stride_y := ps
	var stride_z := ps * ps
	var neighbor_offsets := PackedInt32Array([
		1, -1, stride_y, -stride_y, stride_z, -stride_z,
	])

	# ---- 性能优化（阶段 E 决策记录：原生迁移不可行后的 GDScript 热路径改进）----
	# 1. 每个 (block_id, face) 的图集 tile 与 UV 矩形按需缓存：
	#    热循环内不再做字符串查找与除法
	# 2. FACES 常量字典预展开为数组，消除逐面字典键查找
	var has_states := not chunk.sparse_block_states.is_empty()
	var cached_tiles := {}   # "block_id:kind" -> [tile_x_norm, tile_y_norm, inv_cols, inv_rows]
	var inv_cols := 1.0 / TextureAtlasLoader.COLS
	var inv_rows := 1.0 / TextureAtlasLoader.ROWS
	# 预展 FACES 为并行数组
	var face_normals: Array[Vector3i] = []
	var face_corners: Array = []
	var face_corner_uvs: Array = []
	var face_kinds: Array[String] = []
	var face_normal_vecs: Array[Vector3] = []
	for f in FACES.size():
		var face: Dictionary = FACES[f]
		face_normals.append(face["normal"])
		face_corners.append(face["corners"])
		face_corner_uvs.append(face["corner_uvs"])
		face_kinds.append(String(face["face_kind"]))
		face_normal_vecs.append(Vector3(face["normal"]))

	var tile_cache := {}  # block_id*8+face -> Vector2(tile 原点)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# 树叶面单独成桶（cutout 表面：alpha 裁切镂空材质）；顶点/UV
	# 与不透明网格共享，仅索引分流——碰撞构建合并两桶
	var cutout_indices := PackedInt32Array()

	for z in s:
		for y in s:
			for x in s:
				var pidx := (z + 1) * stride_z + (y + 1) * stride_y + (x + 1)
				var block_id := padded[pidx]
				# 水走独立半透明表面（append_water_faces）；枝干走专用
				# 几何通道（append_branch_faces，radius 状态驱动），
				# 均不进普通不透明网格
				if block_id == VoxelTypes.AIR_ID or block_id == VoxelTypes.WATER_ID 						or block_id == VoxelTypes.BRANCH_ID 						or solid_by_id[block_id] == 0:
					continue
				var textures: Dictionary = textures_by_id[block_id]
				var state: Dictionary = EMPTY_STATE
				if has_states:
					state = chunk.get_state(Vector3i(x, y, z))
				for f in FACES.size():
					if occludes_by_id[padded[pidx + neighbor_offsets[f]]] == 1:
						continue
					var corners: Array = face_corners[f]
					var corner_uvs: Array = face_corner_uvs[f]
					var normal_vec := face_normal_vecs[f]
					var base_index := vertices.size()
					# tile 原点：无状态走缓存（键 "block:face"，免字符串查找/除法）
					var tile_origin := Vector2.ZERO
					if state.is_empty():
						var cache_key := block_id * 8 + f
						if tile_cache.has(cache_key):
							tile_origin = tile_cache[cache_key]
						else:
							var tile_name := String(textures.get(
									face_kinds[f], textures.get("side", "")))
							var tile := TextureAtlasLoader.tile_grid(tile_name)
							tile_origin = Vector2(
									float(tile.x) * inv_cols, float(tile.y) * inv_rows)
							tile_cache[cache_key] = tile_origin
					else:
						var tile_name := effective_tile_name(
								textures, state, face_normals[f])
						var tile := TextureAtlasLoader.tile_grid(tile_name)
						tile_origin = Vector2(
								float(tile.x) * inv_cols, float(tile.y) * inv_rows)
					for c in 4:
						var corner: Vector3 = corners[c]
						vertices.append(Vector3(
								x + corner.x,
								y + corner.y,
								z + corner.z
						))
						normals.append(normal_vec)
						var cuv: Vector2 = corner_uvs[c]
						uvs.append(Vector2(
								tile_origin.x + cuv.x * inv_cols,
								tile_origin.y + cuv.y * inv_rows))
					# 索引绕序与角点顺序相反：Godot 正面 = 面外侧看顺时针。
					# 树叶面进 cutout 桶（独立渲染表面），其余进不透明桶。
					# 直接 append 六索引——曾 append_array(PackedInt32Array([...]))
					# 每面分配临时数组，数千面/区块纯 GC 压力
					if block_id == VoxelTypes.LEAVES_ID:
						cutout_indices.append(base_index)
						cutout_indices.append(base_index + 2)
						cutout_indices.append(base_index + 1)
						cutout_indices.append(base_index)
						cutout_indices.append(base_index + 3)
						cutout_indices.append(base_index + 2)
					else:
						indices.append(base_index)
						indices.append(base_index + 2)
						indices.append(base_index + 1)
						indices.append(base_index)
						indices.append(base_index + 3)
						indices.append(base_index + 2)
	var result := {
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"indices": indices,
		"cutout_indices": cutout_indices,
	}
	var c := chunk.chunk_coord
	var d := chunk.dimensions
	append_water_faces(padded, ps, result,
			collect_water_levels_world(chunk, neighbors),
			Vector3i(c.x * d.x, c.y * d.y, c.z * d.z))
	return result


## ---- 水面（§6.5：与不透明网格分离的半透明表面）----

## 水顶面相对方块顶的下沉量（MC 式水面略低于方块顶，岸线更自然）。
const WATER_SURFACE_DROP := 0.125

## 从区块稀疏状态提取水格级别，合并 27 邻域为一张
## {世界格坐标: level} 表——水面角点高度查询会跨界（角点由 2x2
## 四格共享，可能落在邻区块）。源（无状态）不进表，缺省 0。
static func collect_water_levels_world(
		chunk: ChunkData, neighbors: Array
) -> Dictionary:
	var levels := {}
	_merge_water_levels(levels, chunk)
	for n in neighbors:
		if n != null and n != chunk:
			_merge_water_levels(levels, n)
	return levels


static func _merge_water_levels(levels: Dictionary, chunk: ChunkData) -> void:
	if chunk == null or not chunk.block_ids.has(VoxelTypes.WATER_ID):
		return
	var c := chunk.chunk_coord
	var d := chunk.dimensions
	var origin := Vector3i(c.x * d.x, c.y * d.y, c.z * d.z)
	for local in chunk.sparse_block_states:
		var state: Dictionary = chunk.sparse_block_states[local]
		if state.has("level") and chunk.get_block(local) == VoxelTypes.WATER_ID:
			levels[origin + local] = int(state["level"])


## 表面水块（上方为空气）的顶面高度：源 0.875（水面张力下沉），
## 流动 1..7 级逐级递减成阶梯，8 级（下落柱）满格（理论不到此分支）。
static func water_surface_height(level: int) -> float:
	if level <= 0:
		return 1.0 - WATER_SURFACE_DROP
	if level >= 8:
		return 1.0
	return (8.0 - float(level)) * (1.0 - WATER_SURFACE_DROP) / 8.0

## 把填充缓存中的水方面到 out 的 water_* 数组（面剔除与贪心共用）。
## 规则：水只在邻格为空气时出面——水-水内部面剔除、水-固体不出面
##（固体自己的面隔着水可见）。
## 高度模型（连续水面）：角点高度 = 共享该角点的 2x2 四格中所有
## 水格顶高的最大值。相邻水面因此在共享边上角点同高 -> 顶面成为
## 连续折面（斜坡衔接而非一格一层的台阶断崖），侧面顶边随角点
## 倾斜成梯形，级别差造成的竖直缝隙由 max 天然封住。
## levels_world 来自 collect_water_levels_world（世界坐标 -> level，
## 含邻区块；缺省 = 源）。origin 为本区块世界原点。未加 UV（纯色材质）。
static func append_water_faces(
		padded: PackedInt32Array, ps: int, out: Dictionary,
		levels_world: Dictionary = {}, origin: Vector3i = Vector3i.ZERO
) -> void:
	var stride_y := ps
	var stride_z := ps * ps
	var neighbor_offsets := PackedInt32Array([
		1, -1, stride_y, -stride_y, stride_z, -stride_z,
	])
	# 两个通道：顶/底面（双面材质，潜水视角可见水面）与四侧
	#（背面剔除材质，防下落水柱远侧背面穿透叠加）
	var vertices: PackedVector3Array = out.get("water_vertices", PackedVector3Array())
	var normals: PackedVector3Array = out.get("water_normals", PackedVector3Array())
	var indices: PackedInt32Array = out.get("water_indices", PackedInt32Array())
	var colors: PackedColorArray = out.get("water_colors", PackedColorArray())
	var side_vertices: PackedVector3Array = out.get(
			"water_side_vertices", PackedVector3Array())
	var side_normals: PackedVector3Array = out.get(
			"water_side_normals", PackedVector3Array())
	var side_indices: PackedInt32Array = out.get(
			"water_side_indices", PackedInt32Array())
	var side_colors: PackedColorArray = out.get(
			"water_side_colors", PackedColorArray())
	var size := ps - 2
	# FACES 预展开（曾每面 FACES[f] 字典查找 + face["normal"]/["corners"]
	# 两次键查询——水通道是湿区块 79% 耗时的大头）
	var normals_flat := [
		Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	]
	var corners_flat: Array = []
	for f2 in FACES.size():
		corners_flat.append(FACES[f2]["corners"])
	for z in size:
		for y in size:
			for x in size:
				var pidx := (z + 1) * stride_z + (y + 1) * stride_y + (x + 1)
				if padded[pidx] != VoxelTypes.WATER_ID:
					continue
				for f in FACES.size():
					if padded[pidx + neighbor_offsets[f]] != VoxelTypes.AIR_ID:
						continue
					var normal: Vector3 = normals_flat[f]
					var is_side: bool = normal.y == 0.0
					var corners: Array = corners_flat[f]
					var base: int = (side_vertices.size()
							if is_side else vertices.size())
					for c in 4:
						var corner: Vector3 = corners[c]
						var vy := corner.y
						if corner.y == 1.0:
							vy = _corner_water_height(padded, ps, x, y, z,
									x + int(corner.x), z + int(corner.z),
									levels_world, origin)
						var v := Vector3(x + corner.x, y + vy, z + corner.z)
						# 角点衰减（角点 2x2 四格的固体性直接决定）——
						# 数据全在单圈 padded 内：跨区块边界的角点两侧
						# 区块算出同值（曾用格级场平均，两侧参与的格集
						# 不同 -> 区块边界直线裂缝）
						var fade := _corner_shore_fade(padded, ps,
								x + int(corner.x), y, z + int(corner.z))
						var fade_color := Color(fade, 0.0, 0.0)
						if is_side:
							side_vertices.append(v)
							side_normals.append(normal)
							side_colors.append(fade_color)
						else:
							vertices.append(v)
							normals.append(normal)
							colors.append(fade_color)
					# 索引在角点循环外发射（每面一次 ×6——曾误入
					# for c 循环体，每面 ×4 索引，水测试面数全 ×4）
					var bi2 := base
					if is_side:
						side_indices.append(bi2)
						side_indices.append(bi2 + 2)
						side_indices.append(bi2 + 1)
						side_indices.append(bi2)
						side_indices.append(bi2 + 3)
						side_indices.append(bi2 + 2)
					else:
						indices.append(bi2)
						indices.append(bi2 + 2)
						indices.append(bi2 + 1)
						indices.append(bi2)
						indices.append(bi2 + 3)
						indices.append(bi2 + 2)
	if indices.size() > 0:
		out["water_vertices"] = vertices
		out["water_normals"] = normals
		out["water_indices"] = indices
		out["water_colors"] = colors
	if side_indices.size() > 0:
		out["water_side_vertices"] = side_vertices
		out["water_side_normals"] = side_normals
		out["water_side_indices"] = side_indices
		out["water_side_colors"] = side_colors


## 角点 (cx, cz)（y 层）的岸距衰减：角点自身 2x2 四格（同层与
## y+1 层）中的固体格数直接决定——任何紧邻固体 -> 强衰减。
## 关键性质：只依赖单圈 padded 内的数据，跨区块边界的角点在两侧
## 区块的 padded 里数据相同 -> 算出同值 -> 波浪位移一致不裂缝。
## 展开双循环（曾 [0,1]/[cx-1,cx] 数组字面量：水通道每角点一次
## 调用 ×3 数组分配，含水区块实测 47ms/块的大头之一）
static func _corner_shore_fade(
		padded: PackedInt32Array, ps: int, cx: int, cy: int, cz: int
) -> float:
	var stride_y := ps
	var stride_z := ps * ps
	var solid := 0
	for layer in 2:
		var row0 := (cy + 1 + layer) * stride_y
		for gz_off in 2:
			var zbase := (cz + gz_off) * stride_z + row0
			for gx_off in 2:
				var nid: int = padded[zbase + cx + gx_off]
				if nid != VoxelTypes.AIR_ID and nid != VoxelTypes.WATER_ID:
					solid += 1
	return 1.0 - clampf(float(solid) * 0.5, 0.0, 0.85)


## 角点 (cx, cz)（格坐标，取 x 或 x+1 / z 或 z+1）的水面高度：
## 共享该角点的 2x2 四格（cx-1..cx, cz-1..cz，同一 y 层）中所有水格
## 顶高的最大值。水格顶高：上方是水 -> 满格 1.0（柱体内部）；
## 否则按级别 water_surface_height（levels_world 缺省 = 源）。
## 非水格贡献 0（角点朝岸时水面自然降到自身高度）。
static func _corner_water_height(
		padded: PackedInt32Array, ps: int, x: int, y: int, z: int,
		cx: int, cz: int, levels_world: Dictionary, origin: Vector3i
) -> float:
	var stride_y := ps
	var stride_z := ps * ps
	var row := (y + 1) * stride_y
	var above := row + stride_y
	var best := 0.0
	for gz_off in 2:
		var zbase := (cz + gz_off) * stride_z
		for gx_off in 2:
			var gx := cx + gx_off
			var p: int = zbase + row + gx
			if padded[p] != VoxelTypes.WATER_ID:
				continue
			var h := 1.0
			if padded[p + stride_y] != VoxelTypes.WATER_ID:
				# levels 键是逻辑格坐标（padded 坐标 - 1）
				var lvl: int = levels_world.get(
						origin + Vector3i(gx - 1, y, cz + gz_off - 1), 0)
				h = water_surface_height(lvl)
			if h > best:
				best = h
	return best


## ---- 枝干几何（动态树，参考 Dynamic Trees 的 radius 语义）----

## 枝干按 radius 状态（1-8，1 格 = 16 半径单位）出几何：
## - radius 1-2：十字交叉面片（植物式细枝，全高，宽 = radius*2/16）；
## - radius 3-8：方形柱（宽 = radius*2/16 居中），四侧 + 顶/底。## 渐缩方管：从中心（截面 r0）沿 dir 到格边（截面 r1），## 盒面：复用 opaque 的 FACES 角点表（单位盒角 0/1 映射到 mn/mx），