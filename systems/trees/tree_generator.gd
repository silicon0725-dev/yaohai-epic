## 确定性树生成器（结构化树系统 v2：GrowSignal 生长模拟）——
## 纯数据，无场景依赖。生成期（terrain_generator 占位重放）与
## 运行期（tree_manager 实体重建）共用本模块，保证两边结构一致。
##
## 算法源自 DynamicTrees 研究（docs/reference-dynamic-trees.md）：
## - 主干=高度预算内的向上直柱（±height_variation 抖动）；
## - 侧枝=子信号概率地图选向（UP 惯性×层级系数 + 当前方向惯性 +
##   已占格禁行），一级枝可分叉二级末梢枝——每棵树形态不同但同
##   物种轮廓一致（v1 固定模板的死板同族形态根治）；
## - 半径=面积守恒 DP（自末梢向根：r = sqrt(Σ outgoing r²) +
##   tapering，DT BasicBranchBlock 同式）：粗细=供养面积的语义，
##   主干天然底粗顶细（v1 手工线性插值废弃）；
## - 段语言与 v1 完全一致（轴对齐直线段、主干垂直单段、水平段+
##   上翘竖段折线）——mesh_builder/砍伐管线/测试断言零改动。
class_name TreeGenerator
extends RefCounted

## 撒种模块（新 class_name 的全局类缓存不刷新——一律 preload）
const TreeScatterScript := preload("res://systems/trees/tree_scatter.gd")

const UP := Vector3i(0, 1, 0)
const HORIZONTALS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## 树冠水平影响半径（生命周期引用计数用）
const TREE_REACH := 4


## 撒种判定纯函数：该水平列是否长树（确定性）。v2 起委托
## TreeScatter（显式数值 hash + 降水驱动密度 + cell/jitter 最小
## 间距——GDScript 内置 hash 曾让 C# 侧无法复刻，LOD 树烘壳需要
## 同源判定）。签名不变，全部调用点（terrain_generator 撒树、
## tree_manager 列扫描、测试×3）零改动。
static func has_tree_at(world_seed: int, col: Vector2i) -> bool:
	return TreeScatterScript.has_tree_at(world_seed, col)


## 模拟期路径：折线（逐步格 + 步向），切段后输出 BranchNode。
class _Path:
	extends RefCounted
	var cells: Array[Vector3i] = []   # 依次经过的格（含起点）
	var dirs: Array[Vector3i] = []    # cells[i] -> cells[i+1] 的步向
	var parent: _Path = null          # 分叉来源路径（null=主干）
	var fork_cell: Vector3i           # 父路径上的分叉格
	var depth: int = 0                # 0 主干 1 一级枝 2 二级末梢


