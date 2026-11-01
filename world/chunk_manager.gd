## 区块管理器（开发文档 §12 阶段 C / §4.4 / §10.1 / §10.2 / §6.4）。
## 按焦点（玩家）位置流式加载与卸载区块：
##   1. 主线程确定任务与版本（邻区块 edit_serial 快照）；
##   2. WorkerThreadPool 后台计算纯数据（生成区块 / 网格数组）；
##   3. 主线程检查任务仍然有效（仍在视距内、数据未被修改、邻区块
##      序号一致），过期结果直接丢弃；
##   4. 主线程创建/替换引擎资源（ArrayMesh、碰撞形状）。
##
## 调度优先级（§10.2）：玩家所在列 > 视线前方 > 近距离 > 其余，
## 每帧限制提交数量（创建引擎资源较贵）避免主线程卡顿。
##
## 卸载策略（§4.4、§9）：超出视距+缓冲后卸载；被修改的区块先增量
## 写盘（原子替换）再移出内存；写盘失败才退回内存兜底缓存。
## 加载顺序：内存兜底 > 磁盘存档（工作线程读取）> 重新生成。
##
## 区块边界（§6.4）：新区块数据到达时把已存在的邻居标记为脏，
## 用真实边界数据重建（替代"未加载按空气"的临时策略）。
class_name ChunkManager
extends Node

## C# 地形桥（垂直流式的列地表区间；preload 避开类缓存坑）
const NativeTerrainBridge := preload("res://meshing/native_terrain_bridge.gd")

## 视距（水平，区块半径）。setter 清空列排序缓存——_update_streaming
## 只在焦点移动/视线偏转时重建列表，运行时改视距（设置菜单/调试
## 探针）不重算就永远不扩圈
@export var view_distance := 16:
	set(value):
		view_distance = value
		_sorted_columns = []
## 碰撞圈（水平，区块半径）：超出该圈的区块只建网格不建碰撞
## 顶点汤（Concave 形状构建/内存大头，观景视距下绝大部分区块
## 玩家永远物理接触不到）。玩家跨列进入碰撞圈时补建（见
## _update_streaming 的 center_moved 分支）。
@export var collision_radius := 4
## 超出视距多少后卸载（防止来回横跳的缓冲）。
@export var unload_padding := 2
## 在途任务上限（生成+网格合计）。
@export var max_in_flight := 32
## 每帧最多提交的生成结果（提交成本低，可以放宽）。
@export var gen_commit_budget := 8
## 每帧最多提交的网格结果（需创建引擎资源，控制在毫秒级预算内）。
@export var mesh_commit_budget := 3
## 视线前方的优先级加成权重。
@export var view_bias := 2.0
## 自动保存间隔（秒，§9.2 定期保存）。
@export var autosave_interval := 10.0
## 网格算法开关（§6.3 可切换实现）：
## false = 面剔除（默认）；true = Greedy Meshing（需平铺着色器材质，
## 由 main.gd 按本开关选择材质）。两者共享边界/剔除语义与正确性测试。
@export var use_greedy_meshing := false

var world: VoxelWorld
var registry: VoxelRegistry
var generator: TerrainGenerator
var renderer: ChunkRenderer

## 存档系统（阶段 D）。为空时退化为纯内存行为（不落盘）。
var save_system: WorldSave
## 玩家状态提供者（返回可 JSON 化的字典），保存元数据时调用。
var player_state_provider: Callable
## 附加世界状态提供者（如掉落实体 get_save_bundle）。返回可 JSON 化
## 字典，键不得与元数据保留键冲突（冲突由 WorldSave 拦截）。
var extra_meta_provider: Callable

## 树系统生命周期钩子（可空 Callable，chunk ACTIVE/卸载时通知——
## 引用计数由 TreeManager 内部维护，ChunkManager 不关心语义）
var on_chunk_active_cb: Callable
var on_chunk_unloaded_cb: Callable

## 体素光照钩子（光照阶段 2，可空 Callable）：
## - light_init_cb：生成 worker 线程内调用 (chunk, 6面邻块快照)——
##   本块全量光照计算（只写 chunk 自身）
## - on_chunk_data_ready_cb：主线程 DATA_READY 提交后调用 (chunk)——
##   边界光向已加载邻块播出
var light_init_cb: Callable
var on_chunk_data_ready_cb: Callable

