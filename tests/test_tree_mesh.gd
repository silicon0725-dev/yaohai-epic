## 树网格几何测试：枝干盒体连通性（防"枝干之间没有连接"回归）、
## 上翘拐角对齐（防横枝戳出）、贴图等比采样（防拉伸变形）、
## 年轮只上外露段端（防变径台阶缝隙出现年轮）。
## build_mesh 每 24 个顶点 = 一个 _box 调用 → 还原 AABB 盒列表，
## 盒间交叠（含贴面）做并查集连通分量；健康树网格必须单连通。
## 数据层测试（test_trees）不碰网格——枝干断裂曾从测试眼皮下逃过。
extends VoxelTestCase

const TreeGenScript := preload("res://systems/trees/tree_generator.gd")
const SpeciesScript := preload("res://systems/trees/tree_species.gd")
const MeshBuilderScript := preload("res://systems/trees/tree_mesh_builder.gd")


func run() -> void:
	_test_mesh_single_component()
	_test_upturn_corner_aligned()
	_test_uv_no_stretch()
	_test_rings_only_on_segment_ends()
	_test_grain_alignment()
	_test_shadow_mesh_shapes()
	_test_no_degenerate_quads()


## 还原网格的全部 AABB 盒（每盒 6 面 × 4 顶点 = 24 顶点）。
func _boxes_of(tree) -> Array:
	var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
	if mesh == null or mesh.get_surface_count() == 0:
		return []
	var arrays: Array = mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	@warning_ignore("integer_division")
	var box_count := vs.size() / 24
	var boxes: Array = []
	for b in box_count:
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for j in 24:
			var v: Vector3 = vs[b * 24 + j]
			mn = mn.min(v)
			mx = mx.max(v)
		boxes.append([mn, mx])
	return boxes


## 两盒在 eps 膨胀后三轴重叠（贴面算连通）。
func _boxes_connected(a: Array, b: Array, eps: float) -> bool:
	var amn: Vector3 = a[0]
	var amx: Vector3 = a[1]
	var bmn: Vector3 = b[0]
	var bmx: Vector3 = b[1]
	return amn.x - eps < bmx.x and amx.x + eps > bmn.x \
			and amn.y - eps < bmx.y and amx.y + eps > bmn.y \
			and amn.z - eps < bmx.z and amx.z + eps > bmn.z


func _find(parent: Dictionary, x: int) -> int:
	var root := x
	while parent[root] != root:
		root = parent[root]
	while parent[x] != root:
		var nxt: int = parent[x]
		parent[x] = root
		x = nxt
	return root


func _test_mesh_single_component() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var bad_seeds := 0
	for s in 30:
		var tree = TreeGenScript.generate(sp, 1000 + s, Vector3i(s * 60, 30, 7))
		var boxes: Array = _boxes_of(tree)
		if boxes.is_empty():
			check(false, "种子 %d：网格为空" % s)
			continue
		var parent := {}
		for i in boxes.size():
			parent[i] = i
		for i in boxes.size():
			var bi: Array = boxes[i]
			for j in range(i + 1, boxes.size()):
				if _boxes_connected(bi, boxes[j], 0.01):
					var ri := _find(parent, i)
					var rj := _find(parent, j)
					if ri != rj:
						parent[ri] = rj
		var comps := {}
		for i in boxes.size():
			comps[_find(parent, i)] = true
		if comps.size() > 1:
			bad_seeds += 1
			# 诊断：打印少数分量的盒（定位断口）
			var comp_size := {}
			for i in boxes.size():
				var r := _find(parent, i)
				if not comp_size.has(r):
					comp_size[r] = 0
				comp_size[r] = int(comp_size[r]) + 1
			for r in comp_size:
				if int(comp_size[r]) <= 3:
					for i in boxes.size():
						if _find(parent, i) == r:
							var box: Array = boxes[i]
							print("  种子 %d 孤立盒: %s .. %s" % [s, box[0], box[1]])
			check(false, "种子 %d：网格断裂为 %d 个连通分量（盒数 %d）"
					% [s, comps.size(), boxes.size()])
	check(bad_seeds == 0, "30 种子网格全部单连通（断连种子 %d 个）" % bad_seeds)