## 生成一棵树的完整结构数据（确定性：同 seed 同 origin 同结构）。
## 返回 TreeInstance（枝干图 + 体素索引；叶格由 leaf_cells 按需收集）。
static func generate(species: TreeSpecies, world_seed: int,
		origin: Vector3i) -> TreeInstance:
	var tree := TreeInstance.new()
	tree.species = species
	tree.origin = origin
	tree.random_seed = hash([world_seed, origin.x, origin.z])
	tree.tree_id = tree.random_seed

	var rng := RandomNumberGenerator.new()
	rng.seed = tree.random_seed

	# 主干：高度抖动后纯向上直柱（测试形态约束：垂直单段）。
	var h := maxi(5, species.trunk_height + rng.randi_range(
			-species.height_variation, species.height_variation))
	var trunk := _Path.new()
	trunk.depth = 0
	for i in h:
		trunk.cells.append(origin + UP * i)
	trunk.dirs.resize(h - 1)
	trunk.dirs.fill(UP)

	var occupied := {}
	for c in trunk.cells:
		occupied[c] = true

	# 冠心：主干顶再收 2 格竖直细段（叶球挂点，v1 视觉语言保留）。
	var crown := _Path.new()
	crown.depth = 0
	crown.parent = trunk
	crown.fork_cell = trunk.cells[h - 1]
	for i in 2:
		crown.cells.append(crown.fork_cell + UP * (i + 1))
	crown.dirs.append(UP)
	for c in crown.cells:
		occupied[c] = true

	var paths: Array[_Path] = [trunk, crown]
	var forks_used := 0

	# 一级枝：主干上部按层锚定出枝（层距 3 格，每层 1-2 根——
	# 纯逐格概率每棵只有 ~1.5 枝，冠幅单薄；v1 的轮层秩序感保留）。
	# 出枝高度下限同时满足"上部 55%+"形态约束（v1 测试沿用）。
	var first_y := maxi(species.lowest_branch_height, int(float(h) * 0.55))
	var branch_energy := maxi(3, int(round((float(h) + species.energy_padding)
			/ species.energy_divisor)))
	var y := first_y
	while y < h - 1:
		if forks_used >= species.max_forks:
			break
		var fork_cell := origin + UP * y
		var sd := HORIZONTALS[rng.randi() % 4]
		@warning_ignore("shadowed_variable")
		# 返回本轮消耗的分叉数。当前预算显式传参：GDScript lambda
		# 按值捕获外层 int——曾闭包内直接读 forks_used，同层第二次
		# 调用看到的是 lambda 创建时的旧值（首调已把预算用到上限，
		# 二调仍判"未满"→ 超预算 1-2 枝）；更早版本闭包内 +=
		# 外层恒 0，上限形同虚设
		var spawn_layer := func(pdir: Vector3i, cur: int) -> int:
			var budget := cur
			if budget >= species.max_forks:
				return 0
			if occupied.has(fork_cell + pdir):
				return 0
			var bpath := _grow_branch(species, rng, occupied,
					fork_cell + pdir, pdir, branch_energy, 1)
			if bpath == null:
				return 0
			bpath.parent = trunk
			bpath.fork_cell = fork_cell
			paths.append(bpath)
			budget += 1
			# 二级末梢枝：一级枝水平段中段分叉（预算共享；末梢不再
			# 分叉）。挂点必须前后皆水平步：末格=翘尾挂点（mesh 轴向
			# 收缩）与桥（格表面→边界）同格互相矛盾——收缩躲翘尾后
			# 桥起悬空=整条二级枝断裂（种子 26 盒级实锤）；UP 段格上
			# 挂水平子同样无桥贯穿。last_h=最后一个水平步的 index，
			# 挂点 ∈ [1, last_h-1] 保证 cells[mid] 前后步皆水平
			var last_h := -1
			for di in bpath.dirs.size():
				if bpath.dirs[di].y == 0:
					last_h = di
			if budget < species.max_forks and last_h >= 2 \
					and rng.randf() < 0.5:
				var mid_i := 1 + (rng.randi() % (last_h - 1))
				var mcell: Vector3i = bpath.cells[mid_i]
				var md := HORIZONTALS[rng.randi() % 4]
				if not occupied.has(mcell + md):
					var sub := _grow_branch(species, rng, occupied,
							mcell + md, md, maxi(2, branch_energy - 2), 2)
					if sub != null:
						sub.parent = bpath
						sub.fork_cell = mcell
						paths.append(sub)
						budget += 1
			return budget - cur
		var used: int = spawn_layer.call(sd, forks_used)
		forks_used += used
		if used > 0 and rng.randf() < 0.85 and forks_used < species.max_forks:
			# 同层对向补一根（锚定方向的反面）
			forks_used += spawn_layer.call(-sd, forks_used)
		y += 2

	var cell_r := _conservation_radii(species, paths)
	_emit_segments(tree, paths, cell_r, species)
	return tree


