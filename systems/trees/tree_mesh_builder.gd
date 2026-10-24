## 树干网格构建（结构化树系统 v2）：BranchNode 图 → ArrayMesh。
## 每格一个**轴向盒**（截面半径 r 居中于格中心，轴向满格），
## 分叉格在每个水平子枝方向补**一格桥**（本体表面 → 格边界——
## 不从格中心起：子枝粗于本体时会把细本体上下穿通成"十字穿模"）。
## 水平末格承托上翘竖枝时，轴向末端收回到子枝柱外缘——拐角
## 齐平（横枝不越过竖枝"戳出去"，竖枝落在横枝末端）。
## 贴图按面尺寸等比采样（不拉伸填充，像素保持方形），木纹 V 轴
## 统一对齐世界 Y（横枝竖枝贴图方向一致）；年轮端面只上外露段端
##（变径台阶环带与子枝衔接处贴树皮）。
## 顶点以树根为原点；格中心 = cell + 0.5（水平）。
## 共用方块图集材质（log 贴图）。
class_name TreeMeshBuilder
extends RefCounted


## 构建整棵树（或指定分支子集——倒树刚体用）的 ArrayMesh。
## branch_subset 非空时只构建指定分支（含子递归）。
static func build_mesh(tree: TreeInstance,
		branch_subset: Dictionary = {}) -> ArrayMesh:
	if tree.cell_to_branch.is_empty():
		return null
	var origin := Vector3(tree.origin)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var tile := TextureAtlasLoader.tile_grid("log_side")
	var tile_top := TextureAtlasLoader.tile_grid("log_top")
	var inv_cols := 1.0 / TextureAtlasLoader.COLS
	var inv_rows := 1.0 / TextureAtlasLoader.ROWS
	var uv_o := Vector2(float(tile.x) * inv_cols, float(tile.y) * inv_rows)
	var uv_ot := Vector2(float(tile_top.x) * inv_cols, float(tile_top.y) * inv_rows)

	var subset_mode := not branch_subset.is_empty()
	# 全局分叉格（子枝 start 回退一步；倒树子集只计子集内分支——
	# 被砍掉的子枝要让断口露年轮）。段顶端若有任何子枝续接——
	# 含挂在其他段的（层间巧合：两层枝恰在同一格汇合）——端面
	# 贴树皮不贴年轮
	var fork_cells := {}
	for bid in tree.branches:
		if subset_mode and not branch_subset.has(bid):
			continue
		var node: TreeInstance.BranchNode = tree.branches[bid]
		var fk: Vector3i = node.start_cell - node.axis_step()
		fork_cells[fk] = true
	for bid in tree.branches:
		if subset_mode and not branch_subset.has(bid):
			continue
		var node: TreeInstance.BranchNode = tree.branches[bid]
		_emit_branch_segment(vertices, normals, uvs, indices,
				tree, node, origin, fork_cells,
				uv_o, uv_ot, inv_cols, inv_rows)

	if indices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 阴影专用实心代理：每枝干格一个**轴向满格**盒（半径插值同
