## 快速放置探针：加载世界 → 找开阔地表 → 每 2 帧放一块（模拟用户
## 快速放方块），perf 埋点输出各环节耗时。输出后退出。
extends Node

const ROOT := "user://tmp_probe_fast_place"


func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 1200:
		await get_tree().process_frame
		waited += 1
		if waited >= 60 and main.chunk_manager.is_idle():
			break
	print("world ready")

	# 找玩家脚下的开阔地表（玩家出生点附近，从上往下扫第一个实体格）
	var pp: Vector3 = main.player.global_position
	var bx := int(floor(pp.x)) + 2
	var bz := int(floor(pp.z)) + 2
	var ground_y := 0
	for y in range(int(pp.y) + 24, 1, -1):
		var id: int = main.world.get_block(Vector3i(bx, y, bz))
		if id != VoxelTypes.AIR_ID and id != VoxelTypes.WATER_ID:
			ground_y = y
			break
	print("ground at y=", ground_y, " player y=", pp.y)

	# 快速放置：每 2 帧一块，沿 +x 排开（都压在露天地表=天光柱移除
	# 最贵场景）；再快速全拆（挖掘重扩散）
	var t0 := Time.get_ticks_usec()
	var fmax := 0.0
	var fsum := 0.0
	var fn := 0
	for i in 30:
		var fs := Time.get_ticks_usec()
		main.world.set_block(Vector3i(bx + i, ground_y + 1, bz), 3)
		await get_tree().process_frame
		await get_tree().process_frame
		var fd := (Time.get_ticks_usec() - fs) * 0.001
		fmax = maxf(fmax, fd)
		fsum += fd
		fn += 1
	print("place frames: n=%d avg=%.1fms max=%.1fms" % [fn, fsum / fn, fmax])
	var t1 := Time.get_ticks_usec()
	print("placed 30 in %.0fms" % [(t1 - t0) * 0.001])
	for i in 30:
		main.world.set_block(Vector3i(bx + i, ground_y + 1, bz),
				VoxelTypes.AIR_ID)
		await get_tree().process_frame
		await get_tree().process_frame
	var t2 := Time.get_ticks_usec()
	print("broke 30 in %.0fms" % [(t2 - t1) * 0.001])
	# 等管线排空
	for i in 240:
		await get_tree().process_frame
		if main.chunk_manager.is_idle():
			break
	print("drained")
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
