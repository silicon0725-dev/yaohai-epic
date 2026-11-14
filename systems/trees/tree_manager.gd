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
## 动画倒树驱动参数（DT FalloverAnimationHandler 同构——三自由度
## 合成：绕断口旋转 + 整树重力下坠 + 地面钉住；贴合地形由逐段碰撞
## 反馈涌现，无预计算角）：
## FALL_TURN_ACC_DT=每秒角加速 4/height（DT 每 tick +0.2/height）；
## FALL_SINK_SPEED=整树下坠速率（闭合断口到地面的空隙，抵消侧枝
## 上扬）；FALL_ELASTICITY=碰撞反弹系数（DT TREE_ELASTICITY 0.25）；
## FALL_LAND_SPEED=弹跳衰减落地阈值（DT 同 0.02）；
## FALL_COLLISION_DELAY=起转后碰撞检测延迟（DT 10 tick 防自家脏块）；
## FALL_MAX_ANGLE=转头上限（DT shouldDie 160°——倒栽进低处时终止）
const FALL_TURN_ACC_DT := 4.0
const FALL_SINK_SPEED := 5.0
const FALL_ELASTICITY := 0.25
const FALL_LAND_SPEED := 0.02
const FALL_COLLISION_DELAY := 0.25
const FALL_MAX_ANGLE := deg_to_rad(160.0)
## 消失动画时长（秒）：落地停稳后抖动透明溶解（tree_surface 的
## instance uniform dissolve，世界坐标 hash discard——非 alpha 透明，
## 不透明渲染路径无排序成本）。掉落物在溶解开始时结算（树消散=物
## 已落地）
const FALL_DISSOLVE_TIME := 1.0

var world: VoxelWorld
var registry: VoxelRegistry
var item_registry: ItemRegistry
var species: TreeSpecies
## 全局反向索引：Vector3i（世界格）-> tree_id
var _cell_lookup := {}
## tree_id -> {instance, mesh_node, body, refs, cuts_applied}
var _trees := {}
## v9 按列计数生命周期：已计数的活跃区块（防同步/异步两路重复计数）
## 与每列活跃区块数（归零才回收根列在本列的树）
var _active_chunks := {}  # Vector3i -> true
var _col_active := {}     # Vector2i -> int
## 活动倒树：RigidBody3D -> {cells: int, tree_origin, timer, settled}
##（树枝分量——小质量物理掉落）
var _falling := {}
## 动画倒树：Node3D -> {ang, vel, axis, cells, timer}
##（主干砍断——DT 语义：绕切点朝砍击者方向受控倒下，不进物理
## 引擎。刚体倒树旁有方块会接触抖动（实机"抽搐"），整树倒伏
## 改脚本动画根治；物理化只保留给树枝小分量）
var _falling_anims := {}
## 砍击者位置提供（main 注入 func(): return player）——主干倒向
## 砍树的人；无效时退化为质心偏移方向
var player_provider: Callable
## 砍伐事件流（存档）：按发生顺序
var _cut_events: Array = []
const MAX_CUT_EVENTS := 256
## 掉落结算回调（main 注入：spawn_drop）
var drop_spawner: Callable
## 光照脏树（快速通道）：方块光语义变化（放/挖光源、遮挡变化）
## 时**光照数据已同步落定**——voxel_light 在 block_changed 信号内
## 同步完成 BFS 才返回，重烘无需等管线空闲。曾误等 is_idle：区块
## remesh 队列可拖秒级，树干光照更新明显滞后于地面光池（实机报告）
var _light_dirty := {}
## tid -> 上次重烘时刻（BAKE_COOLDOWN_MSEC 冷却用）
var _bake_last := {}
## 异步首建队列：tid -> {task_id, tree, snap, rev, trunk, crown, shadow}
var _tree_async := {}
## 列 -> [tid] 空间索引（origin 列）：光照脏标记曾对全部树做
## O(N) AABB 扫——世界加载 2000+ 棵后每次挖/放（block_changed
## 信号扇出）12-22ms（实机"快速放方块卡"）。现只查编辑格附近
## 列的树
var _trees_by_col := {}
## 树 AABB 水平最大半径（列索引扫描半径用，保守值）
const TREE_MAX_RADIUS := 8
var _light_dirty_wait := 0.0
## 首建待定树（慢通道）：需邻块到齐才首烘，空闲门控 + 2s 兜底
var _build_pending := {}
var _build_pending_wait := 0.0
## 每帧重烘上限（初次加载后全量标脏一次，限量防单帧长卡）
## 每帧重烘棵数上限：单棵全量重建（几何+逐面光照采样+冠影+上传）
## 5-15ms——曾 4 棵/帧=20-60ms 硬卡（实机"放/挖方块卡一下"：挖放
## 把 3 格内树标脏，合并窗后一次烘）。1 棵/帧把峰值摊成毫秒级毛刺，
## 多棵依次更新 2-3 帧完成，火把点亮感知仍即时
const REBUILD_BUDGET_PER_FRAME := 1
## 单树重烘冷却（毫秒）：连续放拆合并成末态一次
const BAKE_COOLDOWN_MSEC := 400
## 异步首建：每帧入队/提交上限（入队=快照 ~0.2ms，提交 ~1ms）
const ASYNC_ENQUEUE_BUDGET := 8
const ASYNC_COMMIT_BUDGET := 4
## 管线空闲判定（main 注入 chunk_manager.is_idle）：光照传播是排队
## 异步的——过早重烘会采到未更新的光照烘焙进网格（实测 0.15s 时
## torch 邻格仍是 blk=0）。invalid 时退回纯时间窗（测试用）。
var idle_check: Callable


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
		return
	_mark_light_dirty(pos, old_id, new_id)


## 光照相关方块变化（放/挖光源、封挡/挖开遮挡）→ 标脏附近树。
## 树网格顶点色是 _build_visual 建网格时的烘焙采样——不重建则之后
## 放置的火把/提灯永远照不亮枝干（实机报告）。光源变化按影响半径
## 16（火把 14 级衰减全距），遮挡变化按局部 3 格近似（水流同一
## id 不触发：old_id == new_id 早退）。
static func _light_emission(id: int) -> int:
	if id >= 0 and id < VoxelTypes.LIGHT_EMISSION.size():
		return VoxelTypes.LIGHT_EMISSION[id]
	return 0


func _mark_light_dirty(pos: Vector3i, old_id: int, new_id: int) -> void:
	if old_id == new_id:
		return
	if _light_emission(old_id) == _light_emission(new_id) \
			and VoxelTypes.light_opacity(old_id) \
					== VoxelTypes.light_opacity(new_id):
		return
	var margin := 16.0 if (_light_emission(old_id) > 0
			or _light_emission(new_id) > 0) else 3.0
	var p := Vector3(pos)
	# 列索引扫描：编辑格 (margin+TREE_MAX_RADIUS) 范围内的列才可能
	# 有 AABB 够得着的树——曾 O(全部树) AABB 扫（2000+ 棵 12-22ms）
	var r := int(ceil(margin)) + TREE_MAX_RADIUS
	for cx in range(pos.x - r, pos.x + r + 1):
		for cz in range(pos.z - r, pos.z + r + 1):
			var tids: Array = _trees_by_col.get(Vector2i(cx, cz), [])
			for tid in tids:
				if not _trees.has(tid):
					continue
				var aabb: AABB = _trees[tid]["aabb"]
				var nearest := p.clamp(aabb.position, aabb.end)
				if nearest.distance_to(p) <= margin:
					_light_dirty[tid] = true