## 拐角对齐：水平末格承托上翘竖枝时，横枝不得越过竖枝柱外缘
## 戳出（曾满格轴向盒越过竖枝中心线半格，端面悬空）。
## 在"竖枝外缘 → 格边界"的戳出区（横枝末格截面条带内）不得
## 存在任何盒。
func _test_upturn_corner_aligned() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var bad := 0
	var junctions := 0
	for s in 30:
		var origin := Vector3i(s * 60, 30, 7)
		var tree = TreeGenScript.generate(sp, 1000 + s, origin)
		var boxes: Array = _boxes_of(tree)
		for bid in tree.branches:
			var node: TreeInstance.BranchNode = tree.branches[bid]
			if node.axis_step() != Vector3i(0, 1, 0):
				continue  # 只查竖直子枝
			if node.parent_id < 0 or not tree.branches.has(node.parent_id):
				continue
			var parent: TreeInstance.BranchNode = tree.branches[node.parent_id]
			var paxis: Vector3i = parent.axis_step()
			if paxis.y != 0:
				continue  # 父必须是水平段
			var fork: Vector3i = node.start_cell - Vector3i(0, 1, 0)
			if fork != parent.end_cell:
				continue
			junctions += 1
			# 局部坐标与截面（与 builder 同式）
			var cx := float(fork.x - origin.x) + 0.5
			var cy := float(fork.y - origin.y)
			var cz := float(fork.z - origin.z) + 0.5
			var wch := clampf(float(node.radius_start) / 8.0, 0.12, 1.0)
			var wtip := clampf(float(parent.radius_end) / 8.0, 0.12, 1.0)
			# 戳出区：轴向上越过子枝外缘到格边界（留 eps 容差），
			# 截面取横枝末格条带
			var e := 0.015
			var e2 := 0.02
			var rmn := Vector3.ZERO
			var rmx := Vector3.ZERO
			if paxis.x > 0:
				rmn = Vector3(cx + wch + e, cy + 0.5 - wtip - e2, cz - wtip - e2)
				rmx = Vector3(cx + 0.5 + e, cy + 0.5 + wtip + e2, cz + wtip + e2)
			elif paxis.x < 0:
				rmn = Vector3(cx - 0.5 - e, cy + 0.5 - wtip - e2, cz - wtip - e2)
				rmx = Vector3(cx - wch - e, cy + 0.5 + wtip + e2, cz + wtip + e2)
			elif paxis.z > 0:
				rmn = Vector3(cx - wtip - e2, cy + 0.5 - wtip - e2, cz + wch + e)
				rmx = Vector3(cx + wtip + e2, cy + 0.5 + wtip + e2, cz + 0.5 + e)
			else:
				rmn = Vector3(cx - wtip - e2, cy + 0.5 - wtip - e2, cz - 0.5 - e)
				rmx = Vector3(cx + wtip + e2, cy + 0.5 + wtip + e2, cz - wch - e)
			for box: Array in boxes:
				var bmn: Vector3 = box[0]
				var bmx: Vector3 = box[1]
				if rmn.x < bmx.x and rmx.x > bmn.x \
						and rmn.y < bmx.y and rmx.y > bmn.y \
						and rmn.z < bmx.z and rmx.z > bmn.z:
					bad += 1
					check(false, "种子 %d：横枝末格越过上翘竖枝戳出（fork=%s 盒 %s..%s）"
							% [s, fork, bmn, bmx])
					break
	check(junctions >= 30 * 4, "30 种子均有上翘拐角可查（实测 %d 处）" % junctions)
	check(bad == 0, "横枝末格全部与上翘竖枝拐角对齐（戳出 %d 处）" % bad)


