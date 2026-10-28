## 体素光照单元测试（光照阶段 2）：列直射、横向衰减、洞穴变暗、
## 挖开涌入/堵回恢复（增减光 BFS）、放置减光、跨区块传播与边界
## 播出、激活顺序无关性、水/树叶衰减、重算幂等。
extends VoxelTestCase

const CHUNK := 16
const NEIGHBOR_DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## coords 内每块 16³ 全 AIR；filler(chunk) 填方块。
func _make_world(coords: Array, filler: Callable = Callable()) -> VoxelWorld:
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	var world := VoxelWorld.new(config, blocks)
	for coord in coords:
		var chunk := ChunkData.new(coord, Vector3i(CHUNK, CHUNK, CHUNK), 1)
		if filler.is_valid():
			filler.call(chunk)
		world.add_chunk(chunk)
	return world


func _make_light(world: VoxelWorld) -> Node:
	const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
	var light: Node = VoxelLightScript.new()
	light.setup(world)
	return light


## 模拟管线：init（邻块快照种子）+ on_chunk_ready（跨块播出）。
## 工厂版（基类 activate_light）内部自建光照节点，本套件已持 light
## 实例做增量测试——保留手演版
func _activate(world: VoxelWorld, light: Node, coord: Vector3i) -> void:
	var chunk: ChunkData = world.get_chunk(coord)
	var nbs := []
	for d in NEIGHBOR_DIRS:
		nbs.append(world.get_chunk(coord + d))
	light.init_chunk_light(chunk, nbs)
	light.on_chunk_ready(chunk)


func _sky(world: VoxelWorld, pos: Vector3i) -> int:
	var chunk: ChunkData = world.get_chunk(
			VoxelCoords.world_to_chunk(pos, CHUNK))
	return chunk.get_sky_light(VoxelCoords.world_to_local(pos, CHUNK))


func run() -> void:
	_test_column_skylight()
	_test_lateral_falloff()
	_test_cave_dark()
	_test_dig_open_floods()
	_test_seal_restores_dark()
	_test_place_shades()
	_test_cross_chunk_spread()
	_test_vertical_direct_feed_down()
	_test_activation_order_independent()
	_test_water_attenuates()
	_test_leaves_attenuate()
	_test_recompute_idempotent()
	_test_wide_pit_seal_restores()


## 平地上空天光 15 直到底面。
func _test_column_skylight() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 15, 8)), 15, "地表上方空气应为天光 15")
	check_eq(_sky(world, Vector3i(8, 1, 8)), 15, "地表上第 1 格天光 15")
	light.free()


## 狭长掩体走廊（z=7 通道，x 4..15，两侧墙 + 顶盖，x=3 端露天开口）：
## 开口 15，向内逐格 -1。
func _test_lateral_falloff() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
		for x in range(4, CHUNK):
			for y in range(1, 5):
				c.set_block_raw(Vector3i(x, y, 6), VoxelTypes.STONE_ID)
				c.set_block_raw(Vector3i(x, y, 8), VoxelTypes.STONE_ID)
			for z in range(6, 9):
				c.set_block_raw(Vector3i(x, 5, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(3, 2, 7)), 15, "开口外露天 15")
	check_eq(_sky(world, Vector3i(4, 2, 7)), 14, "开口第一格 14")
	check_eq(_sky(world, Vector3i(9, 2, 7)), 9, "第 6 格 9")
	check_eq(_sky(world, Vector3i(15, 2, 7)), 3, "走廊底 3")
	light.free()


## 实心盖正下方完全黑（无开口）。
func _test_cave_dark() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 8:
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 7, 8)), 0, "实心体内天光 0")
	check_eq(_sky(world, Vector3i(8, 8, 8)), 15, "表面上方空气 15")
	check_eq(_sky(world, Vector3i(15, 15, 15)), 15, "体外全亮")
	light.free()