# ---- 生命周期（chunk_manager 钩子驱动） ----

## chunk ACTIVE 时：相交树光照标脏；列内首个区块激活时撒树。
## v9 按列计数（垂直流式：列的活跃层随加载带伸缩，y==0 多半不
## 加载——曾按 y==0 回收，带内的树永不回收=泄漏）。只扫本列根列
## （树 mesh/碰撞是独立实体不受区块边界影响；跨区块占位由
## terrain_generator 的重放机制写入区块数据）。±TREE_REACH 扫描曾
## 导致每树被 ~25 个 chunk 重复建、视距内爆出 1221 棵。
func on_chunk_active(chunk_coord: Vector3i) -> void:
	# 曾激活时把 AABB 相交树标脏（补烘首建缺失的邻块光照）——已删：
	# 首建走 _build_pending 慢通道等管线空闲（邻块数据已全），首烘
	# 即正确；激活补烘实为纯冗余——实机会话 26 次放拆触发 1229 次
	# 重建、415 棵 distinct（玩家走动 chunk 激活流×每棵一次补烘），
	# budget=1 下仍每帧 4-10ms 毛刺。挖放标脏（_mark_light_dirty）
	# 不受影响，光照变化照常更新
	if _active_chunks.has(chunk_coord):
		return
	_active_chunks[chunk_coord] = true
	var col := Vector2i(chunk_coord.x, chunk_coord.z)
	var n: int = int(_col_active.get(col, 0)) + 1
	_col_active[col] = n
	if n == 1:
		_scan_column_trees(col)


## 本列 16×16 根列撒树（确定性重建，_ref_tree 内做地形合法性判定）。
func _scan_column_trees(col: Vector2i) -> void:
	var size := world.config.chunk_size
	var ox := col.x * size
	var oz := col.y * size
	for wx in range(ox, ox + size):
		for wz in range(oz, oz + size):
			if TreeGenerator.has_tree_at(world.config.world_seed,
					Vector2i(wx, wz)):
				_ref_tree(Vector2i(wx, wz))


## chunk 卸载时：列内最后一个活跃区块卸载才回收根列在本列的树。
func on_chunk_unloaded(chunk_coord: Vector3i) -> void:
	if not _active_chunks.has(chunk_coord):
		return  # 未激活即卸载（仅 DATA_READY）：未计数
	_active_chunks.erase(chunk_coord)
	var col := Vector2i(chunk_coord.x, chunk_coord.z)
	var n: int = int(_col_active.get(col, 1)) - 1
	if n > 0:
		_col_active[col] = n
		return
	_col_active.erase(col)
	var size := world.config.chunk_size
	var ox := col.x * size
	var oz := col.y * size
	for tree_id in _trees.keys():
		var entry: Dictionary = _trees[tree_id]
		var origin: Vector3i = entry["instance"].origin
		if origin.x >= ox and origin.x < ox + size \
				and origin.z >= oz and origin.z < oz + size:
			_destroy_tree(tree_id)


## 查询某格所属树实例（无返回 null）。
func get_tree_at(cell: Vector3i) -> TreeInstance:
	var tid = _cell_lookup.get(cell, -1)
	if tid == -1 or not _trees.has(tid):
		return null
	return _trees[tid]["instance"]


## 掉落物碰撞探针（main 接线给 DropManager.trunk_solid_probe）：
## 该格是否属于活树的**主干段**。混合方案下掉落物走体素点碰撞，
## 感知不到树的 StaticBody，主干占位格又是 collision:false——
## "对着树丢东西穿树"由此而来；靠本查询把主干格补为实心。
## 实时读 cell_to_branch：切割/缩短/倒树后格自动失效，无状态同步。
func is_solid_for_items(cell: Vector3i) -> bool:
	var tid = _cell_lookup.get(cell, -1)
	if tid == -1 or not _trees.has(tid):
		return false
	var tree: TreeInstance = _trees[tid]["instance"]
	return tree.cell_to_branch.get(cell) == tree.root_branch_id


func tree_count() -> int:
	return _trees.size()


# ---- 实体构建/销毁 ----

func _ref_tree(col: Vector2i) -> void:
	# 地形合法性（与 terrain_generator 撒树同判定——曾缺此检查，
	# 水域/沙地上凭空建出不可挖的光树干实体"幽灵树"）
	var prof: Dictionary = _get_gen().column_profile(col.x, col.y)
	if int(prof["height"]) <= _get_gen().sea_level:
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
	# 枝干 AABB（供光照脏标记的邻近判定；砍伐缩枝后偏大仅多触发，
	# 保守无害）
	var mn := Vector3i(1 << 29, 1 << 29, 1 << 29)
	var mx := Vector3i(-(1 << 29), -(1 << 29), -(1 << 29))
	for cell in tree.cell_to_branch:
		mn.x = mini(mn.x, cell.x)
		mn.y = mini(mn.y, cell.y)
		mn.z = mini(mn.z, cell.z)
		mx.x = maxi(mx.x, cell.x)
		mx.y = maxi(mx.y, cell.y)
		mx.z = maxi(mx.z, cell.z)
	var entry := {
		"instance": tree, "mesh_node": null, "body": null, "refs": 1,
		"aabb": AABB(Vector3(mn), Vector3(mx - mn) + Vector3.ONE),
	}
	_trees[tree_id] = entry
	var ocol := Vector2i(origin.x, origin.z)
	if not _trees_by_col.has(ocol):
		_trees_by_col[ocol] = []
	(_trees_by_col[ocol] as Array).append(tree_id)
	for cell in tree.cell_to_branch:
		_cell_lookup[cell] = tree_id
	_apply_cuts(tree, tree_id)
	# 首建走慢通道（空闲门控）：根列 chunk 激活瞬间邻块常未就绪，
	# 立即构建会把未加载跨块面烘成回退色——等管线空闲再首烘
	_build_pending[tree_id] = true


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


func _build_visual(tree_id: int, light_only := false) -> void:
	var _t0 := Time.get_ticks_usec()
	var _bd := _build_visual_impl(tree_id, light_only)
	var _dt := Time.get_ticks_usec() - _t0
	if _dt > 2000:
		print("[perf] tree_rebuild %.1fms tid=%d%s (mesh %.1f crown %.1f shadow %.1f)"
				% [_dt * 0.001, tree_id,
						" light-only" if light_only else "",
						float(_bd.get("mesh", 0)) * 0.001,
						float(_bd.get("crown", 0)) * 0.001,
						float(_bd.get("shadow", 0)) * 0.001])