## 贴图不拉伸：每个面（4 顶点一组）的 UV 采样尺寸必须与面内
## 两轴（c0→c1 / c1→c2，轴序与 builder _box 同表）的世界尺寸
## 等比（1 格 = 1 图块；曾满图块拉伸填充，细枝侧面像素被拉成
## 长方形）。木纹环绕会产生 u/v 互换模式，两种都合法。
func _test_uv_no_stretch() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var inv_c := 1.0 / TextureAtlasLoader.COLS
	var inv_r := 1.0 / TextureAtlasLoader.ROWS
	var bad := 0
	for s in 30:
		var tree = TreeGenScript.generate(sp, 1000 + s, Vector3i(s * 60, 30, 7))
		var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for q in range(0, vs.size(), 4):
			var n0: Vector3 = nrm[q]
			var ai := 0
			if absf(n0.y) > 0.5:
				ai = 1
			elif absf(n0.z) > 0.5:
				ai = 2
			var a01 := 1
			var a12 := 2
			if ai == 1 or ai == 2:
				a01 = 0
			if ai == 2:
				a12 = 1
			var c0: Vector3 = vs[q]
			var c1: Vector3 = vs[q + 1]
			var c2: Vector3 = vs[q + 2]
			var s01 := absf(c1[a01] - c0[a01])
			var s12 := absf(c2[a12] - c1[a12])
			var umn := Vector2(INF, INF)
			var umx := Vector2(-INF, -INF)
			for j in 4:
				var u: Vector2 = uv[q + j]
				umn = umn.min(u)
				umx = umx.max(u)
			var du := umx.x - umn.x
			var dv := umx.y - umn.y
			var ok_a: bool = absf(du - s01 * inv_c) < 2e-3 \
					and absf(dv - s12 * inv_r) < 2e-3
			var ok_b: bool = absf(du - s12 * inv_c) < 2e-3 \
					and absf(dv - s01 * inv_r) < 2e-3
			if not (ok_a or ok_b):
				bad += 1
	check(bad == 0, "全部面贴图等比采样不拉伸（拉伸面 %d 个）" % bad)


## 贴图方向统一：V 轴（木纹）对齐世界 Y（±X/±Z 面），±Y 水平面
## V 轴对齐 Z；U 轴 ±X 面对齐 Z、其余对齐 X——横枝与竖枝的贴图
## 方向一致（曾木纹跟随段生长轴，横梁侧面纹理横置与主干不一致）。
func _test_grain_alignment() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var inv_c := 1.0 / TextureAtlasLoader.COLS
	var inv_r := 1.0 / TextureAtlasLoader.ROWS
	var bad := 0
	for s in 30:
		var tree = TreeGenScript.generate(sp, 1000 + s, Vector3i(s * 60, 30, 7))
		var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for q in range(0, vs.size(), 4):
			var n0: Vector3 = nrm[q]
			var ai := 0
			if absf(n0.y) > 0.5:
				ai = 1
			elif absf(n0.z) > 0.5:
				ai = 2
			var va := 1
			var ua := 0
			if ai == 0:
				ua = 2
			elif ai == 1:
				va = 2
			var lo_v := INF
			var hi_v := -INF
			var lo_u := INF
			var hi_u := -INF
			var umn := Vector2(INF, INF)
			var umx := Vector2(-INF, -INF)
			for j in 4:
				var v: Vector3 = vs[q + j]
				lo_v = minf(lo_v, v[va])
				hi_v = maxf(hi_v, v[va])
				lo_u = minf(lo_u, v[ua])
				hi_u = maxf(hi_u, v[ua])
				var u: Vector2 = uv[q + j]
				umn = umn.min(u)
				umx = umx.max(u)
			if absf((umx.y - umn.y) - (hi_v - lo_v) * inv_r) > 2e-3 \
					or absf((umx.x - umn.x) - (hi_u - lo_u) * inv_c) > 2e-3:
				bad += 1
	check(bad == 0, "贴图方向统一（V↔Y/±Y 面 V↔Z，违规面 %d 个）" % bad)