## 全石体挖 L 形（竖井 2 格 + 水平 3 格）→ 光直射贯入并横向渗透。
func _test_dig_open_floods() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 8:
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 7, 8)), 0, "挖开前石体内全黑")
	world.set_block(Vector3i(8, 7, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(8, 6, 8), VoxelTypes.AIR_ID)
	check_eq(_sky(world, Vector3i(8, 7, 8)), 15, "竖井口直射 15")
	check_eq(_sky(world, Vector3i(8, 6, 8)), 15, "井底直射贯入 15")
	world.set_block(Vector3i(9, 6, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(10, 6, 8), VoxelTypes.AIR_ID)
	check_eq(_sky(world, Vector3i(9, 6, 8)), 14, "水平第 1 格 14")
	check_eq(_sky(world, Vector3i(10, 6, 8)), 13, "水平第 2 格 13")
	light.free()


## 竖井口堵回 → 垂直直射断供，全链减光恢复。
func _test_seal_restores_dark() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 8:
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	world.set_block(Vector3i(8, 7, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(8, 6, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(9, 6, 8), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(8, 7, 8), VoxelTypes.STONE_ID)
	check_eq(_sky(world, Vector3i(8, 6, 8)), 0, "井口堵后无侧光源，井底 0")
	check_eq(_sky(world, Vector3i(9, 6, 8)), 0, "水平段同步归 0")
	world.set_block(Vector3i(8, 6, 8), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(9, 6, 8), VoxelTypes.STONE_ID)
	check_eq(_sky(world, Vector3i(8, 6, 8)), 0, "全堵后恢复 0")
	check_eq(_sky(world, Vector3i(9, 6, 8)), 0, "水平段恢复 0")
	light.free()


## 空地上放置方块 → 遮挡下方垂直直射（增量减光）。
func _test_place_shades() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 5, 8)), 15, "放置前直射 15")
	world.set_block(Vector3i(8, 10, 8), VoxelTypes.STONE_ID)
	check_eq(_sky(world, Vector3i(8, 5, 8)), 14, "放置后下方 14（横向渗透）")
	check_eq(_sky(world, Vector3i(8, 9, 8)), 14, "紧贴下方 14")
	light.free()


## 两块相邻：B 块 y=7 走廊被封顶（y=8 盖板），A 块同层露天——
## B 走廊的光全部来自 A|B 边界横向渗透。
func _test_cross_chunk_spread() -> void:
	var filler := func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 7:
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
				if c.chunk_coord.x >= 1:
					c.set_block_raw(Vector3i(x, 8, z), VoxelTypes.STONE_ID)
	var world := _make_world([Vector3i.ZERO, Vector3i(1, 0, 0)], filler)
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	_activate(world, light, Vector3i(1, 0, 0))
	check_eq(_sky(world, Vector3i(15, 7, 8)), 15, "A 块走廊口直射 15")
	check_eq(_sky(world, Vector3i(16, 7, 8)), 14, "B 边界第一格 14")
	check_eq(_sky(world, Vector3i(20, 7, 8)), 10, "B 深处 10")
	check_eq(_sky(world, Vector3i(31, 7, 8)), 0, "B 最深处衰减殆尽 0")
	light.free()


## 上块有直射天光 → 下块顶面 15 直灌（跨块垂直直射特例）。
func _test_vertical_direct_feed_down() -> void:
	var filler := func(c: ChunkData) -> void:
		if c.chunk_coord.y == 1:
			return  # 上块全空：整块天光 15
		for x in CHUNK:
			for z in CHUNK:
				for y in 4:
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	var world := _make_world(
			[Vector3i(0, 0, 0), Vector3i(0, 1, 0)], filler)
	var light := _make_light(world)
	_activate(world, light, Vector3i(0, 1, 0))
	_activate(world, light, Vector3i(0, 0, 0))
	check_eq(_sky(world, Vector3i(8, 15, 8)), 15, "下块顶格 15（上块直灌）")
	check_eq(_sky(world, Vector3i(8, 4, 8)), 15, "表面上方空气 15（直列贯通）")
	check_eq(_sky(world, Vector3i(8, 3, 8)), 0, "实心格 0")
	light.free()


## 激活顺序无关：A→B 与 B→A 两种顺序光照结果一致。
func _test_activation_order_independent() -> void:
	var filler := func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 6:
					var wx := c.chunk_coord.x * CHUNK + x
					if wx % 3 != 0:
						c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	var world1 := _make_world([Vector3i.ZERO, Vector3i(1, 0, 0)], filler)
	var light1 := _make_light(world1)
	_activate(world1, light1, Vector3i.ZERO)
	_activate(world1, light1, Vector3i(1, 0, 0))
	var world2 := _make_world([Vector3i.ZERO, Vector3i(1, 0, 0)], filler)
	var light2 := _make_light(world2)
	_activate(world2, light2, Vector3i(1, 0, 0))
	_activate(world2, light2, Vector3i.ZERO)
	var same := true
	for x in 32:
		for z in 16:
			for y in 16:
				var p := Vector3i(x, y, z)
				if _sky(world1, p) != _sky(world2, p):
					same = false
					break
	check(same, "两种激活顺序天光逐格一致")
	light1.free()
	light2.free()


## 水域逐层衰减（opacity 2：15→13→11→9→7）。整层水（16×16）
## 避免"单格水柱被周围露天侧向渗透主导"——中心格由垂直列主导。
func _test_water_attenuates() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
				for y in range(10, 15):
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.WATER_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 14, 8)), 13, "水第 1 层 13")
	check_eq(_sky(world, Vector3i(8, 13, 8)), 11, "水第 2 层 11")
	check_eq(_sky(world, Vector3i(8, 11, 8)), 7, "水第 4 层 7")
	light.free()


