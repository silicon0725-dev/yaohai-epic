## 区块流式调度策略单元测试（开发文档 §10.2、§4.4）。
## ChunkManager 的决策逻辑为纯静态函数，可 headless 验证。
extends VoxelTestCase


func run() -> void:
	# 视距列集合：圆形边界与排序
	var columns := ChunkManager.desired_columns(Vector2i.ZERO, 2)
	check(columns.has(Vector2i(0, 0)), "包含中心列")
	check(columns.has(Vector2i(2, 0)), "包含半径边界 (2,0)")
	check(columns.has(Vector2i(-1, 1)), "包含 (-1,1)")
	check(not columns.has(Vector2i(2, 1)), "不含圆外 (2,1)")
	check(not columns.has(Vector2i(-2, -2)), "不含圆角 (-2,-2)")
	check_eq(columns.size(), 13, "半径 2 列数为 13")
	check_eq(columns[0], Vector2i(0, 0), "首元素为中心列（最优先）")

	var offset := ChunkManager.desired_columns(Vector2i(5, -3), 1)
	check(offset.has(Vector2i(5, -3)), "偏移中心列包含")
	check(offset.has(Vector2i(6, -3)), "偏移邻列包含")
	check(not offset.has(Vector2i(7, -3)), "偏移圆外不含")
	check_eq(offset.size(), 5, "半径 1 列数为 5")

	# 卸载判定：视距 + 缓冲
	check(
		ChunkManager.should_unload_column(Vector3i(9, 0, 0), Vector2i.ZERO, 5, 2),
		"远列（距离 9 > 5+2）应卸载")
	check(
		not ChunkManager.should_unload_column(
			Vector3i(6, 0, 0), Vector2i.ZERO, 5, 2),
		"缓冲带内（距离 6 <= 7）保留")
	check(
		not ChunkManager.should_unload_column(
			Vector3i(4, 2, 4), Vector2i.ZERO, 5, 2),
		"视距内保留（垂直坐标不参与水平判定）")
	check(
		ChunkManager.should_unload_column(
			Vector3i(-8, 1, -8), Vector2i.ZERO, 5, 2),
		"负方向远列卸载")

	# 优先级：玩家列 > 视线前方 > 同距 > 远列（§10.2）
	var forward := ChunkManager.priority_score(
			Vector2i(2, 0), Vector2i.ZERO, Vector2(1, 0), 2.0)
	var backward := ChunkManager.priority_score(
			Vector2i(-2, 0), Vector2i.ZERO, Vector2(1, 0), 2.0)
	check(forward < backward, "视线前方优先于等距后方")
	var near := ChunkManager.priority_score(
			Vector2i(1, 0), Vector2i.ZERO, Vector2.ZERO, 2.0)
	var far := ChunkManager.priority_score(
			Vector2i(3, 0), Vector2i.ZERO, Vector2.ZERO, 2.0)
	check(near < far, "近列优先于远列")
	var center := ChunkManager.priority_score(
			Vector2i(0, 0), Vector2i.ZERO, Vector2(1, 0), 2.0)
	check(center < near, "玩家所在列最优先")
