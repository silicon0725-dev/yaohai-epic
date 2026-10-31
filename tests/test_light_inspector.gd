## 光照探查插件内核测试：编辑器侧世界重建、光照收敛不动点、
## DDA 探针、挖掘增量 vs 全量收敛等价、热力图网格、存档回读。
## （编辑器 UI 层无法 headless 测——与游戏同代码的数据层全部覆盖。）
extends VoxelTestCase

const Rebuilder := preload("res://addons/voxel_light_inspector/world_rebuilder.gd")
const HeatBuilder := preload("res://addons/voxel_light_inspector/heat_mesh_builder.gd")
const VoxelTypesScript := preload("res://core/voxel_types.gd")
const VoxelCoordsScript := preload("res://core/voxel_coords.gd")
const TreeGeneratorScript := preload("res://systems/trees/tree_generator.gd")
const WorldSaveScript := preload("res://persistence/world_save.gd")

const TEST_SEED := 1337
const SAVE_ROOT := "user://voxel_light_inspector_test"


func run() -> void:
	_test_rebuild_and_light()
	_test_dig_incremental_matches_full()
	_test_probe()
	_test_heat_mesh()
	_test_save_roundtrip()


## 重建 radius 半径世界（center 中心区块）并做光照收敛。
func _build(radius: int, center := Vector2i.ZERO) -> Dictionary:
	var ctx: Dictionary = Rebuilder.load_world_context("user://li_test_no_such_save")
	var bw: Dictionary = Rebuilder.build_world(ctx)
	var coords: Array = Rebuilder.range_coords(
			radius, center, int(ctx["config"].chunks_y))
	for coord in coords:
		Rebuilder.fill_chunk(bw["world"], bw["generator"], ctx["save"], coord, false)
	Rebuilder.converge_light(bw["world"], bw["light"])
	return {"ctx": ctx, "bw": bw}


## 选一根光照语义可靠的测试列：无树、内地格（非区块边界）、
## 地表 9..36（海平面以上、山线以下）、非裸岩。
func _pick_column(generator) -> Vector2i:
	for wx in range(1, 48):
		for wz in range(1, 48):
			if posmod(wx, 16) == 0 or posmod(wz, 16) == 0:
				continue
			if TreeGeneratorScript.has_tree_at(TEST_SEED, Vector2i(wx, wz)):
				continue
			var prof: Dictionary = generator.column_profile(wx, wz)
			var h := int(prof["height"])
			if h >= 9 and h <= 36 and not bool(prof["rocky"]):
				return Vector2i(wx, wz)
	return Vector2i(-1, -1)


func _test_rebuild_and_light() -> void:
	var built := _build(1)
	var world = built["bw"]["world"]
	var generator = built["bw"]["generator"]
	var config = built["ctx"]["config"]
	check_eq(world.chunk_count(), 27, "半径 1 重建 27 区块（3×3×3）")
	check_eq(int(config.world_seed), TEST_SEED, "无存档时用游戏默认种子")

	var col := _pick_column(generator)
	check(col.x >= 0, "存在满足规则的测试列")
	if col.x < 0:
		return
	var h := int(generator.column_profile(col.x, col.y)["height"])

	var top := Rebuilder.light_at(world, Vector3i(
			col.x, int(config.world_height_blocks()) - 1, col.y))
	check_eq(int(top["sky"]), 15, "世界顶部露天格天光 15")
	var above := Rebuilder.light_at(world, Vector3i(col.x, h + 1, col.y))
	check_eq(int(above["sky"]), 15, "无树列地表上格天光 15（垂直直射）")
	var deep := Rebuilder.light_at(world, Vector3i(col.x, 1, col.y))
	check_eq(int(deep["sky"]), 0, "深层地下天光 0")

	var center_chunk = world.get_chunk(Vector3i(0, 0, 0))
	var all_blk_zero := true
	for i in center_chunk.light.size():
		if (center_chunk.light[i] & 0x0F) != 0:
			all_blk_zero = false
			break
	check(all_blk_zero, "无光源世界方块光全 0")
	check_eq(Rebuilder.converge_light(world, built["bw"]["light"]), 1,
			"收敛后重复迭代无变化（返回 1 轮）")


func _test_dig_incremental_matches_full() -> void:
	var built := _build(1)
	var world = built["bw"]["world"]
	var generator = built["bw"]["generator"]
	var col := _pick_column(generator)
	check(col.x >= 0, "挖掘测试列存在")
	if col.x < 0:
		return
	var h := int(generator.column_profile(col.x, col.y)["height"])

	var pos := Vector3i(col.x, h, col.y)
	check(world.set_block(pos, VoxelTypesScript.AIR_ID), "经 world.set_block 挖开地表")
	var lv := Rebuilder.light_at(world, pos)
	check_eq(int(lv["sky"]), 15, "挖开后该格直射天光 15（游戏增量路径）")

	# 等价性：游戏增量更新后的光场 == 全量收敛重算的光场（逐字节）
	var chunk = world.get_chunk(VoxelCoordsScript.world_to_chunk(pos, 16))
	var incremental: PackedByteArray = chunk.light.duplicate()
	Rebuilder.converge_light(world, built["bw"]["light"])
	check_eq(chunk.light, incremental, "挖掘增量更新与全量收敛逐字节一致")


