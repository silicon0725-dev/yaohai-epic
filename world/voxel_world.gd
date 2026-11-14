## 体素世界：数据持有者 + 统一修改 API（开发文档 §8.2）。
## 阶段 C 起水平方向无限：chunks 按需增删，区块数据与
## 视觉节点由 ChunkManager 管理生命周期（§4.4）。
## 渲染网格不是世界数据的事实来源；任何方块修改必须经过
## get_block / set_block / replace_block，以便统一标记网格、
## 碰撞与存档过期，其他系统不得直接改区块数组。
@tool
class_name VoxelWorld
extends RefCounted

var config: WorldConfig
var registry: VoxelRegistry

## 方块实际变更时广播（set_block 成功路径）。水位模拟（WaterFlow）
## 据此把扰动位置入队；语义：只有"数据变化"事件，无负载语义。
signal block_changed(pos: Vector3i, old_id: int, new_id: int)
## 批量写通道（树占位清理等整组变更）：cells 为实际写入的世界格。
## 消费方按区域重算（voxel_light 块级全量、cave_fog 标脏），替代
## 每格一次的 block_changed（增量 BFS 曾每格 2-7ms——审查 3-F3）
signal blocks_changed_batch(cells: Array)
## 方块写入代数（任何写入 +1）——位置类缓存（音效反射面等）的
## 单一失效来源（审查二轮 B4）
var edit_generation := 0

## Vector3i（区块坐标） -> ChunkData
var chunks := {}


func _init(world_config: WorldConfig, block_registry: VoxelRegistry) -> void:
	config = world_config
	registry = block_registry


func chunk_count() -> int:
	return chunks.size()


func has_chunk(chunk_coord: Vector3i) -> bool:
	return chunks.has(chunk_coord)


func get_chunk(chunk_coord: Vector3i) -> ChunkData:
	return chunks.get(chunk_coord)


## 存入生成器产出的区块（由 ChunkManager 调用）。
func add_chunk(chunk: ChunkData) -> void:
	assert(config.in_chunk_bounds(chunk.chunk_coord),
			"区块垂直越界: %s" % chunk.chunk_coord)
	assert(not chunks.has(chunk.chunk_coord),
			"重复添加区块: %s" % chunk.chunk_coord)
	chunks[chunk.chunk_coord] = chunk


## 卸载区块（由 ChunkManager 调用；修改过的区块由管理器另行缓存）。
func remove_chunk(chunk_coord: Vector3i) -> void:
	assert(chunks.has(chunk_coord), "移除不存在的区块: %s" % chunk_coord)
	chunks.erase(chunk_coord)


## 收集 3x3x3 邻域区块引用（供网格构建，仅主线程调用）。
## 布局：index = (dz+1)*9 + (dy+1)*3 + (dx+1)，缺失为 null。
func collect_neighbors(chunk_coord: Vector3i) -> Array:
	var neighbors := []
	neighbors.resize(27)
	for dz in 3:
		for dy in 3:
			for dx in 3:
				neighbors[dz * 9 + dy * 3 + dx] = chunks.get(
						chunk_coord + Vector3i(dx - 1, dy - 1, dz - 1))
	return neighbors


## 网格构建的边界读取策略（§6.4）：显式且一致。
## y < 0 视为实心（世界底部面不渲染）；y 超出世界高度视为空气；
## 水平方向未加载的邻区块视为空气，其数据到达后由
## ChunkManager 重新标记相邻网格（临时策略 + 到达后重标）。
func get_block_for_mesh(world_pos: Vector3i) -> int:
	if world_pos.y < 0:
		return VoxelTypes.BEDROCK_ID
	if not config.in_block_bounds(world_pos):
		return VoxelTypes.AIR_ID
	return get_block(world_pos)


## 区块未加载返回空气 ID。
func get_block(world_pos: Vector3i) -> int:
	if not config.in_block_bounds(world_pos):
		return VoxelTypes.AIR_ID
	var chunk: ChunkData = chunks.get(VoxelCoords.world_to_chunk(world_pos, config.chunk_size))
	if chunk == null:
		return VoxelTypes.AIR_ID
	return chunk.get_block(VoxelCoords.world_to_local(world_pos, config.chunk_size))