func _build_visual_impl(tree_id: int, light_only := false) -> Dictionary:
	var entry: Dictionary = _trees[tree_id]
	var tree: TreeInstance = entry["instance"]
	# 清旧
	if entry["mesh_node"] != null:
		entry["mesh_node"].queue_free()
	if entry["body"] != null:
		entry["body"].queue_free()
	# 树干 mesh（独立合并网格）——唯一含顶点色光照采样的部分，
	# 光照重烘必须重建
	var _m0 := Time.get_ticks_usec()
	var mesh := TreeMeshBuilder.build_mesh(tree, {}, world)
	var _t_mesh: int = Time.get_ticks_usec() - _m0
	if mesh == null:
		return {}
	var mi := MeshInstance3D.new()
	mi.name = "Tree_%d" % tree_id
	mi.mesh = mesh
	mi.material_override = _wood_material()
	mi.position = Vector3(tree.origin)
	add_child(mi)
	entry["mesh_node"] = mi
	# 冠影/木质阴影代理 = 纯几何（无光照采样），只随结构变化
	#（tree.revision）——光照重烘（light_only）复用缓存的 ArrayMesh
	# 资源直接挂新实例，省 ~2ms/次（冠影 1.5+代理 0.5，占单次重建
	# 成本 30%；实机"偶尔卡顿"残余——树旁连续放拆每块都全量重建）
	var _c0 := Time.get_ticks_usec()
	var crown_mesh: ArrayMesh = null
	if light_only and int(entry.get("shadow_rev", -1)) == tree.revision:
		crown_mesh = entry.get("crown_mesh", null)
	if crown_mesh == null:
		crown_mesh = _crown_shadow_mesh(tree)
		entry["crown_mesh"] = crown_mesh
		entry["shadow_rev"] = tree.revision
	if crown_mesh != null:
		var smi := MeshInstance3D.new()
		smi.name = "CrownShadow"
		smi.mesh = crown_mesh
		smi.material_override = _crown_shadow_material()
		smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.add_child(smi)
	var _t_crown: int = Time.get_ticks_usec() - _c0
	# 木质阴影代理：漂亮网格的收尾缩格/分叉桥在阴影通道有周期性
	# 漏光缝（枝影带规律亮斑）——SHADOWS_ONLY 满格盒代理密封补光
	var _s0 := Time.get_ticks_usec()
	var shadow_mesh: ArrayMesh = null
	if light_only and int(entry.get("shadow_rev2", -1)) == tree.revision:
		shadow_mesh = entry.get("wood_shadow_mesh", null)
	if shadow_mesh == null:
		shadow_mesh = TreeMeshBuilder.build_shadow_mesh(tree)
		entry["wood_shadow_mesh"] = shadow_mesh
		entry["shadow_rev2"] = tree.revision
	if shadow_mesh != null:
		var wmi := MeshInstance3D.new()
		wmi.name = "WoodShadow"
		wmi.mesh = shadow_mesh
		wmi.material_override = _crown_shadow_material()
		wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.add_child(wmi)
	var _t_shadow: int = Time.get_ticks_usec() - _s0
	# 碰撞：简化盒（主干段区域，一个 BoxShape）——曾 v15 误置于
	# return 之后成死代码（同步路径树无碰撞，审查发现）
	var body := StaticBody3D.new()
	body.name = "TreeBody_%d" % tree_id
	body.position = Vector3(tree.origin)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var trunk_b = tree.branches.get(tree.root_branch_id)
	if trunk_b != null:
		var h := maxi(1, trunk_b.end_cell.y - trunk_b.start_cell.y + 1)
		var w := float(trunk_b.radius_start) / 8.0
		box.size = Vector3(w * 2.0, float(h), w * 2.0)
		shape.shape = box
		body.add_child(shape)
		shape.position = Vector3(
				float(trunk_b.start_cell.x) + 0.5 - float(tree.origin.x),
				float(h) / 2.0,
				float(trunk_b.start_cell.z) + 0.5 - float(tree.origin.z))
	add_child(body)
	entry["body"] = body
	return {"mesh": _t_mesh, "crown": _t_crown, "shadow": _t_shadow}


## ---- 异步首建管线（worker 数组构建 + 主线程提交） ----

## 入队：主线程收集光照快照（chunk.light 副本——worker 只读无竞争），
## 后台任务建三组数组（trunk/crown/shadow）
func _enqueue_tree_async(tid: int) -> void:
	if _tree_async.has(tid) or not _trees.has(tid):
		return
	var entry: Dictionary = _trees[tid]
	var tree: TreeInstance = entry["instance"]
	var job := {
		"tid": tid, "tree": tree, "rev": tree.revision,
		"snap": _snapshot_light(tid), "cs": world.config.chunk_size,
		"trunk": [], "crown": [], "shadow": [],
	}
	job["task_id"] = WorkerThreadPool.add_task(
			_tree_mesh_job.bind(job), false, "tree_mesh")
	_tree_async[tid] = job


## worker 任务体：只触碰 job 字段与静态构建函数（无 world/场景树）
func _tree_mesh_job(job: Dictionary) -> void:
	job["trunk"] = TreeMeshBuilder.build_mesh_snap_arrays(
			job["tree"], job["snap"], int(job["cs"]))
	job["crown"] = _crown_shadow_arrays(job["tree"])
	job["shadow"] = TreeMeshBuilder.build_shadow_arrays(job["tree"])


## 光照快照：树 AABB±1 覆盖的 chunk coord -> light 字节副本
##（duplicate memcpy ~µs 级；未加载块缺省=露天回退）
func _snapshot_light(tid: int) -> Dictionary:
	var snap := {}
	var aabb: AABB = _trees[tid]["aabb"]
	var s := world.config.chunk_size
	var lo := Vector3i(floori(aabb.position.x) - 1,
			floori(aabb.position.y) - 1, floori(aabb.position.z) - 1)
	var hi := Vector3i(floori(aabb.end.x) + 1,
			floori(aabb.end.y) + 1, floori(aabb.end.z) + 1)
	var c0 := VoxelCoords.world_to_chunk(lo, s)
	var c1 := VoxelCoords.world_to_chunk(hi, s)
	for cx in range(c0.x, c1.x + 1):
		for cy in range(maxi(c0.y, 0), c1.y + 1):
			for cz in range(c0.z, c1.z + 1):
				var ch: ChunkData = world.chunks.get(Vector3i(cx, cy, cz))
				if ch != null:
					snap[Vector3i(cx, cy, cz)] = ch.light.duplicate()
	return snap


## 主线程提交：数组 → ArrayMesh/节点/碰撞体（~1ms/棵）
func _commit_visual_arrays(tid: int, job: Dictionary) -> void:
	var entry: Dictionary = _trees[tid]
	var tree: TreeInstance = entry["instance"]
	if entry["mesh_node"] != null:
		entry["mesh_node"].queue_free()
	if entry["body"] != null:
		entry["body"].queue_free()
	var trunk: Array = job["trunk"]
	if trunk.is_empty():
		return
	var tm := ArrayMesh.new()
	tm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk)
	var mi := MeshInstance3D.new()
	mi.name = "Tree_%d" % tid
	mi.mesh = tm
	mi.material_override = _wood_material()
	mi.position = Vector3(tree.origin)
	add_child(mi)
	entry["mesh_node"] = mi
	# 冠影/木影 ArrayMesh 建后存缓存（光照重烘 light_only 复用）
	var crown: Array = job["crown"]
	if not crown.is_empty():
		var cm := ArrayMesh.new()
		cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, crown)
		entry["crown_mesh"] = cm
		entry["shadow_rev"] = tree.revision
		var smi := MeshInstance3D.new()
		smi.name = "CrownShadow"
		smi.mesh = cm
		smi.material_override = _crown_shadow_material()
		smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.add_child(smi)
	var shadow: Array = job["shadow"]
	if not shadow.is_empty():
		var wm := ArrayMesh.new()
		wm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shadow)
		entry["wood_shadow_mesh"] = wm
		entry["shadow_rev2"] = tree.revision
		var wmi := MeshInstance3D.new()
		wmi.name = "WoodShadow"
		wmi.mesh = wm
		wmi.material_override = _crown_shadow_material()
		wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.add_child(wmi)
	# 碰撞：简化盒（与同步路径同式）
	var body := StaticBody3D.new()
	body.name = "TreeBody_%d" % tid
	body.position = Vector3(tree.origin)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var trunk_b = tree.branches.get(tree.root_branch_id)
	if trunk_b != null:
		var h := maxi(1, trunk_b.end_cell.y - trunk_b.start_cell.y + 1)
		var w := float(trunk_b.radius_start) / 8.0
		box.size = Vector3(w * 2.0, float(h), w * 2.0)
		shape.shape = box
		body.add_child(shape)
		shape.position = Vector3(
				float(trunk_b.start_cell.x) + 0.5 - float(tree.origin.x),
				float(h) / 2.0,
				float(trunk_b.start_cell.z) + 0.5 - float(tree.origin.z))
	add_child(body)
	entry["body"] = body


