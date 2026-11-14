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

## 27 元素邻域快照中 6 向直接邻居的下标（FACES 序：+X,-X,+Y,-Y,+Z,-Z），
## 索引公式见 build_padded_cache：(dz+1)*9 + (dy+1)*3 + (dx+1)。
const LOADED_DIR_INDEX := [14, 12, 16, 10, 22, 4]
## splitmix hash01（与 C# NativeTerrain.Hash01 逐位一致——对拍红线）
const TreeScatter := preload("res://systems/trees/tree_scatter.gd")

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
## 渲染分发桶枚举（render_kind 表的值；GD/C# 两侧语义一致）
const RENDER_SKIP := 0     # 空气/水/枝干：走专用通道或不渲染
const RENDER_OPAQUE := 1   # 不透明桶
const RENDER_CUTOUT := 2   # 镂空桶（树叶；进碰撞）
const RENDER_CROSS := 3    # 排除桶（火把/提灯：实体渲染器呈现，网格不出几何）
const RENDER_PLANT := 4   # 植物（高草/花）：X 十字面片 + 草顶密叶
						  # （cutout 材质双绕序；不进碰撞）

static func build_lookup_tables(registry: VoxelRegistry) -> Dictionary:
	var block_count := registry.block_count()
	var solid_by_id := PackedByteArray()
	var occludes_by_id := PackedByteArray()
	solid_by_id.resize(block_count)
	occludes_by_id.resize(block_count)
	var render_kind := PackedByteArray()
	render_kind.resize(block_count)
	var textures_by_id: Array = []
	textures_by_id.resize(block_count)
	for id in block_count:
		solid_by_id[id] = 1 if registry.is_solid(id) else 0
		occludes_by_id[id] = 1 if registry.occludes(id) else 0
		# 渲染分发桶（dispatch 表）：registry render_type 驱动——替换
		# 网格器里散落的硬编码 ID 判断，加新形态方块只改注册表
		var kind := RENDER_SKIP
		match String(registry.definition_for_id(id).get("render_type", "opaque")):
			"opaque":
				kind = RENDER_OPAQUE
			"cutout":
				kind = RENDER_CUTOUT
			"cross", "model":
				# cross=十字面片（火把）；model=盒件模型（提灯）——
				# 同桶：区块网格跳过，实体渲染（Torch/LanternRenderer）
				kind = RENDER_CROSS
			"plant":
				kind = RENDER_PLANT
		render_kind[id] = kind
		textures_by_id[id] = registry.definition_for_id(id).get("textures", {})
	return {
		"solid": solid_by_id,
		"occludes": occludes_by_id,
		"render_kind": render_kind,
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


## ---- 体素光照 → 顶点色（光照阶段 2）----

## (s+2)^3 光照填充缓存（1 字节/格：高 4bit 天光、低 4bit 方块光）。
## 内部直拷 chunk.light；边界从 27 邻域 light 取；缺失邻块按空气
## （天光 15，与面剔除"未加载当空气"一致，避免边界黑缝）；
## y<0 世界底按实心（光照 0）。角点平滑光照的全部采样都在此缓存内，
## 跨区块边界两侧取到同格数据 -> 同值不裂缝（岸衰减同思路）。
static func build_light_padded(
		chunk: ChunkData, neighbors: Array
) -> PackedByteArray:
	var s := chunk.dimensions.x
	var ps := s + 2
	var padded := PackedByteArray()
	padded.resize(ps * ps * ps)
	padded.fill(0xF0)  # 缺省空气（sky 15 / block 0）
	var light := chunk.light
	for z in s:
		for y in s:
			var src_row := z * s * s + y * s
			var dst_row := (z + 1) * ps * ps + (y + 1) * ps + 1
			for x in s:
				padded[dst_row + x] = light[src_row + x]
	for pz in ps:
		for py in ps:
			var interior_row := pz >= 1 and pz <= s and py >= 1 and py <= s
			for px in ps:
				if interior_row and px >= 1 and px <= s:
					continue
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
				var border_light := 0xF0
				if neighbor != null:
					border_light = neighbor.light[la + s * lb + s * s * lc]
				elif chunk.chunk_coord.y * s + b < 0:
					border_light = 0  # 世界底：实心无光
				padded[px + py * ps + pz * ps * ps] = border_light
	return padded


## 面角点颜色（MC 平滑光照）：以角点为公共角的 2x2 四格光照平均
##（实心格光照 0，天然形成角部 AO 变暗，不另叠显式 AO——双重暗化
## 过头）。
## 顶点色拆双通道语义（日夜循环地基，m³ 与 max 可交换故数学等价）：
##   COLOR.rgb = 方块光暖色 × b³（BSL blocklightColor 1.44/1.0/0.56 色温）
##   COLOR.a   = 天光 s³（着色器端 max(COLOR.a×日夜系数, COLOR.rgb)）
## 昼夜系数在渲染端逐帧下发（u_day），天光数值恒 15 不重传播/不重网格
## ——夜晚方块光自动接管（火把夜战）。
## op_index：面外侧格的 light_padded 索引；tan1/tan2：面切向两轴的
## padded 步长；corner 分量 0/1（0 取 -1 方向格）。
static func vertex_light_color(
		light_padded: PackedByteArray, ps: int,
		op_index: int, tan1_stride: int, tan2_stride: int,
		corner_t1: int, corner_t2: int
) -> Color:
	var o1 := -tan1_stride if corner_t1 == 0 else 0
	var o2 := -tan2_stride if corner_t2 == 0 else 0
	var i0: int = op_index
	var i1: int = op_index + o1
	var i2: int = op_index + o2
	var i3: int = op_index + o1 + o2
	var b0: int = light_padded[i0]
	var b1: int = light_padded[i1]
	var b2: int = light_padded[i2]
	var b3: int = light_padded[i3]
	var sky := (b0 >> 4) + (b1 >> 4) + (b2 >> 4) + (b3 >> 4)
	var blk := (b0 & 15) + (b1 & 15) + (b2 & 15) + (b3 & 15)
	var s := float(sky) * 0.25 / 15.0
	var b := float(blk) * 0.25 / 15.0
	# 深黑洞穴曲线 m^3（纯乘法 IEEE 确定，C# 侧逐位一致）。m^1.5 太缓：
	# 天光 10-12 的洞内区顶点色只压到 0.5-0.7，观感"进洞不变暗"；
	# m^3 下 sky=10→0.30、8→0.16、≤6→接近黑，露天 15 不受影响
	var sky_c := s * s * s
	# 方块光暖色对齐 BSL blocklightColor (255,212,160)/255 归一化
	# (1.44, 1.0, 0.56)：R+44%/B-44%（曾手调 +18%/-25% 偏淡）
	var blk_c := b * b * b
	return Color(
			blk_c * 1.44,
			blk_c,
			blk_c * 0.56,
			sky_c)


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
## water_levels：主线程预收集的水位级别表（worker 安全——collect 会
## 遍历 sparse_block_states Dictionary，主线程水位 tick 同时增删可致
## 哈希表损坏，审查发现）。null = 自行收集（单测/低频路径）。
static func build_mesh_arrays(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array,
		water_levels: Variant = null,
		grass_detail: int = 2,
		states_snap: Variant = null
) -> Dictionary:
	var native := NativeMeshBridge.build(false, registry, chunk, neighbors,
			null, grass_detail, states_snap)
	if not native.is_empty():
		if chunk.has_water:
			var water := NativeMeshBridge.build_water(chunk, neighbors, water_levels)
			if water.is_empty():
				return _build_gd(registry, chunk, neighbors,
						water_levels, grass_detail, states_snap)
			native.merge(water)
		return native
	return _build_gd(registry, chunk, neighbors, water_levels,
			grass_detail, states_snap)


## 共享只读空状态（热循环 per-block 曾构造 {} 4096 次/区块——
## 仅 is_empty() 判断与 effective_tile_name 只读消费，共享安全）
const EMPTY_STATE := {}


static func _build_gd(
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array,
		water_levels: Variant = null,
		grass_detail: int = 2,
		states_snap: Variant = null
) -> Dictionary:
	# states_snap：worker 传入的 states 深拷贝（P1-5 并发修复）；
	# null（主线程/测试直调）时用 chunk.sparse_block_states 本体
	var states: Dictionary = states_snap if states_snap is Dictionary 			else chunk.sparse_block_states
	assert(chunk.dimensions.x == chunk.dimensions.y
			and chunk.dimensions.y == chunk.dimensions.z, "Stage A 仅支持立方体区块")
	var s := chunk.dimensions.x
	var tables := build_lookup_tables(registry)
	var solid_by_id: PackedByteArray = tables["solid"]
	var occludes_by_id: PackedByteArray = tables["occludes"]
	var render_kind: PackedByteArray = tables["render_kind"]
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
	var has_states := not states.is_empty()
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

	# 光照填充缓存 + 面切向轴步长（角点平滑光照采样用）
	var light_padded := build_light_padded(chunk, neighbors)
	var axis_stride := [1, stride_y, stride_z]
	# 每面 normal 轴外的两切向轴（与 FACES 顺序对应）
	var face_tan_axes: Array = [
		[1, 2], [1, 2], [0, 2], [0, 2], [0, 1], [0, 1],
	]
	var face_tan1_stride := PackedInt32Array()
	var face_tan2_stride := PackedInt32Array()
	for f0 in FACES.size():
		face_tan1_stride.append(axis_stride[face_tan_axes[f0][0]])
		face_tan2_stride.append(axis_stride[face_tan_axes[f0][1]])

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	# 树叶面单独成桶（cutout 表面：alpha 裁切镂空材质）；顶点/UV
	# 与不透明网格共享，仅索引分流——碰撞构建合并两桶
	var cutout_indices := PackedInt32Array()
	# 植物/草叶桶：循环只收集格位，循环后统一发射（独立数组/独立
	# cross 表面——不进碰撞，UV 图集空间与主数组解耦）
	var plant_cells: Array = []
	var grass_top_cells: Array = []

	for z in s:
		for y in s:
			for x in s:
				var pidx := (z + 1) * stride_z + (y + 1) * stride_y + (x + 1)
				var block_id := padded[pidx]
				# dispatch 表分发（曾硬编码 AIR/WATER/BRANCH ID 判断）：
				# skip = 专用通道（水/枝干）或不渲染；cross = 十字面片
				var kind: int = render_kind[block_id]
				if kind == RENDER_PLANT:
					# 植物（高草/花）：循环后统一发射 X 十字面片
					plant_cells.append([x, y, z, pidx])
					continue
				if kind == RENDER_CROSS:
					# cross 桶方块（火把）由实体渲染器呈现（TorchRenderer），
					# 网格不出几何——chunk cross 路径曾用户实机不可见（绕行）
					continue
				if kind == RENDER_SKIP or solid_by_id[block_id] == 0:
					continue
				if block_id == VoxelTypes.GRASS_ID:
					var up_id := padded[pidx + neighbor_offsets[2]]
					# 草顶露天空或顶上是植物（地毯全覆盖，高草株从叶间
					# 钻出——GG 观感；hash 世界坐标驱动跨区块稳定）
					# 树冠/枝占位下方也发地毯叶（B9d：树下秃一片被用户
					# 误读为"渲染剔除扇形"——世界固定+脚下即有的真身）
					if up_id == VoxelTypes.AIR_ID \
							or render_kind[up_id] == RENDER_PLANT \
							or up_id == VoxelTypes.BRANCH_ID \
							or up_id == VoxelTypes.LEAVES_ID:
						grass_top_cells.append([x, y, z, pidx])
				var textures: Dictionary = textures_by_id[block_id]
				var state: Dictionary = EMPTY_STATE
				if has_states:
					state = states.get(Vector3i(x, y, z), {})
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
						# BetterGrassify 草坡融合（FANCY 语义，canFullyConnect
						# = relative(face).below()）：草方块暴露水平侧面，
						# 斜下格（面朝向邻格的正下方）也是草 → 整面用顶面
						# 贴图——草坡台阶侧壁涂绿与下阶顶面连片。邻格不遮
						# 挡已由面暴露保证。
						# 交界过渡：本面是土面时，切向邻格的同朝向面 blend →
						# 贴图对应侧加草垂带（variant bit0=u0 侧 bit1=u1 侧；
						# 切向正向→u 减侧的面：+X/-Z，flip 表）。blend/variant
						# 编进 cache_key（+512/+1024×variant）
						var blend := false
						var variant := 0
						if block_id == VoxelTypes.GRASS_ID and f != 2 and f != 3:
							if padded[pidx + neighbor_offsets[f]
									+ neighbor_offsets[3]] \
									== VoxelTypes.GRASS_ID:
								blend = true
							else:
								var t_off: int = neighbor_offsets[4] \
										if f < 4 else neighbor_offsets[0]
								var flip := f == 0 or f == 5
								for sgn in [-1, 1]:
									var nb2: int = pidx + sgn * t_off
									if padded[nb2] == VoxelTypes.GRASS_ID \
											and padded[nb2
											+ neighbor_offsets[f]
											+ neighbor_offsets[3]] \
											== VoxelTypes.GRASS_ID:
										if (sgn > 0) == flip:
											variant |= 1
										else:
											variant |= 2
						var cache_key := block_id * 8 + f \
								+ (512 if blend else 0) + 1024 * variant
						if tile_cache.has(cache_key):
							tile_origin = tile_cache[cache_key]
						else:
							var tile_name := String(textures.get(
									face_kinds[f], textures.get("side", "")))
							if blend:
								tile_name = String(textures.get("top", tile_name))
							elif variant != 0:
								tile_name = String(textures.get(
										["side_u0", "side_u1",
										"side_u01"][variant - 1], tile_name))
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
						# 角点平滑光照：面外层 2x2 四格平均（含实心 0 格的
						# 天然 AO）；两切向轴上 corner 分量决定取 -1 方向格
						var tan_axes: Array = face_tan_axes[f]
						colors.append(vertex_light_color(light_padded, ps,
								pidx + neighbor_offsets[f],
								face_tan1_stride[f], face_tan2_stride[f],
								int(corner[tan_axes[0]]), int(corner[tan_axes[1]])))
					# 索引绕序与角点顺序相反：Godot 正面 = 面外侧看顺时针。
					# 树叶面进 cutout 桶（独立渲染表面），其余进不透明桶。
					# 直接 append 六索引——曾 append_array(PackedInt32Array([...]))
					# 每面分配临时数组，数千面/区块纯 GC 压力
					if kind == RENDER_CUTOUT:
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
		"colors": colors,
		"indices": indices,
		"cutout_indices": cutout_indices,
	}
	var c := chunk.chunk_coord
	var d := chunk.dimensions
	var world_origin := Vector3i(c.x * d.x, c.y * d.y, c.z * d.z)
	# 草叶块级预算（审查 2-F2）：detail=2 满密度单块上界 ~19MB 顶点
	#（1152 顶点/格 × 最多 256 草顶格），编辑重烘必整块重发；草顶格
	# 超预算强制降 detail 1（48 片/单面/2 关键，顶点 -75%，最坏块
	# ~4.8MB）。**等价红线：C# BuildNaive 同常量同判定**（贪心对比
	# 模式无预算——超 160 格时 naive 与 greedy 不再逐位等价，基准
	# 模式语义，可接受）
	if grass_top_cells.size() > GRASS_CELL_BUDGET and grass_detail > 1:
		grass_detail = 1
	for cell in plant_cells:
		if padded[cell[3]] == VoxelTypes.TALL_GRASS_ID:
			# 高草株：×3 高叶簇（GG TALL_PLANT_HEIGHT_MULTIPLIER，
			# 弃 X 十字 billboard——18 片成束，根贴地 0.02）
			append_grass_blades(result, cell[0], cell[1], cell[2],
					light_padded, ps, cell[3], inv_cols, inv_rows,
					world_origin.x + cell[0], world_origin.z + cell[2],
					TALL_N_BY_DETAIL[grass_detail], TALL_PLANT_MULT,
					TALL_PLANT_Y0, TALL_W_MULT, grass_detail)
		else:
			append_plant_faces(result, cell[0], cell[1], cell[2],
					textures_by_id[padded[cell[3]]], light_padded, ps,
					cell[3], inv_cols, inv_rows,
					world_origin.x + cell[0], world_origin.z + cell[2])
	for cell in grass_top_cells:
		append_grass_blades(result, cell[0], cell[1], cell[2],
				light_padded, ps, cell[3], inv_cols, inv_rows,
				world_origin.x + cell[0], world_origin.z + cell[2],
				0, 1.0, 1.0, 1.0, grass_detail)
	append_water_faces(padded, ps, result,
			water_levels if water_levels != null
					else collect_water_levels_world(chunk, neighbors),
			Vector3i(c.x * d.x, c.y * d.y, c.z * d.z),
			loaded_dirs(neighbors))
	return result


