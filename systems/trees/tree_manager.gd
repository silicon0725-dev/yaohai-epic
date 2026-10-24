## 树管理器（结构化树系统 v1）：统一入口。
## - 引用计数生命周期：chunk ACTIVE/卸载钩子驱动（chunk_manager 的
##   两个可空 Callable），影响范围 ±TREE_REACH 内首个 chunk 激活时
##   建实体（确定性重放生成 + 应用砍伐记录），归零销毁
## - 砍伐管线：占位挖掘 → split → BFS 连通性 → 失支撑分量转
##   RigidBody3D（受控倒伏）→ 落地结算掉落物
## - 存档：cut 事件流入 world.json extra meta（drops 键同模式）
class_name TreeManager
extends Node3D

## 活动倒树刚体上限（超限跳过物理直接结算）
const MAX_FALLING_TREES := 8
## 倒树结算条件（秒）
const FALL_TIMEOUT := 5.0
const FALL_SETTLE_TIME := 1.0
## RigidBody 重力倍率：游戏手感重力 24.0 / 引擎默认 9.8
const GRAVITY_SCALE := 24.0 / 9.8

var world: VoxelWorld
var registry: VoxelRegistry
var item_registry: ItemRegistry
var species: TreeSpecies
## 全局反向索引：Vector3i（世界格）-> tree_id
var _cell_lookup := {}
## tree_id -> {instance, mesh_node, body, refs, cuts_applied}
var _trees := {}
## 活动倒树：RigidBody3D -> {cells: int, tree_origin, timer, settled}
var _falling := {}
## 砍伐事件流（存档）：按发生顺序
var _cut_events: Array = []
## 掉落结算回调（main 注入：spawn_drop）
var drop_spawner: Callable


func setup(p_world: VoxelWorld, p_registry: VoxelRegistry,
		p_items: ItemRegistry) -> void:
	world = p_world
	registry = p_registry
	item_registry = p_items
	species = TreeSpecies.new()
	# BRANCH 被挖（set_block AIR）时驱动砍伐管线——比 BlockMining 的
	# static var Callable 可靠（GDScript static var 在 static func 中
	# 赋值的 Callable 偶发 is_valid()=false）
	world.block_changed.connect(_on_block_changed)


func _on_block_changed(pos: Vector3i, old_id: int, new_id: int) -> void:
	if old_id == VoxelTypes.BRANCH_ID and new_id == VoxelTypes.AIR_ID:
		on_branch_broken(pos)


# ---- 生命周期（chunk_manager 钩子驱动） ----

## chunk ACTIVE 时：影响范围覆盖此 chunk 的树引用 +1。
func on_chunk_active(chunk_coord: Vector3i) -> void:
	# 只扫本 chunk 自身列（根列在本 chunk 的树归此 chunk 管理——
	# 树的 mesh/碰撞是独立实体不受区块边界影响；跨区块占位由
	# terrain_generator 的重放机制写入区块数据）。±TREE_REACH
	# 扫描曾导致每树被 ~25 个 chunk 重复建、视距内爆出 1221 棵。
	# 只处理 y=0 层（树根在地表层，y 层 chunk 不重复建树）。
	if chunk_coord.y != 0:
		return
	var size := world.config.chunk_size
	var ox := chunk_coord.x * size
	var oz := chunk_coord.z * size
	for wx in range(ox, ox + size):
		for wz in range(oz, oz + size):
			if TreeGenerator.has_tree_at(world.config.world_seed,
					Vector2i(wx, wz)):
				_ref_tree(Vector2i(wx, wz))


## chunk 卸载时：引用 -1，归零销毁实体。
func on_chunk_unloaded(chunk_coord: Vector3i) -> void:
	if chunk_coord.y != 0:
		return
	# 只减根列在本 chunk 的树（与 on_chunk_active 对称）
	var size := world.config.chunk_size
	var ox := chunk_coord.x * size
	var oz := chunk_coord.z * size
	for tree_id in _trees.keys():
		var entry: Dictionary = _trees[tree_id]
		var origin: Vector3i = entry["instance"].origin
		if origin.x >= ox and origin.x < ox + size 				and origin.z >= oz and origin.z < oz + size:
			_destroy_tree(tree_id)


## 查询某格所属树实例（无返回 null）。
func get_tree_at(cell: Vector3i) -> TreeInstance:
	var tid = _cell_lookup.get(cell, -1)
	if tid == -1 or not _trees.has(tid):
		return null
	return _trees[tid]["instance"]


func tree_count() -> int:
	return _trees.size()


# ---- 实体构建/销毁 ----

