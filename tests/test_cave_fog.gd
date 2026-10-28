## 洞口体积雾检测单元测试：天窗/隧道口识别、封闭洞不识别、
## 露天不识别、单柱噪声抑制。
extends VoxelTestCase

const CHUNK := 16
const CaveFogScript := preload("res://systems/lighting/cave_fog.gd")
const NEIGHBOR_DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _make_world() -> VoxelWorld:
	# 基础地形：y 0..9 实心石，y 10..15 空气（索引布局 x+16y+256z）
	return make_world(CHUNK, [Vector3i.ZERO], 7, func(chunk: ChunkData) -> void:
		for i in chunk.volume():
			var y := (i / CHUNK) % CHUNK
			chunk.block_ids[i] = VoxelTypes.STONE_ID if y <= 9 else VoxelTypes.AIR_ID)


func _light_world(world: VoxelWorld) -> void:
	const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
	var light: Node = VoxelLightScript.new()
	light.setup(world)
	var chunk: ChunkData = world.get_chunk(Vector3i.ZERO)
	var nbs := []
	for d in NEIGHBOR_DIRS:
		nbs.append(world.get_chunk(Vector3i.ZERO + d))
	light.init_chunk_light(chunk, nbs)
	light.on_chunk_ready(chunk)


func _carve(world: VoxelWorld, from: Vector3i, to: Vector3i) -> void:
	for x in range(mini(from.x, to.x), maxi(from.x, to.x) + 1):
		for y in range(mini(from.y, to.y), maxi(from.y, to.y) + 1):
			for z in range(mini(from.z, to.z), maxi(from.z, to.z) + 1):
				world.set_block(Vector3i(x, y, z), VoxelTypes.AIR_ID)


func run() -> void:
	_test_tunnel_mouth_detected()
	_test_sealed_cave_not_detected()
	_test_open_plain_not_detected()
	_test_single_column_suppressed()


## 露天坑 + 平隧道：隧道口列（有天光 + 有顶盖）聚成簇
func _test_tunnel_mouth_detected() -> void:
	var world := _make_world()
	_carve(world, Vector3i(6, 7, 6), Vector3i(8, 9, 8))   # 露天竖坑
	_carve(world, Vector3i(9, 7, 5), Vector3i(13, 8, 9))  # 有顶平隧道（5 宽）
	_light_world(world)
	var clusters: Array = CaveFogScript.scan_for_mouths(
			world, Vector3i(11, 8, 7))
	check(clusters.size() >= 1, "隧道口应聚出至少一个簇，实际 %d" % clusters.size())
	if clusters.is_empty():
		return
	var c: Dictionary = clusters[0]
	var center: Vector3 = c["center"]
	check(center.x > 5.0 and center.x < 14.0 and center.z > 5.0 and center.z < 10.0,
			"簇中心应在坑/隧道区，实际 %s" % center)
	var half: Vector3 = c["half"]
	check(half.x >= CaveFogScript.HALF_MIN and half.x <= CaveFogScript.HALF_MAX,
			"半轴 X 应在钳制区间，实际 %.1f" % half.x)


## 封闭洞室（无开口无天光）：不识别
func _test_sealed_cave_not_detected() -> void:
	var world := _make_world()
	_carve(world, Vector3i(4, 2, 4), Vector3i(9, 5, 9))  # 全埋洞室
	_light_world(world)
	var clusters: Array = CaveFogScript.scan_for_mouths(
			world, Vector3i(6, 4, 6))
	check(clusters.is_empty(), "封闭洞室不应识别（天光 0），实际 %d 簇" % clusters.size())


## 纯露天（无顶盖）：不识别
func _test_open_plain_not_detected() -> void:
	var world := _make_world()
	_carve(world, Vector3i(4, 8, 4), Vector3i(9, 9, 9))  # 露天浅坑（无顶）
	_light_world(world)
	var clusters: Array = CaveFogScript.scan_for_mouths(
			world, Vector3i(6, 9, 6))
	check(clusters.is_empty(), "露天无顶盖不应识别，实际 %d 簇" % clusters.size())


## 单柱开口（1x1 天窗）：低于 CLUSTER_MIN_COLUMNS 不出雾
func _test_single_column_suppressed() -> void:
	var world := _make_world()
	world.set_block(Vector3i(8, 9, 8), VoxelTypes.AIR_ID)  # 单格天窗
	_carve(world, Vector3i(7, 6, 7), Vector3i(9, 8, 9))    # 下方小洞室
	_light_world(world)
	var clusters: Array = CaveFogScript.scan_for_mouths(
			world, Vector3i(8, 7, 8))
	# 1x1 天窗 + 3x3 洞室：光柱列 1 列（步长 2 采样下 1 列），应被抑制
	check(clusters.is_empty(), "单柱天窗应被噪声抑制，实际 %d 簇" % clusters.size())
