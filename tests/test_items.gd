## 物品层单元测试：注册表、背包堆叠、掉落规则、挖掘时长（§11.1 扩展）。
extends VoxelTestCase


func run() -> void:
	var blocks := VoxelTypes.build_default_registry()
	var items := ItemTypes.build_default_item_registry(blocks)
	_test_registry(blocks, items)
	_test_inventory(items)
	_test_drop_table(blocks, items)
	_test_break_info(blocks, items)
	_test_mine_integration(blocks, items)


func _test_registry(blocks: VoxelRegistry, items: ItemRegistry) -> void:
	check_eq(items.item_count(), 15, "默认物品数（11 方块 + 煤 + 木棍 + 2 镐）")
	check_eq(items.id_for_name("core:stick"), 14, "core:stick 追加在末尾（ID 稳定）")
	# 注册顺序即数值 ID（发布后不可重排）
	check_eq(items.id_for_name("core:grass"), 0, "core:grass -> 0")
	check_eq(items.id_for_name("core:stone"), 2, "core:stone -> 2")
	check_eq(items.id_for_name("core:coal"), 11, "core:coal -> 11")
	check_eq(items.id_for_name("core:wooden_pickaxe"), 12, "木镐 -> 12")
	check_eq(items.id_for_name("core:stone_pickaxe"), 13, "石镐 -> 13")
	check_eq(items.id_for_name("core:nope"), -1, "未知物品 -1")
	check_eq(items.name_for_id(999), "", "未知 ID 空名")

	# 放置类物品的方块联动
	check_eq(items.place_block_id(items.id_for_name("core:dirt")),
			VoxelTypes.DIRT_ID, "core:dirt 物品放置 dirt 方块")
	check_eq(items.place_block_id(items.id_for_name("core:wooden_pickaxe")),
			-1, "工具不可放置")
	check_eq(items.place_block_id(items.id_for_name("core:coal")),
			-1, "材料不可放置")

	# 堆叠上限与工具定义
	check_eq(items.max_stack(items.id_for_name("core:dirt")), 64, "方块堆叠 64")
	check_eq(items.max_stack(items.id_for_name("core:wooden_pickaxe")),
			1, "工具堆叠 1")
	var tool := items.tool_for(items.id_for_name("core:wooden_pickaxe"))
	check_eq(tool.get("class", ""), "pickaxe", "木镐工具类")
	check_eq(tool.get("tier", 0), 2, "木镐等级 2")
	check_eq(tool.get("speed", 0), 4.0, "木镐速度 4x")
	check(items.tool_for(items.id_for_name("core:dirt")).is_empty(),
			"非工具物品 tool 为空")


