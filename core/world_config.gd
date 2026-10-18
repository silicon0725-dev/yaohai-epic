## 世界配置（开发文档 §4.1、§14）。
## 区块尺寸是候选值而非永久架构约束：16^3 与 16x16x32 的取舍
## 由阶段 E 的基准测试决定；数值在创建存档时固定（阶段 D 写入存档头）。
## 阶段 C 起水平方向无限流式加载，只有垂直高度固定。
class_name WorldConfig
extends RefCounted

var chunk_size := 16
var world_seed := 1337

## 垂直区块数（世界高度 = chunks_y * chunk_size）。
var chunks_y := 3


func world_height_blocks() -> int:
	return chunks_y * chunk_size


func in_chunk_bounds(chunk_coord: Vector3i) -> bool:
	return chunk_coord.y >= 0 and chunk_coord.y < chunks_y


func in_block_bounds(world_pos: Vector3i) -> bool:
	return world_pos.y >= 0 and world_pos.y < world_height_blocks()