## build_mesh，无收尾缩格/分叉桥/年轮细节）。漂亮网格的收尾
## 缩格与分叉桥在阴影通道存在周期性漏光缝（用户存档实测：枝影
## 带内规律亮斑，关木影即消失但亮斑仍在→网格投影自身的洞），
## 代理轴向上盒盒共面相接、必然密封，整类缝隙一次消灭。
## 顶点以树根为原点（同 build_mesh）。无 UV。
## 木质阴影代理 v2：每段一个连续锥台（凸体——任意方向投影无内部缝）
## + 分叉格整格立方（节点密封）。历史：逐格插值盒的阶梯凹环漏光
##（光从收尾缩格旁空隙穿过，枝影带规律亮斑）；整格立方密封但丢失
## 树干渐细结构。锥台两端截面 = 段起止半径（与漂亮网格同插值），
## 侧面连续无凹环，阴影同时密封且带锥度。
static func build_shadow_mesh(tree: TreeInstance) -> ArrayMesh:
	if tree.cell_to_branch.is_empty():
		return null
	var origin := Vector3(tree.origin)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var dummy_uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for bid in tree.branches:
		var node: TreeInstance.BranchNode = tree.branches[bid]
		var cells: Array = node.cells()
		var total: int = cells.size()
		if total == 0:
			continue
		var axis := node.axis_step()
		# 分叉格（子枝挂点）整格立方密封节点区
		for cid in node.child_ids:
			var child: TreeInstance.BranchNode = tree.branches.get(cid)
			if child == null:
				continue
			var fcell: Vector3i = child.start_cell - child.axis_step()
			if not cells.has(fcell):
				continue
			var fx := float(fcell.x - origin.x) + 0.5
			var fy := float(fcell.y - origin.y)
			var fz := float(fcell.z - origin.z) + 0.5
			var mn := Vector3(fx - 0.5, fy, fz - 0.5)
			var mx := Vector3(fx + 0.5, fy + 1.0, fz + 0.5)
			for f in 6:
				_box(vertices, normals, dummy_uvs, indices,
						mn, mx, f, Vector2.ZERO, 1.0, 1.0)
		# 段锥台：A = cells[0] 端面（外扩 0.5 仅竖直段，同漂亮网格
		# 首格下探），B = cells[末] 端面；截面半宽 w 沿轴线性插值
		var a: Vector3i = cells[0]
		var b: Vector3i = cells[total - 1]
		var w_a := clampf(float(node.radius_start) / 8.0, 0.12, 1.0)
		var w_b := clampf(float(node.radius_end) / 8.0, 0.12, 1.0)
		var ca: Array[Vector3]
		var cb: Array[Vector3]
		if axis.y != 0:
			var cx := float(a.x - origin.x) + 0.5
			var cz := float(a.z - origin.z) + 0.5
			var ya: float
			var yb: float
			if a.y <= b.y:
				ya = float(a.y - origin.y) - 0.5
				yb = float(b.y - origin.y) + 1.0
			else:
				ya = float(b.y - origin.y)
				yb = float(a.y - origin.y) + 1.0 + 0.5
				var wt := w_a
				w_a = w_b
				w_b = wt
			ca = [
				Vector3(cx - w_a, ya, cz - w_a), Vector3(cx - w_a, ya, cz + w_a),
				Vector3(cx + w_a, ya, cz + w_a), Vector3(cx + w_a, ya, cz - w_a),
			]
			cb = [
				Vector3(cx - w_b, yb, cz - w_b), Vector3(cx - w_b, yb, cz + w_b),
				Vector3(cx + w_b, yb, cz + w_b), Vector3(cx + w_b, yb, cz - w_b),
			]
		elif axis.x != 0:
			var cy2 := float(a.y - origin.y) + 0.5
			var cz2 := float(a.z - origin.z) + 0.5
			var xa: float
			var xb: float
			if a.x <= b.x:
				xa = float(a.x - origin.x)
				xb = float(b.x - origin.x) + 1.0
			else:
				xa = float(b.x - origin.x)
				xb = float(a.x - origin.x) + 1.0
				var wt2 := w_a
				w_a = w_b
				w_b = wt2
			ca = [
				Vector3(xa, cy2 - w_a, cz2 - w_a), Vector3(xa, cy2 - w_a, cz2 + w_a),
				Vector3(xa, cy2 + w_a, cz2 + w_a), Vector3(xa, cy2 + w_a, cz2 - w_a),
			]
			cb = [
				Vector3(xb, cy2 - w_b, cz2 - w_b), Vector3(xb, cy2 - w_b, cz2 + w_b),
				Vector3(xb, cy2 + w_b, cz2 + w_b), Vector3(xb, cy2 + w_b, cz2 - w_b),
			]
		else:
			var cx3 := float(a.x - origin.x) + 0.5
			var cy3 := float(a.y - origin.y) + 0.5
			var za: float
			var zb: float
			if a.z <= b.z:
				za = float(a.z - origin.z)
				zb = float(b.z - origin.z) + 1.0
			else:
				za = float(b.z - origin.z)
				zb = float(a.z - origin.z) + 1.0
				var wt3 := w_a
				w_a = w_b
				w_b = wt3
			ca = [
				Vector3(cx3 - w_a, cy3 - w_a, za), Vector3(cx3 - w_a, cy3 + w_a, za),
				Vector3(cx3 + w_a, cy3 + w_a, za), Vector3(cx3 + w_a, cy3 - w_a, za),
			]
			cb = [
				Vector3(cx3 - w_b, cy3 - w_b, zb), Vector3(cx3 - w_b, cy3 + w_b, zb),
				Vector3(cx3 + w_b, cy3 + w_b, zb), Vector3(cx3 + w_b, cy3 - w_b, zb),
			]
		_prism(vertices, normals, dummy_uvs, indices, ca, cb)
	if indices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 锥台发射：cap_a/cap_b 各 4 角，统一角序 (u-,v-)(u-,v+)(u+,v+)(u+,v-)