## 同步等待某树的异步任务落定（砍伐/回收前冲刷——防 worker 读
## tree 结构与主线程 split 并发）
func _flush_tree_async(tid: int) -> void:
	if not _tree_async.has(tid):
		return
	var job: Dictionary = _tree_async[tid]
	WorkerThreadPool.wait_for_task_completion(int(job["task_id"]))
	_tree_async.erase(tid)  # 数组弃用：调用方随后同步重建


func _destroy_tree(tree_id: int) -> void:
	_flush_tree_async(tree_id)
	var entry: Dictionary = _trees[tree_id]
	if entry["mesh_node"] != null:
		entry["mesh_node"].queue_free()
	if entry["body"] != null:
		entry["body"].queue_free()
	var o := (entry["instance"] as TreeInstance).origin
	var arr: Array = _trees_by_col.get(Vector2i(o.x, o.z), [])
	arr.erase(tree_id)
	if arr.is_empty():
		_trees_by_col.erase(Vector2i(o.x, o.z))
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
	# 切点所在段（split 前查）：根段=砍主干 → 动画倒伏（DT 语义，
	# 朝砍击者）；其余=树枝分量 → 刚体物理掉落
	# 异步构建冲刷：worker 正在读 tree 结构，split 前同步等完
	_flush_tree_async(tree.tree_id)
	var cut_id: int = tree.cell_to_branch.get(cell, -1)
	tree.split_branch_at_cell(cell)
	tree.record_cut(cell)
	# 存档膨胀防护：只保留最近 MAX_CUT_EVENTS 条（旧事件丢失仅
	# 表现为已砍树在远古区域重放长回——可接受；曾无限增长整体写入
	# world.json，审查发现）
	if _cut_events.size() >= MAX_CUT_EVENTS:
		_cut_events = _cut_events.slice(_cut_events.size() - MAX_CUT_EVENTS + 1)
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
		# 转刚体（树枝分量）或动画倒伏（主干砍断）。**先于结构移
		# 除**——网格 build_mesh(tree, unsup) 依赖 unsup 分支仍在
		# tree.branches：曾先 erase 再 spawn，子集永远为空 → 网格
		# null → 倒伏体只剩碰撞盒与叶盒，木段本体隐形（"碰撞还在
		# 枝干不见"）。阈值 ≥2：砍一半的 2 格短段也要有倒伏表现
		if cut_id == tree.root_branch_id \
				and _falling_anims.size() < MAX_FALLING_TREES \
				and cells.size() >= 2:
			_spawn_falling_animated(tree, unsup, cells, fallen_leaves)
		elif _falling.size() < MAX_FALLING_TREES and cells.size() >= 2:
			_spawn_falling_rigid(tree, unsup, cells, fallen_leaves)
		else:
			_settle_drop(cells.size(),
					Vector3(cells[0]) + Vector3(0.5, 0.5, 0.5))
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
		# 占位清除：批量通道（逐格 set_block 曾每格触发一次光照增量
		# BFS 2-7ms，一棵树几十格=单次砍伐卡 100-300ms——审查 3-F3；
		# 批量末尾一次 blocks_changed_batch，光照按块全量重算）。
		# 曾同步重建受影响区块（v5，防"跳半格"竞态）——已移除：
		# 跳半格真因是断口空隙悬空（v6 连根倒根治），且树 mesh 盒
		# 包住区块立方，立方延迟 1-3 帧消失不可见
		var clear_cells: Array = []
		for c in cells:
			if world.get_block(c) == VoxelTypes.BRANCH_ID:
				clear_cells.append(c)
		for leaf_cell in fallen_leaves:
			if world.get_block(leaf_cell) == VoxelTypes.LEAVES_ID:
				clear_cells.append(leaf_cell)
		if not clear_cells.is_empty():
			world.set_blocks_batch(clear_cells, VoxelTypes.AIR_ID)

	# 重建保留树视觉
	tree.revision += 1
	if tree.cell_to_branch.is_empty():
		_destroy_tree(tree.tree_id)
	else:
		_build_visual(tree.tree_id)


## 倒树视觉公共构建（物理刚体与动画倒伏共用）：枝干 mesh 子集 +
## 叶盒 mesh，顶点相对 pivot 偏移。返回节点数组（空叶返回 2 元素）。
func _make_falling_visual(tree: TreeInstance, unsup: Dictionary,
		leaves: Array[Vector3i], pivot: Vector3) -> Array[Node3D]:
	var out: Array[Node3D] = []
	# **真实枝干 mesh 子集**（TreeMeshBuilder 只建脱落分支——正确
	# 贴图与形状，不用 BoxMesh 链）。root_drop=false：不画首格下探
	# 0.5 接缝盒（倒树 B 段下方=被砍空格，下探盒悬空=底部多余半格，
	# 落地盖章时消失=实机"往上跳一点"错觉），砍口底面改贴年轮
	var sub_mesh := TreeMeshBuilder.build_mesh(tree, unsup, world, false)
	if sub_mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = sub_mesh
		mi.material_override = _wood_material()
		# 顶点以树根为原点——挂载点在 pivot，需要偏移
		mi.position = Vector3(tree.origin) - pivot
		out.append(mi)
	# **叶视觉**（叶盒 + 树叶贴图 alpha 裁切镂空——与区块叶面同观感；
	# 曾纯色绿盒。复用 TreeMeshBuilder._box：满格面=满图块不拉伸）
	if not leaves.is_empty():
		var leaf_holder := MeshInstance3D.new()
		var leaf_arrays := []
		leaf_arrays.resize(Mesh.ARRAY_MAX)
		var lv := PackedVector3Array()
		var ln := PackedVector3Array()
		var lu := PackedVector2Array()
		var li := PackedInt32Array()
		var tile := TextureAtlasLoader.tile_grid("leaves")
		var inv_c := 1.0 / TextureAtlasLoader.COLS
		var inv_r := 1.0 / TextureAtlasLoader.ROWS
		var uv_leaf := Vector2(float(tile.x) * inv_c, float(tile.y) * inv_r)
		var lc_colors := PackedColorArray()
		for lc in leaves:
			var c := Vector3(lc) + Vector3(0.5, 0.5, 0.5) - pivot
			# 叶格自身光照（双通道，与 build_mesh light_of 同式——
			# _leaf_material 已换 tree_surface shader）
			var col := Color(0, 0, 0, 1)
			var lch: ChunkData = world.chunks.get(
					VoxelCoords.world_to_chunk(lc, world.config.chunk_size))
			if lch != null:
				var llocal := VoxelCoords.world_to_local(lc,
						world.config.chunk_size)
				var sky := float(lch.get_sky_light(llocal)) / 15.0
				var blk := float(lch.get_block_light(llocal)) / 15.0
				var blk_c := blk * blk * blk
				var sky_c := sky * sky * sky
				col = Color(blk_c * 1.44, blk_c, blk_c * 0.56, sky_c)
			for f in 6:
				TreeMeshBuilder._box(lv, ln, lu, lc_colors, li,
						c - Vector3(0.5, 0.5, 0.5), c + Vector3(0.5, 0.5, 0.5),
						f, col, uv_leaf, inv_c, inv_r)
		leaf_arrays[Mesh.ARRAY_VERTEX] = lv
		leaf_arrays[Mesh.ARRAY_NORMAL] = ln
		leaf_arrays[Mesh.ARRAY_TEX_UV] = lu
		leaf_arrays[Mesh.ARRAY_COLOR] = lc_colors
		leaf_arrays[Mesh.ARRAY_INDEX] = li
		var lm := ArrayMesh.new()
		lm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arrays)
		leaf_holder.mesh = lm
		leaf_holder.material_override = _leaf_material()
		out.append(leaf_holder)
	return out


