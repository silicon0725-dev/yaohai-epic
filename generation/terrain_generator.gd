## 固定种子的确定性地形生成器（开发文档 §5）。
## v3（参考 Terrain Diffusion 的合成地形配方移植）：
##   1. 分位匹配——把单纯形 fBm 的输出分布重映射到贴近真实地貌的
##      高程分布（大面积平原、长尾山地），源分位节点在初始化时对
##      本种子噪声采样校准（对应 transform_perlin + build_quantiles）；
##   2. 粗图布局——低频"山脉掩码"决定山在哪里，掩码内叠加脊状
##      噪声（RIDGED）生成山脊线，等价于其 coarse map 条件生成；
##   3. 气候场——低频温度/降水两张粗图 + 温度随海拔的递减率
##      （lapse），据此选生物群系：荒漠（热且干）/ 草原 /
##      裸岩山地 / 滩涂沙地。
## 调整任何参数都必须递增版本——未修改区域会用新算法重建，已保存
## 的完整区块数据不受影响（§5.1、§9）。
class_name TerrainGenerator
extends RefCounted

## C# 原生地形桥（preload 避开新 class_name 的全局类缓存坑）
const NativeTerrainBridge := preload("res://meshing/native_terrain_bridge.gd")

## 生成算法版本。
const GENERATOR_VERSION := 6

# ---- 地层参数（v2 语义保留）----
## 表层以下 3 格为泥土（草区）或砂岩（沙区）。
const DIRT_LAYER_DEPTH := 3
const SANDSTONE_LAYER_DEPTH := 3
## 地表高度不超过此值时为滩涂/干涸湖床沙地。
const SAND_MAX_HEIGHT := 8
## 矿脉噪声阈值（单倍频单纯形 -1..1，越高越稀疏）。
const COAL_ORE_THRESHOLD := 0.60
const IRON_ORE_THRESHOLD := 0.68
## 铁矿最深出现高度（比煤更稀有且更深）。
const IRON_ORE_MAX_Y := 24
## 矿石不生成的地表保护层厚度。
const ORE_SURFACE_MARGIN := 4
## 海平面（v4）：低于它的空气列填水。取 7 与滩涂沙线上限（8）衔接
##——海岸一圈自然成沙滩；水下地表本就 ≤8 全为沙（浅海沙底）。
const SEA_LEVEL := 7

# ---- v3 地形参数 ----
## 高程分布重映射的目标分位表（移植其分位匹配）：输入为噪声的
## 累积分位，输出为高度占比 0..1。质量集中在中低（平原为主），
## 高端长尾（山地稀少而陡峭）——即真实地貌的测高曲线形状。
const KNOT_COUNT := 17
const TARGET_HEIGHT_FRAC := [
	0.030, 0.055, 0.075, 0.095, 0.115, 0.135, 0.155, 0.180,
	0.205, 0.235, 0.270, 0.315, 0.370, 0.445, 0.540, 0.680, 0.900,
]
## 山脉掩码门控（smoothstep 区间）：掩码值高于上界全幅出山，
## 低于下界完全无山——山只出现在粗图划定的区域。
const MOUNTAIN_GATE_LO := 0.30
const MOUNTAIN_GATE_HI := 0.60
## 山脊叠加幅度（高度占比）。
const MOUNTAIN_GAIN := 0.46
## 细节起伏幅度（高度占比）。
const DETAIL_GAIN := 0.045
## 裸岩山地的高度占比阈值（高于此值表层为石头，无泥土）。
const ROCK_SURFACE_FRAC := 0.62
## 气候：温度随高度占比的递减率（高地更冷）。
const TEMP_LAPSE := 0.9
## 荒漠判定：温度与干燥度阈值（低地才算，山地按裸岩处理）。
const DESERT_TEMP := 0.30
const DESERT_DRYNESS := -0.10
const DESERT_MAX_FRAC := 0.45

var config: WorldConfig
var _continental_noise: FastNoiseLite
var _mountain_mask_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _temp_noise: FastNoiseLite
var _precip_noise: FastNoiseLite
var _coal_noise: FastNoiseLite
var _iron_noise: FastNoiseLite
## 本种子噪声的源分位节点（初始化时校准，确定性）。
var _source_knots := PackedFloat32Array()


