## 地面掉落实体单元测试：体素物理（下落/落稳/撞墙/掩埋逃出/冻结）、
## 拾取规则、序列化容错、管理器生命周期（生成/散射/上限/冻结/
## 拾取含部分入包/合并/消散/存档往返）与 world.json 扩展键保护。
extends VoxelTestCase

const TMP_SAVE_ROOT := "user://tmp_drops_test"


func run() -> void:
	var ctx := _make_world()
	_test_physics(ctx)
	_test_spin(ctx)
	_test_pickup_rules(ctx)
	_test_serialize(ctx)
	_test_visuals(ctx)
	_test_ground_lift(ctx)
	_test_manager_spawning(ctx)
	_test_manager_freeze(ctx)
	_test_manager_pickup(ctx)
	_test_manager_merge(ctx)
	_test_manager_persistence(ctx)
	_test_save_extra_keys(ctx)
	_test_water_physics(ctx)


## 单区块世界 (0,0,0)：y<=2 全石头平台，区块 ACTIVE。
func _make_world() -> Dictionary:
	var blocks := VoxelTypes.build_default_registry()
	var items := ItemTypes.build_default_item_registry(blocks)
	var config := WorldConfig.new()
	config.world_seed = 42
	var world := VoxelWorld.new(config, blocks)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16), 1)
	for x in 16:
		for z in 16:
			for y in 3:
				chunk.set_block_raw(Vector3i(x, y, z), VoxelTypes.STONE_ID)
	chunk.state = ChunkState.State.ACTIVE
	world.add_chunk(chunk)
	return {"world": world, "items": items, "blocks": blocks}


func _step(drop: ItemDrop, world: VoxelWorld, times: int, delta := 0.05) -> void:
	for i in times:
		drop.physics_step(world, delta)


# ---- ItemDrop 物理 ----

func _test_physics(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]

	# 自由落体 -> 精确落在平台顶面（3 + 半高 0.18）并落稳
	var drop := ItemDrop.new()
	drop.item_id = ctx["items"].id_for_name("core:dirt")
	drop.count = 1
	drop.position = Vector3(8.5, 6.0, 8.5)
	_step(drop, world, 60)
	check(drop.grounded, "掉落触地 grounded")
	check(absf(drop.position.y - 3.18) <= 0.001, "落点 = 平台顶 + 半高")
	check(drop.velocity.y == 0.0, "落稳后竖直速度清零")
	_step(drop, world, 50)
	check(absf(drop.position.y - 3.18) <= 0.001, "持续落稳不下沉")

	# 掩埋逃出：出生在实心格内逐帧上浮到表面
	var buried := ItemDrop.new()
	buried.item_id = drop.item_id
	buried.count = 1
	buried.position = Vector3(8.5, 2.5, 8.5)
	_step(buried, world, 60)
	check(absf(buried.position.y - 3.18) <= 0.001, "掩埋掉落逃出到表面")
	check(buried.grounded, "逃出后落稳")

	# 撞墙清水平速度：x- 方向一格外墙，向墙滑动原地停住
	world.set_block(Vector3i(7, 3, 8), VoxelTypes.STONE_ID)
	var slider := ItemDrop.new()
	slider.item_id = drop.item_id
	slider.count = 1
	slider.position = Vector3(8.5, 3.18, 8.5)
	slider.velocity = Vector3(-12.0, 0.0, 0.0)
	_step(slider, world, 10)
	check_eq(slider.position.x, 8.5, "撞墙不掉进墙格（停在墙前）")
	check(slider.velocity.x == 0.0, "撞墙清水平速度")
	# 开阔方向正常滑行（摩擦衰减但不瞬停）
	var roller := ItemDrop.new()
	roller.item_id = drop.item_id
	roller.count = 1
	roller.position = Vector3(8.5, 3.18, 8.5)
	roller.velocity = Vector3(0.0, 0.0, -12.0)
	_step(roller, world, 5)
	check(roller.position.z < 7.5, "开阔方向滚动前进（%.2f）" % roller.position.z)

	# 世界底以下视为实心：掉出平台边缘不无限下坠
	var off := ItemDrop.new()
	off.item_id = drop.item_id
	off.count = 1
	off.position = Vector3(-5.5, 6.0, -5.5)  # 区块外（未加载 -> 空气）
	_step(off, world, 200)
	check(off.grounded, "掉出边缘后停在虚拟世界底（y<0 实心）")
	check(absf(off.position.y - 0.18) <= 0.001, "虚拟底落点 = 0 + 半高")


# ---- 拾取规则（无磁吸：MC/BDIR 均无此机制）----