## 跟踪的焦点（玩家）。取其位置计算视距中心，取其相机朝向做优先级偏置。
var focus: Node3D

## 内存兜底缓存：仅当区块卸载时写盘失败才保留在内存（§4.4：
## 卸载前必须已保存或进入可靠的待保存队列）。
var _dormant := {}

var _gen_jobs := {}        # task_id -> job（完成后仍在册，直至提交/丢弃）
var _mesh_jobs := {}       # task_id -> job
var _gen_by_coord := {}    # coord -> task_id（防重复提交）
var _mesh_by_coord := {}   # coord -> task_id（防重复提交）
var _camera: Camera3D
var _autosave_accumulator := 0.0
# 调度缓存（避免每帧重算）：焦点列未变时跳过卸载扫描；列排序
# 仅在焦点列变化或视线偏转 >~30° 时重建；已完整列由游标永久跳过
#（曾每帧 desired_columns 全量生成 + O(n log n) 排序，800 列视距
# 下每帧上万次比较）
var _stream_center := Vector2i(-2147483648, -2147483648)
var _stream_dir := Vector2.ZERO
var _sorted_columns: Array[Vector2i] = []
var _stream_cursor := 0


func setup(
		p_world: VoxelWorld,
		p_registry: VoxelRegistry,
		p_generator: TerrainGenerator,
		p_renderer: ChunkRenderer
) -> void:
	world = p_world
	registry = p_registry
	generator = p_generator
	renderer = p_renderer


func _exit_tree() -> void:
	# 退出保存（§9.2）：先落盘，再等待在途线程结束
	if save_system != null:
		save_all(_current_player_state())
	var ids: Array = []
	ids.append_array(_gen_jobs.keys())
	ids.append_array(_mesh_jobs.keys())
	for task_id in ids:
		WorkerThreadPool.wait_for_task_completion(task_id)
	_gen_jobs.clear()
	_mesh_jobs.clear()
	_gen_by_coord.clear()
	_mesh_by_coord.clear()


func _process(_delta: float) -> void:
	_poll_jobs()
	if focus != null:
		_update_streaming()
	if save_system != null:
		_autosave_accumulator += _delta
		if _autosave_accumulator >= autosave_interval:
			_autosave_accumulator = 0.0
			save_all(_current_player_state())


## 立即保存所有待写区块与世界元数据（自动保存/退出保存/手动共用）。
## 返回成功写盘的区块数。
func save_all(player_state: Dictionary) -> int:
	var saved := 0
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.save_needed and save_system.save_chunk(chunk):
			saved += 1
	var meta_ok := save_system.save_meta(
			world, player_state, _current_extra_state())
	print("存档：写入 %d 个区块，元数据 %s" % [
		saved, "成功" if meta_ok else "失败"])
	return saved


func _current_extra_state() -> Dictionary:
	if not extra_meta_provider.is_valid():
		return {}
	var target = extra_meta_provider.get_object()
	if target == null or not is_instance_valid(target):
		return {}
	var result = extra_meta_provider.call()
	return result if result is Dictionary else {}


func _current_player_state() -> Dictionary:
	if not player_state_provider.is_valid():
		return {}
	var target = player_state_provider.get_object()
	if target == null or not is_instance_valid(target):
		return {}
	return player_state_provider.call()


func in_flight_count() -> int:
	return _gen_jobs.size() + _mesh_jobs.size()


func dormant_count() -> int:
	return _dormant.size()  # 仅统计写盘失败的内存兜底区块


## 流式是否已安定（无在途任务且无脏区块）——调试与冒烟测试用。
func is_idle() -> bool:
	if in_flight_count() > 0:
		return false
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.mesh_dirty or chunk.collision_dirty:
			return false
	return true


