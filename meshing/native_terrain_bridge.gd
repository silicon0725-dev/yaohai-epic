## C# 原生地形生成桥接层（generate C# 化）。
## C# NativeTerrain 覆盖"列剖面 + 方块填充"主体；树重放留在
## GDScript（hash/RNG 序列与树形态算法的等价风险长尾），本桥
## 额外返回每列 height/sandy/rocky 剖面数组供树重放免重复算噪声。
## 块 ID 表从 VoxelTypes 常量打包传入（不硬编码——两轮迁移三次
## 猜错 ID，常量表必须单一来源）。
## 等价红线：GDScript float = 64 位 double，C# 侧全程 double 计算；
## round() 复刻 half-away-from-zero；噪声对象同参数构建（引擎同实现）。
## 实例化路径：新 .cs 的 CSharpScript 在未 --import 环境下 .new 报
## Nonexistent function（与 GDScript 新 class_name 缓存同款坑），
## 经已注册的 NativeMesher.CreateTerrain 工厂转发构造。
extends RefCounted

const VoxelTypesS := preload("res://core/voxel_types.gd")

static var _native_by_seed := {}  # world_seed -> NativeTerrain 实例
static var _checked := false
static var _factory = null  # NativeMesher 实例（已注册的 CSharpScript）


## 探测 C# 可用性（加载一次缓存；VOXEL_NO_NATIVE=1 强制禁用）。
static func available() -> bool:
	if _checked:
		return _factory != null
	_checked = true
	if OS.get_environment("VOXEL_NO_NATIVE") == "1":
		return false
	var script := load("res://native/NativeMesher.cs")
	if script == null:
		return false
	var factory = script.new()
	if factory == null:
		return false
	# 工厂可用性实探（构造一次探针实例）
	var probe = factory.CreateTerrain(0, 64, _block_id_table())
	_factory = factory if probe != null else null
	return _factory != null


static func _block_id_table() -> PackedInt32Array:
	return PackedInt32Array([
		VoxelTypesS.GRASS_ID, VoxelTypesS.DIRT_ID, VoxelTypesS.STONE_ID,
		VoxelTypesS.BEDROCK_ID, VoxelTypesS.SAND_ID,
		VoxelTypesS.SANDSTONE_ID, VoxelTypesS.COAL_ORE_ID,
		VoxelTypesS.IRON_ORE_ID, VoxelTypesS.WATER_ID,
	])


## 主线程预热（main 接线期调用）：完成可用性探测 + 建好当前种子的
## NativeTerrain——否则生成 worker 首调时并发写 _native_by_seed/
## _factory/_checked 静态字典（Godot Dictionary 非线程安全，启动
## 突发期多 worker 同刻首调可致哈希表损坏——审查发现）
static func prewarm(world_seed: int, world_height_blocks: int) -> void:
	if not available():
		return
	if not _native_by_seed.has(world_seed):
		_native_by_seed[world_seed] = _factory.CreateTerrain(
				world_seed, world_height_blocks, _block_id_table())


## 生成区块（C#）。返回 { ids, heights, sandy, rocky }；空字典 = 不可用。
## profiles 覆盖本区块 16×16 列；±TREE_REACH 界外列由调用方回退
## column_profile（每树 1-2 次，成本低）。
static func generate_chunk(
		world_seed: int, world_height_blocks: int,
		chunk_coord: Vector3i, chunk_size: int
) -> Dictionary:
	if not available():
		return {}
	if not _native_by_seed.has(world_seed):
		_native_by_seed[world_seed] = _factory.CreateTerrain(
				world_seed, world_height_blocks, _block_id_table())
	var native = _native_by_seed[world_seed]
	var result: Variant = native.GenerateChunk(chunk_coord, chunk_size)
	if result == null:
		return {}
	return result