func _ref_tree(col: Vector2i) -> void:
	# 地形合法性（与 terrain_generator 撒树同判定——曾缺此检查，
	# 水域/沙地上凭空建出不可挖的光树干实体"幽灵树"）
	var prof: Dictionary = _get_gen().column_profile(col.x, col.y)
	if int(prof["height"]) <= TerrainGenerator.SEA_LEVEL:
		return  # 水域/滩涂
	if prof.get("sandy", false) or prof.get("rocky", false):
		return  # 荒漠沙/裸岩
	var surf: int = int(prof["height"])
	var origin := Vector3i(col.x, surf + 1, col.y)
	var tree_id := hash([world.config.world_seed, origin.x, origin.z])
	if _trees.has(tree_id):
		_trees[tree_id]["refs"] = int(_trees[tree_id]["refs"]) + 1
		return
	# 首次引用：确定性重建 + 应用砍伐记录
	var tree := TreeGenerator.generate(species,
			world.config.world_seed, origin)
	var entry := {
		"instance": tree, "mesh_node": null, "body": null, "refs": 1,
	}
	_trees[tree_id] = entry
	for cell in tree.cell_to_branch:
		_cell_lookup[cell] = tree_id
	_apply_cuts(tree, tree_id)
	_build_visual(tree_id)


var _terrain_gen = null

func _get_gen():
	if _terrain_gen == null:
		_terrain_gen = TerrainGenerator.new(world.config)
	return _terrain_gen


func _apply_cuts(tree: TreeInstance, tree_id: int) -> void:
	for event in _cut_events:
		if event.get("tree", [-1, -1, -1]) == [tree.origin.x, tree.origin.y, tree.origin.z]:
			var cell_arr: Array = event.get("cell", [])
			if cell_arr.size() == 3:
				var cell := Vector3i(cell_arr[0], cell_arr[1], cell_arr[2])
				tree.split_branch_at_cell(cell)
				tree.record_cut(cell)
	# 清除被切格与失支撑分量的索引
	_prune_unsupported(tree)


func _prune_unsupported(tree: TreeInstance) -> void:
	var unsup := tree.find_unsupported()
	if unsup.is_empty():
		return
	for bid in unsup:
		if tree.branches.has(bid):
			var node: TreeInstance.BranchNode = tree.branches[bid]
			for cell in node.cells():
				tree.cell_to_branch.erase(cell)
				_cell_lookup.erase(cell)
			tree.branches.erase(bid)
	# 从剩余枝的 child 列表清掉已删的
	for bid in tree.branches:
		var node: TreeInstance.BranchNode = tree.branches[bid]
		node.child_ids = node.child_ids.filter(
				func(cid): return tree.branches.has(cid))


func _build_visual(tree_id: int) -> void:
	var entry: Dictionary = _trees[tree_id]
	var tree: TreeInstance = entry["instance"]
	# 清旧
	if entry["mesh_node"] != null:
		entry["mesh_node"].queue_free()
	if entry["body"] != null:
		entry["body"].queue_free()
	# 树干 mesh（独立合并网格）
	var mesh := TreeMeshBuilder.build_mesh(tree)
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Tree_%d" % tree_id
	mi.mesh = mesh
	mi.material_override = _wood_material()
	mi.position = Vector3(tree.origin)
	add_child(mi)
	entry["mesh_node"] = mi
	# 碰撞：简化盒（主干段区域，一个 BoxShape）
	var body := StaticBody3D.new()
	body.name = "TreeBody_%d" % tree_id
	body.position = Vector3(tree.origin)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var trunk = tree.branches.get(tree.root_branch_id)
	if trunk != null:
		var h := maxi(1, trunk.end_cell.y - trunk.start_cell.y + 1)
		var w := float(trunk.radius_start) / 8.0
		box.size = Vector3(w * 2.0, float(h), w * 2.0)
		shape.shape = box
		body.add_child(shape)
		shape.position = Vector3(
				float(trunk.start_cell.x) + 0.5 - float(tree.origin.x),
				float(h) / 2.0,
				float(trunk.start_cell.z) + 0.5 - float(tree.origin.z))
	add_child(body)
	entry["body"] = body


func _destroy_tree(tree_id: int) -> void:
	var entry: Dictionary = _trees[tree_id]
	if entry["mesh_node"] != null:
		entry["mesh_node"].queue_free()
	if entry["body"] != null:
		entry["body"].queue_free()
	for cell in entry["instance"].cell_to_branch:
		_cell_lookup.erase(cell)
	_trees.erase(tree_id)


# ---- 砍伐管线（block_mining 转来） ----

