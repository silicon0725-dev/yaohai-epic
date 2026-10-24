## 结构化树系统单元测试（v1）：确定性生成、形态约束、
## 段分裂三分支、连通性分析、叶冠存在性。
extends VoxelTestCase

const TreeGenScript := preload("res://systems/trees/tree_generator.gd")
const TreeInstScript := preload("res://systems/trees/tree_instance.gd")
const SpeciesScript := preload("res://systems/trees/tree_species.gd")
const TreeManagerScript := preload("res://systems/trees/tree_manager.gd")


func _species() -> TreeSpecies:
	var s: TreeSpecies = SpeciesScript.new()
	return s


func run() -> void:
	_test_deterministic_generation()
	_test_shape_constraints()
	_test_split_first_cell()
	_test_split_last_cell()
	_test_split_middle()
	_test_split_root_base()
	_test_top_cut_detaches_crown()
	_test_connectivity()
	_test_leaf_crown()
	_test_crown_shadow()
	_test_leaf_clear_coverage()


## 确定性：同 seed 同 origin 两次生成结构完全一致。
func _test_deterministic_generation() -> void:
	var sp := _species()
	var a := TreeGenScript.generate(sp, 42, Vector3i(10, 5, 10))
	var b := TreeGenScript.generate(sp, 42, Vector3i(10, 5, 10))
	check_eq(b.cell_to_branch.size(), a.cell_to_branch.size(),
			"同种子结构格数一致")
	var same := true
	for cell in a.cell_to_branch:
		if not b.cell_to_branch.has(cell):
			same = false
			break
	check(same, "同种子体素索引一致（确定性）")
	var c := TreeGenScript.generate(sp, 42, Vector3i(20, 5, 20))
	check(c.origin == Vector3i(20, 5, 20), "origin 记录正确")


