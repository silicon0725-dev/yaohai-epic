## 体素网格 DDA 射线检测（Amanatides & Woo，开发文档 §8.1）。
## 相比给每个方块创建物理碰撞对象，网格遍历直接在体素数据上判定，
## 返回命中方块、进入面法线与距离，供挖掘与放置使用。
##
## 返回字典：
##   hit        是否命中实心方块
##   block_pos  命中方块坐标（miss 时为 ZERO）
##   normal     命中面法线（即射线的进入面朝向；起点在方块内时为 ZERO）
##   distance   从射线原点到进入面的距离
class_name VoxelRaycast
extends RefCounted


static func raycast(
		world: VoxelWorld,
		origin: Vector3,
		direction: Vector3,
		max_distance: float
) -> Dictionary:
	var result := {
		"hit": false,
		"block_pos": Vector3i.ZERO,
		"normal": Vector3i.ZERO,
		"distance": 0.0,
	}
	var dir := direction.normalized()
	var pos := Vector3i(
			floori(origin.x), floori(origin.y), floori(origin.z))

	# 起点就在实心方块内：直接命中，进入面无定义（放置方应跳过）
	if world.registry.is_solid(world.get_block(pos)):
		result.hit = true
		result.block_pos = pos
		result.normal = Vector3i.ZERO
		result.distance = 0.0
		return result

	# 每轴步进方向；分量为 0 时 t_max 保持无穷大，该轴永不前进
	var step := Vector3i(
			1 if dir.x > 0.0 else -1 if dir.x < 0.0 else 0,
			1 if dir.y > 0.0 else -1 if dir.y < 0.0 else 0,
			1 if dir.z > 0.0 else -1 if dir.z < 0.0 else 0)
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	if step.x != 0:
		var boundary := float(pos.x + 1) if step.x > 0 else float(pos.x)
		t_max.x = (boundary - origin.x) / dir.x
		t_delta.x = absf(1.0 / dir.x)
	if step.y != 0:
		var boundary := float(pos.y + 1) if step.y > 0 else float(pos.y)
		t_max.y = (boundary - origin.y) / dir.y
		t_delta.y = absf(1.0 / dir.y)
	if step.z != 0:
		var boundary := float(pos.z + 1) if step.z > 0 else float(pos.z)
		t_max.z = (boundary - origin.z) / dir.z
		t_delta.z = absf(1.0 / dir.z)

	while true:
		# 取最近的面边界所在轴前进（并列时偏好 x -> y -> z，确定性可测）
		var axis := 0
		var t_next := t_max.x
		if t_max.y < t_next:
			axis = 1
			t_next = t_max.y
		if t_max.z < t_next:
			axis = 2
			t_next = t_max.z
		if t_next > max_distance:
			return result
		var normal := Vector3i.ZERO
		match axis:
			0:
				pos.x += step.x
				t_max.x += t_delta.x
				normal.x = -step.x
			1:
				pos.y += step.y
				t_max.y += t_delta.y
				normal.y = -step.y
			2:
				pos.z += step.z
				t_max.z += t_delta.z
				normal.z = -step.z
		if world.registry.is_solid(world.get_block(pos)):
			result.hit = true
			result.block_pos = pos
			result.normal = normal
			result.distance = t_next
			return result
	return result
