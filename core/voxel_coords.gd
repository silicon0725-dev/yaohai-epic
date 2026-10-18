## 世界坐标与区块坐标换算的唯一入口（开发文档 §4.2）。
## 所有系统禁止自行实现换算公式；负坐标取整是历史 bug 高发区，
## 本模块的单元测试覆盖 -1、-chunk_size、-chunk_size-1 等边界。
class_name VoxelCoords
extends RefCounted


## 向下取整除法（对负数正确）：-1 / 16 -> -1，-16 / 16 -> -1，-17 / 16 -> -2。
static func floordiv(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	var q := a / b
	var r := a % b
	if r != 0 and ((r < 0) != (b < 0)):
		q -= 1
	return q


## 世界坐标 -> 区块坐标。
static func world_to_chunk(world_pos: Vector3i, chunk_size: int) -> Vector3i:
	return Vector3i(
		floordiv(world_pos.x, chunk_size),
		floordiv(world_pos.y, chunk_size),
		floordiv(world_pos.z, chunk_size)
	)


## 世界坐标 -> 区块内局部坐标，范围 [0, chunk_size)。
static func world_to_local(world_pos: Vector3i, chunk_size: int) -> Vector3i:
	return Vector3i(
		posmod(world_pos.x, chunk_size),
		posmod(world_pos.y, chunk_size),
		posmod(world_pos.z, chunk_size)
	)


## 区块坐标 -> 该区块原点（最小角）的世界坐标。
static func chunk_origin(chunk_coord: Vector3i, chunk_size: int) -> Vector3i:
	return chunk_coord * chunk_size


## 局部坐标 -> 世界坐标（world_to_chunk / world_to_local 的逆运算）。
static func local_to_world(chunk_coord: Vector3i, local_pos: Vector3i, chunk_size: int) -> Vector3i:
	return chunk_coord * chunk_size + local_pos