## 形态约束：主干垂直、侧枝从上部起、有叶。
func _test_shape_constraints() -> void:
	var sp := _species()
	var tree := TreeGenScript.generate(sp, 7, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	# 主干垂直：start 到 end 只有 y 分量
	var d: Vector3i = trunk.end_cell - trunk.start_cell
	check(d.x == 0 and d.z == 0, "主干垂直（无水平偏移）")
	check(d.y >= 5, "主干高度 >= 5（%d）" % (d.y + 1))
	# 侧枝起点在主干上部 40% 以上
	var side_from_top := true
	for bid in tree.branches:
		if bid == tree.root_branch_id:
			continue
		var n = tree.branches[bid]
		if n.parent_id != tree.root_branch_id:
			continue
		var attach_y: int = n.start_cell.y
		var trunk_top: int = trunk.end_cell.y
		if attach_y < trunk.start_cell.y + int(float(d.y) * 0.55):
			side_from_top = false
	check(side_from_top, "侧枝从主干上部伸出（无低处枝）")
	# 体素索引完整：每个枝段格都有索引
	var indexed := true
	for bid in tree.branches:
		var n = tree.branches[bid]
		for cell in n.cells():
			if not tree.cell_to_branch.has(cell):
				indexed = false
	check(indexed, "全部枝干格有反向索引")


## split：切首格 = 断连边（parent 置 -1）。
func _test_split_first_cell() -> void:
	var tree := TreeGenScript.generate(_species(), 1, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	# 找一根侧枝切其首格
	var side_id := -1
	for bid in tree.branches:
		var n = tree.branches[bid]
		if n.parent_id == tree.root_branch_id:
			side_id = bid
			break
	check(side_id >= 0, "找到侧枝")
	var side = tree.branches[side_id]
	var r := tree.split_branch_at_cell(side.start_cell)
	check(r["changed"], "切首格触发变更")
	check(side.parent_id == -1, "断连边后 parent 置 -1")
	check(not tree.cell_to_branch.has(side.start_cell), "被切格索引清除")
	# 连通性：该侧枝（含子枝）不再受支撑
	var unsup := tree.find_unsupported()
	check(unsup.has(side_id), "断连侧枝失支撑")


## split：切末格 = 段缩短。
func _test_split_last_cell() -> void:
	var tree := TreeGenScript.generate(_species(), 2, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	var orig_end: Vector3i = trunk.end_cell
	var orig_len: int = trunk.cells().size()
	var r := tree.split_branch_at_cell(orig_end)
	check(r["changed"], "切末格触发变更")
	check(trunk.cells().size() == orig_len - 1, "段缩短一格")
	check(trunk.end_cell == orig_end - Vector3i(0, 1, 0), "end 回退")


## split：切中间格 = 段分裂 A+B。
func _test_split_middle() -> void:
	var tree := TreeGenScript.generate(_species(), 3, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	var cells: Array = trunk.cells()
	var mid: Vector3i = cells[int(cells.size() / 2)]
	var r := tree.split_branch_at_cell(mid)
	check(r["changed"], "切中间格触发变更")
	var tail_id: int = r["new_tail_id"]
	check(tail_id > 0, "产生新尾段 B")
	var tail = tree.branches[tail_id]
	check(tail.parent_id == -1, "B 段与根断开（分裂）")
	# A 段保持连根
	var sup := tree.find_supported()
	check(sup.has(tree.root_branch_id), "A 段（根）仍受支撑")
	check(not sup.has(tail_id), "B 段失支撑")


## split：切根段首格 = 断地，整树失支撑（曾只置 parent=-1 对根
## 无意义，整树仍"受支撑"——底格被挖树不倒、存档重放树复活）。
func _test_split_root_base() -> void:
	var tree := TreeGenScript.generate(_species(), 6, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	var base: Vector3i = trunk.start_cell
	var r := tree.split_branch_at_cell(base)
	check(r["changed"], "切根段首格触发变更")
	check(not tree.cell_to_branch.has(base), "被切格索引清除")
	var unsup := tree.find_unsupported()
	check(unsup.has(tree.root_branch_id), "根段失支撑（断地）")
	check(unsup.size() == tree.branches.size(),
			"整树全部段失支撑（%d/%d）" % [unsup.size(), tree.branches.size()])
	# 重放语义：同种子重建 + 同切割 → 同样全失支撑（存档一致性）
	var replay := TreeGenScript.generate(_species(), 6, Vector3i(0, 3, 0))
	replay.split_branch_at_cell(base)
	var unsup2 := replay.find_unsupported()
	check(unsup2.size() == replay.branches.size(), "重放同切割整树失支撑")


## split：切主干顶格 → 挂在顶格的冠心段脱钩失支撑（曾按图遍历
## 仍"受支撑"，冠心悬空不掉）。
func _test_top_cut_detaches_crown() -> void:
	var tree := TreeGenScript.generate(_species(), 8, Vector3i(0, 3, 0))
	var trunk = tree.branches[tree.root_branch_id]
	var crown_id := -1
	for bid in tree.branches:
		var n = tree.branches[bid]
		if n.parent_id == tree.root_branch_id and n.id != tree.root_branch_id \
				and n.start_cell - n.axis_step() == trunk.end_cell:
			crown_id = bid
			break
	check(crown_id >= 0, "找到挂在主干顶格的子段（冠心）")
	var r := tree.split_branch_at_cell(trunk.end_cell)
	check(r["changed"], "切顶格触发变更")
	var unsup := tree.find_unsupported()
	check(unsup.has(crown_id), "冠心脱钩失支撑（不悬空）")
	check(not unsup.has(tree.root_branch_id), "主干仍受支撑")


## 连通性：切断一根侧枝不影响他枝。
func _test_connectivity() -> void:
	var tree := TreeGenScript.generate(_species(), 4, Vector3i(0, 3, 0))
	# 找两根不同侧枝
	var sides: Array = []
	for bid in tree.branches:
		var n = tree.branches[bid]
		if n.parent_id == tree.root_branch_id and n.id != tree.root_branch_id:
			sides.append(n)
	check(sides.size() >= 2, "至少两根侧枝（%d）" % sides.size())
	var victim = sides[0]
	tree.split_branch_at_cell(victim.start_cell)
	var sup := tree.find_supported()
	# 其他侧枝仍支撑
	for other in sides:
		if other == victim:
			continue
		check(sup.has(other.id), "他枝不受牵连（%d）" % other.id)
	check(not sup.has(victim.id), "被切枝失支撑")


## 叶冠：末梢叶球 + 冠心，格数 > 枝数。
func _test_leaf_crown() -> void:
	var tree := TreeGenScript.generate(_species(), 5, Vector3i(0, 3, 0))
	var leaves := TreeGenScript.leaf_cells(tree)
	check(leaves.size() > tree.cell_to_branch.size(),
			"叶格多于枝格（%d vs %d）" % [leaves.size(), tree.cell_to_branch.size()])
	# 确定性
	var leaves2 := TreeGenScript.leaf_cells(tree)
	check(leaves.size() == leaves2.size(), "叶生成确定性")


## 隐形实心冠投影：满密度冠 ⊇ 实际叶格（同种子同几何）；投影
## 覆盖满密度冠每一格、仅进阴影贴图（树影漏光双重根因——叶球
## 随机空隙整格漏光 + cutout 叶面透明纹素被阴影通道 discard）
func _test_crown_shadow() -> void:
	var void_total := 0
	for sd in [3, 5, 11, 42]:
		var t := TreeGenScript.generate(_species(), sd, Vector3i(0, 1, 0))
		var leaves := TreeGenScript.leaf_cells(t)
		var shadow := TreeGenScript.leaf_shadow_cells(t)
		var sset := {}
		for c in shadow:
			sset[c] = true
		var missing := 0
		for lc in leaves:
			if not sset.has(lc):
				missing += 1
		check(missing == 0, "实心冠 ⊇ 实际叶格（seed %d 缺 %d）" % [sd, missing])
		void_total += shadow.size() - leaves.size()
	check(void_total > 0, "多 seed 冠空隙存在（共 %d）" % void_total)
	# 投影网格：挂在 mesh_node 下、SHADOWS_ONLY、1 表面、覆盖满密度冠每一格
	#（cutout 叶纹素孔 + 生成空隙都要实心盒兜底——树影漏光双重根因）
	var tm = TreeManagerScript.new()
	var tree := TreeGenScript.generate(_species(), 11, Vector3i(0, 1, 0))
	var parent := MeshInstance3D.new()
	tm._build_crown_shadow(tree, parent)
	var n_child := 0
	var ok_mode := false
	var surf := -1
	var n_verts := -1
	for ch in parent.get_children():
		if ch.name == "CrownShadow":
			n_child += 1
			ok_mode = ch.cast_shadow \
					== GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			surf = ch.mesh.get_surface_count()
			n_verts = ch.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var want_cells := TreeGenScript.leaf_shadow_cells(tree).size()
	check(n_child == 1, "冠投影节点唯一")
	check(ok_mode, "冠投影仅投影不可见（SHADOWS_ONLY）")
	check(surf == 1, "冠投影网格 1 表面")
	# 覆盖契约按暴露面集判（面邻接剔除后内部面不再发射——曾逐格
	# 6 面×24 顶点，单树构建 ~15ms 是走动 hitch 主源之一）。独立
	# 重算期望暴露面数：既能抓住漏发暴露面（覆盖缺口），也能抓住
	# 回退逐格全盒（内部面回归、构建耗时回升）
	var shadow_cells := TreeGenScript.leaf_shadow_cells(tree)
	var cset := {}
	for c in shadow_cells:
		cset[c] = true
	var want_exposed := 0
	for c in shadow_cells:
		for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 1, 0), Vector3i(0, -1, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			if not cset.has(c + d):
				want_exposed += 1
	check(n_verts == want_exposed * 4,
			"投影=满密度冠暴露面集（%d 面 vs %d 顶点）" % [want_exposed, n_verts])
	check(want_cells > 0, "满密度冠格非空")
	parent.free()
	tm.free()


## 倒树清叶覆盖：_collect_leaves_near（半径 2.6 球）必须覆盖全部
## 叶格——曾 12 邻域收集收不走半径 2 叶球的外层（实测 46% 残留
## 悬浮叶）。用真实叶格写入世界后验证。
func _test_leaf_clear_coverage() -> void:
	var blocks = VoxelTypes.build_default_registry()
	var items = ItemTypes.build_default_item_registry(blocks)
	var config = WorldConfig.new()
	var world = VoxelWorld.new(config, blocks)
	# 两层 16³ 区块：树顶叶球可达 y≈16（单层世界顶外的叶写不进
	# 去，曾被误报为清叶残留）
	world.add_chunk(ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16), 1))
	world.add_chunk(ChunkData.new(Vector3i(0, 1, 0), Vector3i(16, 16, 16), 1))
	# 标记 ACTIVE（清叶走 get_block 查询）
	for coord in [Vector3i.ZERO, Vector3i(0, 1, 0)]:
		world.get_chunk(coord).state = ChunkState.State.ACTIVE
	var tm = TreeManagerScript.new()
	tm.setup(world, blocks, items)
	var tree := TreeGenScript.generate(_species(), 11, Vector3i(8, 1, 8))
	var leaves := TreeGenScript.leaf_cells(tree)
	for lc in leaves:
		world.set_block(lc, VoxelTypes.LEAVES_ID, false)
	var cells := tree.cells_of_branches(tree.branches)
	var collected: Array[Vector3i] = tm._collect_leaves_near(cells)
	var set := {}
	for c in collected:
		set[c] = true
	var missing := 0
	for lc in leaves:
		if not set.has(lc):
			missing += 1
	check(missing == 0, "清叶半径覆盖全部叶格（残留 %d/%d）" % [
			missing, leaves.size()])
	tm.free()