## 同步加载一列的活跃带（出生点保底，防止玩家在流式就绪前坠落）。
## 优先级：内存兜底 > 磁盘存档 > 重新生成。带内自上而下（光照下界
## 起算依赖"上方邻块缺失=带顶天空"——见 init_chunk_light）。
func load_column_now(column: Vector2i) -> void:
	var band := column_band(column)
	for y in range(band.y, band.x - 1, -1):
		var coord := Vector3i(column.x, y, column.y)
		if world.has_chunk(coord):
			continue
		var chunk: ChunkData = null
		if _dormant.has(coord):
			chunk = _restore_dormant(coord)
		elif save_system != null:
			chunk = save_system.load_chunk(coord)
		if chunk == null:
			chunk = generator.generate_chunk(coord)
			chunk.state = ChunkState.State.DATA_READY
			world.add_chunk(chunk)
		renderer.register_chunk(coord)
	# 光照初始化（列内逐块：先入列的就绪块作为后续块的种子来源，
	# 再统一 on_chunk_ready 做跨块播出；dormant 恢复块光照可能过期，同样重算）
	for y in range(band.y, band.x - 1, -1):
		var coord := Vector3i(column.x, y, column.y)
		var chunk_l: ChunkData = world.get_chunk(coord)
		if chunk_l != null and light_init_cb.is_valid():
			light_init_cb.call(chunk_l, _collect_light_neighbors(coord))
			if on_chunk_data_ready_cb.is_valid():
				on_chunk_data_ready_cb.call(chunk_l)
	# 纵向邻居全部就绪后再统一构建网格，避免列内互相触发重建
	for y in range(band.y, band.x - 1, -1):
		var coord := Vector3i(column.x, y, column.y)
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk == null or not chunk.mesh_dirty:
			continue
		var arrays := {}
		if use_greedy_meshing:
			arrays = GreedyMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
		else:
			arrays = ChunkMesher.build_mesh_arrays(
					registry, chunk, world.collect_neighbors(coord))
		renderer.apply_mesh(coord, arrays, chunk.collision_dirty)
		chunk.mesh_dirty = false
		chunk.collision_dirty = false
		chunk.state = ChunkState.State.ACTIVE
		# 激活回调（树按列计数等）：_commit_mesh 路径首次提交时逐块调，
		# 本同步路径曾漏调——出生列树实体不建、区块内树"隐形"直到任意
		# 重网格（审查发现）。逐块调用与异步路径对齐（树系统按列计数）
		if on_chunk_active_cb.is_valid():
			on_chunk_active_cb.call(coord)
	# 已存在的水平邻居需要用本列的真实边界数据重建
	for y in range(band.y, band.x - 1, -1):
		_mark_neighbors_dirty(Vector3i(column.x, y, column.y), true)


# ---- 调度策略（纯函数，可单元测试） ----