## BRANCH 占位被挖：管线 = split → BFS → 脱落分量转刚体 →
## 重建保留树 → 叶清除 → 落地结算。
func on_branch_broken(cell: Vector3i) -> void:
	var tree := get_tree_at(cell)
	if tree == null:
		return
	tree.split_branch_at_cell(cell)
	tree.record_cut(cell)
	_cut_events.append({
		"op": "cut",
		"cell": [cell.x, cell.y, cell.z],
		"tree": [tree.origin.x, tree.origin.y, tree.origin.z],
	})
	# 被挖格的 set_block 已由 BlockMining 完成（信号驱动本函数）
	_cell_lookup.erase(cell)

	# BFS 连通性
	var unsup := tree.find_unsupported()
	if not unsup.is_empty():
		var cells := tree.cells_of_branches(unsup)
		# 脱落分量的叶格（倒树视觉跟随——先收集再清除）
		var fallen_leaves := _collect_leaves_near(cells)
		# 从结构中移除失支撑分支
		for bid in unsup:
			if tree.branches.has(bid):
				var node: TreeInstance.BranchNode = tree.branches[bid]
				for c in node.cells():
					tree.cell_to_branch.erase(c)
					_cell_lookup.erase(c)
				tree.branches.erase(bid)
		for bid in tree.branches:
			var node: TreeInstance.BranchNode = tree.branches[bid]
			node.child_ids = node.child_ids.filter(
					func(cid): return tree.branches.has(cid))
		# 占位清除（set_block AIR 走区块管线；会再次触发本信号但
		# get_tree_at 已返回 null，无递归）
		for c in cells:
			if world.get_block(c) == VoxelTypes.BRANCH_ID:
				world.set_block(c, VoxelTypes.AIR_ID, false)
		# 叶占位清除（走区块管线）
		for leaf_cell in fallen_leaves:
			if world.get_block(leaf_cell) == VoxelTypes.LEAVES_ID:
				world.set_block(leaf_cell, VoxelTypes.AIR_ID, false)
		# 转刚体（或超限直接结算）
		if _falling.size() < MAX_FALLING_TREES and cells.size() >= 3:
			_spawn_falling_rigid(tree, unsup, cells, fallen_leaves)
		else:
			_settle_drop(cells.size(),
					Vector3(cells[0]) + Vector3(0.5, 0.5, 0.5))

	# 重建保留树视觉
	tree.revision += 1
	if tree.cell_to_branch.is_empty():
		_destroy_tree(tree.tree_id)
	else:
		_build_visual(tree.tree_id)


func _spawn_falling_rigid(tree: TreeInstance,
		unsup: Dictionary, cells: Array[Vector3i],
		leaves: Array[Vector3i]) -> void:
	var body := RigidBody3D.new()
	body.gravity_scale = GRAVITY_SCALE
	# 受控倒伏：绕切点向质心偏移方向翻倒
	var centroid := Vector3.ZERO
	for c in cells:
		centroid += Vector3(c) + Vector3(0.5, 0.5, 0.5)
	centroid /= float(cells.size())
	var cut_cell: Vector3i = tree.cut_cells[tree.cut_cells.size() - 1]
	var pivot := Vector3(cut_cell) + Vector3(0.5, 0.5, 0.5)
	var lean := Vector3(centroid.x - pivot.x, 0, centroid.z - pivot.z)
	if lean.length() < 0.1:
		lean = Vector3(1, 0, 0)
	lean = lean.normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([tree.origin.x, tree.origin.z, cut_cell])
	lean = lean.rotated(Vector3.UP, rng.randf() * 0.6 - 0.3).normalized()
	body.angular_velocity = Vector3(lean.z, 0, -lean.x) * 1.2
	body.linear_velocity = lean * 0.3

	# **真实枝干 mesh 子集**（TreeMeshBuilder 只建脱落分支——正确
	# 贴图与形状，不用 BoxMesh 链）
	var sub_mesh := TreeMeshBuilder.build_mesh(tree, unsup)
	if sub_mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = sub_mesh
		mi.material_override = _wood_material()
		# 顶点以树根为原点——刚体在 pivot，需要偏移
		mi.position = Vector3(tree.origin) - pivot
		body.add_child(mi)
	# **叶视觉**（叶球盒，绿色材质——不做精确叶网格）
	if not leaves.is_empty():
		var leaf_holder := MeshInstance3D.new()
		var leaf_arrays := []
		leaf_arrays.resize(Mesh.ARRAY_MAX)
		var lv := PackedVector3Array()
		var li := PackedInt32Array()
		for lc in leaves:
			var c := Vector3(lc) + Vector3(0.5, 0.5, 0.5) - pivot
			var b0 := lv.size()
			for corner in [
				c + Vector3(-0.5,-0.5,-0.5), c + Vector3(0.5,-0.5,-0.5),
				c + Vector3(0.5,0.5,-0.5), c + Vector3(-0.5,0.5,-0.5),
				c + Vector3(-0.5,-0.5,0.5), c + Vector3(0.5,-0.5,0.5),
				c + Vector3(0.5,0.5,0.5), c + Vector3(-0.5,0.5,0.5),
			]:
				lv.append(corner)
			for tri in [
				[b0,b0+2,b0+1],[b0,b0+3,b0+2],[b0+4,b0+5,b0+6],[b0+4,b0+6,b0+7],
				[b0,b0+1,b0+5],[b0,b0+5,b0+4],[b0+3,b0+7,b0+6],[b0+3,b0+6,b0+2],
				[b0+1,b0+2,b0+6],[b0+1,b0+6,b0+5],[b0,b0+4,b0+7],[b0,b0+7,b0+3],
			]:
				li.append_array(PackedInt32Array(tri))
		leaf_arrays[Mesh.ARRAY_VERTEX] = lv
		leaf_arrays[Mesh.ARRAY_INDEX] = li
		var lm := ArrayMesh.new()
		lm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arrays)
		leaf_holder.mesh = lm
		leaf_holder.material_override = _leaf_material()
		body.add_child(leaf_holder)

	# 碰撞（简化盒）
	var shape := CollisionShape3D.new()
	var cshape := BoxShape3D.new()
	cshape.size = Vector3(0.8, float(cells.size()) * 0.5, 0.8)
	shape.shape = cshape
	shape.position = centroid - pivot
	body.add_child(shape)
	body.position = pivot
	add_child(body)
	_falling[body] = {
		"cells": cells.size(),
		"timer": 0.0,
		"settled": 0.0,
	}


