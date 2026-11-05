## 物品层 HUD 布局检查（可 headless 运行，无需显示环境）：
##   godot-4 --headless --path . res://debug/items_ui_check.tscn
## 快捷栏曾因 PRESET_MODE_MINSIZE 在 _ready 时容器未布局出最小尺寸
## 而 0 尺寸不可见；本检查程序化断言 HUD 几何与网格背包接线，防回归：
##   1. 快捷栏面板矩形非零且宽度吻合 8 列推导值；
##   2. 8 列面板尺寸正确且可见，图标四边内缩；
##   3. 起始装备已入包（快捷栏列 0 = 木镐），选中列显示名正确；
##   4. 背包界面开关正常（三分区 8×9 / 8×2 / 4×4，条目节点齐备，
##      木镐条目竖向跨两格 = 多格占位生效）。
## 使用隔离存档目录。退出码 0 = 全部通过。
extends Node

const ISOLATED_SAVE_ROOT := "user://tmp_items_ui_check"

var failures: Array[String] = []


func _ready() -> void:
	_cleanup_save()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ISOLATED_SAVE_ROOT
	add_child(main)
	for i in 5:
		await get_tree().process_frame

	var players := main.find_children("Player", "CharacterBody3D", true, false)
	_expect(not players.is_empty(), "找到 Player 节点")
	if players.is_empty():
		_report()
		return
	var player: CharacterBody3D = players[0]

	# 1. 快捷栏面板矩形
	var hotbar: Control = player.get("_hotbar_panel")
	_expect(hotbar != null, "快捷栏面板存在")
	if hotbar != null:
		_expect(hotbar.size.x >= 8.0 * 52.0,
				"快捷栏宽度覆盖 8 列（实际 %.0f）" % hotbar.size.x)
		_expect(hotbar.size.y >= 44.0,
				"快捷栏高度覆盖槽位（实际 %.0f）" % hotbar.size.y)
		_expect(hotbar.visible, "快捷栏可见")

	# 2. 列面板
	var col_panels: Array = player.get("_hb_col_panels")
	_expect(col_panels.size() == 8, "8 个快捷栏列")
	var slots_ok := true
	for panel in col_panels:
		if panel.size.x < 44.0 or panel.size.y < 44.0:
			slots_ok = false
	_expect(slots_ok, "全部列尺寸未被压扁")

	# 图标内缩：不遮挡列边框（选中高亮）——曾因 FULL_RECT 铺满而遮挡
	var icons: Array = player.get("_hb_col_icons")
	var icons_inset := true
	for icon in icons:
		if icon.offset_left < 3 or icon.offset_top < 3 \
				or icon.offset_right > -3 or icon.offset_bottom > -3:
			icons_inset = false
	_expect(icons_inset, "列图标四边内缩（不遮挡边框）")

	# 3. 起始装备与选中显示（AUTO 先快捷栏：列 0 竖镐、列 1 泥土、列 2 木板）
	var inv = player.get("inventory")
	var items: ItemRegistry = player.get("item_registry")
	_expect(inv.count_of(items.id_for_name("core:wooden_pickaxe")) == 1,
			"起始木镐入包")
	_expect(inv.count_of(items.id_for_name("core:dirt")) == 16, "起始泥土入包")
	var col0: Dictionary = inv.hotbar_pick(0)
	_expect(int(col0.get("item_id", -1)) == items.id_for_name("core:wooden_pickaxe"),
			"快捷栏列 0 = 木镐")
	var label: Label = player.get("_item_label")
	_expect(label != null and label.text == "Wooden Pickaxe",
			"选中列显示 Wooden Pickaxe（实际 %s）" % (label.text if label else "<null>"))

	# 4. 背包界面开关（三分区 + 多格条目节点）
	player.call("_toggle_inventory")
	await get_tree().process_frame
	var screen: Control = player.get("_inventory_screen")
	_expect(screen.visible, "E 打开背包界面")
	_expect(player.get("inventory_open"), "inventory_open 状态置位")
	var zones: Dictionary = player.get("_zones")
	_expect(zones.size() == 3, "背包界面三分区（主网格/快捷栏/GEAR）")
	var cells_main: Array = zones[0]["cells"]
	_expect(cells_main.size() == 9 and cells_main[0].size() == 8, "主网格 8×9 格")
	var cells_hotbar: Array = zones[1]["cells"]
	_expect(cells_hotbar.size() == 2 and cells_hotbar[0].size() == 8,
			"快捷栏 8×2 格")
	var cells_gear: Array = zones[2]["cells"]
	_expect(cells_gear.size() == 4 and cells_gear[0].size() == 4, "GEAR 4×4 格")
	# 条目节点：起始装备 3 条；木镐 1×2 竖向跨格
	var entry_nodes: Dictionary = player.get("_entry_nodes")
	_expect(entry_nodes.size() == 3, "条目节点 3 个（起始装备）")
	var pick_node: Control = entry_nodes.get(int(col0.get("uid", -1)))
	_expect(pick_node != null and pick_node.size.y > pick_node.size.x,
			"木镐节点竖向跨格（多格占位生效）")

	# 5. 合成面板：配方行齐全，点击可合成（木板 -> 木棍）
	var craft_rows: Array = player.get("_craft_rows")
	_expect(craft_rows.size() == CraftingRecipes.all().size(),
			"合成面板配方行齐全（%d 条）" % CraftingRecipes.all().size())
	var planks_before: int = inv.count_of(
			inv.item_registry().id_for_name("core:planks"))
	var stick_before: int = inv.count_of(
			inv.item_registry().id_for_name("core:stick"))
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	player.call("_on_craft_row_input",
			click, CraftingRecipes.by_id("core:stick_from_planks"))
	await get_tree().process_frame
	var sticks_gained: int = inv.count_of(
			inv.item_registry().id_for_name("core:stick")) - stick_before
	# 起始装备 16 木板 >= 2，合成应成功产出 4 木棍
	_expect(sticks_gained == 4 and planks_before >= 2,
			"点击配方行合成成功（木板-2 木棍+4）")

	player.call("_toggle_inventory")
	await get_tree().process_frame
	_expect(not screen.visible, "再次 E 关闭背包界面")

	_report()


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("[PASS] ", label)
	else:
		failures.append(label)
		print("[FAIL] ", label)


func _report() -> void:
	if failures.is_empty():
		print("ITEMS UI CHECK: PASS")
		get_tree().quit(0)
	else:
		print("ITEMS UI CHECK: FAIL（%d 项）" % failures.size())
		get_tree().quit(1)


func _cleanup_save() -> void:
	# 必须走 user://（WorldSave.erase_all）；曾用相对路径 DirAccess.open，
	# 清理恒为空操作，退出保存跨运行累积背包直到木板耗尽使检查必败
	WorldSave.new(ISOLATED_SAVE_ROOT,
			VoxelTypes.build_default_registry()).erase_all()
