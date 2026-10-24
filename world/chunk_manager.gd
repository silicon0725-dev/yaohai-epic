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

## 视距（水平，区块半径）。
@export var view_distance := 5
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


## 同步加载一列区块（出生点保底，防止玩家在流式就绪前坠落）。
## 优先级：内存兜底 > 磁盘存档 > 重新生成。
func load_column_now(column: Vector2i) -> void:
	for y in world.config.chunks_y:
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
	# 纵向邻居全部就绪后再统一构建网格，避免列内互相触发重建
	for y in world.config.chunks_y:
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
	# 已存在的水平邻居需要用本列的真实边界数据重建
	for y in world.config.chunks_y:
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
	# 1) 卸载（.keys() 取副本，避免遍历中修改）
	for coord in world.chunks.keys():
		if should_unload_column(coord, center, view_distance, unload_padding):
			_unload_chunk(coord)
	# 2) 按优先级补齐缺失区块（预算不足则下帧继续）
	var view_dir := _view_direction()
	var columns := desired_columns(center, view_distance)
	var compare := func(a: Vector2i, b: Vector2i) -> bool:
		return priority_score(a, center, view_dir, view_bias) \
				< priority_score(b, center, view_dir, view_bias)
	columns.sort_custom(compare)
	for column in columns:
		if in_flight_count() >= max_in_flight:
			break
		for y in world.config.chunks_y:
			var coord := Vector3i(column.x, y, column.y)
			if world.has_chunk(coord) or _gen_by_coord.has(coord):
				continue
			if _dormant.has(coord):
				_restore_dormant(coord)
				renderer.register_chunk(coord)
				_mark_neighbors_dirty(coord)
			else:
				# 磁盘存档由生成任务在工作线程内优先读取（见 _generate_job）
				_enqueue_generation(coord)


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
	# 脏区块网格任务（首次网格化与修改重建共用该路径）
	for coord in world.chunks:
		if in_flight_count() >= max_in_flight:
			break
		var chunk: ChunkData = world.chunks[coord]
		if chunk.mesh_dirty and not _mesh_by_coord.has(coord):
			_enqueue_mesh(coord)


func _enqueue_generation(coord: Vector3i) -> void:
	var job := {"coord": coord, "result": null}
	var task_id := WorkerThreadPool.add_task(
			_generate_job.bind(job, coord), false, "chunk_generate")
	_gen_by_coord[coord] = task_id
	_gen_jobs[task_id] = job


func _generate_job(job: Dictionary, coord: Vector3i) -> void:
	# 优先读磁盘存档（被修改区块的完整数据），无存档才重新生成；
	# 文件读取与生成都远离主线程（§10.1）
	var chunk: ChunkData = null
	if save_system != null:
		chunk = save_system.load_chunk(coord)
	if chunk == null:
		chunk = generator.generate_chunk(coord)
	job["result"] = chunk


func _commit_generation(job: Dictionary) -> bool:
	var coord: Vector3i = job["coord"]
	var chunk: ChunkData = job["result"]
	job["result"] = null
	if chunk == null:
		return false
	if not _is_wanted(coord) or world.has_chunk(coord):
		return false  # 过期任务：不再需要或已被替代，丢弃
	chunk.state = ChunkState.State.DATA_READY
	world.add_chunk(chunk)
	renderer.register_chunk(coord)
	_mark_neighbors_dirty(coord)
	return true


func _enqueue_mesh(coord: Vector3i) -> void:
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
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
		"result": null,
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
				registry, chunk, job["neighbors"])
	else:
		job["result"] = ChunkMesher.build_mesh_arrays(
				registry, chunk, job["neighbors"])


## 27 邻域数组中 6 个面邻居的下标（遮挡判定只读单轴偏移的填充格，
## 对角/棱角邻居的数据不参与面剔除，因此序列号比对只需覆盖面邻居——
## 与 _mark_neighbors_dirty 的标脏范围精确对齐）。
const FACE_NEIGHBOR_INDICES := [4, 10, 12, 14, 16, 22]


func _commit_mesh(job: Dictionary) -> bool:
	var coord: Vector3i = job["coord"]
	var mesh_arrays: Dictionary = job["result"]
	job["result"] = null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not _is_wanted(coord):
		return false  # 已卸载或不再需要
	if chunk.mesh_dirty:
		return false  # 任务期间又被修改：丢弃，脏标记会触发重新排队
	# 面邻居数据序号比对（§4.4 过期任务检查）：任一变化即丢弃。
	# 快照中为 null 的位置后来出现区块（-1 -> >=0）同样视为过期。
	var current := world.collect_neighbors(coord)
	var serials: Array = job["serials"]
	var stored_neighbors: Array = job["neighbors"]
	for i in FACE_NEIGHBOR_INDICES:
		var stored: ChunkData = stored_neighbors[i]
		var now: ChunkData = current[i]
		var stored_serial: int = stored.edit_serial if stored != null else -1
		var now_serial: int = now.edit_serial if now != null else -1
		if stored_serial != now_serial:
			# 兜底：丢弃即重新标脏，保证任何漏标路径都不会卡死/漏重建
			chunk.mesh_dirty = true
			return false
	# 碰撞是否需要重建：纯水位变化（affects_collision=false）只标了
	# mesh_dirty，提交时跳过碰撞形状重建（水无碰撞体）
	renderer.apply_mesh(coord, mesh_arrays, chunk.collision_dirty)
	chunk.mesh_dirty = false
	chunk.collision_dirty = false
	chunk.state = ChunkState.State.ACTIVE
	if on_chunk_active_cb.is_valid():
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
	return Vector2i(coord.x, coord.z).distance_squared_to(center) \
			<= view_distance * view_distance


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