var _leaf_mat: StandardMaterial3D = null
var _wood_mat: StandardMaterial3D = null


func _wood_material() -> StandardMaterial3D:
	if _wood_mat == null:
		_wood_mat = DropVisuals.atlas_material().duplicate()
		_wood_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _wood_mat

func _leaf_material() -> StandardMaterial3D:
	if _leaf_mat == null:
		_leaf_mat = StandardMaterial3D.new()
		_leaf_mat.albedo_color = Color(0.18, 0.38, 0.13)
	return _leaf_mat


## 收集枝干格周围 2 格内的叶格（倒树跟随用）。
func _collect_leaves_near(cells: Array[Vector3i]) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for cell in cells:
		for d in [
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			Vector3i(1, 1, 0), Vector3i(-1, 1, 0),
			Vector3i(0, 1, 1), Vector3i(0, 1, -1),
			Vector3i(1, 1, 1), Vector3i(-1, 1, -1),
		]:
			var p: Vector3i = cell + d
			if world.get_block(p) == VoxelTypes.LEAVES_ID and not out.has(p):
				out.append(p)
	return out


func _process(delta: float) -> void:
	for body in _falling.keys():
		var info: Dictionary = _falling[body]
		info["timer"] = float(info["timer"]) + delta
		if body.linear_velocity.length() < 0.5 and body.angular_velocity.length() < 0.3:
			info["settled"] = float(info["settled"]) + delta
		else:
			info["settled"] = 0.0
		if float(info["settled"]) >= FALL_SETTLE_TIME \
				or float(info["timer"]) >= FALL_TIMEOUT:
			_settle_drop(int(info["cells"]))
			body.queue_free()
			_falling.erase(body)


func _settle_drop(cell_count: int, near := Vector3.ZERO) -> void:
	if not drop_spawner.is_valid():
		return
	var logs := maxi(1, cell_count / 3)
	var sticks := maxi(1, cell_count / 5)
	drop_spawner.call(registry.id_for_name("core:log"), logs, near)
	drop_spawner.call(registry.id_for_name("core:stick"), sticks,
			near + Vector3(0.5, 0.0, 0.5))


# ---- 存档 ----

func get_save_bundle() -> Dictionary:
	return {"trees": {"algorithm": "treegen-v1", "events": _cut_events}}


func apply_save_state(data: Dictionary) -> void:
	var trees_data: Dictionary = data.get("trees", {})
	if trees_data.get("algorithm", "") != "treegen-v1":
		push_warning("未知树存档算法版本，跳过树事件重放")
		return
	_cut_events = trees_data.get("events", [])