## （沿轴看逆时针；u×v 指向 cap_a 外侧）。A 端面用原序、B 端面用逆序
## 即两侧外向；侧面 quad(L[k], L[k+1], H[k+1], H[k]) 逐边外向
##（曾漏光根因之一是绕序错——阴影 pass 背面剔除会吃掉半边影子）。
static func _prism(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		cap_a: Array[Vector3], cap_b: Array[Vector3]
) -> void:
	_quad(vertices, normals, uvs, indices,
			cap_a[0], cap_a[1], cap_a[2], cap_a[3])
	_quad(vertices, normals, uvs, indices,
			cap_b[0], cap_b[3], cap_b[2], cap_b[1])
	for k in 4:
		var k1 := (k + 1) % 4
		_quad(vertices, normals, uvs, indices,
				cap_a[k], cap_a[k1], cap_b[k1], cap_b[k])


## 四角quad（外向绕序），法线由叉积求出；阴影网格 uv 占位。
static func _quad(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3
) -> void:
	var base := vertices.size()
	var n := (p1 - p0).cross(p2 - p0)
	if n.length_squared() < 0.0000001:
		n = Vector3.UP
	else:
		n = n.normalized()
	# 直接展开 append（曾每次调用临时建 [p0..p3] 数组再下标取——
	# 单棵树数千次调用纯 GC 压力）
	vertices.append(p0)
	vertices.append(p1)
	vertices.append(p2)
	vertices.append(p3)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	uvs.append(Vector2.ZERO)
	uvs.append(Vector2.ZERO)
	uvs.append(Vector2.ZERO)
	uvs.append(Vector2.ZERO)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)


