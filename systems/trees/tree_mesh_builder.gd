## 树干网格构建（结构化树系统 v2）：BranchNode 图 → ArrayMesh。
## 每格一个**轴向盒**（截面半径 r 居中于格中心，轴向满格），
## 分叉格（有子枝）用**关节盒**（取各方向最大半径的完整盒）衔接。
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
	for bid in tree.branches:
		if subset_mode and not branch_subset.has(bid):
			continue
		var node: TreeInstance.BranchNode = tree.branches[bid]
		var is_joint := not node.child_ids.is_empty()
		_emit_branch_segment(vertices, normals, uvs, indices,
				tree, node, is_joint, origin,
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


## 一段枝干：逐格轴向盒（半径插值），分叉格（is_joint）用完整关节盒。
static func _emit_branch_segment(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		tree: TreeInstance, node: TreeInstance.BranchNode,
		is_joint: bool, origin: Vector3,
		uv_o: Vector2, uv_ot: Vector2, inv_cols: float, inv_rows: float
) -> void:
	var cells: Array = node.cells()
	var total: int = cells.size()
	if total == 0:
		return
	var axis := node.axis_step()
	var r0 := clampf(float(node.radius_start) / 8.0, 0.12, 1.0)
	var r1 := clampf(float(node.radius_end) / 8.0, 0.12, 1.0)

	# 预计算子枝的连接格（子枝 start 回退一步 = 本段上的分叉点）
	var fork_cells := {}
	for cid in node.child_ids:
		var child: TreeInstance.BranchNode = tree.branches.get(cid)
		if child != null:
			fork_cells[child.start_cell - child.axis_step()] = true

	for i in total:
		var cell: Vector3i = cells[i]
		var t := float(i) / float(maxi(total - 1, 1))
		var w := clampf(lerpf(r0, r1, t), 0.12, 1.0)
		# 关节盒只用在**子枝连接格**（分叉点，三轴满格——水平枝
		# 从满格侧面伸出保证连续；主干中部的 attach 格曾是间隙
		# 断裂处，且暴露内部面=贴图错乱）
		var is_joint_cell: bool = fork_cells.has(cell)
		# 格中心（世界→树局部）：水平 +0.5，y 不加（柱从格底到格顶）
		var cx := float(cell.x - origin.x) + 0.5
		var cy := float(cell.y - origin.y)
		var cz := float(cell.z - origin.z) + 0.5

		if is_joint_cell:
			# 弯曲连接（渐进阶梯，非满格方块）：
			# a) 主干截面 w 的竖直盒（y 满）
			# b) 角过渡盒（截面 (w+枝w)/2，向枝方向偏移 0.25——阶梯）
			# c) 枝截面枝w 的短水平盒（从格中心到格边界，长 0.5）。
			# 枝首格的轴向盒从格边界开始，与 c) 贴合
			var wmax := 0.0
			var branch_dir := Vector3i.ZERO
			for cid in node.child_ids:
				var ch: TreeInstance.BranchNode = tree.branches.get(cid)
				if ch != null and ch.start_cell - ch.axis_step() == cell:
					branch_dir = ch.axis_step()
					wmax = maxf(wmax, clampf(
							float(ch.radius_start) / 8.0, 0.12, 1.0))
			wmax = maxf(wmax, w)
			# a) 竖直主盒
			var mna := Vector3(cx - w, cy, cz - w)
			var mxa := Vector3(cx + w, cy + 1, cz + w)
			for f in 6:
				_box(vertices, normals, uvs, indices, mna, mxa, f,
						uv_ot if f == 2 or f == 3 else uv_o,
						inv_cols, inv_rows)
			# b+c) 向枝方向的过渡（两级阶梯：中截面 + 枝截面短盒）
			var mid_w := (w + wmax) * 0.5
			for step_w in [mid_w, wmax]:
				var reach := 0.25 if step_w == mid_w else 0.5
				var mnb := Vector3(cx - step_w, cy + 0.5 - step_w,
						cz - step_w)
				var mxb := Vector3(cx + step_w, cy + 0.5 + step_w,
						cz + step_w)
				if branch_dir.x > 0:
					mnb.x = cx
					mxb.x = cx + reach
				elif branch_dir.x < 0:
					mxb.x = cx
					mnb.x = cx - reach
				elif branch_dir.z > 0:
					mnb.z = cz
					mxb.z = cz + reach
				elif branch_dir.z < 0:
					mxb.z = cz
					mnb.z = cz - reach
				elif branch_dir.y != 0:
					mnb.y = cy
					mxb.y = cy + 1
				for f in 6:
					_box(vertices, normals, uvs, indices, mnb, mxb, f,
							uv_o, inv_cols, inv_rows)
		elif axis == Vector3i(0, 1, 0):
			# 竖直段：截面 w 居中，y 满。**首格向下多伸 0.5**——
			# 上翘段首格的柱底原本在整数 y（水平段盒中心 cy+0.5 之上
			# 0.25-0.4 格 = 竖直间隙，"没有连接"的真正位置）
			var y_bottom := cy - (0.5 if i == 0 else 0.0)
			var mn := Vector3(cx - w, y_bottom, cz - w)
			var mx := Vector3(cx + w, cy + 1, cz + w)
			for f in 6:
				_box(vertices, normals, uvs, indices, mn, mx, f,
						uv_ot if f == 2 or f == 3 else uv_o,
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
			for f in 6:
				# 水平段轴向两端用年轮端面（f=0/1 为 ±X，f=4/5 为 ±Z）
				var end_face: bool = (axis.x != 0 and (f == 0 or f == 1)) 						or (axis.z != 0 and (f == 4 or f == 5))
				_box(vertices, normals, uvs, indices, mn2, mx2, f,
						uv_ot if end_face else uv_o, inv_cols, inv_rows)


## 六面盒发射（f = FACES 序：0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z）。
static func _box(
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
	# 每面四角（外向绕序）
	var corners: Array[Vector3]
	match f:
		0: corners = [Vector3(mx.x,mn.y,mn.z), Vector3(mx.x,mx.y,mn.z), Vector3(mx.x,mx.y,mx.z), Vector3(mx.x,mn.y,mx.z)]
		1: corners = [Vector3(mn.x,mn.y,mx.z), Vector3(mn.x,mx.y,mx.z), Vector3(mn.x,mx.y,mn.z), Vector3(mn.x,mn.y,mn.z)]
		2: corners = [Vector3(mn.x,mx.y,mn.z), Vector3(mx.x,mx.y,mn.z), Vector3(mx.x,mx.y,mx.z), Vector3(mn.x,mx.y,mx.z)]
		3: corners = [Vector3(mn.x,mn.y,mx.z), Vector3(mx.x,mn.y,mx.z), Vector3(mx.x,mn.y,mn.z), Vector3(mn.x,mn.y,mn.z)]
		4: corners = [Vector3(mn.x,mn.y,mx.z), Vector3(mx.x,mn.y,mx.z), Vector3(mx.x,mx.y,mx.z), Vector3(mn.x,mx.y,mx.z)]
		5: corners = [Vector3(mx.x,mn.y,mn.z), Vector3(mn.x,mn.y,mn.z), Vector3(mn.x,mx.y,mn.z), Vector3(mx.x,mx.y,mn.z)]
	for c in corners:
		vertices.append(c)
		normals.append(n)
	uvs.append(uv_o)
	uvs.append(uv_o + Vector2(inv_cols, 0))
	uvs.append(uv_o + Vector2(inv_cols, inv_rows))
	uvs.append(uv_o + Vector2(0, inv_rows))
	indices.append_array(PackedInt32Array([
		base, base + 2, base + 1,
		base, base + 3, base + 2,
	]))