## 圆形视距内的所有水平列，按距中心升序。
static func desired_columns(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dz * dz <= radius * radius:
				result.append(center + Vector2i(dx, dz))
	var compare := func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(center) < b.distance_squared_to(center)
	result.sort_custom(compare)
	return result


## 列是否应卸载：超出（视距 + 缓冲）半径。
static func should_unload_column(
		chunk_coord: Vector3i,
		center: Vector2i,
		p_view_distance: int,
		padding: int
) -> bool:
	var limit := p_view_distance + padding
	return Vector2i(chunk_coord.x, chunk_coord.z).distance_squared_to(center) \
			> limit * limit


## 越小越优先：距离平方为主，视线前方适度加成（§10.2）。
static func priority_score(
		column: Vector2i,
		center: Vector2i,
		view_dir: Vector2,
		bias: float
) -> float:
	var delta := column - center
	# Vector2i 无 dot 方法，手动展开
	return float(delta.length_squared()) \
			- bias * float(delta.x * view_dir.x + delta.y * view_dir.y)


# ---- 内部实现 ----

func _update_streaming() -> void:
	var center := _focus_column()
	var layer := _focus_chunk_y()
	var center_moved := center != _stream_center
	var layer_moved := layer != _stream_layer
	if center_moved or layer_moved:
		# 1) 卸载（.keys() 取副本，避免遍历中修改）：水平出视距 + 垂直
		# 出活跃带（v9；带随玩家层伸缩，含滞回）。焦点未变时跳过——
		# 新增区块全部来自带内任务提交，不会触发卸载
		for coord in world.chunks.keys():
			if should_unload_column(coord, center, view_distance, unload_padding) \
					or _outside_band(coord):
				_unload_chunk(coord)
		if center_moved:
			_stream_center = center
			_ensure_collision_ring(center)
			_prune_band_cache(center)
		_stream_layer = layer
		_stream_cursor = 0  # 带变化：完整列可能重新缺层
		# 带扩展新含入的 DATA_READY 缓冲层补网格（曾在 gate 中清了
		# 脏标记，无其他触发源）
		for coord in world.chunks:
			var bchunk: ChunkData = world.chunks[coord]
			if bchunk.state == ChunkState.State.DATA_READY \
					and _in_band(coord):
				bchunk.mesh_dirty = true
	# 2) 列排序缓存：焦点列变化或视线偏转 >~30° 才重建（cos 阈值）
	var view_dir := _view_direction()
	if center_moved or _sorted_columns.is_empty() \
			or view_dir == Vector2.ZERO \
			or _stream_dir.dot(view_dir) < 0.866:
		var columns := desired_columns(center, view_distance)
		var compare := func(a: Vector2i, b: Vector2i) -> bool:
			return priority_score(a, center, view_dir, view_bias) \
					< priority_score(b, center, view_dir, view_bias)
		columns.sort_custom(compare)
		_sorted_columns = columns
		_stream_dir = view_dir
		_stream_cursor = 0
	# 3) 补缺：每列自上而下，下层只在上层已就绪时入队（光照下界起算
	# 要求入队快照里上方邻块存在——"上方缺失"恒等于带顶天空）。
	# 列可能在等上层，故跨列扫描（窗口限每帧工作量）；游标只越过
	# 前缀完整列
	var idx := _stream_cursor
	var scanned := 0
	var prefix_complete := true
	while idx < _sorted_columns.size() and scanned < SCAN_WINDOW \
			and in_flight_count() < max_in_flight:
		var complete := _fill_column(_sorted_columns[idx])
		if complete and prefix_complete:
			_stream_cursor = idx + 1
		else:
			prefix_complete = false
		idx += 1
		scanned += 1


## 列补缺一步：自带顶向下找首个缺失层，在途则等，否则入队（休眠
## 恢复/生成）。返回整列带内是否齐全。
func _fill_column(column: Vector2i) -> bool:
	var band := column_band(column)
	for y in range(band.y, band.x - 1, -1):
		var coord := Vector3i(column.x, y, column.y)
		if world.has_chunk(coord):
			continue
		if _gen_by_coord.has(coord):
			return false  # 在途：下层须等它就绪
		if _dormant.has(coord):
			var rchunk: ChunkData = _restore_dormant(coord)
			renderer.register_chunk(coord)
			_mark_neighbors_dirty(coord)
			# 休眠期间光照可能过期（增量未达未加载块），恢复即重算
			if light_init_cb.is_valid():
				light_init_cb.call(rchunk, _collect_light_neighbors(coord))
			if on_chunk_data_ready_cb.is_valid():
				on_chunk_data_ready_cb.call(rchunk)
			continue  # 同步就绪：可继续向下
		# 磁盘存档由生成任务在工作线程内优先读取（见 _generate_job）
		_enqueue_generation(coord)
		return false
	return true


## 地表带缓存修剪：离开视距+缓冲的列丢弃（防长途跋涉缓存无界增长）。
func _prune_band_cache(center: Vector2i) -> void:
	var limit := view_distance + unload_padding + 2
	var lim2 := limit * limit
	for col in _surface_bands.keys():
		if (col as Vector2i).distance_squared_to(center) > lim2:
			_surface_bands.erase(col)


## 玩家跨列后：把新进入碰撞圈的已激活区块标脏补建碰撞（初建时
## 在圈外被跳过）。出圈方向不拆——碰撞保留到区块卸载（内存换
## 稳定，避免边界横跳重建）。
func _ensure_collision_ring(center: Vector2i) -> void:
	if renderer == null or not renderer.has_method("has_collision"):
		return
	var r2 := collision_radius * collision_radius
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		if chunk.state != ChunkState.State.ACTIVE:
			continue
		if Vector2i(coord.x, coord.z).distance_squared_to(center) > r2:
			continue
		if renderer.has_collision(coord):
			continue
		chunk.collision_dirty = true


func _poll_jobs() -> void:
	# 已完成但超出本帧预算的任务留在册中，下一帧继续提交
	var gen_committed := 0
	for task_id in _gen_jobs.keys():
		if gen_committed >= gen_commit_budget:
			break
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		var job: Dictionary = _gen_jobs[task_id]
		_gen_jobs.erase(task_id)
		_gen_by_coord.erase(job["coord"])
		if _commit_generation(job):
			gen_committed += 1
	var mesh_committed := 0
	for task_id in _mesh_jobs.keys():
		if mesh_committed >= mesh_commit_budget:
			break
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		var job: Dictionary = _mesh_jobs[task_id]
		_mesh_jobs.erase(task_id)
		_mesh_by_coord.erase(job["coord"])
		if _commit_mesh(job):
			mesh_committed += 1
	# 脏区块网格任务（首次网格化与修改重建共用该路径）；
	# collision_dirty 单独触发（玩家进入碰撞圈的补建路径——重网格
	# 产出同 arrays，提交时按圈半径决定建碰撞）
	for coord in world.chunks:
		if in_flight_count() >= max_in_flight:
			break
		var chunk: ChunkData = world.chunks[coord]
		if (chunk.mesh_dirty or chunk.collision_dirty) \
				and not _mesh_by_coord.has(coord):
			_enqueue_mesh(coord)


func _enqueue_generation(coord: Vector3i) -> void:
	var job := {
		"coord": coord,
		"result": null,
		# 光照初始化用的 6 面邻块快照（worker 内查 dict 有并发风险）
		"light_neighbors": _collect_light_neighbors(coord),
	}
	var task_id := WorkerThreadPool.add_task(
			_generate_job.bind(job, coord), false, "chunk_generate")
	_gen_by_coord[coord] = task_id
	_gen_jobs[task_id] = job


## 6 面已加载邻块引用（顺序 +x,-x,+y,-y,+z,-z，缺失 null）。
func _collect_light_neighbors(coord: Vector3i) -> Array:
	var result := []
	for d in [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]:
		result.append(world.get_chunk(coord + d))
	return result


func _generate_job(job: Dictionary, coord: Vector3i) -> void:
	# 优先读磁盘存档（被修改区块的完整数据），无存档才重新生成；
	# 文件读取与生成都远离主线程（§10.1）
	var chunk: ChunkData = null
	if save_system != null:
		chunk = save_system.load_chunk(coord)
	if chunk == null:
		chunk = generator.generate_chunk(coord)
	# 光照初始化（transient 数组不入库，存档恢复的区块同样全量重算）
	if light_init_cb.is_valid():
		light_init_cb.call(chunk, job["light_neighbors"])
	job["result"] = chunk


func _commit_generation(job: Dictionary) -> bool:
	var coord: Vector3i = job["coord"]
	var chunk: ChunkData = job["result"]
	job["result"] = null
	if chunk == null:
		return false
	# 提交期用带+pad 宽判（与卸载一致）——曾用 _is_wanted 严格带判：
	# 玩家层波动让刚生成的 pad 缓冲层在此被丢弃，state 卡 DATA_READY
	# 且 mesh 永不建立（实测 512 世界单区块无限重入队、is_idle 恒 false）
	if not _is_wanted(coord) or _outside_band(coord) \
			or world.has_chunk(coord):
		return false  # 过期任务：不再需要或已被替代，丢弃
	chunk.state = ChunkState.State.DATA_READY
	world.add_chunk(chunk)
	renderer.register_chunk(coord)
	_mark_neighbors_dirty(coord)
	if on_chunk_data_ready_cb.is_valid():
		on_chunk_data_ready_cb.call(chunk)
	return true


func _enqueue_mesh(coord: Vector3i) -> void:
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return
	# v9 垂直缓冲层（带外 pad 内）只保数据不网格化：这些层的水平
	# 邻按各自列带取舍大量缺失，网格化=邻居全无的孤儿（还会被带
	# 波动反复标脏——实测单区块 6000+ 轮重网格风暴）。清脏标记
	#（数据就绪即安定，is_idle 语义成立）；玩家层变化使带含它时
	# 由 layer_moved 分支补标脏构建
	if not _in_band(coord):
		chunk.mesh_dirty = false
		chunk.collision_dirty = false
		chunk.state = ChunkState.State.DATA_READY
		return
	var neighbors := world.collect_neighbors(coord)
	var serials := []
	serials.resize(27)
	for i in 27:
		var neighbor: ChunkData = neighbors[i]
		serials[i] = neighbor.edit_serial if neighbor != null else -1
	var job := {
		"coord": coord,
		"neighbors": neighbors,
		"serials": serials,
		# 主线程预收集水位表：worker 侧 collect 遍历 sparse_block_states
		# Dictionary，与主线程水位 tick 的增删并发可致哈希表损坏
		#（审查发现）；PackedArray 撕裂由 serial 比对自愈不需快照
		"water_levels": ChunkMesher.collect_water_levels_world(chunk, neighbors),
		"result": null,
		# 入队时是否已 ACTIVE（重网格）：激活回调只该首次触发
		"was_active": chunk.state == ChunkState.State.ACTIVE,
	}
	chunk.state = ChunkState.State.MESH_QUEUED
	# 入队即清脏标记：任务是否过期由上方快照的 edit_serial 判定。
	# 任务期间若有新修改/新邻居到达，脏标记会重新置位，提交时因
	# mesh_dirty 为 true 被丢弃并自动重新排队（§4.4 版本检查）。
	chunk.mesh_dirty = false
	var task_id := WorkerThreadPool.add_task(
			_mesh_job.bind(job, chunk), false, "chunk_mesh")
	_mesh_by_coord[coord] = task_id
	_mesh_jobs[task_id] = job


func _mesh_job(job: Dictionary, chunk: ChunkData) -> void:
	if use_greedy_meshing:
		job["result"] = GreedyMesher.build_mesh_arrays(
				registry, chunk, job["neighbors"], job["water_levels"])
	else:
		job["result"] = ChunkMesher.build_mesh_arrays(
				registry, chunk, job["neighbors"], job["water_levels"])


## 过期比对覆盖全部 26 邻（曾只查 6 面——水面角点高度/岸衰减与
## 光照平滑采样都会读对角区块，角格编辑后对角网格曾带旧数据提交）
const NEIGHBOR_EXPIRE_INDICES: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26]


