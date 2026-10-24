## Q 投掷复现截图：真实调用玩家丢弃入口，抓拍落地后多个时刻。
## 曾在此复现"方块以 30-45° 倾角插进地里"（磁吸拉拽所致）。
extends Node

const ROOT := "user://tmp_capture_q"

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
	player.rotation.y = 0.0
	player.camera.rotation.x = -0.35
	player.inventory.add(items.id_for_name("core:dirt"), 8)
	player.inventory.add(items.id_for_name("core:stick"), 8)
	player.call("_select", 0)
	player.call("_drop_held", false)
	await get_tree().create_timer(0.6).timeout
	player.call("_select", 0)
	player.call("_drop_held", false)
	for delay in [0.4, 0.8, 1.5]:
		await get_tree().create_timer(delay).timeout
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png("res://debug/last_q_%s.png" % str(delay).replace(".", "_"))
		print("shot %s drops=%d" % [delay, dm.drop_count()])
	main.chunk_manager.save_system = null
	main.queue_free()
	await get_tree().process_frame
	WorldSave.new(ROOT, VoxelTypes.build_default_registry()).erase_all()
	get_tree().quit(0)
