## 方块放置（开发文档 §8.2）。目标格必须是世界内的空气格，
## 且不得与排除 AABB（玩家碰撞体）重叠，防止把方块放进玩家身体。
class_name BlockPlacement
extends RefCounted

## 原木等可朝向方块：按放置面法线推导轴向（贴顶/底放 = 竖放 y，
## 贴侧放 = 横放并沿该法线轴向）。
const ORIENTED_BLOCKS := [VoxelTypes.LOG_ID]

## 需要支撑的方块（火把/提灯）：正下方必须是注册表固体（防浮空）
const SUPPORTED_BLOCKS := [VoxelTypes.TORCH_ID, VoxelTypes.LANTERN_ID]


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
	# 植物格可被替换（MC 语义：往草丛上放方块顶掉草）
	var tgt: int = world.get_block(target_pos)
	if tgt != VoxelTypes.AIR_ID and tgt != VoxelTypes.WATER_ID 			and not VoxelTypes.PLANT_IDS.has(tgt):
		return false
	# 支撑检查（火把）：下方碰撞固体 -> 落地火把；否则若贴着点击的
	# 墙面（face_normal 水平）-> 墙挂火把（写 attach 状态，模型贴墙）。
	# 曾只支持落地且静默拒绝——对墙放置"放下没模型"（用户实机）
	if SUPPORTED_BLOCKS.has(block_id):
		# 玩家重叠检查（与常规路径同规则——曾漏：火把可放进身体里）
		if exclude_aabb.intersects(AABB(Vector3(target_pos), Vector3.ONE)):
			return false
		var below := world.get_block(target_pos + Vector3i(0, -1, 0))
		var floor_ok := bool(world.registry.definition_for_id(below).get(
				"collision", true))
		# 提灯只落地（MC 悬挂版需要天花挂点状态，后续再做）
		if block_id == VoxelTypes.LANTERN_ID and not floor_ok:
			return false
		var wall_normal := Vector3i.ZERO
		if not floor_ok:
			if face_normal.y != 0 or face_normal == Vector3i.ZERO:
				return false  # 顶/底面或零法线且无地面 -> 拒绝
			wall_normal = face_normal
		if not world.set_block(target_pos, block_id):
			return false
		if wall_normal != Vector3i.ZERO:
			world.set_block_state(target_pos, "attach",
					"%d,%d,%d" % [wall_normal.x, wall_normal.y,
							wall_normal.z], true)
		return true
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