## 统一修改入口：更新数据并使受影响网格/碰撞过期（含区块边界传播）。
## 方块被替换后其状态清空（放置方随后按需重新写入状态）。
## affects_collision=false 供无碰撞语义的变化用（水位流动：水/空气
## 互转不影响固体碰撞体），跳过碰撞标脏避免整块碰撞形状白重建。
## 玩家编辑通知（main 注入 chunk_manager._on_player_edit）：编辑
## 区块插队重网格
var edit_dirty_cb: Callable


func set_block(world_pos: Vector3i, id: int, affects_collision := true) -> bool:
	var _t0 := Time.get_ticks_usec()
	var _ok := _set_block_impl(world_pos, id, affects_collision)
	var _dt := Time.get_ticks_usec() - _t0
	if _ok and _dt > 8000:
		print("[perf] set_block %.1fms at %s (id %d)" % [_dt * 0.001, world_pos, id])
	return _ok


## 批量写方块（树占位清理等整组同值变更）：逐格写数据+网格失效
##（affects_collision 语义=false——批量通道当前只有树占位 AIR 化，
## 无碰撞方块），单格 block_changed 不发——光照/cave_fog 由末尾
## 一次 blocks_changed_batch 按区域重算（增量 BFS 曾每格 2-7ms，
## 一棵树几十格=单次卡 100-300ms，审查 3-F3）。返回是否有写入。
func set_blocks_batch(cells: Array, id: int) -> bool:
	var written: Array = []
	# 聚合去重标脏（审查二轮 A10）：逐格失效曾每格分配受影响数组 +
	# 同块反复标脏（砍树清叶 200 格 × 最多 7 块 = 上千次字典操作）
	var affected := {}
	for pos_v in cells:
		var pos: Vector3i = pos_v
		if not config.in_block_bounds(pos):
			continue
		var chunk_coord := VoxelCoords.world_to_chunk(
				pos, config.chunk_size)
		var chunk: ChunkData = chunks.get(chunk_coord)
		if chunk == null:
			continue
		var local := VoxelCoords.world_to_local(pos, config.chunk_size)
		if chunk.get_block(local) == id:
			continue
		if not chunk.set_block(local, id):
			continue
		chunk.clear_state(local)
		_collect_affected(affected, chunk_coord, local)
		written.append(pos)
	if not written.is_empty():
		for coord in affected:
			var c: ChunkData = chunks.get(coord)
			if c != null:
				c.mesh_dirty = true  # 批量清叶语义：不标碰撞
		edit_generation += 1
		blocks_changed_batch.emit(written)
	return not written.is_empty()


func _set_block_impl(world_pos: Vector3i, id: int, affects_collision := true) -> bool:
	if not config.in_block_bounds(world_pos):
		return false
	var chunk_coord := VoxelCoords.world_to_chunk(world_pos, config.chunk_size)
	var chunk: ChunkData = chunks.get(chunk_coord)
	if chunk == null:
		return false
	var local := VoxelCoords.world_to_local(world_pos, config.chunk_size)
	var old_id := chunk.get_block(local)
	if not chunk.set_block(local, id):
		return false
	chunk.clear_state(local)
	_invalidate_affected_meshes(chunk_coord, local, affects_collision)
	if old_id != id:
		var _te := Time.get_ticks_usec()
		edit_generation += 1
		block_changed.emit(world_pos, old_id, id)
		_te = Time.get_ticks_usec() - _te
		if _te > 8000:
			print("[perf] signal_fanout %.1fms at %s" % [_te * 0.001, world_pos])
		# 玩家编辑（affects_collision=true；水/树清占位传 false）→
		# 区块管理器优先重网格该块所在区块（插队：绕过在途上限+
		# 优先提交）——异步管线按序排队曾让放置的方块 5-10 帧后才
		# 出现（实机"放置有延迟"）
		if affects_collision and edit_dirty_cb.is_valid():
			edit_dirty_cb.call(world_pos)
	return true