## 子信号逐步生长：概率地图选向（UP 权重×层级系数、当前方向惯性、
## 已占格禁行、禁向下），能量每步 -1，能量尽或四面受阻即止。
## 返回折线路径（首步即失败返回 null）。
static func _grow_branch(species: TreeSpecies, rng: RandomNumberGenerator,
		occupied: Dictionary, start: Vector3i, start_dir: Vector3i,
		energy: int, depth: int) -> _Path:
	var path := _Path.new()
	path.depth = depth
	path.cells.append(start)
	occupied[start] = true
	var dir := start_dir
	while energy > 0:
		energy -= 1
		var head: Vector3i = path.cells[path.cells.size() - 1]
		# 首步强制分叉方向（DT branchOut 语义：新枝沿分叉方向冒出；
		# 且保证 mesh fork 判定 start - axis == 父格——首步走概率地图
		# 会抽到别的方向，fork 指向空格 → 段悬空断裂），后续步自由
		var nd := start_dir
		# 末梢向光性：能量最后两步强制向上——枝端上翘是 v1 以来
		# 的视觉语言（横枝翘尾+mesh 拐角对齐），也符合 DT 末梢细枝
		# 向光语义。锁死模式：触发后只走 UP、UP 被占即终止——曾
		# 掉回概率地图继续水平，翘尾长在枝中段（末格双挂断裂+
		# 拐角戳出的来源之一）
		if energy <= 2 and not path.dirs.is_empty():
			if occupied.has(head + UP):
				break
			nd = UP
			var nxt0: Vector3i = head + nd
			path.dirs.append(nd)
			path.cells.append(nxt0)
			occupied[nxt0] = true
			if energy <= 1:
				break
			continue
		if not path.dirs.is_empty():
			# 概率地图：空气 1；UP += up_prob×层级系数；当前方向 +=
			# 惯性；DOWN 恒 0；已占格 0（禁行——自缠绕防护）
			var up_w := species.up_probability if depth == 0 \
					else int(round(float(species.up_probability)
					* species.branch_up_factor))
			var weights := PackedInt32Array()
			weights.resize(6)
			for i in DIRS.size():
				var d := DIRS[i]
				if d == Vector3i(0, -1, 0) or occupied.has(head + d):
					continue  # 权重保持 0
				var w := 1
				if d == UP:
					# 侧枝（depth>0）UP 权重=up_w 本身（oak 中段禁
					# UP——翘尾只属于末梢向光段）。曾 +=up_w 保留
					# 基础权重 1：中段 1/9 抽中 UP 产生"短水平+竖直
					# 段"乱形（无翘尾语言+末格双挂断裂，种子 26）
					w = up_w if depth > 0 else 1 + up_w
				if d == dir:
					w += species.current_dir_probability
				weights[i] = w
			var total := 0
			for w in weights:
				total += w
			if total <= 0:
				break  # 四面受阻（自身缠绕）——信号终止
			var pick := rng.randi_range(1, total)
			for i in DIRS.size():
				pick -= weights[i]
				if pick <= 0:
					nd = DIRS[i]
					break
		var nxt: Vector3i = head + nd
		path.dirs.append(nd)
		path.cells.append(nxt)
		occupied[nxt] = true
		dir = nd
	if path.cells.size() < 2:
		occupied.erase(start)
		return null
	return path


## 面积守恒半径 DP：r(cell) = sqrt(Σ outgoing r²) + tapering。
## outgoing = 远离根方向的出边：路径内下一格 + 挂此格的子路径首格。
## **倒序遍历 paths**（append 序=父先子后：二级枝紧随其一级、
## crown 在 trunk 后 → 倒序=任何 fork 格计算时其子路径已算完），
## 路径内自尾向头——出边目标半径必已定。不依赖 _Path.parent 链
##（曾用 children 后序递归：lambda 内 parent 赋值不回写外层语义
## 不可靠，子不在 children 里=遍历不到→半径缺 key 崩溃实锤；
## forks_at 只按格索引、spawn 顺序保证正确性）。
## 末梢端 Σ=0 → r=tapering（输出 floor+max(1,..)=1）。
static func _conservation_radii(species: TreeSpecies,
		paths: Array[_Path]) -> Dictionary:
	# 分叉索引：fork_cell -> 子路径列表
	var forks_at := {}
	for p in paths:
		if p.parent == null:
			continue
		if not forks_at.has(p.fork_cell):
			forks_at[p.fork_cell] = []
		(forks_at[p.fork_cell] as Array).append(p)

	var cell_r := {}
	for pi in range(paths.size() - 1, -1, -1):
		var p: _Path = paths[pi]
		# 自尾向头：路径内出边 + 分叉出边（子路径半径已定）
		for i in range(p.cells.size() - 1, -1, -1):
			var sum_sq := 0.0
			if i + 1 < p.cells.size():
				var nr: float = cell_r[p.cells[i + 1]]
				sum_sq += nr * nr
			for sub in (forks_at.get(p.cells[i], []) as Array):
				var sr: float = cell_r[(sub as _Path).cells[0]]
				sum_sq += sr * sr
			cell_r[p.cells[i]] = sqrt(sum_sq) + species.tapering
	return cell_r


