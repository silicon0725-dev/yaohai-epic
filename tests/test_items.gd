## 物品层单元测试：注册表、网格背包占位/堆叠、掉落规则、挖掘时长（§11.1 扩展）。
extends VoxelTestCase

## 新类全局缓存不刷新（约束卡）：一律 preload 引用。
const GridInv := preload("res://items/grid_inventory.gd")


func run() -> void:
	var blocks := VoxelTypes.build_default_registry()
	var items := ItemTypes.build_default_item_registry(blocks)
	_test_registry(blocks, items)
	_test_inventory(items)
	_test_drop_table(blocks, items)
	_test_break_info(blocks, items)
	_test_mine_integration(blocks, items)


func _test_registry(blocks: VoxelRegistry, items: ItemRegistry) -> void:
	check(items.item_count() >= 15, "默认物品数 >= 15（11 方块+煤+木棍+2 镐；曾硬编码 15，加物品即挂）")
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
	# 网格占格尺寸
	check_eq(items.grid_size(items.id_for_name("core:dirt")), Vector2i.ONE,
			"方块占 1×1")
	check_eq(items.grid_size(items.id_for_name("core:wooden_pickaxe")),
			Vector2i(1, 2), "木镐占 1×2")
	var tool := items.tool_for(items.id_for_name("core:wooden_pickaxe"))
	check_eq(tool.get("class", ""), "pickaxe", "木镐工具类")
	check_eq(tool.get("tier", 0), 2, "木镐等级 2")
	check_eq(tool.get("speed", 0), 4.0, "木镐速度 4x")
	check(items.tool_for(items.id_for_name("core:dirt")).is_empty(),
			"非工具物品 tool 为空")