## 年轮（log_top）只允许出现在各段的外露端面（末格外端 / 首格
## 根端，且该格无子枝续接）；变径台阶环带与子枝衔接处必须贴
## 树皮（曾逐格端面满贴年轮——"缝隙里出现年轮"）。
func _test_rings_only_on_segment_ends() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var tile_top := TextureAtlasLoader.tile_grid("log_top")
	var inv_c := 1.0 / TextureAtlasLoader.COLS
	var inv_r := 1.0 / TextureAtlasLoader.ROWS
	var top_umn := Vector2(float(tile_top.x) * inv_c, float(tile_top.y) * inv_r)
	var top_umx := top_umn + Vector2(inv_c, inv_r)
	var bad := 0
	var ring_quads := 0
	for s in 30:
		var origin := Vector3i(s * 60, 30, 7)
		var tree = TreeGenScript.generate(sp, 1000 + s, origin)
		# 全局分叉格集合（子枝 start 回退一步；与 builder 同式）
		var fork_cells := {}
		for bid in tree.branches:
			var ch: TreeInstance.BranchNode = tree.branches[bid]
			var fk: Vector3i = ch.start_cell - ch.axis_step()
			fork_cells[fk] = true
		# 允许年轮的平面：段端面（端格无子枝续接）。键 "轴|坐标"
		var allowed := {}
		for bid in tree.branches:
			var node: TreeInstance.BranchNode = tree.branches[bid]
			var cells: Array = node.cells()
			var ax: Vector3i = node.axis_step()
			var ai := 0
			if ax.y != 0:
				ai = 1
			elif ax.z != 0:
				ai = 2
			var sgn := ax.x + ax.y + ax.z
			var first: Vector3i = cells[0]
			var last: Vector3i = cells[cells.size() - 1]
			# 端面平面：顶端 = 末格边界外缘（sgn 方向）；根端 = 首格
			# 边界（竖直段首格带 0.5 下探盒，根面再低 0.5）
			var tip_plane := float(last[ai] - origin[ai]) + 0.5 + 0.5 * sgn
			var root_plane: float
			if ai == 1:
				root_plane = float(first[ai] - origin[ai]) - 0.5
			else:
				root_plane = float(first[ai] - origin[ai]) + 0.5 - 0.5 * sgn
			if not fork_cells.has(first):
				allowed["%d|%.4f" % [ai, root_plane]] = true
			if not fork_cells.has(last):
				allowed["%d|%.4f" % [ai, tip_plane]] = true
		# 扫描年轮面（uv 全部落在 log_top 图块内）
		var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for q in range(0, vs.size(), 4):
			var is_ring := true
			for j in 4:
				var u: Vector2 = uv[q + j]
				if u.x < top_umn.x + 1e-4 or u.x > top_umx.x - 1e-4 \
						or u.y < top_umn.y + 1e-4 or u.y > top_umx.y - 1e-4:
					is_ring = false
					break
			if not is_ring:
				continue
			ring_quads += 1
			var n0: Vector3 = nrm[q]
			var ai := 0
			if absf(n0.y) > 0.5:
				ai = 1
			elif absf(n0.z) > 0.5:
				ai = 2
			var coord: float = vs[q][ai]
			if not allowed.has("%d|%.4f" % [ai, coord]):
				bad += 1
				check(false, "种子 %d：非端面出现年轮（轴 %d @ %.3f）"
						% [s, ai, coord])
	check(ring_quads > 0, "年轮端面存在（实测 %d 个）" % ring_quads)
	check(bad == 0, "年轮只上外露段端（违规 %d 处）" % bad)