## 段聚合输出：路径内连续同向步=一段；转向=新段（parent=前段，
## **不含转向格**——转向格留在前段，子段 start=转向格+新方向一步，
## 与 v1 上翘段语义一致：段间 face-adjacent 不重叠，fork 判定
## child.start - child.axis == 父段末格 对 mesh 分叉桥/砍伐脱钩都
## 成立）。新路径首段 parent=分叉格所在段。守恒半径 floor 后写段
## 首/尾（段内线性过渡由 mesh_builder 插值呈现）。首段=主干。
static func _emit_segments(tree: TreeInstance, paths: Array[_Path],
		cell_r: Dictionary, species: TreeSpecies) -> void:
	# 段 = {cells: Array[Vector3i], parent_seg: Dictionary, axis: Vector3i}
	var all_segs: Array = []
	var seg_of_cell := {}   # Vector3i -> seg（跨路径分叉挂点定位）

	for p in paths:
		# 首段轴向=路径第一步方向（首格先入段，第一步必延续）
		var axis0: Vector3i = p.dirs[0] if not p.dirs.is_empty() \
				else Vector3i(0, 1, 0)
		var cur := {"cells": [p.cells[0]], "parent_seg": {}, "axis": axis0}
		if p.parent != null:
			# 路径首段挂分叉格所在段；分叉格自身留在父段内
			cur["parent_seg"] = seg_of_cell.get(p.fork_cell, {})
		all_segs.append(cur)
		seg_of_cell[p.cells[0]] = cur
		for i in range(1, p.cells.size()):
			# dirs[i-1] = cells[i-1] → cells[i] 的步向；转向=旧段末格
			# cells[i-1] + 新段 [cells[i]..]（face-adjacent 不重叠）
			var nd: Vector3i = p.dirs[i - 1]
			if nd == cur["axis"]:
				(cur["cells"] as Array).append(p.cells[i])
			else:
				cur = {"cells": [p.cells[i]], "parent_seg": cur, "axis": nd}
				all_segs.append(cur)
			seg_of_cell[p.cells[i]] = cur

	# 输出 BranchNode（先建全部段再连父子——id 依赖两遍）
	var seg_to_id := {}
	for seg in all_segs:
		var node := TreeInstance.BranchNode.new()
		node.id = tree.next_branch_id
		tree.next_branch_id += 1
		var cells: Array = seg["cells"]
		if cells.is_empty():
			continue
		node.start_cell = cells[0]
		node.end_cell = cells[cells.size() - 1]
		node.axis_hint = seg["axis"]
		node.radius_start = _radius_at(cell_r, cells[0], species)
		node.radius_end = _radius_at(cell_r,
				cells[cells.size() - 1], species)
		seg_to_id[seg] = node.id
		if tree.root_branch_id < 0:
			tree.root_branch_id = node.id
		tree.register_branch(node)
	for seg in all_segs:
		var parent_seg: Dictionary = seg["parent_seg"]
		if parent_seg.is_empty():
			continue
		if not seg_to_id.has(seg):
			continue
		var node: TreeInstance.BranchNode = tree.branches[seg_to_id[seg]]
		node.parent_id = seg_to_id.get(parent_seg, -1)
		if node.parent_id >= 0 and tree.branches.has(node.parent_id):
			(tree.branches[node.parent_id] \
					as TreeInstance.BranchNode).child_ids.append(node.id)


