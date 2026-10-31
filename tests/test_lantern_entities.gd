## 提灯实体渲染器单元测试：放置/拆除生命周期、区块激活扫描重建
##（BlockEntityRenderer 基类管线 + MC 模型加载路径的存档恢复守卫）。
## 无 Pastoral 包环境下走程序化回退模型——测试不依赖外部目录。
extends VoxelTestCase

const LanternRendererScript := preload("res://presentation/lantern_renderer.gd")


func _make_world() -> VoxelWorld:
	return make_world(4, [Vector3i.ZERO])


func _make_renderer(world: VoxelWorld) -> Node:
	var r: Node = LanternRendererScript.new()
	if tree_root != null:
		tree_root.add_child(r)
	r.setup(world, VoxelTypes.LANTERN_ID)
	return r


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	_test_spawn_despawn()
	_test_chunk_active_scan()
	_test_model_present()
	_test_placement_floor_only()
	_test_block_light()


## 放置 -> 实体出现；拆除 -> 实体移除（基类管线）
func _test_spawn_despawn() -> void:
	var world := _make_world()
	var r := _make_renderer(world)
	check_eq(r.count(), 0, "初始无实体")
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.LANTERN_ID)
	r._spawn_deferred(Vector3i(2, 1, 2))  # 延迟入口（无帧泵）
	check_eq(r.count(), 1, "放置后实体出现")
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.AIR_ID)
	check_eq(r.count(), 0, "拆除后实体移除")
	r.free()


## 区块激活扫描：方块表已存在时补建实体（存档恢复路径）
func _test_chunk_active_scan() -> void:
	var world := _make_world()
	world.set_block(Vector3i(1, 1, 1), VoxelTypes.LANTERN_ID)
	var r := _make_renderer(world)
	check_eq(r.count(), 0, "扫描前无实体")
	r.on_chunk_active(Vector3i.ZERO)
	check_eq(r.count(), 1, "激活扫描补建实体")
	r.on_chunk_unloaded(Vector3i.ZERO)
	check_eq(r.count(), 0, "卸载清除实体")
	r.free()


## 模型守卫：无论包存在与否都给出可用网格（回退 4 盒件）
func _test_model_present() -> void:
	var world := _make_world()
	var r := _make_renderer(world)
	var mesh: Mesh = r._mesh
	check(mesh != null, "模型网格存在")
	if mesh is ArrayMesh:
		check((mesh as ArrayMesh).get_surface_count() >= 1,
				"至少 1 个表面")
	r.free()


## 放置规则：落地可放（下方 collision 固体）；无地面且非墙面 -> 拒绝
##（提灯不做墙挂）
func _test_placement_floor_only() -> void:
	var world := _make_world()
	# make_world 通常带实心底；确保 (2,0,2) 下方有地面
	world.set_block(Vector3i(2, 0, 2), VoxelTypes.STONE_ID)
	var far_aabb := AABB(Vector3(1000, 1000, 1000), Vector3.ONE)
	check(BlockPlacement.place(world, Vector3i(2, 1, 2),
			VoxelTypes.LANTERN_ID, far_aabb, Vector3i.UP),
			"落地提灯可放置")
	check(world.get_block(Vector3i(2, 1, 2)) == VoxelTypes.LANTERN_ID,
			"方块已写入")
	# 侧向点击且下方无支撑 -> 拒绝（无墙挂）
	world.set_block(Vector3i(2, 0, 2), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.AIR_ID)
	world.set_block(Vector3i(2, 2, 2), VoxelTypes.STONE_ID)
	check(not BlockPlacement.place(world, Vector3i(2, 2, 2) + Vector3i(1, 0, 0),
			VoxelTypes.LANTERN_ID, far_aabb, Vector3i(1, 0, 0)),
			"无地面侧放拒绝（提灯不墙挂）")


## 方块光：放置后本格 15、上方 14、同层隔 2 格 13（发光 15 传播守卫）
func _test_block_light() -> void:
	var world := _make_world()
	activate_light(world, Vector3i.ZERO)
	check(world.set_block(Vector3i(1, 1, 1), VoxelTypes.LANTERN_ID),
			"提灯放置")
	var chunk: ChunkData = world.chunks.get(Vector3i.ZERO)
	check_eq(chunk.get_block_light(Vector3i(1, 1, 1)), 15, "光源格光 15")
	check_eq(chunk.get_block_light(Vector3i(1, 2, 1)), 14, "上方格光 14")
	check_eq(chunk.get_block_light(Vector3i(3, 1, 1)), 13,
			"同层隔 2 格光 13（衰减 2）")
	check_eq(VoxelTypes.light_emission(VoxelTypes.LANTERN_ID), 15,
			"发射表登记 15")