## 主干砍断 → 动画倒伏（DT 语义）：绕切点朝砍击者方向受控倒下，
## 不进物理引擎——刚体旁有方块会接触抖动（实机"抽搐"），整树
## 倒伏走脚本动画根治。
func _spawn_falling_animated(tree: TreeInstance,
		unsup: Dictionary, cells: Array[Vector3i],
		leaves: Array[Vector3i]) -> void:
	var cut_cell: Vector3i = tree.cut_cells[tree.cut_cells.size() - 1]
	# 铰链=**断口格底面中心**。DT 语义整树连根倒：被砍的断口格跟
	# 着树一起倒（视觉补断口格木盒）——底部从地面/树桩顶面起绕铰
	# 链旋转，**永远无空隙**。曾铰链在断口格中心+动画从断口+1 起：
	# 被砍格留出 1 格空隙→树底悬空 0.2s 再下沉闭合=实机"刚开始
	# 跳起半格"（悬空-落下被感知为跳）。
	var pivot := Vector3(cut_cell) + Vector3(0.5, 0, 0.5)
	# 树底贴地面（钉地下限计算用）：铰链 x/z 处地形顶面（排除
	# 树叶/枝干——占位清除前自家占位不可当地面）
	var ground_y := _ground_top_y(pivot.x, pivot.z, cut_cell.y + 8,
			float(tree.origin.y))
	# 树桩顶面（砍非底端）：从被砍格向下扫第一个实体格（含 BRANCH
	# 树桩——树干圆柱穿树干圆柱极显眼，实机"上面的树穿过下面的
	# 主干"；_ground_top_y 排除 BRANCH 不能复用）。倒树绕断口旋转
	# 时 B0 底面压在树桩顶面上（φ<90° 钉住），转出正上方后贴桩侧
	# 滑坠到地面；无树桩（砍贴地格）=地面线等价
	var stump_top_y := ground_y
	var sy := cut_cell.y - 1
	while sy > cut_cell.y - 8:
		var sid := world.get_block(Vector3i(cut_cell.x, sy, cut_cell.z))
		if sid != VoxelTypes.AIR_ID and sid != VoxelTypes.LEAVES_ID \
				and sid != VoxelTypes.WATER_ID:
			stump_top_y = float(sy) + 1.0
			break
		sy -= 1
	# 倒向：砍击者（DT 语义——树倒向你）；拿不到/太近退化为质心偏移
	var fall_dir := Vector3.ZERO
	if player_provider.is_valid():
		var p = player_provider.call()
		if p != null and p is Node3D:
			var to_p: Vector3 = (p as Node3D).global_position - pivot
			to_p.y = 0.0
			if to_p.length() > 1.5:
				fall_dir = to_p.normalized()
	if fall_dir == Vector3.ZERO:
		var centroid := Vector3.ZERO
		for c in cells:
			centroid += Vector3(c) + Vector3(0.5, 0.5, 0.5)
		centroid /= float(cells.size())
		fall_dir = Vector3(centroid.x - pivot.x, 0, centroid.z - pivot.z)
		if fall_dir.length() < 0.1:
			fall_dir = Vector3(1, 0, 0)
		fall_dir = fall_dir.normalized()
	var visual := _make_falling_visual(tree, unsup, leaves, pivot)
	# 断口格木盒（DT 整树连根倒）：被砍格跟着树倒——盒占 cut 格
	# [cut.y, cut.y+1]，宽=B0 段基部半径，底面=铰链（贴地/贴桩），
	# 与 B0 盒无缝衔接。无此盒则被砍格留 1 格空隙=树底悬空（跳感）
	var b0_node: TreeInstance.BranchNode = null
	for bid in unsup:
		var node: TreeInstance.BranchNode = tree.branches.get(bid)
		if node != null and node.axis_step().y != 0 \
				and node.start_cell == cut_cell + Vector3i(0, 1, 0):
			b0_node = node
			break
	if b0_node != null:
		var sw := clampf(float(b0_node.radius_start) / 8.0, 0.12, 1.0)
		var cv := PackedVector3Array()
		var cn := PackedVector3Array()
		var cu := PackedVector2Array()
		var cc := PackedColorArray()
		var ci := PackedInt32Array()
		var tile_o := TextureAtlasLoader.tile_grid("log_side")
		var tile_t := TextureAtlasLoader.tile_grid("log_top")
		var inv_c2 := 1.0 / TextureAtlasLoader.COLS
		var inv_r2 := 1.0 / TextureAtlasLoader.ROWS
		var uv_o2 := Vector2(float(tile_o.x) * inv_c2, float(tile_o.y) * inv_r2)
		var uv_t2 := Vector2(float(tile_t.x) * inv_c2, float(tile_t.y) * inv_r2)
		# 断口格光照（双通道，露天=Color(0,0,0,1)；未加载同回退）
		var cut_col := Color(0, 0, 0, 1)
		var cch: ChunkData = world.chunks.get(VoxelCoords.world_to_chunk(
				cut_cell, world.config.chunk_size))
		if cch != null:
			var cloc := VoxelCoords.world_to_local(cut_cell,
					world.config.chunk_size)
			var csky := float(cch.get_sky_light(cloc)) / 15.0
			var cblk := float(cch.get_block_light(cloc)) / 15.0
			var cblk3 := cblk * cblk * cblk
			var csky3 := csky * csky * csky
			cut_col = Color(cblk3 * 1.44, cblk3, cblk3 * 0.56, csky3)
		for f in 6:
			TreeMeshBuilder._box(cv, cn, cu, cc, ci,
					Vector3(-sw, 0, -sw), Vector3(sw, 1, sw),
					f, cut_col,
					uv_t2 if f == 2 or f == 3 else uv_o2, inv_c2, inv_r2)
		var cut_arrays := []
		cut_arrays.resize(Mesh.ARRAY_MAX)
		cut_arrays[Mesh.ARRAY_VERTEX] = cv
		cut_arrays[Mesh.ARRAY_NORMAL] = cn
		cut_arrays[Mesh.ARRAY_TEX_UV] = cu
		cut_arrays[Mesh.ARRAY_COLOR] = cc
		cut_arrays[Mesh.ARRAY_INDEX] = ci
		var cut_mesh := ArrayMesh.new()
		cut_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cut_arrays)
		var cut_mi := MeshInstance3D.new()
		cut_mi.mesh = cut_mesh
		cut_mi.material_override = _wood_material()
		visual.append(cut_mi)
	var holder := Node3D.new()
	holder.position = pivot
	for n in visual:
		holder.add_child(n)
	add_child(holder)
	# 旋转轴 = UP×dir（右手定则：绕此轴正转把树顶转向 fall_dir）
	var axis := Vector3.UP.cross(fall_dir).normalized()
	# DT FalloverAnimationHandler 参数：角加速度=4/质心高（长树转得
	# 慢，真实分量感）；碰撞段数=主干格数（≤24，DT 同 clamp）；
	# 段半宽从尖端 1/16 渐变到基部半径（段盒随段号变粗）
	var centroid_y := 0.0
	for c in cells:
		centroid_y += float(c.y) + 0.5
	centroid_y = centroid_y / float(cells.size()) - pivot.y
	var height := maxf(centroid_y * 2.0, 2.0)
	# 主干段：unsup 里竖直段的最长格链
	var seg_count := 0
	var base_half := 0.125
	for bid in unsup:
		var node: TreeInstance.BranchNode = tree.branches.get(bid)
		if node == null or node.axis_step().y == 0:
			continue
		if node.cells().size() > seg_count:
			seg_count = node.cells().size()
			base_half = clampf(float(node.radius_start) / 8.0, 0.0625, 0.5)
	seg_count = mini(seg_count, 24)
	_falling_anims[holder] = {
		"ang": 0.0, "vel": 0.0, "axis": axis, "dir": fall_dir,
		"cells": cells.size(), "timer": 0.0,
		"height": height, "seg_count": seg_count, "base_half": base_half,
		"landed": false, "drop": 0.0, "ground_y": ground_y,
		"stump_top_y": stump_top_y, "pivot": pivot, "dissolve": -1.0,
	}