## 6 向直接邻区块是否已加载（FACES 序：+X,-X,+Y,-Y,+Z,-Z）。
## 27 元素邻域快照索引 = (dz+1)*9 + (dy+1)*3 + (dx+1)；快照不是
## 27 元素时一律视为已加载（保持旧行为）。
static func loaded_dirs(neighbors: Array) -> PackedByteArray:
	var dirs := PackedByteArray()
	if neighbors.size() != 27:
		return dirs
	dirs.resize(6)
	for f in 6:
		dirs[f] = 1 if neighbors[LOADED_DIR_INDEX[f]] != null else 0
	return dirs


## ---- 植物（dispatch 表 plant 桶：高草/花 X 十字 + 草顶密叶）----
## GrassierGrass 思想自研：全部几何一次性烘焙进区块网格（零逐帧
## CPU/GPU compute），风摆由顶点着色器承担（Phase B）。**等价
## 红线：C# NativeMesher 逐位复刻**（顶点顺序/常数一致）。
## X 十字内缩量（MC 式：面片不贴格边）
const PLANT_INSET := 0.15
## 单片草叶几何常量（GrassierGrass 观感对齐：细叶密植+区域草浪+
## 簇姿态连贯——独立随机会显"毛躁"，区域相关才成"草浪"）
# —— GG 默认起步、按用户观感逐轮上调（B7：整体加高+高低差拉大+
# 高草超玩家；swell 0.47-1.17 的 32 格大区草浪承担"整片起伏"）——
const BLADE_HALF_W := 0.04    # BAKED_BASE_WIDTH 0.040（宽 0.08）

