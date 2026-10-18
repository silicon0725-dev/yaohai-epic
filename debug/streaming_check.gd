## 流式 + 存档集成检查（可 headless 运行，无需显示环境）：
##   godot-4 --headless --path . res://debug/streaming_check.tscn
## 验证阶段 C/D 的关键行为（开发文档 §4.4、§6.4、§9.3）：
##   1. 初始流式安定后区块数量受视距约束，玩家脚下区块 ACTIVE；
##   2. 修改方块后脏区块自动重建（网格不再脏）；
##   3. 持久化：修改落盘 -> 远走卸载（磁盘仍在）-> 返回从磁盘恢复；
##   4. 重启：销毁场景重新加载存档，玩家修改仍然存在（§9.3 场景 1）。
## 使用隔离存档目录，不触碰真实存档。退出码 0 = 全部通过。
extends Node

const TIMEOUT_FRAMES := 3000
const TELEPORT_OFFSET := Vector3(400.0, 0.0, 0.0)  # 列距 25 > 视距+缓冲
const ISOLATED_SAVE_ROOT := "user://tmp_streaming_check"

var failures: Array[String] = []
var world: VoxelWorld
var manager: ChunkManager
var player: CharacterBody3D
var edited_block := Vector3i.ZERO


func _ready() -> void:
	_cleanup_save()
	var main: Node = _spawn_main()

	if await _wait_idle("初始流式安定"):
		for i in 30:
			await get_tree().process_frame
		_check_initial()

	await _check_edit_rebuilt()
	await _test_unload_reload(main)
	await _test_restart(main)
	_cleanup_save()
	_report()


func _spawn_main() -> Node:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ISOLATED_SAVE_ROOT  # 隔离存档目录
	add_child(main)
	world = main.world
	manager = main.chunk_manager
	player = main.player
	return main


func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _wait_idle(label: String) -> bool:
	# 至少等 30 帧再判定安定，避免流式尚未启动时误判
	var waited := 0
	while waited < TIMEOUT_FRAMES:
		await get_tree().process_frame
		waited += 1
		if waited >= 30 and manager.is_idle():
			return true
	var stuck: Array[String] = []
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.mesh_dirty or chunk.collision_dirty:
			if stuck.size() < 8:
				stuck.append("%s(state=%d dirty=%d/%d)" % [
					str(coord), chunk.state, int(chunk.mesh_dirty),
					int(chunk.collision_dirty)])
	failures.append("%s：%d 帧内未安定（in_flight=%d）卡脏区块: %s" % [
		label, TIMEOUT_FRAMES, manager.in_flight_count(),
		"; ".join(PackedStringArray(stuck)) if stuck.size() > 0 else "无"])
	return false


func _check_initial() -> void:
	# 视距 5：圆内约 81 列 x 3 = 243 区块
	check(world.chunk_count() > 150,
		"初始区块加载数量合理: %d" % world.chunk_count())
	check(world.chunk_count() < 320,
		"初始区块数量受视距约束: %d" % world.chunk_count())
	var standing_coord := VoxelCoords.world_to_chunk(
			player.global_position, world.config.chunk_size)
	var standing: ChunkData = world.get_chunk(standing_coord)
	check(standing != null and standing.state == ChunkState.State.ACTIVE,
		"玩家脚下区块 ACTIVE（物理未冻结）")
	check(player.is_on_floor(), "玩家站在地面上")


func _check_edit_rebuilt() -> void:
	# 在玩家头顶放置方块（必为空气格），等待脏重建安定
	var head := player.global_position + Vector3(0.0, 4.0, 0.0)
	edited_block = Vector3i(floori(head.x), floori(head.y), floori(head.z))
	check(world.set_block(edited_block, VoxelTypes.STONE_ID), "放置方块成功")
	await _wait_idle("编辑后重建安定")
	check(world.get_block(edited_block) == VoxelTypes.STONE_ID, "编辑生效")
	var chunk: ChunkData = world.get_chunk(
			VoxelCoords.world_to_chunk(edited_block, world.config.chunk_size))
	check(chunk != null and not chunk.mesh_dirty, "所在区块网格已重建")


func _test_unload_reload(main: Node) -> void:
	# 主动落盘（不等自动保存），验证文件存在
	main.chunk_manager.save_all(main.player.get_save_state())
	var save_system: WorldSave = main.save_system
	var edit_coord := VoxelCoords.world_to_chunk(
			edited_block, world.config.chunk_size)
	check(save_system.has_chunk(edit_coord), "修改区块已落盘")

	# 远走：编辑区块卸载，磁盘文件保留
	var spawn := player.global_position
	player.global_position = spawn + TELEPORT_OFFSET
	await _wait_idle("远走安定")
	check(world.get_chunk(edit_coord) == null, "编辑区块已卸载")
	check(save_system.has_chunk(edit_coord), "卸载后磁盘文件保留")
	check(manager.dormant_count() == 0, "写盘成功不占用内存兜底")

	# 返回：从磁盘恢复玩家修改（§9.3 场景 2）
	player.global_position = spawn
	await _wait_idle("返回安定")
	check(world.get_block(edited_block) == VoxelTypes.STONE_ID,
		"返回后从磁盘恢复玩家修改")

	# 回到出生点再存一份（重启用）
	main.chunk_manager.save_all(main.player.get_save_state())


func _test_restart(main: Node) -> void:
	# 销毁场景 = 进程内模拟退出；重新实例化 = 重新启动读档（§9.3 场景 1）
	main.queue_free()
	for i in 10:
		await get_tree().process_frame
	check(not is_instance_valid(main), "旧场景已销毁")

	var restarted := _spawn_main()
	await _wait_idle("重启后流式安定")
	for i in 30:
		await get_tree().process_frame
	check(world.get_block(edited_block) == VoxelTypes.STONE_ID,
		"重启后玩家修改仍然存在（存档持久化）")
	check(player.is_on_floor(), "重启后玩家站在存档位置的地面上")
	var save_system: WorldSave = restarted.save_system
	check(save_system.has_chunk(VoxelCoords.world_to_chunk(
			edited_block, world.config.chunk_size)), "重启后存档文件仍在")
	# 不在此释放重启场景：_report 还要读取它的状态；
	# 进程退出时 _exit_tree 会自动做退出保存


func _cleanup_save() -> void:
	WorldSave.new(ISOLATED_SAVE_ROOT,
			VoxelTypes.build_default_registry()).erase_all()


func _report() -> void:
	for failure in failures:
		print("FAIL: ", failure)
	print("结果: chunks=%d saved=%d in_flight=%d" % [
		world.chunk_count(),
		manager.save_system.saved_chunk_count() if manager.save_system != null else 0,
		manager.in_flight_count()])
	print("STREAMING CHECK: %s" % ("PASS" if failures.is_empty() else "FAIL"))
	get_tree().quit(0 if failures.is_empty() else 1)