## 主干逐段碰撞测试（DT testCollision 同构）：段 i 中心 = 铰链 +
## dir·(sinφ·i) + UP·(cosφ·i)，段盒半宽随段号变粗；中心格为地形
## 实体（非空气/叶/枝干/水）即碰撞。单格中心查询——树干半嵌地面
## （中心仍在空气格）不触发，转过头（中心进实体格）才回退。
func _test_trunk_collision(pivot: Vector3, dir: Vector3, ang: float,
		seg_count: int, base_half: float) -> bool:
	var h := sin(ang)
	var v := cos(ang)
	for seg in seg_count:
		# 段 0 = 断口上方第一格（距离 seg+1.5：断口格 1.0+B0 中心
		# 0.5）——可视格从断口格（含补盒）+B0 链式排布
		var dist := float(seg) + 1.5
		var c := pivot + dir * (h * dist) \
				+ Vector3.UP * (v * dist)
		@warning_ignore("integer_division")
		var half := clampf(0.0625 * float(seg + 1) * 2.0, 0.0625, base_half)
		var id := world.get_block(Vector3i(int(floor(c.x)),
				int(floor(c.y + half * 0.9)), int(floor(c.z))))
		if id != VoxelTypes.AIR_ID and id != VoxelTypes.LEAVES_ID \
				and id != VoxelTypes.BRANCH_ID and id != VoxelTypes.WATER_ID:
			return true
	return false


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

	for n in _make_falling_visual(tree, unsup, leaves, pivot):
		body.add_child(n)

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
		"dissolve": -1.0,
	}


var _leaf_mat: ShaderMaterial = null
var _wood_mat: ShaderMaterial = null
var _crown_shadow_mat: StandardMaterial3D = null


## 隐形实心冠投影。两层问题实测归因（用户世界 t3 视图分级关闭 +
## 无影参考帧差分）：① 叶球生成空隙（末梢密度 0.85/沿途 0.5）——
## 空隙格整格漏光；② 叶面 cutout 贴图的透明纹素在阴影通道被
## discard，每个叶面自身漏"纹素孔"。故投影必须覆盖**满密度冠的
## 每一格**（含已有叶格）：纹素孔后面有实心盒兜底，光线穿不过。
## SHADOWS_ONLY 只进阴影贴图；与真实叶面同格共面（同深度，bias
## 把接收面向光源侧推，不自暗）。树被砍/重建/倒伏随 mesh_node
## 释放重建。
## 面邻接剔除：格集合的内部面被邻格共面覆盖，不发射（暴露面集与
## 逐格全盒逐像素一致——阴影深度图不变），构建顶点数与阴影 pass
## 光栅量降 ~2/3（满密度冠 ~300 格曾全发 6 面）。曾逐格 _box 全
## 六面 + leaf_shadow_cells O(n²) 去重，单棵树构建 ~15ms，走动
## hitch 显著（walk p95 100ms→剔除后实测见 perf_tree_bench）。
const FACE_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## 冠影网格（纯几何，无光照采样——光照重烘可缓存复用）：
## 满密度冠每格暴露面盒（面邻接剔除）。返回 ArrayMesh（无叶格 null）
func _crown_shadow_mesh(tree: TreeInstance) -> ArrayMesh:
	var arrays: Array = _crown_shadow_arrays(tree)
	if arrays.is_empty():
		return null
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


## 冠影数组构建（worker 安全：纯 tree 数据 + 静态面发射）
func _crown_shadow_arrays(tree: TreeInstance) -> Array:
	var cells := {}
	for c in TreeGenerator.leaf_shadow_cells(tree):
		cells[c] = true
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var dummy_uvs := PackedVector2Array()
	# 阴影代理不渲染（只投影），签名统一要 colors/light——丢弃用
	var shadow_colors := PackedColorArray()
	var idx := PackedInt32Array()
	for c: Vector3i in cells:
		var mn := Vector3(float(c.x - tree.origin.x),
				float(c.y - tree.origin.y), float(c.z - tree.origin.z))
		for f in 6:
			if cells.has(c + FACE_DIRS[f]):
				continue
			TreeMeshBuilder._face(verts, norms, dummy_uvs, shadow_colors,
					idx, mn, mn + Vector3.ONE, f, Color(0, 0, 0, 1),
					Vector2.ZERO, 0.0, 0.0)
	if idx.is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## 兼容旧测试入口：构建并挂载到 parent
func _build_crown_shadow(tree: TreeInstance, parent: MeshInstance3D) -> void:
	var am := _crown_shadow_mesh(tree)
	if am == null:
		return
	var smi := MeshInstance3D.new()
	smi.name = "CrownShadow"
	smi.mesh = am
	smi.material_override = _crown_shadow_material()
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	parent.add_child(smi)


func _crown_shadow_material() -> StandardMaterial3D:
	# 纯白不透明：仅阴影 pass 消费，颜色无意义
	if _crown_shadow_mat == null:
		_crown_shadow_mat = StandardMaterial3D.new()
	return _crown_shadow_mat