## 一段枝干：逐格轴向盒（半径插值）。分叉格在每个子枝方向补
## 两级阶梯桥——同格多个子枝各自独立桥接（曾只桥最后一个匹配
## 方向，同格其余子枝整段悬空）；本段自身轴向盒在分叉格照常发射
##（水平段的关节小柱不占满轴向格，曾与自身末格留 0.375 格缝隙）。
static func _emit_branch_segment(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		tree: TreeInstance, node: TreeInstance.BranchNode,
		origin: Vector3, fork_cells: Dictionary,
		uv_o: Vector2, uv_ot: Vector2, inv_cols: float, inv_rows: float
) -> void:
	var cells: Array = node.cells()
	var total: int = cells.size()
	if total == 0:
		return
	var axis := node.axis_step()
	var r0 := clampf(float(node.radius_start) / 8.0, 0.12, 1.0)
	var r1 := clampf(float(node.radius_end) / 8.0, 0.12, 1.0)

	# 分叉格 -> [(子枝方向, 子枝起始截面)]（子枝 start 回退一步 =
	# 本段上的分叉点；同格可能多个方向）
	var child_forks := {}
	for cid in node.child_ids:
		var child: TreeInstance.BranchNode = tree.branches.get(cid)
		if child == null:
			continue
		var key: Vector3i = child.start_cell - child.axis_step()
		if not child_forks.has(key):
			child_forks[key] = []
		(child_forks[key] as Array).append([child.axis_step(),
				clampf(float(child.radius_start) / 8.0, 0.12, 1.0)])

	for i in total:
		var cell: Vector3i = cells[i]
		var t := float(i) / float(maxi(total - 1, 1))
		var w := clampf(lerpf(r0, r1, t), 0.12, 1.0)
		# 格中心（世界→树局部）：水平 +0.5，y 不加（柱从格底到格顶）
		var cx := float(cell.x - origin.x) + 0.5
		var cy := float(cell.y - origin.y)
		var cz := float(cell.z - origin.z) + 0.5

		# 1) 本段自身轴向盒（分叉格同样保留）
		if axis == Vector3i(0, 1, 0):
			# 竖直段：截面 w 居中，y 满。首格下探 0.5 与下方段贯穿
			#（拆独立 0.5 高盒——整盒 1.5 高的侧面超一个图块宽）。
			# 年轮只上外露端面（末格顶 / 首格底且该格无任何子枝
			# 续接——全局分叉格判定）：逐格变径的台阶环带曾满贴
			# 年轮（"缝隙里出现年轮"）。
			var ring_top: bool = i == total - 1 and not fork_cells.has(cell)
			if i == 0:
				# 下探盒截面内缩 0.005——与下方段等宽时侧面共面闪烁
				var wd := maxf(w - 0.005, 0.05)
				var mna := Vector3(cx - wd, cy - 0.5, cz - wd)
				var mxa := Vector3(cx + wd, cy, cz + wd)
				for f in 6:
					_box(vertices, normals, uvs, indices, mna, mxa, f,
							uv_ot if (f == 3 and not fork_cells.has(cell)) \
									else uv_o,
							inv_cols, inv_rows)
			var mn := Vector3(cx - w, cy, cz - w)
			var mx := Vector3(cx + w, cy + 1, cz + w)
			for f in 6:
				_box(vertices, normals, uvs, indices, mn, mx, f,
						uv_ot if f == 2 and ring_top else uv_o,
						inv_cols, inv_rows)
		else:
			# 水平段（X 或 Z）：轴向满格，截面 = 竖直方向 w×w
			var mn2: Vector3
			var mx2: Vector3
			if axis.x != 0:
				mn2 = Vector3(cx - 0.5, cy + 0.5 - w, cz - w)
				mx2 = Vector3(cx + 0.5, cy + 0.5 + w, cz + w)
			else:  # axis.z
				mn2 = Vector3(cx - w, cy + 0.5 - w, cz - 0.5)
				mx2 = Vector3(cx + w, cy + 0.5 + w, cz + 0.5)
			# 拐角对齐：末格承托竖直子枝（上翘段）时，满格轴向盒会
			# 越过子枝中心线半格——横枝端面悬空"戳出去"、竖枝像从
			# 横枝中段冒出。轴向末端收回到子枝柱外缘（拐角齐平）。
			# 仅末格处理：段中格剪短会与本段下一格留缝。
			if i == total - 1 and child_forks.has(cell):
				var wch_v := 0.0
				for fork_info: Array in child_forks[cell]:
					if (fork_info[0] as Vector3i).y != 0:
						wch_v = maxf(wch_v, float(fork_info[1]))
				if wch_v > 0.0:
					if axis.x > 0:
						mx2.x = minf(mx2.x, cx + wch_v)
					elif axis.x < 0:
						mn2.x = maxf(mn2.x, cx - wch_v)
					elif axis.z > 0:
						mx2.z = minf(mx2.z, cz + wch_v)
					else:
						mn2.z = maxf(mn2.z, cz - wch_v)
			# 年轮只上外露端面：末格/首格的轴向端面且该格无任何
			# 子枝续接（全局分叉格；上翘子枝处的端面环带贴树皮衔接）
			var tip_f := 0
			var root_f := 1
			if axis.x < 0:
				tip_f = 1
				root_f = 0
			elif axis.z > 0:
				tip_f = 4
				root_f = 5
			elif axis.z < 0:
				tip_f = 5
				root_f = 4
			var no_child: bool = not fork_cells.has(cell)
			for f in 6:
				var ring_f: bool = no_child \
						and ((f == tip_f and i == total - 1) \
						or (f == root_f and i == 0))
				_box(vertices, normals, uvs, indices, mn2, mx2, f,
						uv_ot if ring_f else uv_o, inv_cols, inv_rows)

		# 2) 分叉桥：每个水平子枝方向一格桥（本体表面 → 格边界）。
		# 竖直子枝无需桥——其首格下探 0.5 已与本盒贯穿交叠。
		# 桥从本体表面内 0.02 起——曾从格中心起：子枝比本体粗时
		# 桥截面大于细本体，把本体上下穿通成"十字穿模"。本体表面
		# 已近格边界（w≥0.45）则免桥（子枝起始即与本体表面贴合）。
		if not child_forks.has(cell):
			continue
		for fork_info: Array in child_forks[cell]:
			var bdir: Vector3i = fork_info[0]
			var wch: float = fork_info[1]
			if bdir.y != 0:
				continue
			var bw := maxf(w, wch)
			var inset := maxf(w - 0.02, 0.0)
			if 0.5 - inset < 0.05:
				continue
			var mnb := Vector3(cx - bw, cy + 0.5 - bw, cz - bw)
			var mxb := Vector3(cx + bw, cy + 0.5 + bw, cz + bw)
			if bdir.x > 0:
				mnb.x = cx + inset
				mxb.x = cx + 0.5
			elif bdir.x < 0:
				mxb.x = cx - inset
				mnb.x = cx - 0.5
			elif bdir.z > 0:
				mnb.z = cz + inset
				mxb.z = cz + 0.5
			else:
				mxb.z = cz - inset
				mnb.z = cz - 0.5
			for f in 6:
				_box(vertices, normals, uvs, indices, mnb, mxb, f,
						uv_o, inv_cols, inv_rows)


