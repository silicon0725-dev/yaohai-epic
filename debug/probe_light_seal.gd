## 封盖减光追踪：5x5x7 坑逐格封盖，打印中心格天光演变定位回灌点。
## headless：godot --headless --path . -s debug/probe_light_seal.gd
extends SceneTree

const CHUNK := 16


func _init() -> void:
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	var world := VoxelWorld.new(config, registry)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(CHUNK, CHUNK, CHUNK), 1)
	for x in CHUNK:
		for z in CHUNK:
			chunk.set_block_raw(Vector3i(x, 0, z), VoxelTypes.STONE_ID)
	world.add_chunk(chunk)
	var light: Node = load("res://systems/lighting/voxel_light.gd").new()
	light.setup(world)
	light.init_chunk_light(chunk, [null, null, null, null, null, null])
	light.on_chunk_ready(chunk)
	# 挖 5x5x7（x/z 6..10，y 1..7）
	for dx in 5:
		for dz in 5:
			for dy in 7:
				world.set_block(Vector3i(6 + dx, 1 + dy, 6 + dz), VoxelTypes.AIR_ID)
	print("敞坑 center=", _sky(world, 8, 4, 8), " corner=", _sky(world, 6, 2, 6))
	# 逐格封盖 y=8
	for dx in 5:
		for dz in 5:
			world.set_block(Vector3i(6 + dx, 8, 6 + dz), VoxelTypes.STONE_ID)
			print("盖 (%d,8,%d) center=%d corner=%d wall(7,5,8)=%d" % [
					6 + dx, 6 + dz, _sky(world, 8, 4, 8), _sky(world, 6, 2, 6),
					_sky(world, 7, 5, 8)])
	# 手动触发兜底重算看结果（C# 与 GD 分别跑，区分实现错/语义错）
	var ok: bool = light._init_chunk_light_native(
			chunk, [null, null, null, null, null, null])
	print("native recompute ok=", ok, " center=", _sky(world, 8, 4, 8),
			" corner=", _sky(world, 6, 2, 6))
	light._init_chunk_light_gd(chunk, [null, null, null, null, null, null])
	print("gd recompute center=", _sky(world, 8, 4, 8),
			" corner=", _sky(world, 6, 2, 6))
	quit(0)


func _sky(world: VoxelWorld, x: int, y: int, z: int) -> int:
	var c: ChunkData = world.get_chunk(
			VoxelCoords.world_to_chunk(Vector3i(x, y, z), CHUNK))
	return c.get_sky_light(VoxelCoords.world_to_local(Vector3i(x, y, z), CHUNK))