func _wood_material() -> ShaderMaterial:
	if _wood_mat == null:
		_wood_mat = _tree_surface_material(false)
	return _wood_mat

func _leaf_material() -> ShaderMaterial:
	# 树叶贴图材质（图集 + alpha 裁切镂空，与区块叶面同观感；
	# 曾纯色绿。双面：贴图孔洞透出背面内壁，叶盒看起来更饱满）
	if _leaf_mat == null:
		_leaf_mat = _tree_surface_material(true)
	return _leaf_mat


## 树表面材质：tree_surface.gdshader 双通道（方块光→EMISSION
## fullbright、天光→ALBEDO×u_day）——StandardMaterial 合并式
## max(s,b) 顶点色在露天区被天光值吞掉火把贡献（sky=15 ≥ 火把
## 14，暖色调制永不触发），与地形同构后昼夜两头都成立。
func _tree_surface_material(cutout: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://presentation/tree_surface.gdshader")
	var base := DropVisuals.atlas_material() as StandardMaterial3D
	if base != null and base.albedo_texture != null:
		material.set_shader_parameter("atlas", base.albedo_texture)
	material.set_shader_parameter("cutout_mode", cutout)
	return material


## 日夜系数下发（main._update_day_night 每帧调）；材质未建时跳过
##（建好后下一帧即有值）
func set_day_factor(v: float) -> void:
	if _wood_mat != null:
		_wood_mat.set_shader_parameter("u_day", v)
	if _leaf_mat != null:
		_leaf_mat.set_shader_parameter("u_day", v)


## 倒树清叶半径：叶球生成半径 2（球判 d<=2.3），冠心球落格用
## dy+1 而距离判定用 dy（生成器 off-by-one），顶层叶实际可达 3.0
## ——收集取 3.1 覆盖之。曾只扫 12 个邻域偏移（水平±1），222 叶
## 残留 101（46%）倒树后悬浮
const LEAF_CLEAR_RADIUS := 3.1

var _leaf_scan_offsets: Array[Vector3i] = []


## 收集枝干格周围 LEAF_CLEAR_RADIUS 球内的叶格（倒树跟随清除用）。
func _collect_leaves_near(cells: Array[Vector3i]) -> Array[Vector3i]:
	if _leaf_scan_offsets.is_empty():
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				for dz in range(-4, 5):
					if Vector3(dx, dy, dz).length() <= LEAF_CLEAR_RADIUS:
						_leaf_scan_offsets.append(Vector3i(dx, dy, dz))
	var seen := {}
	var out: Array[Vector3i] = []
	for cell in cells:
		for d in _leaf_scan_offsets:
			var p: Vector3i = cell + d
			if seen.has(p):
				continue
			seen[p] = true
			if world.get_block(p) == VoxelTypes.LEAVES_ID:
				out.append(p)
	return out


func _process(delta: float) -> void:
	# 快速通道：光照事件重烘。光照数据在信号内同步落定，合并窗口
	#（0.15s，水流级联/多格编辑合并为一次）后即烘，不等管线空闲；
	# 每帧限量防单帧长卡
	if not _light_dirty.is_empty():
		_light_dirty_wait += delta
		if _light_dirty_wait >= 0.15:
			var built := 0
			var now_msec := Time.get_ticks_msec()
			for tid in _light_dirty.keys():
				if built >= REBUILD_BUDGET_PER_FRAME:
					break
				# 单树冷却（BAKE_COOLDOWN_MSEC）：树旁连续放拆每块都
				# 标脏 → 曾逐块全量重建（实机 23 次/棵）。冷却期内留
				# 在脏集合不烘，连续编辑合并成末态一次
				if now_msec - int(_bake_last.get(tid, 0)) < BAKE_COOLDOWN_MSEC:
					continue
				_light_dirty.erase(tid)
				if _trees.has(tid):
					_build_visual(tid, true)
					_bake_last[tid] = now_msec
					built += 1
		if _light_dirty.is_empty():
			_light_dirty_wait = 0.0
	# 慢通道（首建）：根列 chunk 激活瞬间邻块常未就绪，等管线空闲
	# 再首烘；2s 兜底防饿死（兜底烘出的未加载面走 light_of 安全回退）
	if not _build_pending.is_empty():
		_build_pending_wait += delta
		var ready := false
		if idle_check.is_valid():
			ready = _build_pending_wait >= 2.0 or bool(idle_check.call())
		else:
			ready = _build_pending_wait >= 0.15
		if ready:
			var built2 := 0
			for tid in _build_pending.keys():
				if built2 >= ASYNC_ENQUEUE_BUDGET:
					break
				_build_pending.erase(tid)
				if _trees.has(tid):
					# 首建走 worker 异步（曾是主线程 6-10ms/棵×流式
					# 700 棵=5.3s 持续卡帧——探针实锤占日志耗时 86%）：
					# 主线程只做光照快照+入队，数组构建在后台，提交才
					# 上主线程（~1ms/棵）
					_enqueue_tree_async(tid)
					built2 += 1
		if _build_pending.is_empty():
			_build_pending_wait = 0.0
	# 异步树构建：轮询完成 → 主线程提交（ArrayMesh/节点/碰撞体）
	if not _tree_async.is_empty():
		var committed := 0
		for tid in _tree_async.keys():
			if committed >= ASYNC_COMMIT_BUDGET:
				break
			var job: Dictionary = _tree_async[tid]
			if not WorkerThreadPool.is_task_completed(int(job["task_id"])):
				continue
			WorkerThreadPool.wait_for_task_completion(int(job["task_id"]))
			_tree_async.erase(tid)
			if not _trees.has(tid):
				continue  # 构建期间被回收
			var tree_a: TreeInstance = _trees[tid]["instance"]
			if tree_a.revision != int(job["rev"]):
				_enqueue_tree_async(tid)  # 构建期间结构变了：重排
				continue
			_commit_visual_arrays(tid, job)
			committed += 1
	# 动画倒树（主干砍断）——DT FalloverAnimationHandler 同构：
	# ①整树重力下坠（闭合断口→地面空隙，抵消绕底旋转的侧枝上扬）
	# ②角加速旋转 ③每帧主干逐段碰撞地形，命中=回退+弹性反弹，
	# 衰减落地 → 停留结算。不进物理引擎——旁有方块也绝不抖
	for anim in _falling_anims.keys():
		var ainfo: Dictionary = _falling_anims[anim]
		# delta 钳制：砍树触发 set_block 重网格化会卡出数秒巨帧——
		# 单 tick ang=4/h·delta² 直接冲破 160° 上限假落地（capture
		# "LANDED at frame 1" 实锤）。DT 跑固定 tick 天然免疫，
		# 真实 delta 必须钳到 1/30s，卡帧期间动画慢放而非瞬移
		var d := minf(delta, 1.0 / 30.0)
		# ① 整体下坠（钉地双向跟随）：断口格盒底面=铰链本身（距
		# pivot 0，在旋转轴上不随 φ 升降）→ 钉地线 drop = ground−
		# pivot.y **恒定**。开局 drop=0（贴地/贴桩）——**无初始空隙**
		# （曾铰链在断口格中心+动画从断口+1 起：被砍格空隙让树底悬空
		# 0.2s 再下沉=实机"刚开始跳起半格"）；φ≥90° 树桩约束释放后
		# 树滑坠到地面线。速率限 FALL_SINK_SPEED 防瞬跳
		var floor_drop: float = float(ainfo["ground_y"]) \
				- (ainfo["pivot"] as Vector3).y
		# 树桩约束（砍非底端）：φ<90° 时树干压在树桩上方，钉在树桩
		# 顶面（圆柱穿圆柱=实机"穿过下面的主干"）；φ≥90° 树干转出
		# 树桩正上方，约束释放→贴桩侧滑坠到地面
		if float(ainfo["stump_top_y"]) > float(ainfo["ground_y"]) \
				and float(ainfo["ang"]) < PI * 0.5:
			floor_drop = maxf(floor_drop,
					float(ainfo["stump_top_y"]) \
					- (ainfo["pivot"] as Vector3).y)
		ainfo["drop"] = maxf(floor_drop,
				float(ainfo["drop"]) - FALL_SINK_SPEED * d)
		(anim as Node3D).position = (ainfo["pivot"] as Vector3) \
				+ Vector3(0, float(ainfo["drop"]), 0)
		ainfo["timer"] = float(ainfo["timer"]) + d
		if bool(ainfo["landed"]):
			# 落地停稳：停留 FALL_SETTLE_TIME → 抖动透明溶解
			# FALL_DISSOLVE_TIME → 消失。掉落物在溶解开始时结算
			# （树消散=物已落地）；曾停留后瞬间消失（实机突兀）
			if float(ainfo["timer"]) >= FALL_SETTLE_TIME \
					+ float(ainfo["land_at"]) \
					and float(ainfo.get("dissolve", -1.0)) < 0.0:
				_settle_drop(int(ainfo["cells"]),
						(anim as Node3D).global_position)
				ainfo["dissolve"] = 0.0
			var dsv := float(ainfo.get("dissolve", -1.0))
			if dsv >= 0.0:
				dsv = minf(dsv + d / FALL_DISSOLVE_TIME, 1.0)
				ainfo["dissolve"] = dsv
				for sub in (anim as Node3D).get_children():
					if sub is MeshInstance3D:
						(sub as MeshInstance3D).set_instance_shader_parameter(
								"dissolve", dsv)
				if dsv >= 1.0:
					(anim as Node3D).queue_free()
					_falling_anims.erase(anim)
			continue
		# 角加速（DT: fallSpeed += 0.2/height 每 tick → ×20/tick_rate）
		ainfo["vel"] += FALL_TURN_ACC_DT / float(ainfo["height"]) * d
		ainfo["ang"] = float(ainfo["ang"]) + float(ainfo["vel"]) * d
		# 碰撞延迟窗（DT 10 tick 防自家脏块；占位清除 spawn 同帧完成）
		if float(ainfo["timer"]) >= FALL_COLLISION_DELAY \
				and float(ainfo["vel"]) > 0.0 \
				and _test_trunk_collision(
					(anim as Node3D).position, ainfo["dir"],
					float(ainfo["ang"]), int(ainfo["seg_count"]),
					float(ainfo["base_half"])):
			# 回退本帧旋转 + 弹性反弹（DT addRotation(-fallSpeed)）
			ainfo["ang"] = float(ainfo["ang"]) - float(ainfo["vel"]) * d
			ainfo["vel"] = float(ainfo["vel"]) * -FALL_ELASTICITY
			if absf(float(ainfo["vel"])) < FALL_LAND_SPEED:
				ainfo["landed"] = true
				ainfo["land_at"] = float(ainfo["timer"])
		# 转头上限（DT shouldDie 160°——倒栽低处时终止）
		if float(ainfo["ang"]) >= FALL_MAX_ANGLE:
			ainfo["landed"] = true
			ainfo["land_at"] = float(ainfo["timer"])
		(anim as Node3D).basis = Basis(ainfo["axis"], float(ainfo["ang"]))
	for body in _falling.keys():
		var info: Dictionary = _falling[body]
		info["timer"] = float(info["timer"]) + delta
		if body.linear_velocity.length() < 0.5 and body.angular_velocity.length() < 0.3:
			info["settled"] = float(info["settled"]) + delta
		else:
			info["settled"] = 0.0
		if (float(info["settled"]) >= FALL_SETTLE_TIME \
				or float(info["timer"]) >= FALL_TIMEOUT) \
				and float(info.get("dissolve", -1.0)) < 0.0:
			# 结算位置 = 倒伏刚体当前位置（曾漏传 near，掉落物全被
			# 传送到世界原点 (0,0.5,0)——实机审查发现）。掉落物在
			# 溶解开始时结算（树消散=物已落地）
			_settle_drop(int(info["cells"]), body.global_position)
			info["dissolve"] = 0.0
		var bdv := float(info.get("dissolve", -1.0))
		if bdv >= 0.0:
			bdv = minf(bdv + delta / FALL_DISSOLVE_TIME, 1.0)
			info["dissolve"] = bdv
			for sub in body.get_children():
				if sub is MeshInstance3D:
					(sub as MeshInstance3D).set_instance_shader_parameter(
							"dissolve", bdv)
			if bdv >= 1.0:
				body.queue_free()
				_falling.erase(body)


## 列地面顶面高度（倒树钉地计算用）：从 from_y 向下找第一个地形
## 实体格（排除空气/树叶/枝干——spawn 时占位未清，自家占位不可
## 当地面；水保留=树停水面）。未加载/超深回退 fallback。
func _ground_top_y(x: float, z: float, from_y: int, fallback: float) -> float:
	var iy := from_y
	for _step in 48:
		var id := world.get_block(Vector3i(int(floor(x)), iy, int(floor(z))))
		if id != VoxelTypes.AIR_ID and id != VoxelTypes.LEAVES_ID \
				and id != VoxelTypes.BRANCH_ID:
			return float(iy) + 1.0
		iy -= 1
	return fallback


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
	return {"trees": {"algorithm": "treegen-v2", "events": _cut_events}}


## 砍伐记录的按树根分组快照（供 chunk_manager 生成 job 构造时取用，
## worker 经参数链只读）——生成器重放树时据此剪枝，保证体素与结构
## 同源（审查 3-F2）。每次全量重建：事件 ≤MAX_CUT_EVENTS（256），
## 微秒级；砍树后新入队的生成任务自然拿到最新记录。
func cut_events_by_root() -> Dictionary:
	var by_root := {}
	for event in _cut_events:
		var t: Array = event.get("tree", [])
		if t.size() != 3:
			continue
		var key := Vector2i(int(t[0]), int(t[2]))
		var c: Array = event.get("cell", [])
		if c.size() != 3:
			continue
		if not by_root.has(key):
			by_root[key] = []
		(by_root[key] as Array).append(
				Vector3i(int(c[0]), int(c[1]), int(c[2])))
	return by_root


func apply_save_state(data: Dictionary) -> void:
	var trees_data: Dictionary = data.get("trees", {})
	if trees_data.get("algorithm", "") != "treegen-v2":
		push_warning("未知树存档算法版本，跳过树事件重放")
		return
	_cut_events = trees_data.get("events", [])
	# JSON 回读的坐标是浮点（27.0）——规整回 int（Vector3i 构造与
	# _apply_cuts 的 origin 数组比较都要精确整数）
	for event in _cut_events:
		for key in ["cell", "tree"]:
			var arr: Array = event.get(key, [])
			for i in arr.size():
				arr[i] = int(arr[i])
