## 墙角 Q 丢弃专项复现：单件与堆叠物品扔向墙角，断言二者都停在
## 墙脚地面上（不上墙），并出截图。曾表现为堆叠物跳到上方一格。
extends Node

const ROOT := "user://tmp_capture_corner"

func _ready() -> void:
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	var waited := 0
	while waited < 900:
		await get_tree().process_frame
		waited += 1
		if waited >= 30 and main.chunk_manager.is_idle():
			break
	var player: PlayerController = main.player
	var dm: DropManager = main.drop_manager
	var items: ItemRegistry = player.item_registry
	var w: VoxelWorld = main.world
	# 玩家正前方 4 格处搭 L 形墙角（3 高）
	var fwd := -player.global_transform.basis.z
	var base_cell := Vector3i(
			floori(player.global_position.x + fwd.x * 4.0), 0,
			floori(player.global_position.z + fwd.z * 4.0))
	var ground_y := 0
	for y in range(40, -1, -1):
		if w.registry.is_solid(w.get_block(Vector3i(base_cell.x, y, base_cell.z))):
			ground_y = y
			break
	for dy in 3:
		for d in 3:
			w.set_block(base_cell + Vector3i(-d, ground_y + 1 + dy, 0),
					VoxelTypes.BRICKS_ID)
			w.set_block(base_cell + Vector3i(0, ground_y + 1 + dy, -d),
					VoxelTypes.BRICKS_ID)
	await get_tree().create_timer(0.5).timeout
	# 正对墙角：先扔单件再扔整堆（泥土 x6）
	player.rotation.y = atan2(-fwd.x, -fwd.z)
	player.camera.rotation.x = -0.25
	player.inventory.add(items.id_for_name("core:dirt"), 10)
	player.call("_select", 1)
	player.call("_drop_held", false)
	await get_tree().create_timer(0.7).timeout
	player.call("_select", 1)
	player.call("_drop_held", true)
	# 等待落定（2.5s >> 补间/延迟）
	await get_tree().create_timer(2.5).timeout
	var failures := 0
	for k in dm.drop_count():
		var d := dm.drop_at(k)
		var bottom := d.position.y - ItemDrop.HALF_HEIGHT
		print("drop[%d] count=%d pos=(%.2f,%.2f,%.2f) bottom=%.2f ground=%.1f g=%s" % [
			k, d.count, d.position.x, d.position.y, d.position.z, bottom,
			float(ground_y + 1), d.grounded])
		if d.count > 1 and absf(bottom - float(ground_y + 1)) > 0.05:
			print("[FAIL] 堆叠掉落没有停在墙脚地面！")
			failures += 1
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("res://debug/last_corner.png")
	print("CORNER CHECK: %s drops=%d" % ["PASS" if failures == 0 else "FAIL", dm.drop_count()])
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0 if failures == 0 else 1)