func _test_inventory(items: ItemRegistry) -> void:
	var inv := Inventory.new(items, 24, 12)
	check_eq(inv.size(), 24, "24 格")
	check_eq(inv.hotbar_size, 12, "快捷栏 12 格")

	# 添加与堆叠
	var dirt := items.id_for_name("core:dirt")
	check_eq(inv.add(dirt, 70), 0, "70 泥土全部放入（并堆 + 开新堆）")
	check_eq(inv.count_at(0), 64, "第一堆 64")
	check_eq(inv.count_at(1), 6, "第二堆 6")
	check_eq(inv.add(dirt, 10), 0, "再放 10（并入第二堆到 16）")
	check_eq(inv.count_at(1), 16, "第二堆 16")

	# 背包满：溢出返回剩余
	var inv2 := Inventory.new(items, 2, 2)
	check_eq(inv2.add(dirt, 200), 72, "2 格只装 128，剩 72")

	# 移除
	check_eq(inv2.remove_at(0, 30), 30, "移除 30")
	check_eq(inv2.count_at(0), 34, "剩 34")
	check_eq(inv2.remove_at(0, 999), 34, "移除超量取整堆")
	check(inv2.is_empty(0), "清空后空格")

	# 移动/交换/合并
	var inv3 := Inventory.new(items, 3, 3)
	var stone := items.id_for_name("core:stone")
	var log := items.id_for_name("core:log")
	inv3.add(dirt, 10)              # slot0
	inv3.add(stone, 5)              # slot1
	inv3.move_or_swap(0, 2)         # 移动到空格
	check_eq(inv3.item_id_at(2), dirt, "移动：物品跟随")
	check(inv3.is_empty(0), "移动：原格清空")
	inv3.move_or_swap(0, 2)         # 空格来源 = 无操作
	check_eq(inv3.item_id_at(2), dirt, "空源无操作")
	inv3.move_or_swap(2, 1)         # 不同类交换
	check_eq(inv3.item_id_at(1), dirt, "交换：目标变泥土")
	check_eq(inv3.item_id_at(2), stone, "交换：来源变石头")
	var inv4 := Inventory.new(items, 2, 2)
	inv4.add(dirt, 10)              # slot0 10
	inv4.add(dirt, 20)              # slot1 20
	inv4.move_or_swap(0, 1)         # 同类合并（10 并入 20 -> 30）
	check_eq(inv4.count_at(1), 30, "同类合并")
	check(inv4.is_empty(0), "合并后来源空")

	# 序列化往返（稳定名称）
	var data := inv4.serialize()
	check_eq(data[1].get("item"), "core:dirt", "序列化用稳定名称")
	var inv5 := Inventory.new(items, 2, 2)
	inv5.deserialize(data)
	check_eq(inv5.count_of(dirt), 30, "反序列化还原总量")

	# 容错：未知名称跳过、超上限截断
	inv5.deserialize([{"item": "core:gone", "count": 5},
			{"item": "core:stone", "count": 999999}])
	check(inv5.is_empty(0), "未知物品名跳过")
	check_eq(inv5.count_at(1), 64, "超上限截断到 max_stack")

	# 起始装备
	var inv6 := Inventory.new(items, 24, 12)
	inv6.apply_starting_kit(ItemTypes.STARTING_KIT)
	check_eq(inv6.count_of(items.id_for_name("core:wooden_pickaxe")), 1,
			"起始木镐")
	check_eq(inv6.count_of(items.id_for_name("core:dirt")), 16, "起始泥土")
	check_eq(inv6.count_of(items.id_for_name("core:planks")), 16, "起始木板")


func _test_drop_table(blocks: VoxelRegistry, items: ItemRegistry) -> void:
	# 例外规则
	var grass_drops := DropTable.drops_for(VoxelTypes.GRASS_ID, blocks, items)
	check_eq(grass_drops.size(), 1, "草方块掉 1 种")
	check_eq(grass_drops[0]["item_id"], items.id_for_name("core:dirt"),
			"草方块掉泥土")
	var stone_drops := DropTable.drops_for(VoxelTypes.STONE_ID, blocks, items)
	check_eq(stone_drops[0]["item_id"],
			items.id_for_name("core:cobblestone"), "石头掉圆石")
	var coal_drops := DropTable.drops_for(VoxelTypes.COAL_ORE_ID, blocks, items)
	check_eq(coal_drops[0]["item_id"], items.id_for_name("core:coal"),
			"煤矿掉煤")
	check_eq(DropTable.drops_for(VoxelTypes.BEDROCK_ID, blocks, items).size(),
			0, "基岩无掉落")
	# 默认：掉自身
	var sand_drops := DropTable.drops_for(VoxelTypes.SAND_ID, blocks, items)
	check_eq(sand_drops[0]["item_id"], items.id_for_name("core:sand"),
			"沙掉自身")
	var iron_drops := DropTable.drops_for(VoxelTypes.IRON_ORE_ID, blocks, items)
	check_eq(iron_drops[0]["item_id"], items.id_for_name("core:iron_ore"),
			"铁矿掉自身（熔炼属后续玩法）")


