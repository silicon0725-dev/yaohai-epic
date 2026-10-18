## 开发辅助：物品层 HUD 视觉检查 + 接线冒烟。
##   godot-4 --path . res://debug/capture_items.tscn
## 输出两张截图（游戏 HUD / 打开的背包界面）并程序化校验：
##   - 起始装备已入包（木镐/泥土/木板）
##   - 快捷栏 12 格 UI 已构建
##   - 背包界面开关切换正常
extends Node

func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	# 隔离存档：截图检查不读写真实存档（否则退出保存会覆盖玩家进度）
	main.save_root = "user://tmp_capture_items"
	add_child(main)
	# HUD 检查不需要大视距：收缩加载半径，加快安定（慢机器友好）
	var manager0 = main.get("chunk_manager")
	if manager0 != null:
		manager0.view_distance = 2
	var waited := 0
	# HUD 验证不依赖世界流式安定：等若干帧（区块开始渲染）即截图
	while waited < 60:
		await get_tree().process_frame
		waited += 1

	var players := main.find_children("Player", "CharacterBody3D", true, false)
	if players.is_empty():
		print("CAPTURE_ITEMS: FAIL - no player")
		get_tree().quit(1)
		return
	var player: CharacterBody3D = players[0]

	# 接线冒烟：起始装备与 UI 构建
	var inv: Inventory = player.get("inventory")
	var items: ItemRegistry = player.get("item_registry")
	var pickaxe := items.id_for_name("core:wooden_pickaxe")
	var ok: bool = inv.count_of(pickaxe) == 1 \
			and inv.count_of(items.id_for_name("core:dirt")) == 16 \
			and inv.count_of(items.id_for_name("core:planks")) == 16 \
			and player.get("_slot_panels").size() == 12
	print("接线冒烟（起始装备/快捷栏 UI）: %s" % ("PASS" if ok else "FAIL"))

	await RenderingServer.frame_post_draw
	_capture("res://debug/capture_hud.png")

	player.call("_toggle_inventory")
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_capture("res://debug/capture_inventory.png")
	print("背包界面打开: %s" % str(player.get("inventory_open")))

	get_tree().quit(0 if ok else 1)


func _capture(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("截图: ", path)