func _commit_mesh(job: Dictionary) -> bool:
	var coord: Vector3i = job["coord"]
	var mesh_arrays: Dictionary = job["result"]
	job["result"] = null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or _outside_band(coord):
		return false  # 已卸载/带外超 pad：不再需要（卸载即将发生）
	if not _is_wanted(coord):
		# 水平出视距。仍在卸载缓冲内（padding>0）的区块不会被卸载、
		# 也无重排源——补回 mesh_dirty 触发重排，否则网格缺失卡
		# MESH_QUEUED（_enqueue_mesh 已清标记）
		if not should_unload_column(coord, _focus_column(),
				view_distance, unload_padding):
			chunk.mesh_dirty = true
		return false
	if chunk.mesh_dirty:
		return false  # 任务期间又被修改：丢弃，脏标记会触发重新排队
	# 面邻居数据序号比对（§4.4 过期任务检查）：任一变化即丢弃。
	# 快照中为 null 的位置后来出现区块（-1 -> >=0）同样视为过期。
	var current := world.collect_neighbors(coord)
	var serials: Array = job["serials"]
	var stored_neighbors: Array = job["neighbors"]
	for i in NEIGHBOR_EXPIRE_INDICES:
		var stored: ChunkData = stored_neighbors[i]
		var now: ChunkData = current[i]
		var stored_serial: int = stored.edit_serial if stored != null else -1
		var now_serial: int = now.edit_serial if now != null else -1
		if stored_serial != now_serial:
			# 兜底：丢弃即重新标脏，保证任何漏标路径都不会卡死/漏重建
			chunk.mesh_dirty = true
			return false
	# 碰撞是否需要重建：纯水位变化（affects_collision=false）只标了
	# mesh_dirty，跳过碰撞形状重建（水无碰撞体）；碰撞圈外的区块
	# 不建顶点汤（观景视距下远区块玩家接触不到——Concave 构建/内存
	# 大头），进入圈时由 _ensure_collision_ring 补建
	var want_collision := Vector2i(coord.x, coord.z) \
			.distance_squared_to(_stream_center) \
			<= collision_radius * collision_radius
	renderer.apply_mesh(coord, mesh_arrays,
			chunk.collision_dirty and want_collision)
	chunk.mesh_dirty = false
	chunk.collision_dirty = false
	chunk.state = ChunkState.State.ACTIVE
	# 激活回调只在首次进入 ACTIVE 时调（曾每次重网格都调——树 refs
	# 无限膨胀 + 每次重扫 16x16 列做完整 column_profile，审查发现）
	if on_chunk_active_cb.is_valid() and not job["was_active"]:
		on_chunk_active_cb.call(coord)
	return true