func _test_pickup_rules(ctx: Dictionary) -> void:
	var drop := ItemDrop.new()
	drop.position = Vector3(8.5, 3.18, 8.5)
	drop.age = 1.0
	drop.pickup_delay = 0.5

	# 距离判定
	check(drop.ready_for_pickup(Vector3(9.3, 4.0, 8.5)), "水平 0.8 内可拾取")
	check(not drop.ready_for_pickup(Vector3(9.7, 4.0, 8.5)), "水平 1.2 外不可")
	check(not drop.ready_for_pickup(Vector3(8.5, 5.0, 8.5)), "垂直 1.82 外不可")
	check(drop.ready_for_pickup(Vector3(8.5, 4.3, 8.5)), "垂直 1.12 内可拾取")
	# 出生保护
	var young := ItemDrop.new()
	young.position = Vector3(8.5, 3.18, 8.5)
	young.age = 0.3
	young.pickup_delay = 0.5
	check(not young.ready_for_pickup(Vector3(8.5, 3.18, 8.5)), "保护期内不可拾取")
	# 落定后不受外部拉力：无磁吸即物品安放不动（回归锚点：
	# 磁吸曾把落地物品拉离地面卡在坡上，表现为随机倾角插进地里）
	var world: VoxelWorld = ctx["world"]
	var settled := ItemDrop.new()
	settled.position = Vector3(8.5, 3.18, 3.5)
	for i in 40:
		settled.physics_step(world, 0.05)
	check(settled.position.is_equal_approx(Vector3(8.5, 3.18, 3.5)),
			"落定掉落不受拉力（无磁吸，原地安放）")
	# 消散
	var aging := ItemDrop.new()
	aging.age = ItemDrop.DESPAWN_SECONDS - 0.1
	check(not aging.despawn_ready(), "未到时长不消散")
	aging.age += 0.2
	check(aging.despawn_ready(), "满 5 分钟（活跃时间）消散")


# ---- 自旋（模仿 BDIR：空中推进、落地冻结）----