func _test_break_info(blocks: VoxelRegistry, items: ItemRegistry) -> void:
	var wooden := items.tool_for(items.id_for_name("core:wooden_pickaxe"))
	var stone_pick := items.tool_for(items.id_for_name("core:stone_pickaxe"))

	# 无工具要求方块：基准速度，徒手可掉落
	var dirt := BlockMining.break_info(
			VoxelTypes.DIRT_ID, blocks, {})
	check_eq(dirt["seconds"], 0.75, "徒手挖泥土 0.75s")
	check(dirt["drops"], "泥土徒手掉落")
	check(dirt["breakable"], "泥土可挖")

	# 徒手挖石头：4 倍减速 + 不掉落
	var stone_hand := BlockMining.break_info(
			VoxelTypes.STONE_ID, blocks, {})
	check_eq(stone_hand["seconds"], 5.5 * 4.0, "徒手挖石头 4 倍减速")
	check(not stone_hand["drops"], "徒手挖石头无掉落")

	# 木镐：加速 + 掉落
	var stone_wood := BlockMining.break_info(
			VoxelTypes.STONE_ID, blocks, wooden)
	check_eq(stone_wood["seconds"], 5.5 / 4.0, "木镐挖石头 1.375s")
	check(stone_wood["drops"], "木镐挖石头掉落")

	# 石镐更快
	var stone_stone := BlockMining.break_info(
			VoxelTypes.STONE_ID, blocks, stone_pick)
	check_eq(stone_stone["seconds"], 5.5 / 8.0, "石镐挖石头 0.6875s")

	# 等级不足的低级镐（假设 tier 1）：4 倍减速 + 不掉落
	var weak_pick := {"class": "pickaxe", "tier": 1, "speed": 4.0}
	var stone_weak := BlockMining.break_info(
			VoxelTypes.STONE_ID, blocks, weak_pick)
	check_eq(stone_weak["seconds"], 5.5 * 4.0 / 4.0, "低级镐减速链")
	check(not stone_weak["drops"], "低级镐挖石头无掉落")

	# 基岩 / 空气
	var bedrock := BlockMining.break_info(VoxelTypes.BEDROCK_ID, blocks, stone_pick)
	check(not bedrock["breakable"], "基岩不可破坏（任何工具）")
	var air := BlockMining.break_info(VoxelTypes.AIR_ID, blocks, {})
	check(not air["breakable"], "空气不可破坏")

	# 镐不影响泥土速度（class 不匹配不加速）
	var dirt_pick := BlockMining.break_info(
			VoxelTypes.DIRT_ID, blocks, wooden)
	check_eq(dirt_pick["seconds"], 0.75, "镐挖泥土不加速")


func _test_mine_integration(blocks: VoxelRegistry, items: ItemRegistry) -> void:
	# 真实世界上的挖掘 -> 掉落进背包
	var config := WorldConfig.new()
	config.world_seed = 42
	var world := VoxelWorld.new(config, blocks)
	var chunk := ChunkData.new(Vector3i.ZERO,
			Vector3i(config.chunk_size, config.chunk_size, config.chunk_size), 1)
	chunk.set_block_raw(Vector3i(1, 1, 1), VoxelTypes.STONE_ID)
	chunk.set_block_raw(Vector3i(2, 1, 1), VoxelTypes.GRASS_ID)
	chunk.set_block_raw(Vector3i(3, 1, 1), VoxelTypes.BEDROCK_ID)
	world.add_chunk(chunk)
	check_eq(world.chunk_count(), 1, "测试区块就绪")

	# 石头（允许掉落） -> 圆石
	var drops := BlockMining.mine(world, Vector3i(1, 1, 1), items, true)
	check_eq(drops.size(), 1, "石头掉 1 组")
	var inv := Inventory.new(items, 24, 12)
	for drop in drops:
		inv.add(int(drop["item_id"]), int(drop["count"]))
	check_eq(inv.count_of(items.id_for_name("core:cobblestone")), 1,
			"挖掘圆石入包")

	# 工具不足（白挖）
	var no_drops := BlockMining.mine(world, Vector3i(2, 1, 1), items, false)
	check_eq(no_drops.size(), 0, "关闭掉落时无物品")
	check_eq(world.get_block(Vector3i(2, 1, 1)), VoxelTypes.AIR_ID,
			"方块仍被破坏")

	# 基岩
	var bedrock := BlockMining.mine(world, Vector3i(3, 1, 1), items, true)
	check_eq(bedrock.size(), 0, "基岩不可挖")
	check_eq(world.get_block(Vector3i(3, 1, 1)), VoxelTypes.BEDROCK_ID,
			"基岩原样")

	# 放置消耗链路（BlockPlacement 不变；调用方语义由玩家控制器保证）
	check(BlockPlacement.place(world, Vector3i(2, 1, 1),
			VoxelTypes.DIRT_ID, AABB(Vector3(50, 50, 50), Vector3.ONE)),
			"放置成功")
	check_eq(world.get_block(Vector3i(2, 1, 1)), VoxelTypes.DIRT_ID, "放置生效")