## 新数据到达：把已存在的邻居标记为脏，用真实边界数据重建（§6.4）。
## horizontal_only 用于同步预热列，避免同列纵向互相触发无谓重建。
func _mark_neighbors_dirty(coord: Vector3i, horizontal_only := false) -> void:
	var deltas := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0)]
	if not horizontal_only:
		deltas.append_array([Vector3i(0, 1, 0), Vector3i(0, -1, 0)])
	deltas.append_array([Vector3i(0, 0, 1), Vector3i(0, 0, -1)])
	for delta in deltas:
		var neighbor: ChunkData = world.get_chunk(coord + delta)
		if neighbor != null and neighbor.state != ChunkState.State.DATA_READY:
			neighbor.mesh_dirty = true
			neighbor.collision_dirty = true


func _restore_dormant(coord: Vector3i) -> ChunkData:
	var chunk: ChunkData = _dormant[coord]
	_dormant.erase(coord)
	chunk.mesh_dirty = true
	chunk.collision_dirty = true
	chunk.state = ChunkState.State.DATA_READY
	world.add_chunk(chunk)
	return chunk


func _unload_chunk(coord: Vector3i) -> void:
	if on_chunk_unloaded_cb.is_valid():
		on_chunk_unloaded_cb.call(coord)
	# 在途任务的结果会在提交时因"不再需要/区块不存在"被丢弃
	renderer.remove_chunk(coord)
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return
	if chunk.data_modified:
		var persisted := true
		if chunk.save_needed:
			# 增量存盘：卸载前把修改写透磁盘（§9.2）
			persisted = save_system != null and save_system.save_chunk(chunk)
		elif save_system != null and not save_system.has_chunk(coord):
			# 无待写标记但磁盘无文件（理论不可达）：兜底写一份
			persisted = save_system.save_chunk(chunk)
		if not persisted:
			# 写盘失败：内存兜底缓存，绝不丢玩家修改（§4.4）
			chunk.state = ChunkState.State.EVICT_PENDING
			_dormant[coord] = chunk
	world.remove_chunk(coord)