## 整层树叶逐层 -1（opacity 1）。
func _test_leaves_attenuate() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
				for y in range(13, 15):
					c.set_block_raw(Vector3i(x, y, z), VoxelTypes.LEAVES_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	check_eq(_sky(world, Vector3i(8, 14, 8)), 14, "叶第 1 层 14")
	check_eq(_sky(world, Vector3i(8, 13, 8)), 13, "叶第 2 层 13")
	light.free()


## 重复 init 结果幂等（重算=恢复）。
func _test_recompute_idempotent() -> void:
	var filler := func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				for y in 6:
					if (x + z) % 2 == 0:
						c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	var world := _make_world([Vector3i.ZERO], filler)
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	var before := PackedByteArray((world.get_chunk(Vector3i.ZERO) as ChunkData).light)
	_activate(world, light, Vector3i.ZERO)
	var after := PackedByteArray((world.get_chunk(Vector3i.ZERO) as ChunkData).light)
	check_eq(before, after, "重复全量重算逐字节一致")
	light.free()


## 密闭大坑（5x5x7，四周围墙）逐格封盖后应整体回黑。
## 注意坑四周必须围实心墙：y=0 平台世界中坑外全是露天空气，
## 光从敞侧渗入是物理正确（= 15 - 到露天格的曼哈顿距离）——
## 早期版本没围墙，"残留 12/14"实为正确值导致的误报。
func _test_wide_pit_seal_restores() -> void:
	var world := _make_world([Vector3i.ZERO], func(c: ChunkData) -> void:
		for x in CHUNK:
			for z in CHUNK:
				c.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
		# 坑围墙（x/z = 5 或 11 一圈，y 1..9——坑 6..10 外一圈）
		for x in range(5, 12):
			for z in range(5, 12):
				if x == 5 or x == 11 or z == 5 or z == 11:
					for y in range(1, 10):
						c.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID))
	var light := _make_light(world)
	_activate(world, light, Vector3i.ZERO)
	# 墙内挖 5x5x7（x/z 6..10，y 1..7）
	for dx in 5:
		for dz in 5:
			for dy in 7:
				world.set_block(
						Vector3i(6 + dx, 1 + dy, 6 + dz), VoxelTypes.AIR_ID)
	check_eq(_sky(world, Vector3i(8, 4, 8)), 15, "敞坑中心直射 15")
	# 逐格封盖 y=8（与集成脚本同顺序）
	for dx in 5:
		for dz in 5:
			world.set_block(Vector3i(6 + dx, 8, 6 + dz), VoxelTypes.STONE_ID)
	var center := _sky(world, Vector3i(8, 4, 8))
	check(center <= 1, "封盖后密闭坑中心应全黑，实际 %d" % center)
	var corner := _sky(world, Vector3i(6, 2, 6))
	check(corner <= 2, "封盖后坑角落应近全黑，实际 %d" % corner)
	light.free()
