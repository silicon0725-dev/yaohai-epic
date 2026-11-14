## 火把实体渲染器单元测试：放置/拆除的实体生命周期、贴墙偏移、
## 区块激活扫描重建（chunk cross 路径改实体渲染的守卫）。
extends VoxelTestCase

const TorchRendererScript := preload("res://presentation/torch_renderer.gd")


func _make_world() -> VoxelWorld:
	return make_world(4, [Vector3i.ZERO])


func _make_renderer(world: VoxelWorld) -> Node:
	var r: Node = TorchRendererScript.new()
	if tree_root != null:
		tree_root.add_child(r)
	r.setup(world, VoxelTypes.TORCH_ID)
	return r


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	_test_spawn_despawn_on_change()
	_test_attach_offset()
	_test_chunk_active_scan()
	_test_flame_surface()
	_test_multimesh_lifecycle()


## 放置 -> 实体出现；拆除 -> 实体移除
func _test_spawn_despawn_on_change() -> void:
	var world := _make_world()
	var r := _make_renderer(world)
	check_eq(r.count(), 0, "初始无实体")
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.TORCH_ID)
	r._spawn_deferred(Vector3i(2, 1, 2))  # 延迟入口（无帧泵）
	check_eq(r.count(), 1, "放置后实体出现")
	world.set_block(Vector3i(2, 1, 2), VoxelTypes.AIR_ID)
	check_eq(r.count(), 0, "拆除后实体移除")
	r.free()


## 墙挂偏移：attach 状态写入后实体位置带 -attach*6/16
func _test_attach_offset() -> void:
	var world := _make_world()
	var r := _make_renderer(world)
	world.set_block(Vector3i(2, 2, 2), VoxelTypes.TORCH_ID)
	world.set_block_state(Vector3i(2, 2, 2), "attach", "1,0,0", true)
	# 实际链路：block_changed 延迟到帧末生成（读到 attach）。单测无帧
	# 泵——直接调延迟入口验证（含状态读取）；已存在时重定位
	r._spawn_deferred(Vector3i(2, 2, 2))
	var mi: MeshInstance3D = r._by_cell.get(Vector3i(2, 2, 2))
	check(mi != null, "实体存在")
	if mi != null:
		check(absf(mi.position.x - (2.0 - 6.0 / 16.0)) < 0.001,
				"贴墙偏移 x=-6/16（实际 %s）" % mi.position.x)
	r.free()


## 区块激活扫描：已存在方块表的火把补建实体（存档恢复路径）
func _test_chunk_active_scan() -> void:
	var world := _make_world()
	world.set_block(Vector3i(1, 1, 1), VoxelTypes.TORCH_ID)
	var r := _make_renderer(world)
	# setup 后 block_changed 已错过（方块先于渲染器存在）——扫描补建
	check_eq(r.count(), 0, "扫描前无实体")
	r.on_chunk_active(Vector3i.ZERO)
	check_eq(r.count(), 1, "激活扫描补建实体")
	r.on_chunk_unloaded(Vector3i.ZERO)
	check_eq(r.count(), 0, "卸载清除实体")
	r.free()


## 火焰面守卫：三表面（棍/炭头/火焰体），火焰体是盒网格（体积
## raymarch 着色器）带 ShaderMaterial
func _test_flame_surface() -> void:
	var world := _make_world()
	var r := _make_renderer(world)
	var mesh: ArrayMesh = r._mesh
	check_eq(mesh.get_surface_count(), 3, "三表面：棍+炭头+火焰体")
	var mat: ShaderMaterial = mesh.surface_get_material(2)
	check(mat != null and mat is ShaderMaterial and mat.shader != null,
			"火焰体是 ShaderMaterial")
	if mat != null and mat.shader != null:
		check_eq(mat.get_shader_parameter("energy"), 1.0, "火焰 energy 初值")
	var arrays: Array = mesh.surface_get_arrays(2)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	check_eq(verts.size(), 24, "火焰体盒网格 24 顶点")
	r.free()


## MultiMesh 路径（审查二轮 C8）：spawn/despawn 的末位交换保序、
## 重定位不涨实例数、贴墙偏移进 transform。断言读本地镜像
##（_xforms_by_index）——headless 下 MultiMesh 的 get_instance_transform
## 是渲染服务器存根（读写全零），真机下镜像与 _mm 双写一致
func _test_multimesh_lifecycle() -> void:
	var world := _make_world()
	var r: Node = TorchRendererScript.new()
	if tree_root != null:
		tree_root.add_child(r)
	r.setup(world, VoxelTypes.TORCH_ID, true)
	for x in 3:
		world.set_block(Vector3i(x, 1, 0), VoxelTypes.TORCH_ID)
		r._spawn_deferred(Vector3i(x, 1, 0))
	check_eq(r.count(), 3, "三实例")
	check_eq(r._mm.instance_count, 3, "实例缓冲 3")
	# 拆中间那支：末位实例交换到空槽，缓冲收缩
	world.set_block(Vector3i(1, 1, 0), VoxelTypes.AIR_ID)
	check_eq(r.count(), 2, "拆除后 2 实例")
	check_eq(r._mm.instance_count, 2, "实例缓冲收缩 2")
	var t0: Transform3D = r._xforms_by_index[0]
	check(absf(t0.origin.x) < 0.001 and absf(t0.origin.z) < 0.001,
			"槽 0 位置保持")
	check_eq(r._by_cell.get(Vector3i(2, 1, 0), -1), 1, "末位实例换到槽 1")
	var t1: Transform3D = r._xforms_by_index[1]
	check(absf(t1.origin.x - 2.0) < 0.001, "槽 1 是原末位位置")
	# attach 后补的重定位：原地更新 transform，实例数不涨
	world.set_block_state(Vector3i(2, 1, 0), "attach", "1,0,0", true)
	r._spawn_deferred(Vector3i(2, 1, 0))
	check_eq(r._mm.instance_count, 2, "重定位不涨实例数")
	var t1b: Transform3D = r._xforms_by_index[1]
	check(absf(t1b.origin.x - (2.0 - 6.0 / 16.0)) < 0.001,
			"重定位带贴墙偏移（实际 %s）" % t1b.origin.x)
	r.free()