func _test_inventory(items: ItemRegistry) -> void:
	var dirt := items.id_for_name("core:dirt")
	var stone := items.id_for_name("core:stone")
	var pick := items.id_for_name("core:wooden_pickaxe")
	var main := GridInv.Zone.MAIN
	var hotbar := GridInv.Zone.HOTBAR
	var gear := GridInv.Zone.GEAR

	# 分区尺寸与行序 first-fit 布局（AUTO 先快捷栏 → 主网格）
	var inv := GridInv.new(items)
	check_eq(inv.zone_size(main), Vector2i(8, 9), "主网格 8×9")
	check_eq(inv.zone_size(hotbar), Vector2i(8, 2), "快捷栏 8×2")
	check_eq(inv.zone_size(gear), Vector2i(4, 4), "GEAR 区 4×4")
	check_eq(inv.add(dirt, 70), 0, "70 泥土全部放入（并堆 + 开新堆）")
	check_eq(int(inv.entry_at_cell(hotbar, 0, 0).get("count", 0)), 64,
			"首堆 64 落快捷栏 (0,0)")
	check_eq(int(inv.entry_at_cell(hotbar, 1, 0).get("count", 0)), 6,
			"次堆 6 落快捷栏 (1,0)")
	check_eq(inv.add(dirt, 10), 0, "再放 10（并入次堆）")
	check_eq(int(inv.entry_at_cell(hotbar, 1, 0).get("count", 0)), 16,
			"次堆并到 16")
	check(inv.is_empty_cell(main, 0, 0), "主网格未被触碰")

	# 背包满：溢出返回剩余（AUTO 区 = 快捷 1 格 + 主 2 格 = 192）
	var inv2 := GridInv.new(items, Vector2i(2, 1), Vector2i(1, 1))
	check_eq(inv2.add(dirt, 200), 8, "3 格只装 192，剩 8")

	# 条目移除（不跨堆）
	var first := inv2.entry_at_cell(hotbar, 0, 0)
	check_eq(inv2.remove_at_entry(first, 30), 30, "移除 30")
	check_eq(int(inv2.entry_at_cell(hotbar, 0, 0).get("count", 0)), 34,
			"剩 34")
	check_eq(inv2.remove_at_entry(first, 999), 34, "移除超量取整堆")
	check(inv2.is_empty_cell(hotbar, 0, 0), "清空后空格")

	# 跨堆移除：条目序从后往前扣（合成语义沿用）
	var inv3 := GridInv.new(items, Vector2i(2, 1), Vector2i(1, 1))
	inv3.add(dirt, 64)                  # 快捷栏 (0,0) 满堆
	inv3.add(dirt, 20)                  # 主网格 (0,0) 新堆 20
	check_eq(inv3.remove_item(dirt, 30), 30, "跨堆移除 30")
	check_eq(int(inv3.entry_at_cell(hotbar, 0, 0).get("count", 0)), 54,
			"先扣末堆再扣首堆")
	check(inv3.is_empty_cell(main, 0, 0), "末堆（主网格）扣光")

	# 多格物品：镐 1×2 自然竖放，first_fit 空间不足时自动转横
	var invp := GridInv.new(items, Vector2i(2, 3), Vector2i(1, 1))
	check_eq(invp.add(pick, 1), 0, "镐入包")
	check(not invp.is_empty_cell(main, 0, 0)
			and not invp.is_empty_cell(main, 0, 1), "镐竖占 (0,0)-(0,1)")
	check(invp.is_empty_cell(main, 1, 0), "(1,0) 仍空")
	invp.add(pick, 1)                   # (1,0)-(1,1)
	check(not invp.is_empty_cell(main, 1, 1), "第二把竖占右列")
	invp.add(pick, 1)                   # 竖放无处容身 -> 旋转横放 (0,2)-(1,2)
	var third := invp.entry_at_cell(main, 0, 2)
	check_eq(int(third.get("item_id", -1)), pick, "第三把自动转横放底行")
	check(bool(third.get("rotated", false)), "first_fit 空间不足时自动旋转")

	# 拖拽原语：pickup / try_drop 旋转 / BLOCKED
	var invr := GridInv.new(items, Vector2i(2, 2), Vector2i(1, 1))
	invr.add(pick, 1)
	var held := invr.pickup(main, 0, 0)
	check(invr.is_empty_cell(main, 0, 1), "pickup 后脚印清空")
	check_eq(invr.try_drop(held, main, 1, 0, true),
			GridInv.DropResult.BLOCKED, "横放越界被拒（状态未变）")
	check_eq(invr.try_drop(held, main, 0, 0, true), GridInv.DropResult.PLACED,
			"旋转后落格成功")
	var rotated_entry := invr.entry_at_cell(main, 0, 0)
	check(bool(rotated_entry.get("rotated", false)), "条目标记旋转")
	check(not invr.is_empty_cell(main, 1, 0), "横放覆盖 (1,0)")
	check(invr.is_empty_cell(main, 0, 1), "(0,1) 不再被占")

	# 同类 1×1 并堆：整并 MERGED / 部分 PARTIAL
	var invm := GridInv.new(items, Vector2i(2, 1), Vector2i(1, 1))
	invm.add(dirt, 64)                  # 快捷栏 (0,0) 满堆
	invm.add(dirt, 10)                  # 主网格 (0,0) 新堆（满堆不并）
	invm.remove_at_entry(invm.entry_at_cell(hotbar, 0, 0), 58)  # 首堆剩 6
	var held10 := invm.pickup(main, 0, 0)
	check_eq(invm.try_drop(held10, hotbar, 0, 0, false),
			GridInv.DropResult.MERGED, "拖到非满同类堆=整堆并入")
	check_eq(int(invm.entry_at_cell(hotbar, 0, 0).get("count", 0)), 16,
			"并入后 16")
	check(invm.is_empty_cell(main, 0, 0), "整并后来源消失")

	# 部分并入 PARTIAL：目标堆 58 + 手中满堆 64 -> 并 6 剩 58
	var invp2 := GridInv.new(items, Vector2i(2, 1), Vector2i(1, 1))
	invp2.add(dirt, 64)                 # 快捷栏 (0,0) 满
	invp2.add(dirt, 64)                 # 主网格 (0,0) 满（满堆不并）
	invp2.remove_at_entry(invp2.entry_at_cell(hotbar, 0, 0), 6)  # 首堆 58
	var held_full := invp2.pickup(main, 0, 0)
	check_eq(invp2.try_drop(held_full, hotbar, 0, 0, false),
			GridInv.DropResult.PARTIAL, "装不下整堆=部分并入")
	check_eq(int(held_full.get("count", 0)), 58, "余量 58 留在手中")
	check_eq(int(invp2.entry_at_cell(hotbar, 0, 0).get("count", 0)), 64,
			"目标堆满")

	# 拖到多格物品上 = BLOCKED（非同类并堆）
	var invb := GridInv.new(items, Vector2i(2, 2), Vector2i(1, 1))
	invb.add(pick, 1)                   # 主网格 (0,0)-(0,1) 竖放
	invb.add(stone, 1)                  # 快捷栏 (0,0)
	var held_stone := invb.pickup(hotbar, 0, 0)
	check_eq(invb.try_drop(held_stone, main, 0, 0, false),
			GridInv.DropResult.BLOCKED, "压在镐上被拒")
	invb.try_drop(held_stone, hotbar, 0, 0, false)

	# GEAR 区：自动入包绝不进，手动拖放可进出
	var invg := GridInv.new(items, Vector2i(1, 1), Vector2i(1, 1))
	invg.add(dirt, 128)                 # AUTO 区填满
	check_eq(invg.add(dirt, 1), 1, "AUTO 满：溢出不进 GEAR")
	check_eq(invg.entries_in(gear).size(), 0, "GEAR 保持空")
	var invg2 := GridInv.new(items, Vector2i(2, 2), Vector2i(1, 1))
	invg2.add(dirt, 5)
	var to_gear := invg2.pickup(hotbar, 0, 0)
	check_eq(invg2.try_drop(to_gear, gear, 0, 0, false),
			GridInv.DropResult.PLACED, "手动可放 GEAR")
	check_eq(invg2.count_of(dirt), 5, "count_of 覆盖全部分区")
	var from_gear := invg2.pickup(gear, 0, 0)
	check_eq(int(from_gear.get("item_id", -1)), dirt, "GEAR 可取回")

	# 快捷栏列语义：覆盖该列的条目中起始行最小者优先
	var invh := GridInv.new(items, Vector2i(1, 1), Vector2i(4, 2))
	var log := items.id_for_name("core:log")
	var sand := items.id_for_name("core:sand")
	var gravel := items.id_for_name("core:gravel")
	var planks := items.id_for_name("core:planks")
	invh.add(dirt, 64)                  # 快捷 (0,0)
	invh.add(stone, 1)                  # 快捷 (1,0)
	invh.add(log, 1)                    # (2,0)
	invh.add(sand, 1)                   # (3,0)
	invh.add(gravel, 1)                 # 第二行 (0,1)
	invh.add(planks, 1)                 # 第二行 (1,1)
	check_eq(int(invh.hotbar_pick(0).get("item_id", -1)), dirt,
			"同列上下两堆：上格优先")
	check_eq(int(invh.hotbar_pick(1).get("item_id", -1)), stone, "列 1")
	check_eq(int(invh.hotbar_pick(3).get("item_id", -1)), sand, "列 3")
	check_eq(int(invh.count_of(planks)), 1, "第二行正常存放")
	# 多格物品归属起始列：镐竖放跨快捷栏两行
	var invh2 := GridInv.new(items, Vector2i(1, 1), Vector2i(4, 2))
	invh2.add(dirt, 64)                 # 快捷 (0,0)
	invh2.add(pick, 1)                  # 快捷 (1,0)-(1,1) 竖放
	check_eq(int(invh2.hotbar_pick(1).get("item_id", -1)), pick,
			"竖放镐归属起始列 1")

	# can_fit：堆空隙 + 空位容量（多格物品逐堆模拟不虚报）
	var invf := GridInv.new(items, Vector2i(2, 3), Vector2i(1, 1))
	check(invf.can_fit(dirt, 448), "7 格泥土容量 448")
	check(not invf.can_fit(dirt, 449), "超出容量拒判")
	check(not invf.can_fit(dirt, 0), "零数量恒 false")
	check(invf.can_fit(pick, 3), "2×3 主网格容 3 把镐（2 竖+1 横）")
	check(not invf.can_fit(pick, 4), "第 4 把无处安放")
	invf.add(pick, 1)
	invf.add(pick, 1)
	invf.add(pick, 1)
	check(not invf.can_fit(pick, 1), "镐位耗尽")

	# 序列化 v2 往返（稳定名称 + 原位恢复）
	var invs := GridInv.new(items, Vector2i(2, 2), Vector2i(1, 1))
	invs.add(dirt, 30)
	invs.add(pick, 1)
	var data := invs.serialize()
	check_eq(int(data.get("v", 0)), 2, "序列化版本 2")
	check_eq(data["entries"].size(), 2, "两个条目")
	var invs2 := GridInv.new(items, Vector2i(2, 2), Vector2i(1, 1))
	invs2.deserialize(data)
	check_eq(invs2.count_of(dirt), 30, "泥土还原")
	check_eq(invs2.count_of(pick), 1, "镐还原")
	check_eq(int(invs2.entry_at_cell(hotbar, 0, 0).get("count", 0)), 30,
			"原位恢复")

	# 旧槽位存档（Array）自动迁移 first-fit
	invs2.deserialize([{"item": "core:dirt", "count": 10},
			{"item": "core:wooden_pickaxe", "count": 1}])
	check_eq(invs2.count_of(dirt), 10, "旧档泥土迁移")
	check_eq(int(invs2.entry_at_cell(hotbar, 0, 0).get("count", 0)), 10,
			"旧档泥土落快捷栏 (0,0)")
	check(not invs2.is_empty_cell(main, 0, 1), "旧档镐竖放迁移")

	# 容错：未知名称跳过、超上限截断、越界/重叠降级 first-fit
	invs2.deserialize({"v": 2, "entries": [
			{"item": "core:gone", "count": 5},
			{"item": "core:dirt", "count": 999999, "zone": 0, "x": 0, "y": 0},
			{"item": "core:dirt", "count": 7, "zone": 0, "x": 99, "y": 99}]})
	check_eq(invs2.count_of(dirt), 71, "未知名跳过 + 截断 + 越界降级不丢")

	# 起始装备
	var inv6 := GridInv.new(items)
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
	var inv := GridInv.new(items)
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
