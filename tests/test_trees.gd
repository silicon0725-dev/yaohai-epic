## 结构化树系统单元测试（v1）：确定性生成、形态约束、
## 段分裂三分支、连通性分析、叶冠存在性。
extends VoxelTestCase

const TreeGenScript := preload("res://systems/trees/tree_generator.gd")
const TreeInstScript := preload("res://systems/trees/tree_instance.gd")
const SpeciesScript := preload("res://systems/trees/tree_species.gd")


func _species() -> TreeSpecies:
	var s: TreeSpecies = SpeciesScript.new()
	return s


func run() -> void:
	_test_deterministic_generation()
	_test_shape_constraints()
	_test_split_first_cell()
	_test_split_last_cell()
	_test_split_middle()
	_test_connectivity()
	_test_leaf_crown()


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
