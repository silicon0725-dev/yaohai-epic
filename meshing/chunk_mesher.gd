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
static func build_mesh_arrays(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
) -> Dictionary:
	# 面剔除固定走 GDScript：A/B 基准显示 C# 路径因跨语言装箱开销
	# 反而慢 2.3×（12.9 → 29.3 ms/区块）；算法本身太轻，收益盖不过桥接成本。
	# （Greedy 网格器走 C#，见 greedy_mesher.gd；C# 实现保留用于等价测试。）
	return _build_gd(registry, chunk, neighbors)


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

	for z in s:
		for y in s:
			for x in s:
				var pidx := (z + 1) * stride_z + (y + 1) * stride_y + (x + 1)
				var block_id := padded[pidx]
				if block_id == VoxelTypes.AIR_ID or solid_by_id[block_id] == 0:
					continue
				var textures: Dictionary = textures_by_id[block_id]
				var state: Dictionary = {}
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
					# 索引绕序与角点顺序相反：Godot 正面 = 面外侧看顺时针
					indices.append_array(PackedInt32Array([
						base_index, base_index + 2, base_index + 1,
						base_index, base_index + 3, base_index + 2,
					]))
	return {
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
		"indices": indices,
	}
