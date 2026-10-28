## 单个区块的体素数据（开发文档 §4.3）。
## block_ids 使用紧凑整数数组保存方块数值 ID（经注册表映射到稳定名称）。
## 特殊状态（朝向、开关、容器内容）先用稀疏表占位，
## MVP 不为普通方块支付额外存储成本。
class_name ChunkData
extends RefCounted

var chunk_coord: Vector3i
var dimensions: Vector3i
var block_ids: PackedInt32Array

## 体素光照（光照阶段 2）：1 字节/格，高 4bit 天光、低 4bit 方块光
##（0-15）。transient 派生数据：不入库，加载/生成时由 VoxelLightSystem
## 重算（WaterFlow _pending 的"派生不持久化"同模式）。
var light: PackedByteArray

## 稀疏状态表：局部坐标 -> 状态字典（如 {"axis": "x"}）。
## 值必须是可 JSON 化的类型（字符串/数字/布尔），随区块存档持久化。
var sparse_block_states := {}

## 生成算法版本（TerrainGenerator.GENERATOR_VERSION），供存档迁移判断（§5.1）。
var generation_version := 0

## 数据修改序号：每次经 set_block 修改 +1。
## 流式加载的网格任务在提交时比对邻区块序号，发现变化即丢弃结果
##（过期任务不得覆盖新状态，§4.4）。
var edit_serial := 0

# ---- dirty_flags（§4.3）：数据修改 / 网格过期 / 碰撞过期 / 存档待写回 ----
var data_modified := false
var mesh_dirty := true
var collision_dirty := true
var save_needed := false

## 生命周期状态，见 chunk_state.gd。
var state: ChunkState.State = ChunkState.State.UNLOADED


func _init(
		coord: Vector3i = Vector3i.ZERO,
		dims: Vector3i = Vector3i(16, 16, 16),
		gen_version: int = 0
) -> void:
	chunk_coord = coord
	dimensions = dims
	generation_version = gen_version
	block_ids = PackedInt32Array()
	block_ids.resize(dims.x * dims.y * dims.z)
	block_ids.fill(0)
	light = PackedByteArray()
	light.resize(dims.x * dims.y * dims.z)
	light.fill(0)


func volume() -> int:
	return dimensions.x * dimensions.y * dimensions.z


func is_valid_local(local: Vector3i) -> bool:
	return local.x >= 0 and local.y >= 0 and local.z >= 0 \
			and local.x < dimensions.x and local.y < dimensions.y and local.z < dimensions.z


## 索引布局：x + size.x * (y + size.y * z)。
func local_index(local: Vector3i) -> int:
	return local.x + dimensions.x * (local.y + dimensions.y * local.z)


## 越界返回 -1（调用方负责先做范围检查）。
func get_block(local: Vector3i) -> int:
	if not is_valid_local(local):
		push_error("ChunkData.get_block 越界: %s in %s" % [local, chunk_coord])
		return -1
	return block_ids[local_index(local)]


## 玩家/规则修改入口：写入数据并标记修改与待存档。
## 网格与碰撞的失效由 VoxelWorld 统一处理（它才知道邻区块）。
func set_block(local: Vector3i, id: int) -> bool:
	if not is_valid_local(local):
		push_error("ChunkData.set_block 越界: %s in %s" % [local, chunk_coord])
		return false
	block_ids[local_index(local)] = id
	data_modified = true
	save_needed = true
	edit_serial += 1
	return true


## 生成器专用填充：只写数据，不标记玩家修改。
## 调用方（TerrainGenerator）保证局部坐标合法。
func set_block_raw(local: Vector3i, id: int) -> void:
	block_ids[local_index(local)] = id


# ---- 体素光照读写（0-15；数组 1 字节/格：高 4bit 天光、低 4bit 方块光） ----
## 越界返回 -1；未经 VoxelLightSystem 初始化的区块全 0（深黑）。

func get_sky_light(local: Vector3i) -> int:
	if not is_valid_local(local):
		return -1
	return light[local_index(local)] >> 4


func set_sky_light(local: Vector3i, value: int) -> void:
	var i := local_index(local)
	light[i] = (light[i] & 0x0F) | (value << 4)


func get_block_light(local: Vector3i) -> int:
	if not is_valid_local(local):
		return -1
	return light[local_index(local)] & 0x0F


func set_block_light(local: Vector3i, value: int) -> void:
	var i := local_index(local)
	light[i] = (light[i] & 0xF0) | value


# ---- 方块状态（朝向、开关等；稀疏存储，随存档持久化） ----

## 读取某格状态（无状态返回空字典）。返回内部引用，调用方只读。
func get_state(local: Vector3i) -> Dictionary:
	if not is_valid_local(local):
		return {}
	return sparse_block_states.get(local, {})


## 写入状态键值。推进 edit_serial 并标记待存档（§4.4 过期任务检查）。
## 是否使网格过期由调用方决定（朝向影响贴图，容器内容不影响）。
func set_state(local: Vector3i, key: String, value) -> bool:
	if not is_valid_local(local):
		push_error("ChunkData.set_state 越界: %s in %s" % [local, chunk_coord])
		return false
	if not sparse_block_states.has(local):
		sparse_block_states[local] = {}
	sparse_block_states[local][key] = value
	data_modified = true
	save_needed = true
	edit_serial += 1
	return true


## 清除某格全部状态（方块被替换/挖掉时调用）。无状态则无操作。
func clear_state(local: Vector3i) -> void:
	if sparse_block_states.has(local):
		sparse_block_states.erase(local)
		data_modified = true
		save_needed = true
		edit_serial += 1
