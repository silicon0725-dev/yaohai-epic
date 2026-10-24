## C# 原生网格桥接层（阶段 E 决策落地）。
## 负责将 GDScript 的世界数据（ChunkData/Registry/27 邻域）拼装为
## C# NativeMesher 需要的扁平数组，并在原生不可用时返回空字典
## 供调用方回退到纯 GDScript 实现。
##
## 可用性探测：编译好的 .NET 程序集在编辑器导入后可 load。
## 调用方（ChunkMesher/GreedyMesher 的门面）首次调用时探测并缓存。
class_name NativeMeshBridge
extends RefCounted

static var _native: RefCounted = null
static var _checked := false
static var _tile_cache := {}  # registry_id -> {top, side, bottom: PackedInt32Array}

const TILE_NAMES := [
	"grass_top", "grass_side", "dirt", "stone", "bedrock",
	"log_top", "log_side", "planks", "cobblestone", "bricks",
	"sand", "sandstone", "gravel", "coal_ore", "iron_ore", "leaves",
]


## 探测 C# 原生网格器是否可用（加载一次并缓存）。
## 设置 VOXEL_NO_NATIVE=1 可强制禁用（A/B 基准与问题隔离用）。
static func available() -> bool:
	if _checked:
		return _native != null
	_checked = true
	if OS.get_environment("VOXEL_NO_NATIVE") == "1":
		return false
	var script := load("res://native/NativeMesher.cs")
	if script == null:
		return false
	_native = script.new()
	return _native != null


## 为指定注册表构建 tile 下标表（缓存）。
static func _tile_tables(registry: VoxelRegistry) -> Dictionary:
	var key := registry.get_instance_id()
	if _tile_cache.has(key):
		return _tile_cache[key]
	var top := PackedInt32Array()
	var side := PackedInt32Array()
	var bottom := PackedInt32Array()
	for id in registry.block_count():
		var textures: Dictionary = registry.definition_for_id(id).get("textures", {})
		top.append(TILE_NAMES.find(String(textures.get("top", ""))))
		side.append(TILE_NAMES.find(String(textures.get("side", ""))))
		bottom.append(TILE_NAMES.find(String(textures.get("bottom", ""))))
	var tables := {"top": top, "side": side, "bottom": bottom}
	_tile_cache[key] = tables
	return tables


## 拼装 27 邻域扁平数组（build / build_water 共用）。
## append_array 批拷——曾逐元素 27×4096 次循环写，110k 次/任务的
## 纯 GDScript 桥接开销，A/B 里全算在 C# 头上。
static func _pack_neighbors(chunk: ChunkData, neighbors: Array) -> Dictionary:
	var s := chunk.dimensions.x
	var volume := s * s * s
	var neighbor_ids := PackedInt32Array()
	var neighbor_exists := PackedByteArray()
	neighbor_exists.resize(27)
	for i in 27:
		var nb: ChunkData = neighbors[i]
		if nb != null:
			neighbor_exists[i] = 1
			neighbor_ids.append_array(nb.block_ids)
		else:
			neighbor_ids.resize(neighbor_ids.size() + volume)
	return {
		"ids": neighbor_ids,
		"exists": neighbor_exists,
		"volume": volume,
	}


## 拼装并调用 C# 原生网格器。返回空字典 = 原生不可用或失败。
## 本层保持中立；是否走原生由各网格器门面按基准结论决定：
## A/B（192 区块，本机 2 核，桥批拷后）：面剔除 4.6 vs 20.6ms、
## 贪心 6.0 vs 24.0ms（C# 4-4.5×，含桥接成本）。
## 等价测试仍直调本层覆盖两条 C# 路径。
static func build(
		greedy: bool,
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array
) -> Dictionary:
	if not available():
		return {}
	var packed := _pack_neighbors(chunk, neighbors)
	var neighbor_ids: PackedInt32Array = packed["ids"]
	var neighbor_exists: PackedByteArray = packed["exists"]

	var tables := _tile_tables(registry)
	var lookup := ChunkMesher.build_lookup_tables(registry)
	var solid: PackedByteArray = lookup["solid"]
	var occl: PackedByteArray = lookup["occludes"]

	var result: Variant
	if greedy:
		result = _native.BuildGreedy(
			chunk.chunk_coord, chunk.dimensions.x,
			chunk.block_ids, neighbor_ids, neighbor_exists,
			solid, occl,
			tables["top"], tables["side"], tables["bottom"],
			chunk.sparse_block_states,
			TextureAtlasLoader.COLS, TextureAtlasLoader.ROWS,
			VoxelTypes.BRANCH_ID)
	else:
		result = _native.BuildNaive(
			chunk.chunk_coord, chunk.dimensions.x,
			chunk.block_ids, neighbor_ids, neighbor_exists,
			solid, occl,
			tables["top"], tables["side"], tables["bottom"],
			chunk.sparse_block_states,
			TextureAtlasLoader.COLS, TextureAtlasLoader.ROWS,
			VoxelTypes.BRANCH_ID, VoxelTypes.LEAVES_ID)
	if result == null:
		return {}
	return result


## C# 水通道（water_* 8 数组；与 GDScript append_water_faces 等价，
## 等价测试水世界用例保证）。levels_world 打包为扁平数组避开 C# 侧
## Variant Dictionary 查询。返回空字典 = 原生不可用。
static func build_water(chunk: ChunkData, neighbors: Array) -> Dictionary:
	if not available():
		return {}
	var levels := ChunkMesher.collect_water_levels_world(chunk, neighbors)
	var lx := PackedInt32Array()
	var ly := PackedInt32Array()
	var lz := PackedInt32Array()
	var lv := PackedInt32Array()
	lx.resize(levels.size())
	ly.resize(levels.size())
	lz.resize(levels.size())
	lv.resize(levels.size())
	var i := 0
	for k: Vector3i in levels:
		lx[i] = k.x
		ly[i] = k.y
		lz[i] = k.z
		lv[i] = levels[k]
		i += 1
	var packed := _pack_neighbors(chunk, neighbors)
	var wc := chunk.chunk_coord
	var wd := chunk.dimensions
	var result: Variant = _native.BuildWater(
			wc, wd.x,
			chunk.block_ids, packed["ids"], packed["exists"],
			lx, ly, lz, lv,
			wc.x * wd.x, wc.y * wd.y, wc.z * wd.z)
	if result == null:
		return {}
	return result