func _test_spin(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var drop := ItemDrop.new()
	drop.position = Vector3(8.5, 6.0, 8.5)

	# 空中：角度持续推进
	drop.physics_step(world, 0.1)
	var first := drop.spin_angle
	check(first > 0.0, "空中自旋推进（%.3f rad）" % first)
	drop.physics_step(world, 0.1)
	check(drop.spin_angle > first, "空中持续推进")

	# 落地：角度冻结（歪着停在地上 = 姿态保留）
	for i in 80:
		drop.physics_step(world, 0.05)
	check(drop.grounded, "已落地")
	var frozen := drop.spin_angle
	for i in 20:
		drop.physics_step(world, 0.05)
	check(drop.spin_angle == frozen, "落地后角度冻结（姿态保留）")

	# 弹起（向上速度）重新推进：落地帧不推进、离地后继续
	drop.velocity.y = 6.0
	drop.physics_step(world, 0.05)
	check(not drop.grounded, "弹起离地")
	var before_rise := drop.spin_angle
	drop.physics_step(world, 0.05)
	check(drop.spin_angle > before_rise, "离地后恢复自旋")


# ---- 序列化 ----

func _test_serialize(ctx: Dictionary) -> void:
	var items: ItemRegistry = ctx["items"]
	var dirt := items.id_for_name("core:dirt")

	var drop := ItemDrop.new()
	drop.item_id = dirt
	drop.count = 7
	drop.position = Vector3(1.5, -2.25, 3.75)
	drop.velocity = Vector3(0.5, -1.0, 2.0)
	drop.age = 12.5
	drop.pickup_delay = 1.0
	drop.spin_angle = 2.25
	drop.spin_phase = 4.5
	var restored := ItemDrop.deserialize(drop.serialize(items), items)
	check(restored != null, "正常数据可还原")
	if restored != null:
		check_eq(restored.item_id, dirt, "物品还原")
		check_eq(restored.count, 7, "数量还原")
		check(restored.position.is_equal_approx(drop.position), "位置还原")
		check(restored.velocity.is_equal_approx(drop.velocity), "速度还原")
		check(absf(restored.age - 12.5) <= 0.001, "年龄还原")
		check(absf(restored.pickup_delay - 1.0) <= 0.001, "保护期还原")
		check(absf(restored.spin_angle - 2.25) <= 0.001, "自旋角还原")
		check(absf(restored.spin_phase - 4.5) <= 0.001, "自旋相位还原")

	# 容错：未知名称 / 非正数量 / 超堆截断 / 坐标形状
	var base := {"item": "core:dirt", "count": 3,
			"pos": [1, 2, 3], "vel": [0, 0, 0]}
	check(ItemDrop.deserialize(
			_variant(base, {"item": "core:gone"}), items) == null,
			"未知物品名跳过")
	check(ItemDrop.deserialize(
			_variant(base, {"count": 0}), items) == null, "零数量跳过")
	var clamped := ItemDrop.deserialize(_variant(base, {"count": 999}), items)
	check_eq(clamped.count, 64, "数量截断到 max_stack")
	check_eq(ItemDrop.deserialize(_variant(base, {
			"item": "core:wooden_pickaxe", "count": 5}), items).count, 1,
			"工具超堆截断到 1")
	check(ItemDrop.deserialize(_variant(base, {"pos": [1, 2]}), items) == null,
			"坐标形状不对跳过")
	# 旧档兼容：v1 掉落存档无 spin/phase 键，缺省 0
	var legacy := ItemDrop.deserialize(base.duplicate(true), items)
	check(legacy != null and legacy.spin_angle == 0.0
			and legacy.spin_phase == 0.0, "旧档无姿态键缺省 0")


## 基础字典 + 覆盖项（Dictionary.merge 原地修改，包一层便于链式断言）。
func _variant(base: Dictionary, overrides: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	result.merge(overrides, true)
	return result


## 四元数姿态等价比较：±q 双重覆盖是同一旋转（Node3D.quaternion 的
## getter 从 basis 重推导，可能返回负号形式），作用于正交向量后比较。
func _pose_close(a: Quaternion, b: Quaternion) -> bool:
	return (a * Vector3.FORWARD).is_equal_approx(b * Vector3.FORWARD) \
			and (a * Vector3.RIGHT).is_equal_approx(b * Vector3.RIGHT)


# ---- 视觉资源与姿态（模仿 BDIR）----

func _test_visuals(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	var blocks: VoxelRegistry = ctx["blocks"]
	var dirt := items.id_for_name("core:dirt")
	var coal := items.id_for_name("core:coal")

	# 迷你方块网格：六面 24 顶点 36 索引，与地形网格器同面表
	var cube := DropVisuals.cube_mesh_for(
			blocks.id_for_name("core:dirt"), blocks)
	var arrays := cube.surface_get_arrays(0)
	check_eq(arrays[Mesh.ARRAY_VERTEX].size(), 24, "迷你方块 6 面 x 4 顶点")
	check_eq(arrays[Mesh.ARRAY_INDEX].size(), 36, "迷你方块 12 三角形")
	check_eq(cube.surface_get_material(0), DropVisuals.atlas_material(),
			"迷你方块共享图集材质")

	# 挤出像素网格：厚贴图（多像素方柱，顶/底 + 轮廓侧边）
	var extruded := DropVisuals.extruded_mesh_for(coal, items)
	var ex_arrays := extruded.surface_get_arrays(0)
	check(ex_arrays[Mesh.ARRAY_VERTEX].size() > 100,
			"挤出网格有厚度（%d 顶点 > 100）" % ex_arrays[Mesh.ARRAY_VERTEX].size())
	check(ex_arrays[Mesh.ARRAY_INDEX].size() % 6 == 0,
			"挤出网格全四边形三角化")
	check_eq(extruded.surface_get_material(0),
			DropVisuals.flat_material_for(coal, items), "挤出网格挂平面材质")
	# 煤块图标：去底后中心完整（旧版整面填充会被键控成碎点）
	var coal_image := ItemIcons.sprite_image_for(coal, items)
	check(coal_image.get_pixel(0, 0).a < 0.5, "煤块图标角透明（去底）")
	check(coal_image.get_pixel(16, 16).a > 0.5, "煤块图标中心不透明（本体完整）")

	# 姿态：方块翻滚四元数 = Rz(spin) * Rx(-90°)；平面 = Ry(spin)
	var manager := DropManager.new()
	manager.setup(world, items)
	var cube_drop := manager.spawn_drop(dirt, 1, Vector3(8.5, 5.0, 8.5))
	cube_drop.spin_angle = 0.0
	cube_drop.spin_phase = 0.0
	var flat_drop := manager.spawn_drop(
			coal, 1, Vector3(9.5, 5.0, 8.5))
	flat_drop.spin_angle = 1.25
	flat_drop.spin_phase = 0.0
	manager.process_drops(0.016)
	var cube_root: Node3D = manager._visuals[0]
	var flat_root: Node3D = manager._visuals[1]
	# 断言用推进后的实际角度（process 期间空中翻滚已 +SPIN_SPEED*dt）
	# 姿态 = 偏航（相位）∘ 绕 X 的总倾角（TIP + 翻滚角），两类同链
	var expect_cube := Quaternion(Vector3.UP, cube_drop.spin_phase) \
			* Quaternion(Vector3(1.0, 0.0, 0.0),
					DropManager.TIP_FROM_STANDING + cube_drop.spin_angle)
	check(_pose_close(cube_root.quaternion, expect_cube),
			"方块空中姿态 = qy(偏航) * qx(TIP+翻滚)")
	var expect_flat := Quaternion(Vector3.UP, flat_drop.spin_phase) \
			* Quaternion(Vector3(1.0, 0.0, 0.0),
					DropManager.TIP_FROM_STANDING + flat_drop.spin_angle)
	check(_pose_close(flat_root.quaternion, expect_flat),
			"平面物品空中同样翻滚（ItemPhysic 行为，与方块同链）")

	# 数量副本：count>1 散布副本（上限 MAX_SCATTER_MODELS），count 变化重建
	var pile := manager.spawn_drop(dirt, 8, Vector3(2.5, 5.0, 2.5))
	manager.process_drops(0.016)
	var pile_root: Node3D = manager._visuals[2]
	check_eq(pile_root.get_child_count(), DropManager.MAX_SCATTER_MODELS,
			"散布副本数封顶（主模型 + 副本）")
	for child in pile_root.get_children():
		if child.name.begins_with("copy"):
			check(child.position.y >= -0.001, "立方体副本竖直只向上（不嵌地）")
	# 平面副本：躺平后沿 local -z 抬升（世界向上），不嵌地、不倾斜
	var flat_pile := manager.spawn_drop(coal, 8, Vector3(1.5, 5.0, 1.5))
	manager.process_drops(0.016)
	var flat_pile_root: Node3D = manager._visuals[3]
	for child in flat_pile_root.get_children():
		if child.name.begins_with("copy"):
			check(child.position.z <= 0.001,
					"平面副本沿 -z 抬升（平躺后世界向上，不嵌地）")
	pile.count = 2
	manager.process_drops(0.016)
	check_eq(pile_root.get_child_count(), 2, "count 变化重建副本数")
	pile.count = 1
	manager.process_drops(0.016)
	check_eq(pile_root.get_child_count(), 1, "回落单模型")

	# 贴地：模型中心即旋转原点；落地端正站立（仅偏航、底面完全贴地），
	# 空中翻滚才用支撑半径公式定高
	var landed := manager.spawn_drop(dirt, 1, Vector3(4.5, 5.0, 4.5))
	for i in 120:
		manager.process_drops(0.05)
	check(landed.grounded, "贴地测试掉落已落地")
	var landed_root: Node3D = manager._visuals[4]
	check(landed_root.get_child(0).position == Vector3.ZERO,
			"模型中心即旋转原点（绕自身中心翻滚）")
	var settled_theta := snappedf(
			DropManager.TIP_FROM_STANDING + landed.spin_angle, PI / 2.0)
	check(_pose_close(landed_root.quaternion,
			Quaternion(Vector3.UP, landed.spin_phase)
					* Quaternion(Vector3(1.0, 0.0, 0.0), settled_theta)),
			"落地方块面贴地安放（最近 90° 倍数 + 偏航）")
	check(absf(landed_root.position.y - DropVisuals.CUBE_SIZE * 0.5
			- (landed.position.y - ItemDrop.HALF_HEIGHT)) <= 0.0001,
			"落地方块底面完全贴地（支撑半径 = 半边长）")
	check(flat_drop.grounded, "平面物品落地")
	check(_pose_close(manager._visuals[1].quaternion,
			Quaternion(Vector3.UP, flat_drop.spin_phase)
					* Quaternion(Vector3(1.0, 0.0, 0.0),
							DropManager.TIP_FROM_STANDING)),
			"平面物品落地瞬间平贴（theta=90° + 偏航，Mod 行为）")
	check(absf(manager._visuals[1].position.y
			- DropVisuals.FLAT_THICKNESS * 0.5
			- (flat_drop.position.y - ItemDrop.HALF_HEIGHT)) <= 0.0001,
			"平面物品平躺贴地（支撑半径 = 半厚度）")

	# 触地补间：落地瞬间姿态仍介于空中姿态与目标之间，随后到位
	var tween_drop := manager.spawn_drop(dirt, 1, Vector3(6.5, 3.6, 6.5))
	tween_drop.spin_angle = 0.0
	tween_drop.spin_phase = 1.0
	var steps := 0
	while not tween_drop.grounded and steps < 200:
		manager.process_drops(0.05)
		steps += 1
	check(tween_drop.grounded, "补间测试掉落已触地")
	var tween_root: Node3D = manager._visuals[5]
	var tween_target := Quaternion(Vector3.UP, tween_drop.spin_phase) \
			* Quaternion(Vector3(1.0, 0.0, 0.0), snappedf(
					DropManager.TIP_FROM_STANDING + tween_drop.spin_angle,
					PI / 2.0))
	check(not _pose_close(tween_root.quaternion, tween_target),
			"触地瞬间仍在缓动中（角度未到位）")
	for i in 12:  # 0.6s > 缓动时长 0.25s
		manager.process_drops(0.05)
	check(_pose_close(tween_root.quaternion, tween_target),
			"缓动完成：面贴地到位（<= 45° 滚动）")

	# 出生相位随机分布
	var phases := {}
	for i in 24:
		var probe := manager.spawn_drop(coal, 1, Vector3(3.5, 5.0, 3.5))
		phases[probe.spin_phase] = true
	check(phases.size() > 1, "出生相位非恒定（%d 种）" % phases.size())


# ---- 台阶/贴墙碰撞（碰撞足迹 = 视觉足迹，不嵌地）----

func _test_ground_lift(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	# 平台顶 3.0；旁放两个 1 格台阶（顶 4.0）
	world.set_block(Vector3i(5, 3, 8), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(5, 3, 7), VoxelTypes.STONE_ID)

	var manager := DropManager.new()
	manager.setup(world, items)
	var coal := items.id_for_name("core:coal")
	var dirt := items.id_for_name("core:dirt")

	# 平面物品碰撞足迹（对角 ±0.269）压到台阶格 -> 物理直接停台阶顶
	var edge := manager.spawn_drop(coal, 1, Vector3(4.85, 5.0, 8.5))
	for i in 120:
		manager.process_drops(0.05)
	check(edge.grounded, "台阶沿掉落已落地")
	check(absf(edge.position.y - 4.18) <= 0.001,
			"平面足迹压台阶：物理停在台阶顶（y=%.2f）" % edge.position.y)
	var edge_bottom: float = manager._visuals[0].position.y 			- DropVisuals.FLAT_THICKNESS * 0.5
	check(absf(edge_bottom - 4.0) <= 0.01,
			"平躺底面 = 台阶顶（%.2f）" % edge_bottom)

	# 远离台阶：停在平台顶，视觉底面 = 平台顶
	var plain := manager.spawn_drop(coal, 1, Vector3(8.5, 5.0, 8.5))
	for i in 120:
		manager.process_drops(0.05)
	check(absf(plain.position.y - 3.18) <= 0.001, "平地掉落停平台顶")
	var plain_bottom: float = manager._visuals[1].position.y 			- DropVisuals.FLAT_THICKNESS * 0.5
	check(absf(plain_bottom - 3.0) <= 0.01, "平地平躺底面 = 平台顶")

	# 立方体单件支撑半径（±0.125）够不到台阶列 -> 停平台顶；
	# count>1 只加横向阻挡余量（支撑不变），合并后仍停在原地——
	# 旁边的台阶不再被当成落脚面（MC 小盒支撑语义）
	var cube_edge := manager.spawn_drop(dirt, 1, Vector3(4.8, 5.0, 7.5))
	for i in 120:
		manager.process_drops(0.05)
	check(absf(cube_edge.position.y - 3.18) <= 0.001,
			"立方体单件停平台顶")
	cube_edge.count = 5
	for i in 40:
		manager.process_drops(0.05)
	check(absf(cube_edge.position.y - 3.18) <= 0.001,
			"合并后支撑不变仍停原地（不上台阶，y=%.2f）" % cube_edge.position.y)
	# 贴墙：平面物品的碰撞足迹先于视觉撞墙（停在墙外，不插进墙体）
	world.set_block(Vector3i(1, 3, 8), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(1, 4, 8), VoxelTypes.STONE_ID)
	world.set_block(Vector3i(1, 5, 8), VoxelTypes.STONE_ID)
	var wall_probe := manager.spawn_drop(coal, 1, Vector3(3.0, 5.5, 8.5))
	wall_probe.velocity = Vector3(-6.0, 0.0, 0.0)
	for i in 120:
		manager.process_drops(0.05)
	check(wall_probe.position.x - wall_probe.footprint_radius >= 2.0,
			"贴墙停住不进墙体（x=%.2f r=%.2f）" % [
					wall_probe.position.x, wall_probe.footprint_radius])
	check(absf(wall_probe.position.y - 3.18) <= 0.001, "贴墙掉落在墙边落地")

	# 墙角堆叠回归：大足迹（±0.327）伸进墙列，落地/落定都不得把
	# 物品竖直抬上墙（曾表现为堆叠物落到墙角后自动跳到上方一格）
	var stack_wall := manager.spawn_drop(dirt, 5, Vector3(2.2, 5.5, 8.5))
	for i in 120:
		manager.process_drops(0.05)
	check(stack_wall.grounded, "墙角堆叠掉落已落地")
	check(absf(stack_wall.position.y - 3.18) <= 0.001,
			"墙角方块堆叠停在地面（不上墙，y=%.2f）" % stack_wall.position.y)
	var flat_wall := manager.spawn_drop(coal, 5, Vector3(2.2, 5.5, 8.6))
	for i in 120:
		manager.process_drops(0.05)
	check(absf(flat_wall.position.y - 3.18) <= 0.001,
			"墙角平面堆叠停在地面（y=%.2f）" % flat_wall.position.y)


# ---- 管理器：生成与上限 ----

func _test_manager_spawning(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	var manager := DropManager.new()
	manager.setup(world, items)

	# 散射生成：速度向上、数量保留、生成表现子节点
	check(manager.spawn_scatter(
			items.id_for_name("core:dirt"), 5, Vector3(8.5, 5.0, 8.5)),
			"散射生成成功")
	check_eq(manager.drop_count(), 1, "实体计数 1")
	var drop := manager.drop_at(0)
	check(drop.velocity.y > 1.0, "散射初速向上（%.2f）" % drop.velocity.y)
	check_eq(drop.count, 5, "数量保留")
	check_eq(manager.get_child_count(), 1, "每个掉落一个 Sprite3D 子节点")

	# 精确生成 + 非法输入
	check(manager.spawn_drop(items.id_for_name("core:stone"), 2,
			Vector3(8.5, 5.0, 8.5)) != null, "精确生成成功")
	check(manager.spawn_drop(-1, 1, Vector3.ZERO) == null, "非法物品拒绝")
	check(manager.spawn_drop(items.id_for_name("core:dirt"), 0,
			Vector3.ZERO) == null, "零数量拒绝")

	# 上限：填满后拒绝（调用方回退直接入包语义）
	while manager.drop_count() < DropManager.MAX_DROPS:
		if manager.spawn_drop(items.id_for_name("core:dirt"), 1,
				Vector3(8.5, 5.0, 8.5)) == null:
			break
	check_eq(manager.drop_count(), DropManager.MAX_DROPS, "实体数达上限")
	check(manager.spawn_scatter(items.id_for_name("core:dirt"), 1,
			Vector3(8.5, 5.0, 8.5)) == false, "超上限散射被拒绝")
	check(manager.spawn_drop(items.id_for_name("core:dirt"), 1,
			Vector3(8.5, 5.0, 8.5)) == null, "超上限精确生成拒绝")


# ---- 管理器：区块未就绪冻结 ----

func _test_manager_freeze(ctx: Dictionary) -> void:
	var items: ItemRegistry = ctx["items"]
	var blocks: VoxelRegistry = ctx["blocks"]
	var config := WorldConfig.new()
	var world := VoxelWorld.new(config, blocks)
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16), 1)
	chunk.set_block_raw(Vector3i(8, 1, 8), VoxelTypes.STONE_ID)
	world.add_chunk(chunk)  # 默认 UNLOADED（非 ACTIVE）

	var manager := DropManager.new()
	manager.setup(world, items)
	var spawn_at := Vector3(8.5, 5.0, 8.5)
	manager.spawn_drop(items.id_for_name("core:dirt"), 3, spawn_at)
	manager.process_drops(0.1)
	manager.process_drops(0.1)
	var drop := manager.drop_at(0)
	check(drop.position.is_equal_approx(spawn_at), "区块未就绪位置冻结")
	check(drop.age == 0.0, "冻结期间年龄不推进（不场外消散）")

	chunk.state = ChunkState.State.DATA_READY
	manager.process_drops(0.1)
	check(drop.age == 0.0, "DATA_READY 仍未激活")

	chunk.state = ChunkState.State.ACTIVE
	for i in 120:
		manager.process_drops(0.05)
	check(drop.age > 1.0, "激活后年龄推进")
	check(drop.grounded, "激活后正常下落触地（石块顶 + 半高 %.2f）" % drop.position.y)
	check(absf(drop.position.y - 2.18) <= 0.001, "落在单块石头顶面")


# ---- 管理器：拾取（含满包/部分入包）----

func _test_manager_pickup(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	var dirt := items.id_for_name("core:dirt")
	var stone := items.id_for_name("core:stone")

	var manager := DropManager.new()
	manager.setup(world, items)
	var inv := Inventory.new(items, 24, 12)
	manager.pickup_inventory = inv
	var player := Node3D.new()
	player.position = Vector3(8.5, 4.18, 8.5)
	manager.pickup_target = player

	# 命中即拾取
	manager.spawn_drop(dirt, 5, player.position, Vector3.ZERO, 0.0)
	manager.process_drops(0.016)
	check_eq(manager.drop_count(), 0, "贴近掉落即被拾取")
	check_eq(inv.count_of(dirt), 5, "拾取入包")

	# 保护期内不拾取，期满自动拾取
	manager.spawn_drop(dirt, 2, player.position, Vector3.ZERO, 0.5)
	manager.process_drops(0.016)
	check_eq(manager.drop_count(), 1, "保护期内不拾取")
	for i in 40:
		manager.process_drops(0.016)
	check_eq(manager.drop_count(), 0, "保护期满自动拾取")

	# 满包：不拾取，掉落原地保留（独立管理器，避免上面的掉落串场）
	var manager2 := DropManager.new()
	manager2.setup(world, items)
	var full := Inventory.new(items, 2, 2)
	full.add(dirt, 64)
	full.add(dirt, 64)
	manager2.pickup_inventory = full
	manager2.pickup_target = player
	manager2.spawn_drop(stone, 3, player.position, Vector3.ZERO, 0.0)
	for i in 10:
		manager2.process_drops(0.016)
	check_eq(manager2.drop_count(), 1, "满包掉落保留")
	check_eq(full.count_of(stone), 0, "满包不吞物品")

	# 总空间不足的部分入包：同类堆装到满，剩余留在掉落里
	#（Inventory.add 会开新堆，所以只有整包无空格时才会留余量）
	var partial := Inventory.new(items, 2, 2)
	partial.add(dirt, 60)
	partial.add(stone, 64)  # 占住第二格，只剩同类 4 格空间
	var manager3 := DropManager.new()
	manager3.setup(world, items)
	manager3.pickup_inventory = partial
	manager3.pickup_target = player
	manager3.spawn_drop(dirt, 10, player.position, Vector3.ZERO, 0.0)
	for i in 3:
		manager3.process_drops(0.016)
	check_eq(partial.count_of(dirt), 64, "同类堆装满到 64")
	check_eq(manager3.drop_count(), 1, "剩余仍在地面")
	check_eq(manager3.drop_at(0).count, 6, "掉落余量 6")

	# Inventory.can_fit 配套语义
	check(not partial.can_fit(dirt, 1), "同类无空间 can_fit false")
	check(not partial.can_fit(stone, 1), "满包他类也 false")
	var fresh := Inventory.new(items, 1, 1)
	check(fresh.can_fit(dirt, 64), "单空格可放整堆")
	check(not fresh.can_fit(dirt, 65), "单格装不下 65")
	check(not partial.can_fit(dirt, 0), "零数量恒 false")

	player.free()


# ---- 管理器：合并与消散 ----

func _test_manager_merge(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	var dirt := items.id_for_name("core:dirt")
	var stone := items.id_for_name("core:stone")

	var manager := DropManager.new()
	manager.setup(world, items)

	# 同类近距离合并
	manager.spawn_drop(dirt, 5, Vector3(8.5, 5.0, 8.5), Vector3.ZERO, 999.0)
	manager.spawn_drop(dirt, 7, Vector3(8.6, 5.0, 8.5), Vector3.ZERO, 999.0)
	manager.process_drops(DropManager.MERGE_INTERVAL + 0.01)
	check_eq(manager.drop_count(), 1, "同类掉落合并为一")
	check_eq(manager.drop_at(0).count, 12, "合并数量累加")

	# 异类不合并
	manager.spawn_drop(stone, 3, Vector3(8.55, 5.0, 8.5), Vector3.ZERO, 999.0)
	manager.process_drops(DropManager.MERGE_INTERVAL + 0.01)
	check_eq(manager.drop_count(), 2, "异类掉落不合并")

	# 超堆合并：溢出留在另一方
	var overflow := DropManager.new()
	overflow.setup(world, items)
	overflow.spawn_drop(dirt, 60, Vector3(8.5, 5.0, 8.5), Vector3.ZERO, 999.0)
	overflow.spawn_drop(dirt, 60, Vector3(8.6, 5.0, 8.5), Vector3.ZERO, 999.0)
	overflow.process_drops(DropManager.MERGE_INTERVAL + 0.01)
	check_eq(overflow.drop_count(), 2, "超堆保留两实体")
	var counts := [overflow.drop_at(0).count, overflow.drop_at(1).count]
	check(counts.has(64) and counts.has(56), "超堆合并 64 + 56（%s）" % str(counts))

	# 远距离不合并
	var apart := DropManager.new()
	apart.setup(world, items)
	apart.spawn_drop(dirt, 5, Vector3(1.5, 5.0, 1.5), Vector3.ZERO, 999.0)
	apart.spawn_drop(dirt, 5, Vector3(8.5, 5.0, 8.5), Vector3.ZERO, 999.0)
	apart.process_drops(DropManager.MERGE_INTERVAL + 0.01)
	check_eq(apart.drop_count(), 2, "远距离不合并")

	# 消散：活跃年龄满时长移除
	var aging := DropManager.new()
	aging.setup(world, items)
	aging.spawn_drop(dirt, 5, Vector3(8.5, 5.0, 8.5), Vector3.ZERO, 999.0)
	aging.drop_at(0).age = ItemDrop.DESPAWN_SECONDS - 0.05
	aging.process_drops(0.016)
	check_eq(aging.drop_count(), 1, "未满时长保留")
	aging.drop_at(0).age = ItemDrop.DESPAWN_SECONDS
	aging.process_drops(0.016)
	check_eq(aging.drop_count(), 0, "满时长消散移除")


# ---- 管理器：存档往返 ----

func _test_manager_persistence(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	var dirt := items.id_for_name("core:dirt")
	var pickaxe := items.id_for_name("core:wooden_pickaxe")

	var source := DropManager.new()
	source.setup(world, items)
	source.spawn_drop(dirt, 9, Vector3(1.5, 4.0, 2.5),
			Vector3(0.5, 1.0, -0.5), 0.3)
	source.spawn_drop(pickaxe, 1, Vector3(-3.5, 7.0, 0.5), Vector3.ZERO, 1.2)
	var bundle := source.get_save_bundle()
	check(bundle.has("drops") and bundle["drops"].size() == 2, "存档包 2 条掉落")

	var restored_mgr := DropManager.new()
	restored_mgr.setup(world, items)
	check_eq(restored_mgr.apply_save_state(bundle["drops"]), 2, "全部恢复")
	check_eq(restored_mgr.drop_count(), 2, "恢复后实体计数")
	var first := restored_mgr.drop_at(0)
	check_eq(first.item_id, dirt, "恢复物品身份")
	check_eq(first.count, 9, "恢复数量")
	check(first.position.is_equal_approx(Vector3(1.5, 4.0, 2.5)), "恢复位置")
	check(first.velocity.is_equal_approx(Vector3(0.5, 1.0, -0.5)), "恢复速度")
	check(absf(first.pickup_delay - 0.3) <= 0.001, "恢复保护期")

	# 容错：未知物品 / 非字典 / 坏坐标跳过，超堆截断
	var mixed: Array = bundle["drops"].duplicate()
	mixed.append({"item": "core:gone", "count": 1,
			"pos": [0, 0, 0], "vel": [0, 0, 0]})
	mixed.append("junk")
	mixed.append({"item": "core:dirt", "count": 2, "pos": [1, 2]})
	var tolerant := DropManager.new()
	tolerant.setup(world, items)
	check_eq(tolerant.apply_save_state(mixed), 2, "坏数据跳过好数据恢复")
	check_eq(tolerant.drop_count(), 2, "坏数据不计入实体")


# ---- world.json 扩展键 ----

func _test_save_extra_keys(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var blocks: VoxelRegistry = ctx["blocks"]
	var save := WorldSave.new(TMP_SAVE_ROOT, blocks)
	save.erase_all()

	check(save.save_meta(world, {}, {
			"drops": [{"item": "core:dirt", "count": 3}],
			"world_seed": 999,  # 保留键：必须被拒绝
		}), "带扩展键保存成功")
	var meta := save.load_meta()
	check(meta.has("drops"), "扩展键 drops 持久化")
	check_eq(meta["world_seed"], 42, "保留键不被扩展覆盖")
	var drops: Array = meta["drops"]
	check_eq(drops.size(), 1, "掉落数据原样读回")

	# 旧式调用（无 extra）不受影响
	check(save.save_meta(world, {}), "无扩展键保存成功")
	var plain := save.load_meta()
	check(not plain.has("extra"), "无扩展键时元数据干净")
	check(plain.has("player_state"), "原有键不受影响")
	save.erase_all()


# ---- 水中物理（v4：浮水物品上浮、重物缓沉）----

func _test_water_physics(ctx: Dictionary) -> void:
	var world: VoxelWorld = ctx["world"]
	var items: ItemRegistry = ctx["items"]
	# 在平台上造一柱水：(8, 3..6, 2) 全水，上方空气
	for y in range(3, 7):
		world.set_block(Vector3i(8, y, 2), VoxelTypes.WATER_ID)

	# 木棍（浮水）：水中缓慢上浮
	var stick := ItemDrop.new()
	stick.item_id = items.id_for_name("core:stick")
	stick.floats = true
	stick.position = Vector3(8.5, 3.5, 2.5)
	for i in 30:
		stick.physics_step(world, 0.05)
	check(stick.position.y > 3.5, "浮水物品在水中上浮（%.2f）" % stick.position.y)
	# 直接限速跟随方案（随波起伏）：竖直速度恒零，上浮以位置推进
	check(stick.position.y < 6.8, "仍在向水面途中（未冒顶）")

	# 泥土（重物）：水中缓沉且不超过水终端速度
	var dirt := ItemDrop.new()
	dirt.item_id = items.id_for_name("core:dirt")
	dirt.floats = false
	dirt.position = Vector3(8.5, 5.5, 2.5)
	dirt.velocity = Vector3(0.0, -10.0, 0.0)
	for i in 20:
		dirt.physics_step(world, 0.05)
	check(dirt.position.y < 5.5, "重物在水中下沉（%.2f）" % dirt.position.y)
	check(dirt.velocity.y >= -ItemDrop.WATER_TERMINAL - 0.01,
			"水中下沉被终端速度限制（%.2f）" % dirt.velocity.y)

	# 管理器置入的 floats 分类正确（木制品浮、石制品沉）
	var manager := DropManager.new()
	manager.setup(world, items)
	var stick_drop := manager.spawn_drop(
			items.id_for_name("core:stick"), 1, Vector3(8.5, 4.5, 2.5))
	check(stick_drop.floats, "管理器判定木棍浮水")
	var stone_drop := manager.spawn_drop(
			items.id_for_name("core:stone"), 1, Vector3(8.5, 4.5, 2.5))
	check(not stone_drop.floats, "管理器判定石头沉水")

	# 水柱清理（不污染后续测试）
	for y in range(3, 7):
		world.set_block(Vector3i(8, y, 2), VoxelTypes.AIR_ID)