## 读取某格状态（无状态或位置无效返回空字典）。
func get_block_state(world_pos: Vector3i) -> Dictionary:
	if not config.in_block_bounds(world_pos):
		return {}
	var chunk: ChunkData = chunks.get(
			VoxelCoords.world_to_chunk(world_pos, config.chunk_size))
	if chunk == null:
		return {}
	return chunk.get_state(
			VoxelCoords.world_to_local(world_pos, config.chunk_size))


## 写入方块状态（统一入口，§8.2）。affects_mesh 为 true 时使所在
## 区块网格过期（朝向影响贴图）；容器内容等纯数据状态传 false。
## 碰撞形状不因状态改变（满立方体方块）。
func set_block_state(
		world_pos: Vector3i, key: String, value, affects_mesh := true
) -> bool:
	if not config.in_block_bounds(world_pos):
		return false
	var chunk_coord := VoxelCoords.world_to_chunk(world_pos, config.chunk_size)
	var chunk: ChunkData = chunks.get(chunk_coord)
	if chunk == null:
		return false
	var local := VoxelCoords.world_to_local(world_pos, config.chunk_size)
	if not chunk.set_state(local, key, value):
		return false
	if affects_mesh:
		chunk.mesh_dirty = true
	return true


## 条件替换：仅当当前位置方块与期望一致时替换（防止并发/过期操作覆盖）。
func replace_block(world_pos: Vector3i, expected_id: int, new_id: int) -> bool:
	if get_block(world_pos) != expected_id:
		return false
	return set_block(world_pos, new_id)


## 修改区块边缘方块时，相邻区块的对应网格与碰撞必须失效（§6.4）。
## affects_collision=false 只标网格（水位流动等无碰撞变化）。
func _invalidate_affected_meshes(
		chunk_coord: Vector3i, local: Vector3i, affects_collision := true
) -> void:
	var affected := {}
	_collect_affected(affected, chunk_coord, local)
	for coord in affected:
		var chunk: ChunkData = chunks.get(coord)
		if chunk != null:
			chunk.mesh_dirty = true
			if affects_collision:
				chunk.collision_dirty = true


## 受影响区块收集（纯计算，写入字典天然去重——单格与批量共用；
## 审查二轮 A10：批量路径曾逐格分配 1-7 元素数组 + 重复标同块）
func _collect_affected(affected: Dictionary,
		chunk_coord: Vector3i, local: Vector3i) -> void:
	var size := config.chunk_size
	affected[chunk_coord] = true
	if local.x == 0:
		affected[chunk_coord + Vector3i(-1, 0, 0)] = true
	if local.x == size - 1:
		affected[chunk_coord + Vector3i(1, 0, 0)] = true
	if local.y == 0:
		affected[chunk_coord + Vector3i(0, -1, 0)] = true
	if local.y == size - 1:
		affected[chunk_coord + Vector3i(0, 1, 0)] = true
	if local.z == 0:
		affected[chunk_coord + Vector3i(0, 0, -1)] = true
	if local.z == size - 1:
		affected[chunk_coord + Vector3i(0, 0, 1)] = true
	# 角点 2x2 采样跨对角区块（水面角点高度/岸衰减、光照平滑）：
	# x、z 同时贴边时对角块也要标脏（曾漏标——角格挖放后对角区块
	# 的水面角点错位/裂缝，serial 过期比对同扩全 26 邻）
	var x_edge := local.x == 0 or local.x == size - 1
	var z_edge := local.z == 0 or local.z == size - 1
	if x_edge and z_edge:
		var dx := 1 if local.x == size - 1 else -1
		var dz := 1 if local.z == size - 1 else -1
		affected[chunk_coord + Vector3i(dx, 0, dz)] = true
		if local.y == 0 or local.y == size - 1:
			var dy := 1 if local.y == size - 1 else -1
			affected[chunk_coord + Vector3i(dx, dy, dz)] = true
