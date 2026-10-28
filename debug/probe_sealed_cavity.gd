## 真封闭腔判定：16^3 全实心石头 chunk 内挖 3x3x3 腔（四周全是石头，
## 无任何露天通道）——腔内天光必须为 0。再测顶部开 1x1 口的对照腔
## （渗入值应 = 15 - 到口的最短步数）。C# 与 GD 两条路都测。
## headless：godot --headless --path . -s debug/probe_sealed_cavity.gd
extends SceneTree

const CHUNK := 16


func _init() -> void:
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	var world := VoxelWorld.new(config, registry)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(CHUNK, CHUNK, CHUNK), 1)
	# 全实心石头（注意：y=0 那层换成基岩以防越界歧义）
	for x in CHUNK:
		for y in CHUNK:
			for z in CHUNK:
				chunk.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	world.add_chunk(chunk)
	var light: Node = load("res://systems/lighting/voxel_light.gd").new()
	light.setup(world)

	# 场景 A：封闭腔 x/z/y 6..8（离 chunk 边界 6 格，四周全石头）
	for dx in 3:
		for dz in 3:
			for dy in 3:
				world.set_block(Vector3i(6 + dx, 6 + dy, 6 + dz), VoxelTypes.AIR_ID)
	# 场景 B：对照腔 x/z 11..13 y 6..8，顶部 y=9 开 1x1 口（x=12,z=12）
	for dx in 3:
		for dz in 3:
			for dy in 3:
				world.set_block(Vector3i(11 + dx, 6 + dy, 11 + dz), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(12, 9, 12), VoxelTypes.AIR_ID)

	var ok_native: bool = light._init_chunk_light_native(
			chunk, [null, null, null, null, null, null])
	print("=== C# init ok=", ok_native, " ===")
	_report(world)
	light._init_chunk_light_gd(chunk, [null, null, null, null, null, null])
	print("=== GD init ===")
	_report(world)

	# 增量路径也测：在封腔前的世界里先 init，再挖腔（挖=减光+回灌）
	var world2 := VoxelWorld.new(config, registry)
	var chunk2 := ChunkData.new(Vector3i.ZERO, Vector3i(CHUNK, CHUNK, CHUNK), 1)
	for x in CHUNK:
		for y in CHUNK:
			for z in CHUNK:
				chunk2.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	world2.add_chunk(chunk2)
	light.setup(world2)
	light.init_chunk_light(chunk2, [null, null, null, null, null, null])
	for dx in 3:
		for dz in 3:
			for dy in 3:
				world2.set_block(Vector3i(6 + dx, 6 + dy, 6 + dz), VoxelTypes.AIR_ID)
	print("=== 增量挖掘路径（set_block 触发减光/回灌）===")
	for dy in 3:
		var row := ""
		for dz in 3:
			for dx in 3:
				row += "%2d " % _sky(world2, 6 + dx, 6 + dy, 6 + dz)
			row += "| "
		print("  y=%d  %s" % [6 + dy, row])
	quit(0)


func _report(world: VoxelWorld) -> void:
	print("  封闭腔 sky（应全 0）:")
	for dy in 3:
		var row := ""
		for dz in 3:
			for dx in 3:
				row += "%2d " % _sky(world, 6 + dx, 6 + dy, 6 + dz)
			row += "| "
		print("  y=%d  %s" % [6 + dy, row])
	print("  对照腔 sky（顶部开口 1x1，口在 y=9 x/z=12；随距离衰减）:")
	for dy in 3:
		var row := ""
		for dz in 3:
			for dx in 3:
				row += "%2d " % _sky(world, 11 + dx, 6 + dy, 11 + dz)
			row += "| "
		print("  y=%d  %s" % [6 + dy, row])


func _sky(world: VoxelWorld, x: int, y: int, z: int) -> int:
	var c: ChunkData = world.get_chunk(
			VoxelCoords.world_to_chunk(Vector3i(x, y, z), CHUNK))
	return c.get_sky_light(VoxelCoords.world_to_local(Vector3i(x, y, z), CHUNK))
