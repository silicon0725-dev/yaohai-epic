## 隧道天光=15 异常追踪：手搭 chunk（y0..9 石头 + y10..15 露天），
## 按游戏同序挖竖井+隧道，逐步打印关键格 sky，定位 15 的注入点。
## headless：godot --headless --path . -s debug/probe_tunnel_light.gd
extends SceneTree

const CHUNK := 16
# 地形：y<=9 石头，y>=10 空气（地表第一实心格 = y9）
const SURFACE := 9
const SX := 8        # 竖井 x/z
const SHAFT_BOT := 2 # 竖井底 y
const TZ := 8        # 隧道 z（单宽即可复现）
var world: VoxelWorld
var light: Node


func _init() -> void:
	var registry := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.world_seed = 7
	world = VoxelWorld.new(config, registry)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(CHUNK, CHUNK, CHUNK), 1)
	for x in CHUNK:
		for z in CHUNK:
			for y in CHUNK:
				if y <= SURFACE:
					chunk.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	world.add_chunk(chunk)
	light = load("res://systems/lighting/voxel_light.gd").new()
	light.setup(world)
	light.init_chunk_light(chunk, [null, null, null, null, null, null])
	light.on_chunk_ready(chunk)
	_sky_dump("init 基线")

	# 竖井：y9..2 逐格（自上而下，同游戏挖掘路径）
	for y in range(SURFACE, SHAFT_BOT - 1, -1):
		world.set_block(Vector3i(SX, y, TZ), VoxelTypes.AIR_ID)
	print("竖井底 (%d,%d,%d) sky=%d" % [SX, SHAFT_BOT, TZ, _sky(SX, SHAFT_BOT, TZ)])

	# 隧道：x=9..14，y=SHAFT_BOT..+1 双层，自浅入深逐格（同游戏顺序）
	for dx in 6:
		for dy in 2:
			var x := SX + 1 + dx
			var y := SHAFT_BOT + dy
			world.set_block(Vector3i(x, y, TZ), VoxelTypes.AIR_ID)
			if dx >= 3 or dy == 1:
				print("挖 (%d,%d,%d) 后: 本格=%d 前一格(x-1,底)=%d 头顶(y+2)=%d" % [
						x, y, TZ, _sky(x, y, TZ), _sky(x - 1, SHAFT_BOT, TZ),
						_sky(x, y + 2, TZ)])
	_sky_dump("隧道完")
	quit(0)


func _sky_dump(tag: String) -> void:
	print("=== %s：隧道纵剖面 (z=%d) sky/块 ===" % [tag, TZ])
	var header := "      "
	for x in range(SX - 1, SX + 8):
		header += "%3d" % x
	print(header)
	for y in range(SURFACE + 2, SHAFT_BOT - 1, -1):
		var row := "y=%2d  " % y
		for x in range(SX - 1, SX + 8):
			var b: int = world.get_block(Vector3i(x, y, TZ))
			var s := _sky(x, y, TZ)
			row += ("%3d" % s) if b == VoxelTypes.AIR_ID else "  ·"
		print(row)


func _sky(x: int, y: int, z: int) -> int:
	var c: ChunkData = world.get_chunk(
			VoxelCoords.world_to_chunk(Vector3i(x, y, z), CHUNK))
	return c.get_sky_light(VoxelCoords.world_to_local(Vector3i(x, y, z), CHUNK))
