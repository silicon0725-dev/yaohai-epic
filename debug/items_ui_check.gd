## 物品层 HUD 布局检查（可 headless 运行，无需显示环境）：
##   godot-4 --headless --path . res://debug/items_ui_check.tscn
## 快捷栏曾因 PRESET_MODE_MINSIZE 在 _ready 时容器未布局出最小尺寸
## 而 0 尺寸不可见；本检查程序化断言 HUD 几何与背包接线，防回归：
##   1. 快捷栏面板矩形非零且宽度吻合 12 槽位推导值；
##   2. 12 个槽位面板尺寸正确且可见；
##   3. 起始装备已入包，选中槽显示名正确；
##   4. 背包界面开关正常（24 格、开合切换）。
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
		_expect(hotbar.size.x >= 12 * 44, "快捷栏宽度覆盖 12 槽（实际 %.0f）" % hotbar.size.x)
		_expect(hotbar.size.y >= 44.0, "快捷栏高度覆盖槽位（实际 %.0f）" % hotbar.size.y)
		_expect(hotbar.visible, "快捷栏可见")

	# 2. 槽位面板
	var slot_panels: Array = player.get("_slot_panels")
	_expect(slot_panels.size() == 12, "12 个快捷栏槽位")
	var slots_ok := true
	for panel in slot_panels:
		if panel.size.x < 40.0 or panel.size.y < 40.0:
			slots_ok = false
	_expect(slots_ok, "全部槽位尺寸未被压扁")

	# 图标内缩：不遮挡槽位边框（选中高亮）——曾因 FULL_RECT 铺满而遮挡
	var icons: Array = player.get("_slot_icons")
	var icons_inset := true
	for icon in icons:
		if icon.offset_left < 3 or icon.offset_top < 3 \
				or icon.offset_right > -3 or icon.offset_bottom > -3:
			icons_inset = false
	_expect(icons_inset, "槽位图标四边内缩（不遮挡边框）")

	# 3. 起始装备与选中显示
	var inv: Inventory = player.get("inventory")
	var items: ItemRegistry = player.get("item_registry")
	_expect(inv.count_of(items.id_for_name("core:wooden_pickaxe")) == 1, "起始木镐入包")
	_expect(inv.count_of(items.id_for_name("core:dirt")) == 16, "起始泥土入包")
	var label: Label = player.get("_item_label")
	_expect(label != null and label.text == "Wooden Pickaxe",
			"选中槽显示 Wooden Pickaxe（实际 %s）" % (label.text if label else "<null>"))

	# 4. 背包界面开关
	player.call("_toggle_inventory")
	await get_tree().process_frame
	var screen: Control = player.get("_inventory_screen")
	_expect(screen.visible, "E 打开背包界面")
	_expect(player.get("inventory_open"), "inventory_open 状态置位")
	var inv_slots: Array = player.get("_inv_slot_panels")
	_expect(inv_slots.size() == 24, "背包界面 24 格")

	# 5. 合成面板：配方行齐全，点击可合成（木板 -> 木棍）
	var craft_rows: Array = player.get("_craft_rows")
	_expect(craft_rows.size() == CraftingRecipes.all().size(),
			"合成面板配方行齐全（%d 条）" % CraftingRecipes.all().size())
	var planks_before := inv.count_of(inv.item_registry().id_for_name("core:planks"))
	var stick_before := inv.count_of(inv.item_registry().id_for_name("core:stick"))
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	player.call("_on_craft_row_input",
			click, CraftingRecipes.by_id("core:stick_from_planks"))
	await get_tree().process_frame
	var sticks_gained := inv.count_of(
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
	var dir := DirAccess.open(ISOLATED_SAVE_ROOT.get_slice("://", 1))
	if dir != null:
		for file in dir.get_files():
			dir.remove(file)
		var base := "user://"
		DirAccess.open(base).remove(ISOLATED_SAVE_ROOT.get_slice("://", 1))
