## 远景山壳测试：C# 四环金字塔 mesh 几何（surface/顶点/海平面压平/
## 环带边界无缝）、GD 壳节点构建流程（worker 产 mesh + 重建步进）。
extends VoxelTestCase

const Bridge := preload("res://meshing/native_terrain_bridge.gd")
const ShellScript := preload("res://presentation/distant_shell.gd")


func run() -> void:
	_test_shell_mesh_geometry()
	await _test_shell_node_build()


## C# GenerateShellMesh 纯几何验证（不依赖场景树）。
func _test_shell_mesh_geometry() -> void:
	if not Bridge.available():
		check(false, "C# 原生可用（壳只走 C# 路径）")
		return
	var native = Bridge.get_native(1337, 48)
	check(native != null, "取得 NativeTerrain 实例")
	var mesh: Mesh = native.GenerateShellMesh(32, 32)
	check(mesh != null, "壳 mesh 生成非空")
	if mesh == null:
		return
	check_eq(mesh.get_surface_count(), 4, "四环带各一 surface")
	var total_v := 0
	for si in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		total_v += v.size()
		check(v.size() > 0 and idx.size() == v.size() / 2 * 6 - 0
				or idx.size() > 0, "环带 %d 索引非空" % si)
		check(cols.size() == v.size(), "环带 %d 顶点色齐备" % si)
		# 海平面压平：海列顶点 y == SEA_LEVEL-0.1（6.9 伪水面）；
		# 陆列裙边下沉 2 格——滩涂最低 h=8 → 6.0 是设计内下界，
		# 断言抓的是塌陷异常（算法错时洞穴/低谷会打出 y≤5）
		var sea_v := 0
		var min_y := 1e9
		for i in v.size():
			min_y = minf(min_y, v[i].y)
			if absf(v[i].y - 6.9) < 0.05:
				sea_v += 1
		check(min_y >= 5.95, "环带 %d 无深度塌陷顶点（min %.2f）"
				% [si, min_y])
		if si == 3:
			check(sea_v > 0, "最外环存在海面顶点（%d）" % sea_v)
	# 总量与环表一致：4×(rows+1)×512；AABB 覆盖 2×4096
	check(total_v >= 130000 and total_v <= 140000,
			"金字塔顶点总量（%d，预算 ~13.5 万）" % total_v)
	var aabb: AABB = mesh.get_aabb()
	check(aabb.size.x >= 8100.0 and aabb.size.z >= 8100.0,
			"壳 AABB 覆盖 ~8192 格（%.0f）" % aabb.size.x)
	# 环带缝：surf0 最外行（r=68，半径 240+68*4=512）与 surf1 最内行
	#（r=0，半径 512）顶点逐点重合（统一 512 扇区 + 整除环表）
	var a0: Array = mesh.surface_get_arrays(0)
	var a1: Array = mesh.surface_get_arrays(1)
	var v0: PackedVector3Array = a0[Mesh.ARRAY_VERTEX]
	var v1: PackedVector3Array = a1[Mesh.ARRAY_VERTEX]
	var w := 512
	var mismatches := 0
	for s in 16:
		var p0: Vector3 = v0[68 * w + (s * 31) % w]
		var p1: Vector3 = v1[(s * 31) % w]
		if p0.distance_to(p1) > 0.01:
			mismatches += 1
	check_eq(mismatches, 0, "环带边界顶点逐点重合（0-1 环）")


## GD 壳节点：setup 后首帧触发 worker 构建，mesh 就位；跨 64 格
## 触发重建（headless 下 worker 池与 physics 帧均可用）。
func _test_shell_node_build() -> void:
	if not Bridge.available():
		return
	var shell = ShellScript.new()
	tree_root.add_child(shell)
	var world = load("res://world/voxel_world.gd").new(
			load("res://core/world_config.gd").new(),
			load("res://core/voxel_types.gd").build_default_registry())
	var player := Node3D.new()
	var cam := Camera3D.new()
	player.add_child(cam)
	tree_root.add_child(player)
	shell.setup(world, player, null)
	player.global_position = Vector3(32, 20, 32)
	var mesh_inst: MeshInstance3D = shell.get_child(0)
	check(mesh_inst.mesh == null, "构建前 mesh 为空")
	# 等 worker（构建 ~0.2s）+ 主线程提交（_physics_process）
	for i in 300:
		await tree_root.get_tree().physics_frame
		if mesh_inst.mesh != null:
			break
	check(mesh_inst.mesh != null, "worker 构建后 mesh 就位")
	if mesh_inst.mesh != null:
		check(mesh_inst.mesh.get_surface_count() == 4, "节点 mesh 四环带")
	# 玩家跨 64 格：触发重建（等第二轮中心变化）
	var first_center: Vector2i = shell._center
	player.global_position = Vector3(32 + 96, 20, 32)
	for i in 300:
		await tree_root.get_tree().physics_frame
		if shell._center != first_center:
			break
	check(shell._center != first_center, "跨 64 格触发壳中心步进")
	shell.queue_free()
	player.queue_free()