func _is_wanted(coord: Vector3i) -> bool:
	if not world.config.in_chunk_bounds(coord):
		return false
	var center := _focus_column()
	var col := Vector2i(coord.x, coord.z)
	if col.distance_squared_to(center) > view_distance * view_distance:
		return false
	var band := column_band(col)
	return coord.y >= band.x and coord.y <= band.y


# ---- v9 垂直流式（Cubic Chunks / Minetest 思路）----
## chunks_y 不超过此值的世界整列加载（48 高老世界/测试语义不变）。
const LEGACY_FULL_COLUMN_LAYERS := 4
## 地表带下沿：列足迹最低地表再往下多少格（洞口/浅挖）。
const BAND_BELOW_BLOCKS := 16
## 地表带上沿：max(最高地表, 海平面) 再往上多少格（树高 ≤20）。
const BAND_ABOVE_BLOCKS := 24
## 玩家带：碰撞圈内列额外保证玩家所在层 ±N（挖掘/飞行/建造）。
const PLAYER_BAND := 2
## 垂直卸载滞回（带外再多 N 层才卸，防层边界来回横跳）。
const V_UNLOAD_PAD := 1
## 每帧补缺扫描的列数上限（列可能在等上层就绪，需跨列推进）。
const SCAN_WINDOW := 96