func _test_probe() -> void:
	var built := _build(1)
	var world = built["bw"]["world"]
	var generator = built["bw"]["generator"]
	var col := _pick_column(generator)
	check(col.x >= 0, "探针测试列存在")
	if col.x < 0:
		return
	var h := int(generator.column_profile(col.x, col.y)["height"])

	var hit: Dictionary = Rebuilder.probe(
			world,
			Vector3(float(col.x) + 0.5, 60.0, float(col.y) + 0.5),
			Vector3(0, -1, 0))
	check(bool(hit.get("hit", false)), "垂直下探命中")
	if bool(hit.get("hit", false)):
		check_eq(Vector3i(hit["block_pos"]), Vector3i(col.x, h, col.y), "命中地表块")
		check_eq(Vector3i(hit["face_pos"]), Vector3i(col.x, h + 1, col.y),
				"命中面外格为地表上格")
		check(int(hit["block_id"]) != VoxelTypesScript.AIR_ID, "命中非空气")
		check_eq(int(hit["cell_sky"]), 0, "实心命中格天光 0")
		check_eq(int(hit["face_sky"]), 15, "命中面外格天光 15")
		check(hit.get("chunk") != null, "探针携带所属区块引用")

	var miss: Dictionary = Rebuilder.probe(
			world, Vector3(0.5, 49.5, 0.5), Vector3(0, 1, 0))
	check(miss.is_empty(), "朝天射线未命中返回空")


func _test_heat_mesh() -> void:
	# 找一棵已知树，以其区块为中心重建（树荫产生 1-14 天光格）
	var tree_col := Vector2i(-1, -1)
	for wx in range(0, 160):
		for wz in range(0, 160):
			if TreeGeneratorScript.has_tree_at(TEST_SEED, Vector2i(wx, wz)):
				tree_col = Vector2i(wx, wz)
				break
		if tree_col.x >= 0:
			break
	check(tree_col.x >= 0, "种子下存在树列")
	var center := Vector2i(
			VoxelCoordsScript.floordiv(tree_col.x, 16),
			VoxelCoordsScript.floordiv(tree_col.y, 16))
	var built := _build(1, center)
	var world = built["bw"]["world"]

	var result: Dictionary = HeatBuilder.build(world, {
		"sky": true, "block": true, "min_level": 1, "max_level": 14,
		"borders": true,
	})
	check(int(result["cubes"]) > 0, "热力图有立方体（树荫/梯度 1-14 天光格存在）")
	var heat = result["heat"]
	check(heat != null, "热力图网格非空")
	if heat != null:
		check_eq((heat as ArrayMesh).get_surface_count(), 1, "热力图单表面")
	var border = result["border"]
	check(border != null, "边框网格非空")
	if border != null:
		var bl: PackedVector3Array = (border as ArrayMesh).surface_get_arrays(0)[
				Mesh.ARRAY_VERTEX]
		check_eq(bl.size(), world.chunk_count() * 24, "每区块 24 边框顶点")


func _test_save_roundtrip() -> void:
	var registry = VoxelTypesScript.build_default_registry()
	var ws = WorldSaveScript.new(SAVE_ROOT, registry)
	ws.erase_all()
	ws.ensure_dirs()

	var ctx: Dictionary = Rebuilder.load_world_context(SAVE_ROOT)
	var bw: Dictionary = Rebuilder.build_world(ctx)
	for coord in Rebuilder.range_coords(0, Vector2i.ZERO, 3):
		Rebuilder.fill_chunk(bw["world"], bw["generator"], ctx["save"], coord, false)

	var target := Vector3i(3, 7, 3)
	check(bw["world"].set_block(target, VoxelTypesScript.SANDSTONE_ID), "写入测试方块")
	check(ws.save_chunk(bw["world"].get_chunk(Vector3i(0, 0, 0))), "区块存档写入")

	# 全新上下文回读：存档应覆盖确定性生成
	var ctx2: Dictionary = Rebuilder.load_world_context(SAVE_ROOT)
	var bw2: Dictionary = Rebuilder.build_world(ctx2)
	var fr: Dictionary = Rebuilder.fill_chunk(
			bw2["world"], bw2["generator"], ctx2["save"], Vector3i(0, 0, 0), true)
	check_eq(String(fr["source"]), "save", "回读来源为存档")
	check_eq(bw2["world"].get_block(target), VoxelTypesScript.SANDSTONE_ID,
			"存档改动在世界重建后保留")

	ws.erase_all()
