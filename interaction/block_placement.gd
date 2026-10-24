## 方块放置（开发文档 §8.2）。目标格必须是世界内的空气格，
## 且不得与排除 AABB（玩家碰撞体）重叠，防止把方块放进玩家身体。
class_name BlockPlacement
extends RefCounted

## 原木等可朝向方块：按放置面法线推导轴向（贴顶/底放 = 竖放 y，
## 贴侧放 = 横放并沿该法线轴向）。
const ORIENTED_BLOCKS := [VoxelTypes.LOG_ID]


static func place(
		world: VoxelWorld,
		target_pos: Vector3i,
		block_id: int,
		exclude_aabb: AABB,
		face_normal := Vector3i.ZERO
) -> bool:
	if block_id == VoxelTypes.AIR_ID:
		return false
	# 水视同空气：可以往水里放方块（替换水）
	if world.get_block(target_pos) != VoxelTypes.AIR_ID 			and world.get_block(target_pos) != VoxelTypes.WATER_ID:
		return false
	var block_aabb := AABB(Vector3(target_pos), Vector3.ONE)
	# 边界相接也算重叠：站在方块上时不允许往脚下格放置
	if exclude_aabb.intersects(block_aabb):
		return false
	if not world.set_block(target_pos, block_id):
		return false
	# 可朝向方块：按命中面法线写入 axis 状态（影响贴图，需重建网格）
	if ORIENTED_BLOCKS.has(block_id) and face_normal != Vector3i.ZERO:
		world.set_block_state(target_pos, "axis",
				axis_for_normal(face_normal), true)
	return true


## 由命中面法线推导方块轴向："x" / "y" / "z"。
static func axis_for_normal(normal: Vector3i) -> String:
	if absi(normal.y) == 1:
		return "y"
	if absi(normal.x) == 1:
		return "x"
	if absi(normal.z) == 1:
		return "z"
	return "y"  # 零法线（起点在方块内）默认竖放
