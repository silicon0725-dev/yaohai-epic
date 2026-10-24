## 树实例：权威结构数据（结构化树系统 v1）。
## 网格与碰撞只是表现；一切查询/砍伐/存档都以此为准。
## 坐标全部使用**世界绝对坐标**（树生成后位置永不变，避免局部/
## 世界转换错误；渲染局部化只发生在 MeshBuilder 内部）。
class_name TreeInstance
extends RefCounted

enum State { ALIVE, STUMP_ONLY, REMOVED }

var tree_id: int
var species: TreeSpecies
var origin: Vector3i          # 根格（草地上一格，世界坐标）
var random_seed: int
var state: int = State.ALIVE
var revision: int = 0         # 结构变化递增（异步网格构建校验用，预留）

## 枝干图：int -> BranchNode
var branches := {}
var root_branch_id: int = -1
var next_branch_id: int = 1

## 体素反向索引：Vector3i（世界格）-> int（branch_id）。
## 每个可交互的 BRANCH 占位格都必须能唯一定位到所属枝段。
var cell_to_branch := {}

## 枝段被切断的记录（存档事件重放用；按发生顺序）
var cut_cells: Array[Vector3i] = []


## 枝干结构节点：一段沿轴向的连续格链（start→end 含两端）。
## 局部切割由 split_branch_at_cell 处理（段可分裂）。
class BranchNode:
	extends RefCounted
	var id: int
	var parent_id: int = -1
	var child_ids: Array[int] = []
	var start_cell: Vector3i
	var end_cell: Vector3i
	var radius_start: int = 1
	var radius_end: int = 1

	func length() -> int:
		return (end_cell - start_cell).length() as int + 1

	## 段内所有格（沿轴向逐格）
	func cells() -> Array[Vector3i]:
		var out: Array[Vector3i] = []
		var d := axis_step()
		var p := start_cell
		while true:
			out.append(p)
			if p == end_cell:
				break
			p += d
		return out

	## 轴向单位步进（start→end）。单格段（d 为零向量）默认竖直
	##（上翘末梢都是单格——曾返回 (0,0,0) 被渲染成 Z 轴横片）
	func axis_step() -> Vector3i:
		var d := end_cell - start_cell
		if d.x != 0:
			return Vector3i(sign(d.x), 0, 0)
		if d.z != 0:
			return Vector3i(0, 0, sign(d.z))
		if d.y != 0:
			return Vector3i(0, sign(d.y), 0)
		return Vector3i(0, 1, 0)


func register_branch(node: BranchNode) -> void:
	branches[node.id] = node
	if node.parent_id >= 0 and branches.has(node.parent_id):
		(branches[node.parent_id] as BranchNode).child_ids.append(node.id)
	# 建立体素索引
	for cell in node.cells():
		cell_to_branch[cell] = node.id


## 局部切割（P0-3）：切断枝段内部的体素后拆分剩余结构。
## 三种情形：
## - cell == start：断开与父的连接边（parent 置 -1）；
## - cell == end：段缩短一格（末格被挖）；
## - 中间格：段分裂为 A（start..cell-1，保留 parent）与
##   B（cell+1..end，新 id，原段的子枝挂到 B）。
## 不在此判断支撑——那是随后的连通性分析（find_supported）。
## 返回 {changed: bool, new_tail_id: int}（中间格分裂时 B 的 id）。
func split_branch_at_cell(cell: Vector3i) -> Dictionary:
	if not cell_to_branch.has(cell):
		return {"changed": false, "new_tail_id": -1}
	var node: BranchNode = branches[cell_to_branch[cell]]
	var axis := node.axis_step()
	var cells := node.cells()
	var idx := cells.find(cell)
	assert(idx >= 0)

	# 清除被切格的索引
	cell_to_branch.erase(cell)

	if idx == 0:
		# 断连接边：与父脱钩（parent 的 child 列表移除本段）
		if node.parent_id >= 0 and branches.has(node.parent_id):
			var parent: BranchNode = branches[node.parent_id]
			parent.child_ids.erase(node.id)
		node.parent_id = -1
		revision += 1
		return {"changed": true, "new_tail_id": -1}

	if idx == cells.size() - 1:
		# 段缩短：end 回退一格
		node.end_cell = cells[idx - 1]
		node.radius_end = node.radius_start  # 简化：缩短后端半径取起点
		revision += 1
		return {"changed": true, "new_tail_id": -1}

	# 中间格：分裂为 A + B
	var tail := BranchNode.new()
	tail.id = next_branch_id
	next_branch_id += 1
	tail.start_cell = cells[idx + 1]
	tail.end_cell = node.end_cell
	tail.radius_start = node.radius_end  # B 的起点半径沿用原终点
	tail.radius_end = node.radius_end
	# 原段子的子枝全部转挂 B
	for cid in node.child_ids:
		if branches.has(cid):
			(branches[cid] as BranchNode).parent_id = tail.id
			tail.child_ids.append(cid)
	node.child_ids = []
	node.end_cell = cells[idx - 1]
	node.radius_end = node.radius_start
	# B 的体素索引重建（原索引指向旧段 id）
	for c in tail.cells():
		cell_to_branch[c] = tail.id
	branches[tail.id] = tail
	revision += 1
	return {"changed": true, "new_tail_id": tail.id}


## 连通性分析（P0-4 前半）：从根段 BFS，返回仍受支撑的 branch_id 集。
## 队列头索引版（避免 pop_front 的 O(n) 移动）。
func find_supported() -> Dictionary:
	var supported := {}
	if not branches.has(root_branch_id):
		return supported
	var queue: Array[int] = [root_branch_id]
	var head := 0
	supported[root_branch_id] = true
	while head < queue.size():
		var cur: BranchNode = branches[queue[head]]
		head += 1
		for cid in cur.child_ids:
			if supported.has(cid) or not branches.has(cid):
				continue
			supported[cid] = true
			queue.append(cid)
		# 分裂/切断后父边已断的段通过 child 关系遍历不到——
		# 同时沿 parent 反向：分裂的 A 段 child 里没有 B，但 B 若
		# 仍连着根需经 parent 链可达。BFS 用无向遍历（parent+child）。
		if cur.parent_id >= 0 and branches.has(cur.parent_id) \
				and not supported.has(cur.parent_id):
			supported[cur.parent_id] = true
			queue.append(cur.parent_id)
	return supported


## 失支撑的分支集合（= 全部 - supported）。
func find_unsupported() -> Dictionary:
	var sup := find_supported()
	var unsup := {}
	for bid in branches:
		if not sup.has(bid):
			unsup[bid] = true
	return unsup


## 按分支集合收集全部体素（含被切格之外的段内格）。
func cells_of_branches(ids: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for bid in ids:
		if branches.has(bid):
			out.append_array((branches[bid] as BranchNode).cells())
	return out


## 结构总格数（含已被切格的扣除——cell_to_branch 只含现存格）。
func living_cell_count() -> int:
	return cell_to_branch.size()


## 序列化（存档用：结构由种子重放重建，只存切割事件流）。
func serialize_cuts() -> Array:
	var out := []
	for c in cut_cells:
		out.append([c.x, c.y, c.z])
	return out


func record_cut(cell: Vector3i) -> void:
	cut_cells.append(cell)
	revision += 1
