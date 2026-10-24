## 体素世界：数据持有者 + 统一修改 API（开发文档 §8.2）。
## 阶段 C 起水平方向无限：chunks 按需增删，区块数据与
## 视觉节点由 ChunkManager 管理生命周期（§4.4）。
## 渲染网格不是世界数据的事实来源；任何方块修改必须经过
## get_block / set_block / replace_block，以便统一标记网格、
## 碰撞与存档过期，其他系统不得直接改区块数组。
class_name VoxelWorld
extends RefCounted

var config: WorldConfig
var registry: VoxelRegistry

## 方块实际变更时广播（set_block 成功路径）。水位模拟（WaterFlow）
## 据此把扰动位置入队；语义：只有"数据变化"事件，无负载语义。
signal block_changed(pos: Vector3i, old_id: int, new_id: int)

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
func set_block(world_pos: Vector3i, id: int, affects_collision := true) -> bool:
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
		block_changed.emit(world_pos, old_id, id)
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
	var size := config.chunk_size
	var affected: Array[Vector3i] = [chunk_coord]
	if local.x == 0:
		affected.append(chunk_coord + Vector3i(-1, 0, 0))
	if local.x == size - 1:
		affected.append(chunk_coord + Vector3i(1, 0, 0))
	if local.y == 0:
		affected.append(chunk_coord + Vector3i(0, -1, 0))
	if local.y == size - 1:
		affected.append(chunk_coord + Vector3i(0, 1, 0))
	if local.z == 0:
		affected.append(chunk_coord + Vector3i(0, 0, -1))
	if local.z == size - 1:
		affected.append(chunk_coord + Vector3i(0, 0, 1))
	for coord in affected:
		var chunk: ChunkData = chunks.get(coord)
		if chunk != null:
			chunk.mesh_dirty = true
			if affects_collision:
				chunk.collision_dirty = true
