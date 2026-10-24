## 地面掉落实体集成检查（可 headless 运行，无需显示环境）：
##   godot-4 --headless --path . res://debug/drops_check.tscn
## 端到端验证物品层掉落闭环：
##   1. 主场景接线：DropManager 挂接玩家拾取目标与背包；
##   2. 挖掘路径：玩家 _break_block -> BlockMining/DropTable -> 散射生成
##      地面掉落 -> 下落 -> 磁吸自动拾取入包；
##   3. 远处掉落超出磁吸半径不被拾取，掉落与 Sprite3D 一一对应；
##   4. 存档往返：掉落与背包写入 world.json，重启实例后原样恢复。
## 使用隔离存档目录。退出码 0 = 全部通过。
extends Node

const ISOLATED_SAVE_ROOT := "user://tmp_drops_check"
## 物理帧预算（60fps 语义）：拾取等待 4 秒
const PICKUP_TIMEOUT_FRAMES := 240

var failures: Array[String] = []


func _ready() -> void:
	_cleanup_save()
	await _run()
	_report()


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ISOLATED_SAVE_ROOT
	add_child(main)
	for i in 10:
		await get_tree().physics_frame

	var player: PlayerController = main.player
	var drop_manager: DropManager = main.drop_manager
	_expect(player != null and drop_manager != null, "主场景创建玩家与掉落管理器")
	if drop_manager == null or player == null:
		return
	_expect(drop_manager.pickup_target == player, "拾取目标接线（玩家）")
	_expect(drop_manager.pickup_inventory == player.inventory, "拾取背包接线")

	var items: ItemRegistry = player.item_registry
	var dirt := items.id_for_name("core:dirt")
	var cobble := items.id_for_name("core:cobblestone")

	# -- 挖掘路径：脚下方块 -> 地面掉落 -> 自动拾取 --
	var mined_name := _mine_block_under(player)
	# 期望物品经 DropTable 推导（挖石得圆石等，v3 地形出生点可能
	# 踩在石头/沙地上，不能假定"挖什么得什么"）
	var drop_entries := DropTable.drops_for(
			player.world.registry.id_for_name(mined_name),
			player.world.registry, items)
	var item_id: int = drop_entries[0]["item_id"]
	_expect(drop_manager.drop_count() == 1, "挖掘产物生成地面掉落（%s）" % mined_name)
	var have_before := player.inventory.count_of(item_id)
	var picked := false
	for i in PICKUP_TIMEOUT_FRAMES:
		await get_tree().physics_frame
		if drop_manager.drop_count() == 0:
			picked = true
			break
	_expect(picked, "挖掘掉落自动拾取")
	_expect(player.inventory.count_of(item_id) == have_before + 1,
			"拾取入包（%d -> %d）" % [
				have_before, player.inventory.count_of(item_id)])

	# -- 头顶精确掉落同样闭环 --
	var dirt_before := player.inventory.count_of(dirt)
	drop_manager.spawn_drop(dirt, 5,
			player.global_position + Vector3(0.0, 2.5, 0.0), Vector3.ZERO, 0.0)
	picked = false
	for i in PICKUP_TIMEOUT_FRAMES:
		await get_tree().physics_frame
		if drop_manager.drop_count() == 0:
			picked = true
			break
	_expect(picked, "头顶掉落自动拾取")
	_expect(player.inventory.count_of(dirt) == dirt_before + 5, "头顶掉落拾取入包")

	# -- 远处掉落保留 + 表现节点对应 --
	drop_manager.spawn_drop(cobble, 3,
			player.global_position + Vector3(3.5, 1.0, 1.5), Vector3.ZERO, 0.0)
	for i in 90:
		await get_tree().physics_frame
	_expect(drop_manager.drop_count() == 1, "远处掉落不被拾取（超出磁吸半径）")
	_expect(drop_manager.get_child_count() == 1, "掉落与视觉根节点一一对应")

	# -- Q 丢弃：手持物品朝视线抛出，短保护期防吸回 --
	# 起始装备 slot0 = 木镐（堆叠 1）、slot1 = 泥土 x16
	var pickaxe_id := items.id_for_name("core:wooden_pickaxe")
	_expect(player.inventory.count_of(pickaxe_id) == 1, "丢弃前手持木镐在包")
	player.call("_drop_held", false)
	_expect(player.inventory.count_of(pickaxe_id) == 0, "Q 扔出 1 个（消耗手持）")
	var thrown := -1
	for i in drop_manager.drop_count():
		if drop_manager.drop_at(i).item_id == pickaxe_id:
			thrown = i
	_expect(thrown >= 0, "木镐成为地面掉落")
	if thrown >= 0:
		var thrown_drop := drop_manager.drop_at(thrown)
		_expect(thrown_drop.count == 1, "单件丢弃数量 1")
		_expect(thrown_drop.pickup_delay > 0.0, "丢弃带出生保护期")
		var eyes := player.global_position + Vector3(0.0, 0.7, 0.0)
		_expect(thrown_drop.position.distance_to(eyes) < 8.0,
				"从视线方向抛出（距眼睛 %.1f 格）" % thrown_drop.position.distance_to(eyes))
	# Ctrl+Q 整堆：切到泥土槽扔整堆（挖掘/拾取的泥土已并入该堆）
	player.call("_select", 1)
	var held_dirt := player.inventory.count_at(1)
	var dirt_before_q := player.inventory.count_of(dirt)
	player.call("_drop_held", true)
	_expect(player.inventory.count_of(dirt) == dirt_before_q - held_dirt,
			"Ctrl+Q 扔整堆（泥土 -%d）" % held_dirt)
	var pile_found := false
	for i in drop_manager.drop_count():
		var probe_drop := drop_manager.drop_at(i)
		if probe_drop.item_id == dirt and probe_drop.count == held_dirt:
			pile_found = true
	_expect(pile_found, "整堆丢弃数量完整（泥土 x%d 一堆）" % held_dirt)
	# 等待抛出物飞离/落定：保护期内不吸回，玩家静立不拾取远处掉落
	for i in 150:
		await get_tree().physics_frame
	_expect(player.inventory.count_of(pickaxe_id) == 0,
			"抛出的木镐不被站在原地的玩家吸回")

	# -- 存档往返：重启实例后掉落与背包恢复 --
	var dirt_at_save := player.inventory.count_of(dirt)
	main.chunk_manager.save_all(player.get_save_state())
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	var main2: Node = load("res://scenes/main.tscn").instantiate()
	main2.save_root = ISOLATED_SAVE_ROOT
	add_child(main2)
	for i in 10:
		await get_tree().physics_frame
	var dm2: DropManager = main2.drop_manager
	_expect(dm2 != null and dm2.drop_count() >= 1,
			"重启后掉落恢复（%d）" % (dm2.drop_count() if dm2 else -1))
	if dm2 != null and dm2.drop_count() > 0:
		var restored := dm2.drop_at(0)
		_expect(restored.item_id == cobble and restored.count == 3,
				"恢复掉落身份与数量（圆石 x3）")
	_expect(main2.player.inventory.count_of(dirt) == dirt_at_save,
			"重启后背包恢复")
	main2.queue_free()
	await get_tree().process_frame
	_cleanup_save()


## 挖玩家脚下第一个实心方块（经玩家统一挖掘入口，返回方块稳定名称）。
func _mine_block_under(player: PlayerController) -> String:
	var world: VoxelWorld = player.world
	var pos := Vector3i(
			floori(player.global_position.x),
			floori(player.global_position.y - 0.5),
			floori(player.global_position.z))
	while pos.y >= 0 and not world.registry.is_solid(world.get_block(pos)):
		pos.y -= 1
	var block_name := world.registry.name_for_id(world.get_block(pos))
	player.set("_mine_drops", true)
	player.call("_break_block", pos)
	return block_name


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("[PASS] ", label)
	else:
		failures.append(label)
		print("[FAIL] ", label)


func _report() -> void:
	if failures.is_empty():
		print("DROPS CHECK: PASS")
		get_tree().quit(0)
	else:
		print("DROPS CHECK: FAIL（%d 项）" % failures.size())
		get_tree().quit(1)


func _cleanup_save() -> void:
	var save := WorldSave.new(
			ISOLATED_SAVE_ROOT, VoxelTypes.build_default_registry())
	save.erase_all()
