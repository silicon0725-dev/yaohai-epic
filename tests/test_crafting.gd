## 合成系统单元测试：配方定义、原子合成、跨堆消耗、升级闭环（§11.1 扩展）。
extends VoxelTestCase


func run() -> void:
	var blocks := VoxelTypes.build_default_registry()
	var items := ItemTypes.build_default_item_registry(blocks)
	_test_recipe_definitions(items)
	_test_inventory_remove_item(items)
	_test_can_craft_and_craft(items)
	_test_progression_chain(items)
	_test_atomicity(items)


func _test_recipe_definitions(items: ItemRegistry) -> void:
	check_eq(CraftingRecipes.all().size(), 4, "v1 配方 4 条")
	for recipe in CraftingRecipes.all():
		check(String(recipe.get("id", "")) != "", "配方有 id")
		var output: Array = recipe.get("output", [])
		check(output.size() == 2, "配方 output 形状 [名称, 数量]")
		check(items.id_for_name(String(output[0])) >= 0,
				"产物已注册: %s" % output[0])
		check(int(output[1]) > 0, "产物数量为正")
		for entry: Array in recipe.get("inputs", []):
			check(items.id_for_name(String(entry[0])) >= 0,
					"材料已注册: %s" % entry[0])
			check(int(entry[1]) > 0, "材料数量为正")
	# 关键配方在位
	check(not CraftingRecipes.by_id("core:wooden_pickaxe").is_empty(),
			"木镐配方存在")
	check(not CraftingRecipes.by_id("core:stone_pickaxe").is_empty(),
			"石镐配方存在")
	check(CraftingRecipes.by_id("core:none").is_empty(), "未知配方空字典")


func _test_inventory_remove_item(items: ItemRegistry) -> void:
	var inv := Inventory.new(items, 4, 4)
	var dirt := items.id_for_name("core:dirt")
	inv.add(dirt, 64)   # slot0 满
	inv.add(dirt, 10)   # slot1 10
	inv.add(dirt, 5)    # slot2 5
	# 跨堆移除 70：应从末尾堆先扣（5 + 10 + 55 of 64）
	check_eq(inv.remove_item(dirt, 70), 70, "跨堆移除 70")
	check_eq(inv.count_of(dirt), 9, "剩 9（在满堆中）")
	check(inv.is_empty(1) and inv.is_empty(2), "末尾两堆被清空")
	check_eq(inv.count_at(0), 9, "剩余都在第一堆")
	check_eq(inv.remove_item(dirt, 999), 9, "超量移除取全部")
	check_eq(inv.count_of(dirt), 0, "清零")


func _test_can_craft_and_craft(items: ItemRegistry) -> void:
	var planks := items.id_for_name("core:planks")
	var stick := items.id_for_name("core:stick")
	var pick := items.id_for_name("core:wooden_pickaxe")
	var inv := Inventory.new(items, 9, 9)
	var pick_recipe := CraftingRecipes.by_id("core:wooden_pickaxe")

	check(not CraftingRecipes.can_craft(pick_recipe, inv), "空包不可合成")
	inv.add(planks, 3)
	check(not CraftingRecipes.can_craft(pick_recipe, inv), "缺木棍不可合成")
	inv.add(planks, 2)   # 共 5（拆跨两堆也没关系，计数跨堆）
	inv.add(stick, 2)
	check(CraftingRecipes.can_craft(pick_recipe, inv), "材料齐全可合成")
	check(CraftingRecipes.craft(pick_recipe, inv), "合成成功")
	check_eq(inv.count_of(pick), 1, "产出木镐")
	check_eq(inv.count_of(planks), 2, "木板剩 2（5-3；跨堆计数消耗正确）")
	check_eq(inv.count_of(stick), 0, "木棍全消耗")
	check(not CraftingRecipes.craft(pick_recipe, inv), "材料耗尽后再合成失败")


func _test_progression_chain(items: ItemRegistry) -> void:
	# 从 2 根原木走完整升级链：原木 -> 木板 -> 木棍 -> 木镐
	# （镐共需 5 木板：3 直接 + 2 换 4 木棍；单根原木不够，与 MC 一致）
	var log := items.id_for_name("core:log")
	var planks := items.id_for_name("core:planks")
	var stick := items.id_for_name("core:stick")
	var wood_pick := items.id_for_name("core:wooden_pickaxe")
	var cobble := items.id_for_name("core:cobblestone")
	var stone_pick := items.id_for_name("core:stone_pickaxe")
	var inv := Inventory.new(items, 9, 9)

	inv.add(log, 2)
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:planks_from_log"), inv), "原木合成木板（第 1 根）")
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:planks_from_log"), inv), "原木合成木板（第 2 根）")
	check_eq(inv.count_of(planks), 8, "2 原木 -> 8 木板")
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:stick_from_planks"), inv), "木板合成木棍")
	check_eq(inv.count_of(planks), 6, "消耗 2 木板")
	check_eq(inv.count_of(stick), 4, "产出 4 木棍")
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:wooden_pickaxe"), inv), "合成木镐")
	check_eq(inv.count_of(wood_pick), 1, "持有木镐")
	check_eq(inv.count_of(planks), 3, "木板剩 3")
	check_eq(inv.count_of(stick), 2, "剩 2 木棍")

	# 木镐挖石头得圆石（掉落规则见 DropTable），攒 3 块圆石 + 剩余木棍
	inv.add(cobble, 3)
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:stone_pickaxe"), inv), "合成石镐")
	check_eq(inv.count_of(stone_pick), 1, "持有石镐（升级闭环完成）")


func _test_atomicity(items: ItemRegistry) -> void:
	# 材料不足时 craft 必须零副作用
	var planks := items.id_for_name("core:planks")
	var pick := items.id_for_name("core:wooden_pickaxe")
	var inv := Inventory.new(items, 9, 9)
	inv.add(planks, 3)   # 有木板没木棍
	check(not CraftingRecipes.craft(
			CraftingRecipes.by_id("core:wooden_pickaxe"), inv), "缺料合成失败")
	check_eq(inv.count_of(planks), 3, "失败零副作用：木板原样")
	check_eq(inv.count_of(pick), 0, "失败零副作用：无产出")

	# 背包满：消耗照常、产出丢弃（与挖掘掉落同语义，告警）。
	# 单格 64 木板：消耗 2 后堆仍占格，产出的 4 木棍无处安放。
	var inv2 := Inventory.new(items, 1, 1)
	var stick := items.id_for_name("core:stick")
	inv2.add(planks, 64)
	check(CraftingRecipes.craft(
			CraftingRecipes.by_id("core:stick_from_planks"), inv2),
			"背包满时合成仍执行（消耗生效）")
	check_eq(inv2.count_of(planks), 62, "木板消耗 2")
	check_eq(inv2.count_of(stick), 0, "产出木棍无空间，告警丢弃")