var _surface_bands := {}  # Vector2i 列 -> Vector2i(min_layer, max_layer)
var _stream_layer := -2147483648


## 列的垂直活跃带（含两端的 chunk 层索引）：地表带 ∪ 碰撞圈内玩家带，
## 连续区间——光照自上而下初始化要求带内无空洞。
func column_band(col: Vector2i) -> Vector2i:
	var cy: int = world.config.chunks_y
	if cy <= LEGACY_FULL_COLUMN_LAYERS:
		return Vector2i(0, cy - 1)
	var band := _surface_band(col)
	if col.distance_squared_to(_focus_column()) \
			<= collision_radius * collision_radius:
		var py := _focus_chunk_y()
		band = Vector2i(mini(band.x, py - PLAYER_BAND),
				maxi(band.y, py + PLAYER_BAND))
	return Vector2i(clampi(band.x, 0, cy - 1), clampi(band.y, 0, cy - 1))


## 地表带（缓存）：C# 精确算列足迹（外扩一格）地表区间；无 C# 时
## 回退 GD 逐列 profile（慢，仅兜底）。
func _surface_band(col: Vector2i) -> Vector2i:
	if _surface_bands.has(col):
		return _surface_bands[col]
	var s: int = world.config.chunk_size
	var r: Vector2i = NativeTerrainBridge.column_surface_range(
			world.config.world_seed, world.config.world_height_blocks(),
			col, s)
	if r.x > r.y:
		# C# 不可用：GD 回退（外扩一格同语义）
		r = Vector2i(2147483647, -2147483648)
		for dz in range(-1, s + 1):
			for dx in range(-1, s + 1):
				var h := generator.column_height(col.x * s + dx, col.y * s + dz)
				r = Vector2i(mini(r.x, h), maxi(r.y, h))
	var lo := r.x - BAND_BELOW_BLOCKS
	var hi := maxi(r.y, generator.sea_level) + BAND_ABOVE_BLOCKS
	var band := Vector2i(VoxelCoords.floordiv(lo, s), VoxelCoords.floordiv(hi, s))
	_surface_bands[col] = band
	return band


func _focus_chunk_y() -> int:
	var y := focus.global_position.y if focus != null else 0.0
	return VoxelCoords.floordiv(int(floor(y)), world.config.chunk_size)


## 区块是否在其列活跃带内（严格，不含 pad——网格化资格判据）。
func _in_band(coord: Vector3i) -> bool:
	if world.config.chunks_y <= LEGACY_FULL_COLUMN_LAYERS:
		return true
	var band := column_band(Vector2i(coord.x, coord.z))
	return coord.y >= band.x and coord.y <= band.y


## 区块是否在其列活跃带外（含滞回）——垂直卸载判据。
func _outside_band(coord: Vector3i) -> bool:
	if world.config.chunks_y <= LEGACY_FULL_COLUMN_LAYERS:
		return false
	var band := column_band(Vector2i(coord.x, coord.z))
	return coord.y < band.x - V_UNLOAD_PAD or coord.y > band.y + V_UNLOAD_PAD


## 垂直带估算的区块总数（加载进度条分母）。
func estimate_band_chunks(columns: Array[Vector2i]) -> int:
	var total := 0
	for col in columns:
		var band := column_band(col)
		total += band.y - band.x + 1
	return maxi(1, total)


func _focus_column() -> Vector2i:
	var pos := focus.global_position if focus != null else Vector3.ZERO
	var size := world.config.chunk_size
	return Vector2i(
		VoxelCoords.floordiv(int(pos.x), size),
		VoxelCoords.floordiv(int(pos.z), size))


func _view_direction() -> Vector2:
	if _camera == null and focus != null:
		var cameras := focus.find_children("*", "Camera3D", false, false)
		if not cameras.is_empty():
			_camera = cameras[0]
	if _camera == null:
		return Vector2.ZERO
	var forward := -_camera.global_transform.basis.z
	return Vector2(forward.x, forward.z).normalized()