## 阴影代理网格（build_shadow_mesh）v2 契约：段级凸锥台 + 分叉格
## 整格立方。AABB 无法区分"单格段锥台"与"旧逐格盒"，故按语义判：
## ① 多格合并锥台必存在（任一轴 >1 格——树干渐细结构恢复）；
## ② 立方存在（分叉密封）；③ 无薄片（截面 = 2w ≥ 0.24）；
## ④ 盒数远小于枝干格数（防回退逐格发射——旧版盒数≈格数，
## 其阶梯凹环正是漏光根因）。
func _test_shadow_mesh_shapes() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var total_boxes := 0
	var total_cubes := 0
	var total_frusta := 0
	var slivers := 0
	var total_cells := 0
	for s in 10:
		var tree = TreeGenScript.generate(sp, 2000 + s, Vector3i(s * 60, 30, 7))
		total_cells += tree.cell_to_branch.size()
		var mesh: ArrayMesh = MeshBuilderScript.build_shadow_mesh(tree)
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		@warning_ignore("integer_division")
		var box_count := vs.size() / 24
		total_boxes += box_count
		for b in box_count:
			var mn := Vector3(INF, INF, INF)
			var mx := Vector3(-INF, -INF, -INF)
			for j in 24:
				var v: Vector3 = vs[b * 24 + j]
				mn = mn.min(v)
				mx = mx.max(v)
			var size := mx - mn
			var min_ext: float = min(size.x, min(size.y, size.z))
			if min_ext < 0.23:
				slivers += 1
			if size.x > 1.01 or size.y > 1.01 or size.z > 1.01:
				total_frusta += 1
			if absf(size.x - 1.0) <= 0.01 and absf(size.y - 1.0) <= 0.01 \
					and absf(size.z - 1.0) <= 0.01:
				total_cubes += 1
	check(total_boxes > 0, "阴影代理图元存在（实测 %d）" % total_boxes)
	check(slivers == 0, "无薄片图元（截面≥0.24，实测违规 %d）" % slivers)
	check(total_frusta > 0, "多格锥台存在（渐细结构恢复，实测 %d）"
			% total_frusta)
	check(total_cubes > 0, "分叉密封立方存在（实测 %d）" % total_cubes)
	check(total_boxes * 4 < total_cells * 3,
			"盒数明显少于格数（段合并生效 %d 盒 vs %d 格，比率 %.2f）"
			% [total_boxes, total_cells,
			float(total_boxes) / maxf(1.0, float(total_cells))])


## 盒面非退化（防"树缺面"）：_face 转录曾把 f=3(-Y)/f=4(+Z) 的
## c1/c2 的 mx.x 误写成 mn.x——两面退化成零面积线段直接消失
##（顶点数不变，AABB/连通性/UV 测试全部漏检，只有肉眼与像素能
## 看见）。契约：任何 quad 张成的三角形面积非零。只判退化、不判
## 绕序——历史顶点序各面本就不统一（索引 (0,2,1) 统一翻转 + 材质
## 双面），外向点积判据会每盒误报 2 面。
func _test_no_degenerate_quads() -> void:
	var sp: TreeSpecies = SpeciesScript.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bad_unit := 0
	for i in 20:
		var mn := Vector3(rng.randf_range(-5.0, -0.1), rng.randf_range(-5.0, -0.1), rng.randf_range(-5.0, -0.1))
		var mx := Vector3(rng.randf_range(0.1, 5.0), rng.randf_range(0.1, 5.0), rng.randf_range(0.1, 5.0))
		for f in 6:
			var vs := PackedVector3Array()
			var ns := PackedVector3Array()
			var uv := PackedVector2Array()
			var idx := PackedInt32Array()
			MeshBuilderScript._box(vs, ns, uv, idx, mn, mx, f,
					Vector2.ZERO, 1.0, 1.0)
			var gn := (vs[1] - vs[0]).cross(vs[2] - vs[0])
			if gn.length() < 0.002:
				bad_unit += 1
	check(bad_unit == 0, "_box 六面全部非退化（违规 %d）" % bad_unit)
	var bad_mesh := 0
	var bad_shadow := 0
	for s in 10:
		var tree = TreeGenScript.generate(sp, 3000 + s, Vector3i(s * 60, 30, 7))
		var mesh: ArrayMesh = MeshBuilderScript.build_mesh(tree)
		if mesh != null and mesh.get_surface_count() > 0:
			bad_mesh += _degenerate_quad_count(mesh)
		var smesh: ArrayMesh = MeshBuilderScript.build_shadow_mesh(tree)
		if smesh != null and smesh.get_surface_count() > 0:
			bad_shadow += _degenerate_quad_count(smesh)
	check(bad_mesh == 0, "build_mesh 无退化面（违规 %d）" % bad_mesh)
	check(bad_shadow == 0, "build_shadow_mesh 无退化面（违规 %d）" % bad_shadow)


func _degenerate_quad_count(mesh: ArrayMesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bad := 0
	for q in range(0, vs.size(), 4):
		var gn := (vs[q + 1] - vs[q]).cross(vs[q + 2] - vs[q])
		if gn.length() < 0.002:
			bad += 1
	return bad