func _init(world_config: WorldConfig) -> void:
	config = world_config
	# 粗图（低频布局）：大陆高程 4 倍频 / 山脉掩码 / 温度 / 降水
	_continental_noise = _make_fbm(world_config.world_seed, 0.0028, 4)
	_mountain_mask_noise = _make_fbm(world_config.world_seed + 101, 0.0011, 3)
	_temp_noise = _make_fbm(world_config.world_seed + 202, 0.0016, 3)
	_precip_noise = _make_fbm(world_config.world_seed + 303, 0.0013, 3)
	# 细节：山脊（脊状分形）与局部起伏
	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.seed = world_config.world_seed + 404
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridge_noise.frequency = 0.02
	_ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge_noise.fractal_octaves = 3
	_detail_noise = _make_fbm(world_config.world_seed + 505, 0.05, 2)
	# 矿物（v2 语义不变）
	_coal_noise = _make_fbm(world_config.world_seed + 606, 0.08, 1)
	_iron_noise = _make_fbm(world_config.world_seed + 707, 0.09, 1)
	_source_knots = _build_source_quantiles()


static func _make_fbm(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	return noise


## 对本种子的大陆噪声固定采样，构建源分布分位节点（对应
## build_quantiles：分布与种子无关，仅频率/倍频参数决定形状；
## 固定采样坐标保证确定性）。
func _build_source_quantiles() -> PackedFloat32Array:
	var samples: Array[float] = []
	for i in 24:
		for j in 24:
			samples.append(_continental_noise.get_noise_2d(
					float(i * 37 + 3), float(j * 41 + 13)))
	samples.sort()
	var knots := PackedFloat32Array()
	for k in KNOT_COUNT:
		var idx := int(round(float(k) / float(KNOT_COUNT - 1)
				* float(samples.size() - 1)))
		knots.append(samples[idx])
	for k in range(1, knots.size()):
		if knots[k] <= knots[k - 1]:
			knots[k] = knots[k - 1] + 0.0001
	return knots


## 分位匹配（对应 transform_perlin）：把噪声值线性映射到目标
## 高程分布的对应分位高度占比。
func _shape_height(noise_value: float) -> float:
	if noise_value <= _source_knots[0]:
		return float(TARGET_HEIGHT_FRAC[0])
	for k in range(1, _source_knots.size()):
		if noise_value <= _source_knots[k]:
			var t := (noise_value - _source_knots[k - 1]) \
					/ maxf(_source_knots[k] - _source_knots[k - 1], 0.0001)
			return lerpf(float(TARGET_HEIGHT_FRAC[k - 1]), float(TARGET_HEIGHT_FRAC[k]), t)
	return float(TARGET_HEIGHT_FRAC[TARGET_HEIGHT_FRAC.size() - 1])


## 列剖面：高度占比 + 高度 + 生物群系（每列一次，供地层填充）。
## 生物群系：裸岩山地（高）/ 荒漠（热干低地）/ 滩涂沙（近基准面）/
## 草原（默认）。温度含海拔递减（对应其 lapse 公式的简化）。
func column_profile(world_x: int, world_z: int) -> Dictionary:
	var frac := _shape_height(
			_continental_noise.get_noise_2d(world_x, world_z))
	var mask_raw := _mountain_mask_noise.get_noise_2d(world_x, world_z)
	var gate := smoothstep(MOUNTAIN_GATE_LO, MOUNTAIN_GATE_HI, mask_raw)
	if gate > 0.0:
		var ridge01 := clampf(
				(_ridge_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5, 0.0, 1.0)
		frac += gate * ridge01 * MOUNTAIN_GAIN
	frac += _detail_noise.get_noise_2d(world_x, world_z) * DETAIL_GAIN
	frac = clampf(frac, 0.0, 1.0)
	var max_surface := config.world_height_blocks() - 3
	var height := clampi(
			1 + int(round(frac * float(max_surface - 1))), 1, max_surface)
	# v5：压掉"齐平沙洲"（height == SEA_LEVEL，顶面恰在海平面上
	# 0.125 格）——贴水视角是大片无水干沙色平台带 + 同高露头横线，
	# 被视为"水面缺口"。降 1 格沉为 1 格水深浅滩，海滩线从 +1 开始
	if height == SEA_LEVEL:
		height = SEA_LEVEL - 1

	var rocky := frac >= ROCK_SURFACE_FRAC
	var temp := _temp_noise.get_noise_2d(world_x, world_z) \
			- TEMP_LAPSE * maxf(0.0, frac - 0.30)
	var desert := not rocky and height > SAND_MAX_HEIGHT \
			and temp > DESERT_TEMP and frac < DESERT_MAX_FRAC \
			and _precip_noise.get_noise_2d(world_x, world_z) < DESERT_DRYNESS
	var sandy := desert or height <= SAND_MAX_HEIGHT
	return { "height": height, "frac": frac, "rocky": rocky, "sandy": sandy }


## 列表面方块（§5.1 气候群系 + 矿脉层）：按高度占比与气候选块。
func block_for_column(
		profile: Dictionary, world_x: int, world_y: int,
		world_z: int, height: int
) -> int:
	return _block_for_column(profile, profile["rocky"], profile["sandy"],
			world_x, world_y, world_z, height)


## 内联版：rocky/sandy 由调用方解包（生成热循环免每格字符串键取值）。
func _block_for_column(
		profile: Dictionary, rocky: bool, sandy: bool,
		world_x: int, world_y: int, world_z: int, height: int
) -> int:
	if world_y > height:
		return VoxelTypes.AIR_ID
	if world_y == 0:
		return VoxelTypes.BEDROCK_ID
	if world_y == height:
		if rocky:
			return VoxelTypes.STONE_ID
		if sandy or height <= SAND_MAX_HEIGHT:
			return VoxelTypes.SAND_ID
		return VoxelTypes.GRASS_ID
	if world_y >= height - DIRT_LAYER_DEPTH:
		if rocky:
			return VoxelTypes.STONE_ID
		if sandy or height <= SAND_MAX_HEIGHT:
			# 滩涂/荒漠沙地层：紧贴表层的次层是砂岩（测试期望
			# sandy 列 depth 1..3 全为砂岩）
			return VoxelTypes.SANDSTONE_ID
		return VoxelTypes.DIRT_ID
	# 矿脉（确定性单纯形，铁更深更稀有，地表保护层内不出矿）
	if world_y <= height - ORE_SURFACE_MARGIN:
		if world_y <= IRON_ORE_MAX_Y 				and _iron_noise.get_noise_3d(world_x, world_y, world_z) 				> IRON_ORE_THRESHOLD:
			return VoxelTypes.IRON_ORE_ID
		if _coal_noise.get_noise_3d(world_x, world_y, world_z) 				> COAL_ORE_THRESHOLD:
			return VoxelTypes.COAL_ORE_ID
	return VoxelTypes.STONE_ID



## 某一世界列（x, z）的地表高度。独立暴露便于测试与未来生物群系接入。
func column_height(world_x: int, world_z: int) -> int:
	return column_profile(world_x, world_z)["height"]


## 树影响半径（树冠 + 主干倾斜余量，格）
const TREE_REACH := 4


func generate_chunk(chunk_coord: Vector3i) -> ChunkData:
	assert(config.in_chunk_bounds(chunk_coord),
			"生成垂直越界区块: %s" % chunk_coord)
	var size := config.chunk_size
	var chunk := ChunkData.new(
			chunk_coord,
			Vector3i(size, size, size),
			GENERATOR_VERSION
	)
	chunk.state = ChunkState.State.GENERATING
	var origin := VoxelCoords.chunk_origin(chunk_coord, size)
	# C# 优先（等价测试 native_terrain 多种子逐字节保证）：列剖面+方块
	# 填充主体走原生；树重放留 GDScript（hash/RNG 等价风险长尾），
	# 复用 C# 输出的列剖面数组免重复噪声采样。不可用回退 GD 全程
	var native := NativeTerrainBridge.generate_chunk(
			config.world_seed, config.world_height_blocks(),
			chunk_coord, size)
	if not native.is_empty():
		chunk.block_ids = native["ids"]
		_scatter_trees(chunk, native)
	else:
		_fill_columns_gd(chunk, origin, size)
		_scatter_trees(chunk, {})
	chunk.state = ChunkState.State.DATA_READY
	return chunk


## GDScript 列填充回退路径（与 C# NativeTerrain.GenerateChunk 等价，
## 等价测试保证；直写 block_ids 布局 x + y*s + z*s²）。
func _fill_columns_gd(chunk: ChunkData, origin: Vector3i, size: int) -> void:
	var ids := chunk.block_ids
	for lz in size:
		var z_off := lz * size * size
		for lx in size:
			var world_x := origin.x + lx
			var world_z := origin.z + lz
			var profile := column_profile(world_x, world_z)
			var height: int = profile["height"]
			var rocky: bool = profile["rocky"]
			var sandy: bool = profile["sandy"]
			var col := z_off + lx
			for ly in size:
				var world_y := origin.y + ly
				var block_id: int
				# 海平面填充：地表之上的空气低于海平面即为水（v1 静态水）
				if world_y > height and world_y <= SEA_LEVEL:
					block_id = VoxelTypes.WATER_ID
				else:
					block_id = _block_for_column(profile, rocky, sandy,
							world_x, world_y, world_z, height)
				ids[col + ly * size] = block_id


## v6 动态树撒种（确定性哈希）：草地且上方空气、距 chunk 边 >=3 格
##（树冠半径 2 + 主干倾斜余量，避免跨 chunk 截断），草地密度约 5%。
## v6.1 影响范围重放（修"树顶被生成层顶切断"）：每层 chunk 对
## 水平范围内可能影响本层的所有树（根在 ±TREE_REACH 列内、
## 树根的地表任意层）确定性重放生长（同 rng 同树形），只写入
## 落在本层的格——跨层树在每层各写各的部分，完整无截断。
## profiles 非空时（C# 路径）界内列直接查 height/sandy/rocky 数组，
## 界外列（±TREE_REACH 圈）回退 column_profile——每树 1-2 次，量小。
func _scatter_trees(chunk: ChunkData, profiles: Dictionary) -> void:
	var origin := Vector3i(chunk.chunk_coord.x * chunk.dimensions.x,
			chunk.chunk_coord.y * chunk.dimensions.y,
			chunk.chunk_coord.z * chunk.dimensions.z)
	var size: int = chunk.dimensions.x
	var has_profiles := not profiles.is_empty()
	var heights: PackedInt32Array = profiles.get("heights", PackedInt32Array())
	var sandy_arr: PackedByteArray = profiles.get("sandy", PackedByteArray())
	var rocky_arr: PackedByteArray = profiles.get("rocky", PackedByteArray())
	for wx in range(origin.x - TREE_REACH, origin.x + size + TREE_REACH):
		for wz in range(origin.z - TREE_REACH, origin.z + size + TREE_REACH):
			if not TreeGenerator.has_tree_at(config.world_seed,
					Vector2i(wx, wz)):
				continue
			var surf := 0
			var is_sandy := false
			var is_rocky := false
			var lx := wx - origin.x
			var lz := wz - origin.z
			if has_profiles and lx >= 0 and lx < size and lz >= 0 and lz < size:
				var pidx := lz * size + lx
				surf = heights[pidx]
				is_sandy = sandy_arr[pidx] == 1
				is_rocky = rocky_arr[pidx] == 1
			else:
				var profile := column_profile(wx, wz)
				surf = profile["height"]
				is_sandy = profile.get("sandy", false)
				is_rocky = profile.get("rocky", false)
			if surf <= SEA_LEVEL:
				continue  # 水域/滩涂不种树
			# 草地判定（荒漠/裸岩不种）
			if is_sandy or is_rocky:
				continue
			_grow_tree_into_chunk(chunk, Vector3i(wx, surf + 1, wz))

## 确定性重放一棵树并只把落在本 chunk 的枝干/树叶格写入占位
##（跨层/跨区块树由各层重放补齐，树系统 v2 接口）。
func _grow_tree_into_chunk(chunk: ChunkData, root: Vector3i) -> void:
	var sp := TreeSpecies.new()
	var tree := TreeGenerator.generate(sp, config.world_seed, root)
	var origin := Vector3i(chunk.chunk_coord.x * chunk.dimensions.x,
			chunk.chunk_coord.y * chunk.dimensions.y,
			chunk.chunk_coord.z * chunk.dimensions.z)
	# 枝干占位（radius 逐格插值，仅主干）
	for cell in tree.cell_to_branch:
		var local: Vector3i = cell - origin
		if local.x < 0 or local.y < 0 or local.z < 0 				or local.x >= chunk.dimensions.x 				or local.y >= chunk.dimensions.y 				or local.z >= chunk.dimensions.z:
			continue
		if chunk.get_block(local) != VoxelTypes.AIR_ID:
			continue
		chunk.set_block_raw(local, VoxelTypes.BRANCH_ID)
		if tree.cell_to_branch[cell] == tree.root_branch_id:
			var r: int = TreeGenerator.trunk_radius_at(tree, cell)
			if r > 1:
				chunk.set_state(local, "radius", r)
	# 树叶占位
	for leaf in TreeGenerator.leaf_cells(tree):
		var local: Vector3i = leaf - origin
		if local.x < 0 or local.y < 0 or local.z < 0 				or local.x >= chunk.dimensions.x 				or local.y >= chunk.dimensions.y 				or local.z >= chunk.dimensions.z:
			continue
		if chunk.get_block(local) == VoxelTypes.AIR_ID:
			chunk.set_block_raw(local, VoxelTypes.LEAVES_ID)


## 确定性重放一棵树并只把落在本 chunk 的格写入（跨层/跨区块树