## 盒单面发射——**f 指定只发哪一面**（FACES 序：0=+X 1=-X 2=+Y
## 3=-Y 4=+Z 5=-Z）；完整盒由调用方 for f in 6 循环拼出。曾误改
## 为"循环六面全发"，全部调用点面数暴涨 6 倍（探针 mesh_tris
## 2952 vs 预期 ~500 实锤）。需要邻接剔除逐面控制的场合同用本函数。
static func _box(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		mn: Vector3, mx: Vector3, f: int,
		uv_o: Vector2, inv_cols: float, inv_rows: float
) -> void:
	_face(vertices, normals, uvs, indices, mn, mx, f,
			uv_o, inv_cols, inv_rows)


## 单面发射（f 同 _box 序）。供邻接剔除场景逐面调用——冠阴影
## 满密度格集合只发射暴露面（内部面原本被共面邻格覆盖，纯浪费）。
static func _face(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		mn: Vector3, mx: Vector3, f: int,
		uv_o: Vector2, inv_cols: float, inv_rows: float
) -> void:
	var base := vertices.size()
	var n := Vector3.ZERO
	match f:
		0: n = Vector3(1, 0, 0)
		1: n = Vector3(-1, 0, 0)
		2: n = Vector3(0, 1, 0)
		3: n = Vector3(0, -1, 0)
		4: n = Vector3(0, 0, 1)
		5: n = Vector3(0, 0, -1)
	# 每面四角（外向绕序；与 git 基线 _box 逐字一致——曾转录时把
	# f=3/f=4 的 c1/c2 的 mx.x 误写成 mn.x，两面退化成零面积线段，
	# 树"缺面"。改动必须对基线 grep 比对，不靠肉眼）
	var c0: Vector3
	var c1: Vector3
	var c2: Vector3
	var c3: Vector3
	match f:
		0:
			c0 = Vector3(mx.x,mn.y,mn.z)
			c1 = Vector3(mx.x,mx.y,mn.z)
			c2 = Vector3(mx.x,mx.y,mx.z)
			c3 = Vector3(mx.x,mn.y,mx.z)
		1:
			c0 = Vector3(mn.x,mn.y,mx.z)
			c1 = Vector3(mn.x,mx.y,mx.z)
			c2 = Vector3(mn.x,mx.y,mn.z)
			c3 = Vector3(mn.x,mn.y,mn.z)
		2:
			c0 = Vector3(mn.x,mx.y,mn.z)
			c1 = Vector3(mx.x,mx.y,mn.z)
			c2 = Vector3(mx.x,mx.y,mx.z)
			c3 = Vector3(mn.x,mx.y,mx.z)
		3:
			c0 = Vector3(mn.x,mn.y,mx.z)
			c1 = Vector3(mx.x,mn.y,mx.z)
			c2 = Vector3(mx.x,mn.y,mn.z)
			c3 = Vector3(mn.x,mn.y,mn.z)
		4:
			c0 = Vector3(mn.x,mn.y,mx.z)
			c1 = Vector3(mx.x,mn.y,mx.z)
			c2 = Vector3(mx.x,mx.y,mx.z)
			c3 = Vector3(mn.x,mx.y,mx.z)
		5:
			c0 = Vector3(mx.x,mn.y,mn.z)
			c1 = Vector3(mn.x,mn.y,mn.z)
			c2 = Vector3(mn.x,mx.y,mn.z)
			c3 = Vector3(mx.x,mx.y,mn.z)
	# 贴图不拉伸 + 方向统一：按面内 c0→c1 / c1→c2 两轴的世界尺寸
	# 等比采样（±X 面 y/z，±Y 面 x/z，±Z 面 x/y；不足 1 格裁切居
	# 中，超过封顶）。贴图 V 轴（木纹）统一对齐世界 Y——±X 面交换
	# u/v，±Z 面默认即 V↔Y，±Y 水平面 V↔Z——横枝与竖枝的贴图方向
	# 一致（曾木纹跟随段生长轴，横梁侧面纹理横置与主干不一致）。
	var a01 := 1
	var a12 := 2
	if f == 2 or f == 3:
		a01 = 0
	elif f >= 4:
		a01 = 0
		a12 = 1
	var s01 := absf(c1[a01] - c0[a01])
	var s12 := absf(c2[a12] - c1[a12])
	s01 = minf(s01, 1.0)
	s12 = minf(s12, 1.0)
	var swap_uv: bool = f == 0 or f == 1
	var us := s12 if swap_uv else s01
	var vs := s01 if swap_uv else s12
	var u0 := uv_o.x + (1.0 - us) * 0.5 * inv_cols
	var v0 := uv_o.y + (1.0 - vs) * 0.5 * inv_rows
	var du := us * inv_cols
	var dv := vs * inv_rows
	vertices.append(c0)
	vertices.append(c1)
	vertices.append(c2)
	vertices.append(c3)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	if swap_uv:
		uvs.append(Vector2(u0, v0))
		uvs.append(Vector2(u0, v0 + dv))
		uvs.append(Vector2(u0 + du, v0 + dv))
		uvs.append(Vector2(u0 + du, v0))
	else:
		uvs.append(Vector2(u0, v0))
		uvs.append(Vector2(u0 + du, v0))
		uvs.append(Vector2(u0 + du, v0 + dv))
		uvs.append(Vector2(u0, v0 + dv))
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