const BLADE_H_BASE := 0.75    # GG 默认 0.5075 → B7 加高一档
const BLADE_H_PER := 0.30     # 叶内 0.80-1.10（默认 0.88+0.13——拉大株内高低差）
const BLADE_LEAN := 0.16      # 梢歪更活（默认 0.12）
## 高草株（tall_grass 方块）：叶簇替代 X 十字；×3.6 后峰值 2.0+ 超玩家
const TALL_PLANT_MULT := 3.6  # GG TALL_PLANT_HEIGHT_MULTIPLIER 3.0 → B7
const TALL_W_MULT := 1.35     # 高草叶整体加宽（粗细随机之外的基宽抬升）
const TALL_PLANT_N := 18
## 草顶格块级预算（审查 2-F2；C# NativeMesher.GrassCellBudget 同步）
const GRASS_CELL_BUDGET := 160

## 高草株片数按距离分级（近 18 / 中 14 / 远 10——B9c 回补）
const TALL_N_BY_DETAIL := [10, 14, 18]
const TALL_PLANT_Y0 := 0.02   # 根部抬升防贴地 z-fight
## 区域草浪：SWELL_CELL 大区双线性低频高度（GG 32 格瓦片——
## 6 格太碎显"噪"，32 格才出"整片起伏"的草浪观感）
const SWELL_CELL := 32
const SWELL_SALT := 951
## 草簇：CLUSTER_CELL 粗格共享叶向（GG Voronoi 团簇思想）
const CLUSTER_CELL := 3
const CLUSTER_SALT := 961
## 风摆相位盐（UV2 携带；shader 读）
const BLADE_SALT_PH := 971
const PLANT_SALT_PH := 981
## 草叶 hash 盐（C# 同步）
const BLADE_SALT_N := 911
const BLADE_SALT_OX := 912
const BLADE_SALT_OZ := 921
const BLADE_SALT_H := 931
const BLADE_SALT_D := 941


