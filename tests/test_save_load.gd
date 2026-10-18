## 存档单元测试（开发文档 §9.3 必测场景）：
## 序列化往返（含负坐标）、未知方块回退、文件级读写、
## 原子写无残留、损坏文件与缺失文件处理、版本兼容判定。
extends VoxelTestCase

const TMP_ROOT := "user://tmp_save_test"


func _make_chunk(coord: Vector3i) -> ChunkData:
	var chunk := ChunkData.new(coord, Vector3i(4, 4, 4), 7)
	chunk.set_block(Vector3i(1, 2, 3), VoxelTypes.STONE_ID)
	chunk.set_block(Vector3i(3, 0, 0), VoxelTypes.GRASS_ID)
	chunk.set_block(Vector3i(0, 3, 1), VoxelTypes.DIRT_ID)
	# 阶段 E 扩充方块也应正常往返
	chunk.set_block(Vector3i(2, 1, 0), VoxelTypes.LOG_ID)
	chunk.set_block(Vector3i(1, 1, 1), VoxelTypes.SAND_ID)
	chunk.set_block(Vector3i(0, 0, 2), VoxelTypes.IRON_ORE_ID)
	return chunk


func run() -> void:
	var registry := VoxelTypes.build_default_registry()

	# ---- 序列化往返（含正/负坐标，§9.3 场景 3）----
	for coord in [Vector3i(3, -2, 5), Vector3i(-17, 0, -33), Vector3i.ZERO]:
		var chunk := _make_chunk(coord)
		var payload := ChunkSerializer.serialize(registry, chunk)
		var back := ChunkSerializer.deserialize(registry, payload, coord)
		check(back != null, "序列化往返成功 %s" % str(coord))
		if back != null:
			check(back.block_ids == chunk.block_ids, "方块数据一致 %s" % str(coord))
			check_eq(back.generation_version, 7, "生成版本保留")
			check_eq(back.chunk_coord, coord, "坐标保留")

	# 未修改区块（全空气）往返
	var empty_chunk := ChunkData.new(Vector3i(-5, 1, -9), Vector3i(4, 4, 4), 1)
	var empty_back := ChunkSerializer.deserialize(registry,
			ChunkSerializer.serialize(registry, empty_chunk),
			empty_chunk.chunk_coord)
	check(empty_back != null and empty_back.block_ids == empty_chunk.block_ids,
		"全空气区块往返一致")

	# 损坏数据 -> null（§9.3 场景 5）
	check(ChunkSerializer.deserialize(
			registry, PackedByteArray(), Vector3i.ZERO) == null,
		"空数据返回 null")
	var garbage := PackedByteArray()
	garbage.resize(64)
	garbage.fill(0xFF)
	check(ChunkSerializer.deserialize(registry, garbage, Vector3i.ZERO) == null,
		"垃圾数据返回 null")

	# ---- 未知方块名 -> 回退石头（§9.3 场景 4：旧版方块 ID）----
	var custom_registry := VoxelTypes.build_default_registry()
	custom_registry.register_block({
		"id": "test:ghost",
		"render_type": "opaque",
		"textures": {"top": "stone", "side": "stone", "bottom": "stone"},
		"collision": true,
		"occludes_neighbors": true,
	})
	var ghost_chunk := ChunkData.new(Vector3i(9, 0, 9), Vector3i(4, 4, 4), 1)
	ghost_chunk.set_block(Vector3i(2, 2, 2),
			custom_registry.id_for_name("test:ghost"))
	var ghost_back := ChunkSerializer.deserialize(registry,
			ChunkSerializer.serialize(custom_registry, ghost_chunk),
			Vector3i(9, 0, 9))
	check(ghost_back != null, "含未知方块的数据可解析")
	if ghost_back != null:
		check_eq(ghost_back.get_block(Vector3i(2, 2, 2)),
			VoxelTypes.STONE_ID, "未知方块按回退策略替换为石头")

	# ---- WorldSave 文件级 ----
	_cleanup()
	var save := WorldSave.new(TMP_ROOT, registry)
	check(save.ensure_dirs(), "创建存档目录")
	check(not save.has_save(), "初始无元数据")
	check_eq(save.load_meta(), {}, "无元数据返回空字典")

	var config := WorldConfig.new()
	config.world_seed = 777
	var small_world := VoxelWorld.new(config, registry)
	check(save.save_meta(small_world,
			{"position": [1.5, 20.0, 2.5], "yaw": 0.5}),
		"保存元数据成功")
	var meta := save.load_meta()
	check_eq(int(meta.get("world_seed", -1)), 777, "元数据种子往返")
	check_eq(int(meta.get("generator_version", -1)),
		TerrainGenerator.GENERATOR_VERSION, "元数据记录生成版本")
	var loaded_state: Dictionary = meta.get("player_state", {})
	check(absf(float(loaded_state.get("yaw", 0.0)) - 0.5) < 0.0001,
		"玩家状态往返")

	# 区块落盘：负坐标文件 + 原子写无 tmp 残留（§9.2）
	var neg := _make_chunk(Vector3i(-3, 0, -2))
	check(save.save_chunk(neg), "保存负坐标区块成功")
	check(save.has_chunk(Vector3i(-3, 0, -2)), "负坐标区块文件存在")
	check(not FileAccess.file_exists(
			save.chunk_path(Vector3i(-3, 0, -2)) + ".tmp"),
		"原子写无 tmp 残留")
	var loaded_chunk := save.load_chunk(Vector3i(-3, 0, -2))
	check(loaded_chunk != null, "读取负坐标区块成功")
	if loaded_chunk != null:
		check(loaded_chunk.block_ids == neg.block_ids, "负坐标区块数据往返一致")
		check(loaded_chunk.data_modified, "读出区块标记为已修改")
		check(not loaded_chunk.save_needed, "读出区块无需回写")
	check(not neg.save_needed, "成功保存后清除 save_needed")
	check_eq(save.saved_chunk_count(), 1, "落盘区块计数")

	# 未修改区块保存为无操作
	var fresh := ChunkData.new(Vector3i(10, 0, 10), Vector3i(4, 4, 4), 1)
	check(save.save_chunk(fresh), "未修改区块保存为无操作")
	check(not save.has_chunk(Vector3i(10, 0, 10)), "未修改区块不落盘")

	# ---- 损坏与缺失（§9.3 场景 5）----
	var meta_file := FileAccess.open(save.meta_path(), FileAccess.WRITE)
	meta_file.store_string("{ 这不是合法 JSON !!!")
	meta_file.close()
	check_eq(save.load_meta(), {}, "损坏元数据返回空字典")

	var chunk_file := FileAccess.open(
			save.chunk_path(Vector3i(-3, 0, -2)), FileAccess.WRITE)
	chunk_file.store_64(0xdeadbeef)
	chunk_file.close()
	check(save.load_chunk(Vector3i(-3, 0, -2)) == null, "损坏区块文件返回 null")
	check(save.load_chunk(Vector3i(99, 0, 99)) == null, "缺失区块返回 null")

	# ---- 版本兼容判定（§9.3 场景 6）----
	check(SaveMigrations.is_format_compatible(1), "格式版本 1 兼容")
	check(not SaveMigrations.is_format_compatible(99), "未知格式版本不兼容")
	check(SaveMigrations.is_generator_current(
			{"generator_version": TerrainGenerator.GENERATOR_VERSION}),
		"生成版本一致判定")
	check(not SaveMigrations.is_generator_current(
			{"generator_version": 999}),
		"生成版本不一致判定")

	# ---- 删除存档 ----
	save.erase_all()
	check(not save.has_save(), "erase_all 后元数据消失")
	check(not FileAccess.file_exists(save.chunk_path(Vector3i(-3, 0, -2))),
		"erase_all 后区块文件消失")
	check_eq(save.saved_chunk_count(), 0, "erase_all 后计数归零")

	_cleanup()


func _cleanup() -> void:
	var base := DirAccess.open("user://")
	var relative := TMP_ROOT.trim_prefix("user://")
	if base != null and base.dir_exists(relative):
		WorldSave.new(TMP_ROOT, VoxelTypes.build_default_registry()).erase_all()
