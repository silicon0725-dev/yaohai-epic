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
	check_eq(mesh.get_surface_count(), 4, "四级格距各一 surface（水面已并入格顶面）")
	var total_v := 0
	for si in range(0, mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		total_v += v.size()
		check(idx.size() > 0 and cols.size() == v.size()
				and norms.size() == v.size(),
				"级 %d 数组齐备（v=%d）" % [si, v.size()])
		# 方块语言断言：陆格顶面/侧壁顶点 x,z 均对齐全局格距网格
		#（中心 32 + S 的整数倍）。级间边界裙深 = 一级量化步（曾落
		# 到 y=0 的深谷缝在低机位透视下呈放射状楔形暗带，实机两轮）
		var Ss := [4, 8, 16, 32]
		var S: int = Ss[si]
		var aligned := true
		var min_y := 1e9
		for i in v.size():
			min_y = minf(min_y, v[i].y)
		for i in mini(v.size(), 4000):
			var lx := fmod(v[i].x - 32.0, float(S))
			var lz := fmod(v[i].z - 32.0, float(S))
			if absf(lx) > 0.01 and absf(lx + float(S)) > 0.01 \
					and absf(lx - float(S)) > 0.01:
				aligned = false
				break
			if absf(lz) > 0.01 and absf(lz + float(S)) > 0.01 \
					and absf(lz - float(S)) > 0.01:
				aligned = false
				break
		check(aligned, "级 %d 顶点对齐 %d 格网格" % [si, S])
		# 方块风水面：水格顶面 y=sea-0.125（与 chunk 水面同高公式）
		var wtop := 0
		for i in v.size():
			if absf(v[i].y - 6.875) < 0.05:
				wtop += 1
		if si >= 1:
			check(wtop > 0, "级 %d 存在水格顶面（%d 顶点）"
					% [si, wtop])
		check(min_y > 1.0, "级 %d 裙壁不落地（min y=%.0f > 1）"
				% [si, min_y])
	# 总量预算：陆面 ~67 万顶点（水面盘独立）
	check(total_v >= 500000 and total_v <= 900000,
			"方块风陆面顶点总量（%d，预算 ~67 万）" % total_v)
	var aabb: AABB = mesh.get_aabb()
	check(aabb.size.x >= 8100.0 and aabb.size.z >= 8100.0,
			"壳 AABB 覆盖 ~8192 格（%.0f）" % aabb.size.x)
	# AABB 由陆格/水格顶面决定（级 0 内缘 240 起；无独立水面几何）
	check(absf(aabb.position.x - (32.0 - 4064.0)) <= 128.0,
			"壳 AABB 随中心（x=%.0f）" % aabb.position.x)


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
		check(mesh_inst.mesh.get_surface_count() == 4,
				"节点 mesh 四级（水面并入格顶面）")
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
