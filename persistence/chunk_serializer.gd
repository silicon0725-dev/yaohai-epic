## 区块序列化（开发文档 §9.1）：修改过的区块保存完整数据
##（而非生成增量），这样生成算法升级后旧存档仍能精确还原。
##
## 方块用"调色板 + 稳定名称"存储（§2.2）：每个区块文件记录
## 出现过的方块类型到稳定名称（如 core:stone）的映射，数据体
## 只存 1 字节槽位号。注册表重排不会破坏旧存档；读取时未知
## 名称按明确回退策略替换为石头并告警（§11.2）。
##
## v2 起追加稀疏状态段（§4.3 方块状态持久化）：局部坐标 + JSON
## 状态字典（值必须是可 JSON 化类型）。v1 旧档无该段，按版本
## 条件读取，完全兼容。
##
## 字节布局（小端）：
##   u32 magic | u16 格式版本 | u32 生成算法版本
##   i32 坐标x/y/z | u16 尺寸x/y/z
##   u16 调色板数 | 每项: u16 名称字节数 + UTF-8 名称
##   数据体: 每方块 1 字节槽位号（按 x + sx*(y + sy*z) 索引序）
##   [v2] u16 状态项数 | 每项: u16 x/y/z + u16 JSON 字节数 + UTF-8 JSON
class_name ChunkSerializer
extends RefCounted

const CHUNK_MAGIC := 0x5643484B  # "VCHK"
const CHUNK_FORMAT_VERSION := 2
## 未知稳定名称的回退方块（可见、可挖，避免建筑凭空消失）
const UNKNOWN_BLOCK_FALLBACK := "core:stone"


static func serialize(registry: VoxelRegistry, chunk: ChunkData) -> PackedByteArray:
	# 调色板：按首次出现顺序分配槽位（同数据必然同文件，确定性）
	var slot_of := {}
	var palette_names: Array[String] = []
	var data := PackedByteArray()
	data.resize(chunk.block_ids.size())
	for i in chunk.block_ids.size():
		var block_id: int = chunk.block_ids[i]
		var slot: int
		if slot_of.has(block_id):
			slot = slot_of[block_id]
		else:
			slot = palette_names.size()
			assert(slot < 256, "单区块方块种类超过 255，需扩展槽位宽度")
			slot_of[block_id] = slot
			palette_names.append(registry.name_for_id(block_id))
		data[i] = slot

	var peer := StreamPeerBuffer.new()
	peer.big_endian = false
	peer.put_u32(CHUNK_MAGIC)
	peer.put_u16(CHUNK_FORMAT_VERSION)
	peer.put_u32(chunk.generation_version)
	peer.put_32(chunk.chunk_coord.x)
	peer.put_32(chunk.chunk_coord.y)
	peer.put_32(chunk.chunk_coord.z)
	peer.put_u16(chunk.dimensions.x)
	peer.put_u16(chunk.dimensions.y)
	peer.put_u16(chunk.dimensions.z)
	peer.put_u16(palette_names.size())
	for block_name in palette_names:
		var name_bytes := block_name.to_utf8_buffer()
		peer.put_u16(name_bytes.size())
		peer.put_data(name_bytes)
	peer.put_data(data)
	# v2：稀疏状态段（局部坐标 -> JSON 状态字典）
	peer.put_u16(chunk.sparse_block_states.size())
	for local in chunk.sparse_block_states:
		var state: Dictionary = chunk.sparse_block_states[local]
		peer.put_u16(local.x)
		peer.put_u16(local.y)
		peer.put_u16(local.z)
		var state_bytes := JSON.stringify(state).to_utf8_buffer()
		assert(state_bytes.size() < 65536, "状态字典过大，需分片存储")
		peer.put_u16(state_bytes.size())
		peer.put_data(state_bytes)
	return peer.data_array


