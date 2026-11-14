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
	"torch",
	"lantern",
	"grass_blade",
	"grass_tuft",
	"flower_poppy",
	"flower_dandelion",
	"grass_side_u0",
	"grass_side_u1",
	"grass_side_u01"
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


## 已缓存的 C# 实例（先 available() 探测；供光照等其他系统复用）。
static func native() -> RefCounted:
	return _native


## 主线程预热（main 接线期调用）：完成探测 + 预填当前注册表的
## tile 表——否则 mesh worker 首调并发写 _tile_cache/_checked
## （Godot Dictionary 非线程安全——审查发现）
static func prewarm(registry: VoxelRegistry) -> void:
	if not available():
		return
	_tile_tables(registry)


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
## 27 邻域外壳打包（审查二轮 A2）：面剔除真正读到的只有各邻块朝
## 本块的外壳格——6 面 ×s² + 12 棱 ×s + 8 角（s=16 时 1736 格，
## 1/63）——曾整块 append_array 27×4096×4B=442KB/任务 + C#
## AsInt32Array 再拷一份进 LOH（流式期 20-90MB/s 托管垃圾主源）。
## 段布局：按 slot 0..26 顺序，段长=自由轴（offset 分量为 0 的轴）
## 组合数；slot 13（本块自身）永不被边界读、段长 0。C# ReadNb 按
## 同构规则索引（自由轴 x<y<z、stride 递增——等价红线）
static func _pack_neighbors(chunk: ChunkData, neighbors: Array) -> Dictionary:
	var s := chunk.dimensions.x
	var shell := PackedInt32Array()
	shell.resize(6 * s * s + 12 * s + 8)
	var neighbor_exists := PackedByteArray()
	neighbor_exists.resize(27)
	var w := 0
	for slot in 27:
		var dx: int = slot % 3 - 1
		var dy: int = (slot / 3) % 3 - 1
		var dz: int = slot / 9 - 1
		if dx == 0 and dy == 0 and dz == 0:
			continue  # slot 13 = 本块：边界读永不落到它
		var nb: ChunkData = neighbors[slot]
		var seg := _shell_seg_len(dx, dy, dz, s)
		if nb == null:
			w += seg  # 段留零（exists=0 时 C# 不读该 slot）
			continue
		neighbor_exists[slot] = 1
		var ids := nb.block_ids
		# 非零轴固定：正方向取邻块 0 层、负方向取 s-1 层
		var fa := s if dx == 0 else 1
		var fb := s if dy == 0 else 1
		var fc := s if dz == 0 else 1
		for a in fa:
			for b in fb:
				for c in fc:
					var la := a if dx == 0 else (0 if dx > 0 else s - 1)
					var lb := b if dy == 0 else (0 if dy > 0 else s - 1)
					var lc := c if dz == 0 else (0 if dz > 0 else s - 1)
					shell[w] = ids[la + s * lb + s * s * lc]
					w += 1
	return {
		"ids": shell,
		"exists": neighbor_exists,
		"volume": 6 * s * s + 12 * s + 8,
	}


static func _shell_seg_len(dx: int, dy: int, dz: int, s: int) -> int:
	var free_axes := 0
	if dx == 0:
		free_axes += 1
	if dy == 0:
		free_axes += 1
	if dz == 0:
		free_axes += 1
	if free_axes == 2:
		return s * s
	if free_axes == 1:
		return s
	return 1


## 拼装并调用 C# 原生网格器。返回空字典 = 原生不可用或失败。
## 本层保持中立；是否走原生由各网格器门面按基准结论决定：
## A/B（192 区块，本机 2 核，桥批拷后）：面剔除 4.6 vs 20.6ms、
## 贪心 6.0 vs 24.0ms（C# 4-4.5×，含桥接成本）。
## 等价测试仍直调本层覆盖两条 C# 路径。
static func build(
		greedy: bool,
		registry: VoxelRegistry,
		chunk: ChunkData,
		neighbors: Array,
		water_levels: Variant = null,
		grass_detail: int = 2,
		states_snap: Variant = null
) -> Dictionary:
	# water_levels 占位（水走 build_water 专用通道，调用方签名对齐用）；
	# grass_detail：草叶距离分级（性能 B9——近 2/中 1/远 0）；
	# states_snap：worker 的 states 深拷贝（P1-5 并发修复），null=本体
	if not available():
		return {}
	var packed := _pack_neighbors(chunk, neighbors)
	var neighbor_ids: PackedInt32Array = packed["ids"]
	var neighbor_exists: PackedByteArray = packed["exists"]

	var tables := _tile_tables(registry)
	var lookup := ChunkMesher.build_lookup_tables(registry)
	var solid: PackedByteArray = lookup["solid"]
	var occl: PackedByteArray = lookup["occludes"]
	var render_kind: PackedByteArray = lookup["render_kind"]
	# 光照填充缓存（C# 顶点色采样；GD 侧 build_light_padded 是唯一真值，
	# 双语言共享同一份输入避免两套 padded 组装逻辑漂移）
	var light_padded := ChunkMesher.build_light_padded(chunk, neighbors)

	var states_v: Variant = states_snap if states_snap is Dictionary 			else chunk.sparse_block_states
	var result: Variant
	if greedy:
		result = _native.BuildGreedy(
			chunk.chunk_coord, chunk.dimensions.x,
			chunk.block_ids, neighbor_ids, neighbor_exists,
			solid, occl,
			tables["top"], tables["side"], tables["bottom"],
			states_v,
			TextureAtlasLoader.COLS, TextureAtlasLoader.ROWS,
			render_kind,
			light_padded, grass_detail)
	else:
		result = _native.BuildNaive(
			chunk.chunk_coord, chunk.dimensions.x,
			chunk.block_ids, neighbor_ids, neighbor_exists,
			solid, occl,
			tables["top"], tables["side"], tables["bottom"],
			states_v,
			TextureAtlasLoader.COLS, TextureAtlasLoader.ROWS,
			render_kind,
			light_padded, grass_detail)
	if result == null:
		return {}
	return result


## C# 水通道（water_* 8 数组；与 GDScript append_water_faces 等价，
## 等价测试水世界用例保证）。levels_world 打包为扁平数组避开 C# 侧
## Variant Dictionary 查询。返回空字典 = 原生不可用。
static func build_water(
		chunk: ChunkData, neighbors: Array, water_levels: Variant = null
) -> Dictionary:
	if not available():
		return {}
	var levels: Dictionary = water_levels if water_levels != null 			else ChunkMesher.collect_water_levels_world(chunk, neighbors)
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
