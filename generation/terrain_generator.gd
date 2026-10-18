## 固定种子的确定性地形生成器（开发文档 §5）。
## v2（阶段 E 扩充）：低地为沙地（沙 + 砂岩地层），石层内生成
## 煤/铁矿脉。调整任何参数都必须递增版本——未修改区域会用新
## 算法重建，已保存的完整区块数据不受影响（§5.1、§9）。
## 生物群系接口（§5.3）在内核稳定后接入，先保持生成逻辑独立成层。
class_name TerrainGenerator
extends RefCounted

## 生成算法版本。
const GENERATOR_VERSION := 2

## 地层参数：表层 1 格，其下 3 格为泥土（草区）或砂岩（沙区），
## 其余为石头（可能含矿），y=0 为基岩。
const DIRT_LAYER_DEPTH := 3
const SANDSTONE_LAYER_DEPTH := 3
## 地表高度不超过此值时为沙地（滩涂/干涸湖床）。
const SAND_MAX_HEIGHT := 8
## 矿脉噪声阈值（单倍频单纯形 -1..1，越高越稀疏）。
const COAL_ORE_THRESHOLD := 0.60
const IRON_ORE_THRESHOLD := 0.68
## 铁矿最深出现高度（比煤更稀有且更深）。
const IRON_ORE_MAX_Y := 24
## 矿石不生成的地表保护层厚度（表层往下几格仍是石头的区域除外）。
const ORE_SURFACE_MARGIN := 4

const BASE_HEIGHT := 14.0
const CONTINENTAL_AMPLITUDE := 12.0
const DETAIL_AMPLITUDE := 4.0

var config: WorldConfig
var _continental_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _coal_noise: FastNoiseLite
var _iron_noise: FastNoiseLite


func _init(world_config: WorldConfig) -> void:
	config = world_config
	_continental_noise = _make_noise(world_config.world_seed, 0.004, 3)
	_detail_noise = _make_noise(world_config.world_seed + 101, 0.02, 3)
	_coal_noise = _make_noise(world_config.world_seed + 202, 0.08, 1)
	_iron_noise = _make_noise(world_config.world_seed + 303, 0.09, 1)


static func _make_noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	return noise


## 某一世界列（x, z）的地表高度。独立暴露便于测试与未来生物群系接入。
func column_height(world_x: int, world_z: int) -> int:
	var continental := _continental_noise.get_noise_2d(world_x, world_z)
	var detail := _detail_noise.get_noise_2d(world_x, world_z)
	var height := BASE_HEIGHT + continental * CONTINENTAL_AMPLITUDE + detail * DETAIL_AMPLITUDE
	var max_height := config.chunks_y * config.chunk_size - 2
	return clampi(int(round(height)), 1, max_height)


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
	for lz in size:
		for lx in size:
			var height := column_height(origin.x + lx, origin.z + lz)
			for ly in size:
				chunk.set_block_raw(
						Vector3i(lx, ly, lz),
						block_for_column(
								origin.x + lx, origin.y + ly, origin.z + lz, height)
				)
	chunk.state = ChunkState.State.DATA_READY
	return chunk


## 某一世界位置的地层方块（纯函数，供生成与测试使用）。
## 分层自上而下：空气 -> 表层（草/沙）-> 泥土/砂岩 -> 石头（含矿）-> 基岩。
## 注意顺序：高于地表必须是空气（曾漏掉该分支导致世界变实心方块）。
func block_for_column(
		world_x: int, world_y: int, world_z: int, height: int
) -> int:
	if world_y > height:
		return VoxelTypes.AIR_ID
	if world_y == height:
		return VoxelTypes.SAND_ID if height <= SAND_MAX_HEIGHT \
				else VoxelTypes.GRASS_ID
	if world_y == 0:
		return VoxelTypes.BEDROCK_ID
	var sandy := height <= SAND_MAX_HEIGHT
	var layer_depth := SANDSTONE_LAYER_DEPTH if sandy else DIRT_LAYER_DEPTH
	if world_y > height - 1 - layer_depth:
		return VoxelTypes.SANDSTONE_ID if sandy else VoxelTypes.DIRT_ID
	var ore := ore_at(world_x, world_y, world_z, height)
	if ore != VoxelTypes.AIR_ID:
		return ore
	return VoxelTypes.STONE_ID


## 石层内的矿脉判定：返回矿物 ID 或空气（= 无矿）。
func ore_at(world_x: int, world_y: int, world_z: int, height: int) -> int:
	if world_y <= 1 or world_y > height - ORE_SURFACE_MARGIN:
		return VoxelTypes.AIR_ID
	if _coal_noise.get_noise_3d(world_x, world_y, world_z) > COAL_ORE_THRESHOLD:
		return VoxelTypes.COAL_ORE_ID
	if world_y <= IRON_ORE_MAX_Y \
			and _iron_noise.get_noise_3d(world_x, world_y, world_z) > IRON_ORE_THRESHOLD:
		return VoxelTypes.IRON_ORE_ID
	return VoxelTypes.AIR_ID