## 植物 X 十字面片（全 tile UV；两对角 quad 各单片、单绕序单对角线
## ——cross 材质 cull_disabled 双面，B9；曾双绕序=单面材质时代设计）
static func append_plant_faces(
		out: Dictionary, x: int, y: int, z: int,
		textures: Dictionary, light_padded: PackedByteArray,
		ps: int, pidx: int, inv_cols: float, inv_rows: float,
		wx: int = 0, wz: int = 0
) -> void:
	var vertices: PackedVector3Array = out.get(
			"cross_vertices", PackedVector3Array())
	var normals: PackedVector3Array = out.get(
			"cross_normals", PackedVector3Array())
	var uvs: PackedVector2Array = out.get(
			"cross_uvs", PackedVector2Array())
	var uv2s: PackedVector2Array = out.get(
			"cross_uv2s", PackedVector2Array())
	var colors: PackedColorArray = out.get(
			"cross_colors", PackedColorArray())
	var cross_indices: PackedInt32Array = out.get(
			"cross_indices", PackedInt32Array())
	var tile := TextureAtlasLoader.tile_grid(
			String(textures.get("side", "grass_tuft")))
	var o_x := float(tile.x) * inv_cols
	var o_y := float(tile.y) * inv_rows
	var light := vertex_light_color(light_padded, ps, pidx, 1, 1, 1, 1)
	var i0 := PLANT_INSET
	var i1 := 1.0 - PLANT_INSET
	# 两个对角面片：(i0,i0)-(i1,i1) 与 (i0,i1)-(i1,i0)
	var quads := [
		[Vector3(x + i0, y, z + i0), Vector3(x + i1, y, z + i1)],
		[Vector3(x + i0, y, z + i1), Vector3(x + i1, y, z + i0)],
	]
	for q in quads:
		var a: Vector3 = q[0]
		var b: Vector3 = q[1]
		var base := vertices.size()
		vertices.append(a)
		vertices.append(b)
		vertices.append(a + Vector3.UP)
		vertices.append(b + Vector3.UP)
		for k in 4:
			normals.append(Vector3.UP)
			colors.append(light)
		uvs.append(Vector2(o_x, o_y + inv_rows))
		uvs.append(Vector2(o_x + inv_cols, o_y + inv_rows))
		uvs.append(Vector2(o_x, o_y))
		uvs.append(Vector2(o_x + inv_cols, o_y))
		# UV2 风摆（同草叶语义：底 0 顶 1；每株一个相位）
		var pph: float = TreeScatter.hash01(wx, wz, PLANT_SALT_PH)
		uv2s.append(Vector2(0.0, pph))
		uv2s.append(Vector2(0.0, pph))
		uv2s.append(Vector2(1.0, pph))
		uv2s.append(Vector2(1.0, pph))
		# 单绕序（cross 材质 cull_disabled 双面——性能 B9；曾双绕序）。
		# **单对角线配对**（1-2）：正组两三角共享对角线才互补全覆盖
		#（旧双对角线写法 quad 中央留三角洞——B8b 修复）
		cross_indices.append_array(PackedInt32Array([
			base, base + 2, base + 1,
			base + 1, base + 2, base + 3,
		]))
	out["cross_vertices"] = vertices
	out["cross_normals"] = normals
	out["cross_uvs"] = uvs
	out["cross_uv2s"] = uv2s
	out["cross_colors"] = colors
	out["cross_indices"] = cross_indices