## 返回 null 表示数据损坏/不兼容（已记录日志），调用方回退到重新生成。
static func deserialize(
		registry: VoxelRegistry,
		payload: PackedByteArray,
		expected_coord: Vector3i
) -> ChunkData:
	if payload.size() < 30:
		push_warning("区块存档过短: %d 字节" % payload.size())
		return null
	var peer := StreamPeerBuffer.new()
	peer.big_endian = false
	peer.data_array = payload
	if peer.get_u32() != CHUNK_MAGIC:
		push_warning("区块存档 magic 不符（损坏）")
		return null
	var format_version := peer.get_u16()
	if format_version > CHUNK_FORMAT_VERSION:
		push_warning("区块存档格式版本 %d 高于当前支持的 %d" % [
			format_version, CHUNK_FORMAT_VERSION])
		return null
	var generation_version := peer.get_u32()
	var coord := Vector3i(peer.get_32(), peer.get_32(), peer.get_32())
	if coord != expected_coord:
		push_warning("区块存档坐标不符: 文件 %s，期望 %s" % [str(coord), str(expected_coord)])
		return null
	var dims := Vector3i(peer.get_u16(), peer.get_u16(), peer.get_u16())
	var volume := dims.x * dims.y * dims.z
	if volume <= 0:
		push_warning("区块存档尺寸非法: %s" % str(dims))
		return null
	var palette_size := peer.get_u16()
	var palette_ids := PackedInt32Array()
	palette_ids.resize(palette_size)
	for i in palette_size:
		var name_length := peer.get_u16()
		if name_length <= 0 or name_length > 128:
			push_warning("区块存档调色板名称长度非法")
			return null
		var name_result: Array = peer.get_data(name_length)
		if name_result[0] != OK:
			push_warning("区块存档调色板读取失败")
			return null
		var block_name: String = (name_result[1] as PackedByteArray).get_string_from_utf8()
		var block_id := registry.id_for_name(block_name)
		if block_id < 0:
			# §11.2 回退策略：明确告警 + 替换，不中断加载
			push_warning("存档包含未注册方块 '%s'，替换为 %s" % [
				block_name, UNKNOWN_BLOCK_FALLBACK])
			block_id = registry.id_for_name(UNKNOWN_BLOCK_FALLBACK)
		palette_ids[i] = block_id
	var data_result: Array = peer.get_data(volume)
	if data_result[0] != OK or (data_result[1] as PackedByteArray).size() != volume:
		push_warning("区块存档数据体不完整")
		return null
	var data: PackedByteArray = data_result[1]

	var chunk := ChunkData.new(coord, dims, generation_version)
	for i in volume:
		var slot: int = data[i]
		if slot >= palette_size:
			push_warning("区块存档槽位越离（损坏）")
			return null
		chunk.block_ids[i] = palette_ids[slot]

	# v2：读取稀疏状态段（v1 旧档无此段，跳过）
	if format_version >= 2:
		if peer.get_available_bytes() < 2:
			return chunk
		var state_count := peer.get_u16()
		for i in state_count:
			if peer.get_available_bytes() < 8:
				push_warning("区块存档状态段不完整")
				break
			var local := Vector3i(peer.get_u16(), peer.get_u16(), peer.get_u16())
			var json_length := peer.get_u16()
			if json_length == 0 or peer.get_available_bytes() < json_length:
				push_warning("区块存档状态项损坏，跳过剩余状态")
				break
			var json_result: Array = peer.get_data(json_length)
			if json_result[0] != OK:
				break
			var parsed = JSON.parse_string(
					(json_result[1] as PackedByteArray).get_string_from_utf8())
			if local.x >= 0 and local.x < dims.x and local.y >= 0 \
					and local.y < dims.y and local.z >= 0 and local.z < dims.z \
					and parsed is Dictionary:
				chunk.sparse_block_states[local] = parsed
			else:
				push_warning("区块存档状态项非法（越界或非字典），已跳过")
	return chunk
