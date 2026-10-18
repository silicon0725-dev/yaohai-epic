## 坐标换算单元测试（开发文档 §4.2、§11.1）。
## 重点覆盖负坐标边界：-1、-chunk_size、-chunk_size-1。
extends VoxelTestCase

const CS := 16


func run() -> void:
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(0, 0, 0), CS),
		Vector3i(0, 0, 0), "原点属于区块 0")
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(15, 15, 15), CS),
		Vector3i(0, 0, 0), "15 属于区块 0")
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(16, 16, 16), CS),
		Vector3i(1, 1, 1), "16 属于区块 1")
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(-1, -1, -1), CS),
		Vector3i(-1, -1, -1), "-1 属于区块 -1")
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(-16, 0, 0), CS),
		Vector3i(-1, 0, 0), "-16 属于区块 -1")
	check_eq(
		VoxelCoords.world_to_chunk(Vector3i(-17, 0, 0), CS),
		Vector3i(-2, 0, 0), "-17 属于区块 -2")
	check_eq(
		VoxelCoords.world_to_local(Vector3i(-1, 0, 0), CS),
		Vector3i(15, 0, 0), "-1 的局部坐标为 15")
	check_eq(
		VoxelCoords.world_to_local(Vector3i(-16, 0, 0), CS),
		Vector3i(0, 0, 0), "-16 的局部坐标为 0")
	check_eq(
		VoxelCoords.world_to_local(Vector3i(-17, 0, 0), CS),
		Vector3i(15, 0, 0), "-17 的局部坐标为 15")
	check_eq(
		VoxelCoords.chunk_origin(Vector3i(-1, 0, 0), CS),
		Vector3i(-16, 0, 0), "区块 -1 原点为 -16")

	# floordiv 边界
	check_eq(VoxelCoords.floordiv(-1, 16), -1, "floordiv(-1, 16)")
	check_eq(VoxelCoords.floordiv(-15, 16), -1, "floordiv(-15, 16)")
	check_eq(VoxelCoords.floordiv(-16, 16), -1, "floordiv(-16, 16)")
	check_eq(VoxelCoords.floordiv(-17, 16), -2, "floordiv(-17, 16)")
	check_eq(VoxelCoords.floordiv(31, 16), 1, "floordiv(31, 16)")

	# 往返一致性：世界 <-> 区块 + 局部（含大量负坐标）
	for x in range(-70, 70, 7):
		for y in range(-33, 33, 5):
			for z in range(-70, 70, 7):
				var p := Vector3i(x, y, z)
				var chunk := VoxelCoords.world_to_chunk(p, CS)
				var local := VoxelCoords.world_to_local(p, CS)
				check(
					local.x >= 0 and local.x < CS and local.y >= 0 and local.y < CS
					and local.z >= 0 and local.z < CS,
					"局部坐标越界: %s" % p)
				check_eq(
					VoxelCoords.local_to_world(chunk, local, CS), p,
					"往返换算不一致: %s" % p)
