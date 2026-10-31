extends SceneTree
func _initialize():
	await process_frame
	var blocks := VoxelTypes.build_default_registry()
	var config := WorldConfig.new()
	config.chunks_y = 1
	config.chunk_size = 4
	var world := VoxelWorld.new(config, blocks)
	world.add_chunk(ChunkData.new(Vector3i.ZERO, Vector3i(4, 4, 4), 2))
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(2, 2, 2), VoxelTypes.WATER_ID)
	var far := AABB(Vector3(100, 100, 100), Vector3.ONE)
	var ok := BlockPlacement.place(world, Vector3i(2, 3, 2),
			VoxelTypes.TORCH_ID, far, Vector3i(1, 0, 0))
	print("place=", ok, " block=", world.get_block(Vector3i(2, 3, 2)))
	var st := world.get_block_state(Vector3i(2, 3, 2))
	print("state=", st)
	quit(0)