## 草顶密叶：每格 hash 定 2-3 片窄叶（位置/高度/斜向），世界坐标
## 驱动跨区块稳定。叶面沿对角线朝向，梢部顺叶向微倾。
static func append_grass_blades(
		out: Dictionary, x: int, y: int, z: int,
		light_padded: PackedByteArray, ps: int, pidx: int,
		inv_cols: float, inv_rows: float, wx: int, wz: int,
		n_override: int = 0, h_mult: float = 1.0, y0_off: float = 1.0,
		w_mult: float = 1.0, detail: int = 2
) -> void:
	var vertices: PackedVector3Array = out.get(
			"cross_vertices", PackedVector3Array())
	var normals: PackedVector3Array = out.get(
			"cross_normals", PackedVector3Array())
	var uvs: PackedVector2Array = out.get(
			"cross_uvs", PackedVector2Array())
	var uv2s: PackedVector2Array = out.get(
			"cross_uv2s", PackedVector2Array())
	var colors: PackedColorArray = out.get(
			"cross_colors", PackedColorArray())
	var cross_indices: PackedInt32Array = out.get(
			"cross_indices", PackedInt32Array())
	var tile := TextureAtlasLoader.tile_grid("grass_blade")
	var o_x := float(tile.x) * inv_cols
	var o_y := float(tile.y) * inv_rows
	# 光照取草块上方格（叶身所在格；+Y 偏移 = ps——与主循环
	# neighbor_offsets[2] 同源，发射器独立重算）
	var light := vertex_light_color(light_padded, ps,
			pidx + ps, 1, 1, 1, 1)
	# 区域草浪：SWELL_CELL 粗格四角 hash 双线性（大片共享高度特征）
	var gx := float(wx) / float(SWELL_CELL)
	var gz := float(wz) / float(SWELL_CELL)
	var sx := floori(gx)
	var sz := floori(gz)
	var fx := gx - float(sx)
	var fz := gz - float(sz)
	var h00: float = TreeScatter.hash01(sx, sz, SWELL_SALT)
	var h10: float = TreeScatter.hash01(sx + 1, sz, SWELL_SALT)
	var h01: float = TreeScatter.hash01(sx, sz + 1, SWELL_SALT)
	var h11: float = TreeScatter.hash01(sx + 1, sz + 1, SWELL_SALT)
	# GG HEIGHT_NOISE：contrast 1.35/bias 0.5 整形到 0.1(短)-1.28(高)，
	# REGIONAL_LENGTH_FRACTION 0.59 混合（短斑与高草丛并存=成片感）
	var hn := pow(lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz),
			1.35)
	var swell := 1.0 + 0.59 * (lerpf(0.1, 1.28, hn) - 1.0)
	# 叶向基准角（每格一个）：格内叶向相近（近看成束），格间全随机
	# ——任何视角下每格都有近正对的叶面。曾锁死 ±45° 对角（B5-B9e
	# 前）→ 侧对视角全图压线；B9e 簇级基准（3×3 格同向）侧对簇仍
	# 整簇显薄（用户"部分地方还是朝一个方向"）——降到格级+±60° 扰动
	var cell_angle := TAU * TreeScatter.hash01(wx, wz, CLUSTER_SALT)
	# 密度档：近距三档 56/64/72（GG DEFAULT_BLADES_PER_BLOCK 64 茂密
	# 主源）；距离分级（性能 B9/B9c）：中 48/远 32（曾 40/24 断崖太陡
	# 显"辐射缺失"；C# 同步——曾 GD 侧替换静默失败教训）
	var rn: float = TreeScatter.hash01(wx, wz, BLADE_SALT_N)
	var n := n_override if n_override > 0 \
			else ((56 if rn < 0.40 else (64 if rn < 0.80 else 72)) \
			if detail >= 2 else (48 if detail == 1 else 32))
	for i in n:
		var r_ox := TreeScatter.hash01(wx * 4 + i, wz * 3 - i,
				BLADE_SALT_OX + i)
		var r_oz := TreeScatter.hash01(wx * 7 - i, wz * 5 + i,
				BLADE_SALT_OZ + i)
		var r_h := TreeScatter.hash01(wx * 2 + i, wz * 9 + i,
				BLADE_SALT_H + i)
		var r_d := TreeScatter.hash01(wx * 6 + i, wz + i,
				BLADE_SALT_D + i)
		var ph := TreeScatter.hash01(wx * 13 + i, wz * 17 - i,
				BLADE_SALT_PH + i)
		# 贴边撒布（-0.04~1.04）：叶身跨过格线互搭，消除格间 0.16
		# 空带断层（曾 0.08~0.92 内缩=每格四周裸土缝）
		var cx := x - 0.04 + 1.08 * r_ox
		var cz := z - 0.04 + 1.08 * r_oz
		# 叶长 = 基准 ×（高草株 ×3.6）× 区域草浪 × 叶内变化（0.80-1.10）
		var h := maxf(BLADE_H_BASE * h_mult * swell
				* (0.80 + BLADE_H_PER * r_h), 0.02)
		# 叶朝向 = 格基准角 + 叶内 ±60° 扰动（同格多样——侧对方向
		# 也有大量近正对叶面；r_d 复用为扰动源）
		var ang := cell_angle + (r_d - 0.5) * 2.1
		var diag := Vector2(cos(ang), sin(ang))
		# 叶宽：随机 0.75-1.25 ×（高草株加宽）——高草曾是"等宽棍"
		#（18 片同宽+等宽到顶），叶尖再收窄破棍感（GG 叶形 base 0.04
		# → tip 0.013）。w double 算完显式截 float32 再进 Vector2 组件
		# 乘——与 C# 三段路径逐位对齐（对拍坑沉淀）
		var w := BLADE_HALF_W * (0.75 + 0.5 * r_h) * w_mult
		var lean := diag * BLADE_LEAN
		# 叶身曲线（GodotGrass/对马岛 GDC）：近距 4 关键 8 顶点，水平
		# 偏移 ∝ t²（悬臂抛物线）+宽度沿 t 平滑收窄（3 关键 2 段折角
		# 生硬——用户反馈）。中/远距降 2 关键 4 顶点（直线锥叶——
		# 远观感知不到折角，顶点 -50%，性能 B9）
		const CURVE_T := [0.0, 0.30, 0.62, 1.0]
		const CURVE_W := [1.0, 0.90, 0.72, 0.35]
		const CURVE_T2 := [0.0, 1.0]
		const CURVE_W2 := [1.0, 0.35]
		var ckeys: int = 4 if detail >= 2 else 2
		var curve_t: Array = CURVE_T if ckeys == 4 else CURVE_T2
		var curve_w: Array = CURVE_W if ckeys == 4 else CURVE_W2
		var base := vertices.size()
		var sway_w: float = 0.6 + 0.4 * h
		# 十字双面（用户"加一点厚度"）：diag 主面 + 垂直副面——侧对
		# 一个面必正对另一个，任何视角都有可见叶带（等效厚度，比真
		# 厚度盒便宜一半）。**性能 B10：十字只在近距**——中/远距单面
		#（格级全角度叶向 B9f 已保证外圈方向多样性，透视缩小的远景
		# 感知不到单面侧对；外圈占视距面积大头，砍半收益最大）
		var faces: int = 2 if detail >= 2 else 1
		var perp := Vector2(-diag.y, diag.x)
		for ci in ckeys:
			var t: float = curve_t[ci]
			var wt32: float = w * curve_w[ci]
			var half_a := diag * wt32
			var half_b := perp * wt32
			var t2 := t * t
			var xoff := lean.x * t2
			var zoff := lean.y * t2
			var hy := y + y0_off + h * t
			vertices.append(Vector3(cx - half_a.x + xoff, hy,
					cz - half_a.y + zoff))
			vertices.append(Vector3(cx + half_a.x + xoff, hy,
					cz + half_a.y + zoff))
			if faces == 2:
				vertices.append(Vector3(cx - half_b.x + xoff, hy,
						cz - half_b.y + zoff))
				vertices.append(Vector3(cx + half_b.x + xoff, hy,
						cz + half_b.y + zoff))
			for k in faces * 2:
				normals.append(Vector3.UP)
				colors.append(light)
			var v_row: float = o_y + inv_rows * (1.0 - t)
			uvs.append(Vector2(o_x, v_row))
			uvs.append(Vector2(o_x + inv_cols, v_row))
			if faces == 2:
				uvs.append(Vector2(o_x, v_row))
				uvs.append(Vector2(o_x + inv_cols, v_row))
			# UV2 = (风摆权重, 相位)：t ×(0.6+0.4h)——实际叶高烘进
			# 权重，shader 平方衰减下端点摆幅 ∝ h²（高草受风更大）
			for k in faces:
				uv2s.append(Vector2(sway_w * t, ph))
				uv2s.append(Vector2(sway_w * t, ph))
		# (ckeys-1) 段 × faces 面 quad，单绕序（cull_disabled 双面——
		# B9）。关键 stride 2×faces：A 面 (0,1,+stride)、B 面 (2,3,+stride)
		# 单对角线配对（B8b 教训）
		var stride: int = faces * 2
		for s2 in ckeys - 1:
			var v0 := base + s2 * stride
			for f in faces:
				var q := v0 + f * 2
				cross_indices.append(q)
				cross_indices.append(q + stride)
				cross_indices.append(q + 1)
				cross_indices.append(q + 1)
				cross_indices.append(q + stride)
				cross_indices.append(q + stride + 1)
	out["cross_vertices"] = vertices
	out["cross_normals"] = normals
	out["cross_uvs"] = uvs
	out["cross_uv2s"] = uv2s
	out["cross_colors"] = colors
	out["cross_indices"] = cross_indices


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
	if chunk == null or not chunk.has_water:
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
		levels_world: Dictionary = {}, origin: Vector3i = Vector3i.ZERO,
		dir_loaded: PackedByteArray = PackedByteArray()
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
					# 朝未加载邻区块的侧壁不出面：那里没有数据，"空气"
					# 只代表未知。曾一律按空气出面 -> 水柱在加载边界
					# （视距圈边缘 / 流式加载前沿）立起一圈从水面直落
					# 海底的竖墙，等距每 16 格一片=用户实机截图的幕帘。
					if is_side and dir_loaded.size() == 6 and dir_loaded[f] == 0:
						continue
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
## 岸距衰减统一公式：采样到的固体格数 → 衰减（网格器角点与
## 浮物波高采样共用；两处各写曾漂移出 ×0.5 与 /3.0 两套——
## 贴岸浮物与视觉水面起伏不一致，审查发现）
static func shore_fade_value(solid_count: int) -> float:
	return 1.0 - clampf(float(solid_count) * 0.5, 0.0, 0.85)


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
	return shore_fade_value(solid)


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