static func _radius_at(cell_r: Dictionary, cell: Vector3i,
		species: TreeSpecies) -> int:
	return clampi(int(floor(float(cell_r.get(cell, 0.0)))), 1,
			species.trunk_base_radius)


## 叶冠格列表（世界坐标）：每根末梢枝（无子）末端叶球 + 沿途小球
## + 冠心大球。不覆盖非空气判断由调用方负责（这里只算格）。
static func leaf_cells(tree: TreeInstance) -> Array[Vector3i]:
	return _collect_leaf_cells(tree, false)


## 实心冠格（满密度无随机跳过）：与 leaf_cells 同几何同种子，且为
## 其超集。供隐形实心冠投影网格补树冠空隙——视觉保持稀疏镂空、
## 树影实心（叶球随机空隙曾让阳光穿冠、树影漏成斜条纹）
static func leaf_shadow_cells(tree: TreeInstance) -> Array[Vector3i]:
	return _collect_leaf_cells(tree, true)


static func _collect_leaf_cells(tree: TreeInstance, full: bool) -> Array[Vector3i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = tree.random_seed + 777
	var out: Array[Vector3i] = []
	# 去重走 Dictionary（O(1) 查询）——曾用 out.has(p) 线性扫描，
	# 满密度冠 ~300 格时 O(n²) 比较，单棵 2ms+ 纯去重开销
	var seen := {}
	var r_ball: int = tree.species.leaf_ball_radius
	var d_tip: float = 1.0 if full else 0.85
	var d_trail: float = 1.0 if full else 0.5
	for bid in tree.branches:
		var node: TreeInstance.BranchNode = tree.branches[bid]
		if not node.child_ids.is_empty():
			continue
		_ball_cells(out, seen, node.end_cell, r_ball, rng, d_tip)
		# 沿末梢段每格补一个小球（沿途叶簇，树冠有体积）
		for c in node.cells():
			if c != node.end_cell:
				_ball_cells(out, seen, c, maxi(1, r_ball - 1), rng, d_trail)
	# 冠心（主干顶收尾段末端）
	if tree.branches.has(tree.root_branch_id):
		var trunk: TreeInstance.BranchNode = tree.branches[tree.root_branch_id]
		var top := trunk.end_cell
		# 冠心球更大（crown_radius）
		for dy in range(2):
			for dx in range(-tree.species.crown_radius, tree.species.crown_radius + 1):
				for dz in range(-tree.species.crown_radius, tree.species.crown_radius + 1):
					var d := Vector3(dx, dy, dz).length()
					if d > float(tree.species.crown_radius) + 0.5:
						continue
					var p := top + Vector3i(dx, dy + 1, dz)
					if seen.has(p):
						continue
					seen[p] = true
					out.append(p)
	return out


static func _ball_cells(out: Array[Vector3i], seen: Dictionary,
		center: Vector3i, radius: int, rng: RandomNumberGenerator,
		density: float) -> void:
	for dy in range(-1, 2):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var d := Vector3(dx, dy, dz).length()
				if d > float(radius) + 0.3:
					continue
				if d > 0.5 and rng.randf() > density:
					continue
				var p := center + Vector3i(dx, dy, dz)
				if seen.has(p):
					continue
				seen[p] = true
				out.append(p)


## 主干某格的插值半径（占位写入用；mesh_builder 同公式）。
static func trunk_radius_at(tree: TreeInstance, cell: Vector3i) -> int:
	var trunk: TreeInstance.BranchNode = tree.branches.get(tree.root_branch_id)
	if trunk == null:
		return 1
	var h: int = (trunk.end_cell.y - trunk.start_cell.y)
	if h <= 0:
		return trunk.radius_start
	var t := clampf(float(cell.y - trunk.start_cell.y) / float(h),
			0.0, 1.0)
	return int(round(lerpf(float(trunk.radius_start),
			float(trunk.radius_end), t)))
