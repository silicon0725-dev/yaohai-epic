## 地面掉落实体（物品层规则；生命周期与表现见 drop_manager.gd）。
## 挖掘产物不再直接入包，而是生成实体：受重力落向地面、走近自动
## 拾取（MC/BDIR 均无磁吸——磁吸曾把落地物品拉离地面卡在坡上，
## 表现为"以随机倾角插进地里"，已移除）；同类掉落互相合并，
## 超时消散。
## 物理为体素网格上的简化点碰撞（不依赖引擎物理服务器，可 headless 测试）：
##   - 掉落视为水平半宽 0.12、竖直半高 0.18 的小盒，position 为其中心；
##     逐轴移动，移动前探测目标位置四角所在格是否实心，撞墙清速度分量；
##   - y < 0 视为实心（与网格边界策略一致，§6.4），世界顶以上为空气，
##     未加载区块按空气（冻结门禁由 DropManager 负责，防止落入未加载世界）；
##   - 自身所在格变实心（被放置方块掩埋）时逐帧上浮逃出。
## age 只在未冻结时由管理器推进：远离玩家的掉落不会在场外默默消散。
class_name ItemDrop
extends RefCounted

## CPU 言波采样（preload 绕开 .godot 类缓存，headless 测试环境不刷新）
const OceanWavesScript := preload("res://presentation/ocean_waves.gd")

const GRAVITY := 24.0           # 与玩家一致（player_controller.gd）
const TERMINAL_VELOCITY := 32.0
# 水中（参考 ItemPhysic：轻质物上浮、重物缓沉、阻尼放大）
const WATER_GRAVITY := 3.0
const WATER_DRAG := 2.5
const WATER_TERMINAL := 1.5
const FLOAT_RISE_SPEED := 0.8
## 浮物中心停在水面下方的高度（半浸观感；也是震荡收敛的目标位）
const FLOAT_IMMERSE := 0.12
## 水流推力加速度与水平封顶（流动的水把掉落物冲向下游）
const CURRENT_PUSH_ACCEL := 6.0
const FLOW_MAX_SPEED := 1.6
const RADIUS := 0.12            # 默认水平半宽（四角碰撞探测）
const HALF_HEIGHT := 0.18       # 竖直半高
## 落地后水平速度衰减系数（每秒），物品不会无限滑动
const GROUND_FRICTION := 8.0

# ---- 拾取规则（DropManager 消费）----
const PICKUP_RADIUS_H := 1.0    # 水平距离（掉落中心 -> 玩家胶囊中心）
const PICKUP_RADIUS_V := 1.25   # 垂直距离带
## 出生保护时间（秒）：刚生成的掉落不可被磁吸/拾取，
## 防止丢弃物瞬间吸回；挖掘掉落用短值，玩家丢弃用长值
const DESPAWN_SECONDS := 300.0  # 与 MC 一致的 5 分钟
## 空中翻滚角速度（rad/s）。ItemPhysic 空中转速为地面 2 倍，
## 取 2.0 接近其观感：掉落空中持续翻滚，落地平面物品瞬间平贴、
## 方块缓动滚到最近的面贴地角度（姿态见 drop_manager._sync_visuals）。
const SPIN_SPEED := 2.0

const CORNER_SIGNS: Array[Vector2] = [
	Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1),
]
## 8 邻相对偏移（岸距衰减用，与网格器一致）
const NEIGHBOR_8: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1),
	Vector3i(0, 0, -1), Vector3i(1, 0, 1), Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1), Vector3i(-1, 0, -1),
]

var item_id := -1
var count := 0
var position := Vector3.ZERO
## 当前是否在水中（physics_step 每帧刷新；涟漪冲量注入等外部查询用）
var in_water := false
## 本帧刚从空中落水（涟漪冲击消费后由外部清零）
var splash_pending := false
## 波浪跟随速度上限（格/秒）——需大于波形变化速率才贴得住
const WAVE_FOLLOW_SPEED := 1.2
var velocity := Vector3.ZERO
var age := 0.0
var pickup_delay := 0.0
var grounded := false
## 碰撞足迹水平半宽：横向探测（撞墙/台阶沿）必须覆盖视觉模型对角，
## 否则视觉一角会插进墙体；由 DropManager 按物品类型置入（不序列化）。
## 竖直支撑另用 support_radius（视觉半宽，不取对角）——旁边的墙
## 永远不该被当成"脚下的面"。默认 RADIUS 兜底。
var footprint_radius := RADIUS
## 竖直支撑探测半径（落在脚下什么上面）：MC 式小盒语义——物品以
## 中心区域停在地面上，视觉可以悬出边缘；只认"实心且其上为空气"
## 的真表面，墙列（上下皆实心）不参与落地。
var support_radius := RADIUS
## 是否浮于水（木制品等，ItemPhysic 的 swimming 分类）；由管理器
## 按物品身份置入，不序列化（读档重推导）。
var floats := false
## 姿态（ItemPhysic 式单轴翻滚）：spin_angle 是累计翻滚角，只在空中
## 推进、落地冻结；spin_phase 为每实体随机偏航角（躺平面内的朝向，
## 对应 ItemPhysic 实体自身的 Y 朝向）。
var spin_angle := 0.0
var spin_phase := 0.0
## 树干实心探针（physics_step 每帧由管理器注入；见其注释）。
## 不序列化——恢复后管理器重接线。
var trunk_solid_probe: Callable = Callable()


## 推进一帧物理。age 不在此推进（冻结语义归管理器）。
## trunk_probe：树干实心查询（混合方案——掉落物体素点碰撞感知
## 不到树的 StaticBody，主干占位格又 collision:false；由
## TreeManager.is_solid_for_items 经 DropManager 注入，掉落物才
## 撞得上树干。无树/测试场景缺省无效 Callable = 穿透）。
func physics_step(world: VoxelWorld, delta: float,
		trunk_probe: Callable = Callable()) -> void:
	trunk_solid_probe = trunk_probe
	var wet := world.get_block(_cell(position)) == VoxelTypes.WATER_ID
	if wet and not in_water and velocity.y < -1.5:
		splash_pending = true  # 落水冲击（涟漪注入方消费）
	in_water = wet
	if wet:
		_step_in_water(world, delta)
		return
	_escape_if_embedded(world)
	# 静止重叠兜底：出生点贴墙/台阶沿时足迹角点可能已在实心格内
	#（水平探测只拦移动，拦不住"出生即重叠"）。每帧先沿最小穿透
	# 水平轴推出，防止竖直探测把"旁边的墙/台阶"当成落脚面
	#（曾表现为堆叠物落到墙角后自动跳到上方一格）
	_push_out_solid(world)
	if grounded:
		var damping := maxf(0.0, 1.0 - GROUND_FRICTION * delta)
		velocity.x *= damping
		velocity.z *= damping
	velocity.y = maxf(velocity.y - GRAVITY * delta, -TERMINAL_VELOCITY)
	_move_horizontal(world, velocity.x * delta, 0.0)
	_move_horizontal(world, 0.0, velocity.z * delta)
	var was_grounded := grounded
	grounded = false
	_move_vertical(world, velocity.y * delta)
	# 空中自旋推进；触地（或保持触地）即冻结——落地姿态保留
	if not grounded and not was_grounded:
		spin_angle += SPIN_SPEED * delta


## 水中步进：
## - 浮水物品浮到"所在水格实际水位"（water_surface_height(level)，
##   流动级别低 -> 水面矮）下方 FLOAT_IMMERSE 处，到位后竖直速度
##   刹停稳定贴面（修冒出水面被拉回造成的快速上下震荡）；
## - 其余物品缓沉；
## - 水流推力（WaterFlow.flow_direction_at）：沿流向持续加速，
##   水平封顶 FLOW_MAX_SPEED；下落段附加下沉分量；
## - 水平移动带四角碰撞（防推入墙体），竖直直接积分。
func _step_in_water(world: VoxelWorld, delta: float) -> void:
	velocity *= maxf(0.0, 1.0 - WATER_DRAG * delta)
	var cell := _cell(position)
	if floats:
		# 目标水位：WaterFlow.water_surface_at（向上扫表面格 + 级别
		# 高度，与玩家涉水判定共用）+ Physics Mod 言波的 CPU 采样
		# （ocean_waves.gd 与 shader 逐行同式——浮物随波起伏与渲染
		# 一致）。物品浮到实际水位下方 FLOAT_IMMERSE 处，到位后竖直
		# 速度刹停稳定贴面（修冒出水面被拉回造成的快速上下震荡）
		# 波高采样带岸距衰减：与网格器角点同拓扑（2x2 XZ × 上下
		# 2 层的固体数）+ 同公式（shore_fade_value）——两处各写曾
		# 漂移出 /3.0 vs ×0.5，贴岸浮物与视觉水面起伏不一致（审查发现）
		var solid_neighbors := 0
		for dx in 2:
			for dz in 2:
				for dy in 2:
					var nid := world.get_block(cell
							+ Vector3i(dx - 1, dy, dz - 1))
					if nid != VoxelTypes.AIR_ID and nid != VoxelTypes.WATER_ID:
						solid_neighbors += 1
		var shore_fade := ChunkMesher.shore_fade_value(solid_neighbors)
		var target := WaterFlow.water_surface_at(world, cell) 				+ OceanWavesScript.wave_offset(
						position.x, position.z,
						OceanWavesScript.global_time) * shore_fade 				- FLOAT_IMMERSE
		# 波峰钳制：目标不超过**表面格**顶（否则中心被顶进上方空气格，
		# 切普通物理掉回再上浮，形成新的震荡）。注意钳到当前格会把
		# 中间格当表面，物品卡在中层格顶不上浮
		var surface_cell := cell
		while world.get_block(surface_cell + Vector3i(0, 1, 0)) 				== VoxelTypes.WATER_ID:
			surface_cell += Vector3i(0, 1, 0)
		target = minf(target, float(surface_cell.y) + 0.98)
		# 直接限速跟随（无惯性）：弹簧方案实测过冲达波形 2 倍
		#（浮物轻质，无惯性跟随视觉可信且零过冲）；velocity 清零
		# 防止函数尾部的积分双重位移
		position.y = move_toward(position.y, target,
				WAVE_FOLLOW_SPEED * delta)
		velocity.y = 0.0
	else:
		velocity.y = maxf(velocity.y - WATER_GRAVITY * delta, -WATER_TERMINAL)
	var flow := WaterFlow.flow_direction_at(world, cell)
	if flow != Vector3.ZERO:
		velocity.x += flow.x * CURRENT_PUSH_ACCEL * delta
		velocity.z += flow.z * CURRENT_PUSH_ACCEL * delta
		if flow.y < 0.0:
			velocity.y = maxf(
					velocity.y - WATER_TERMINAL * delta, -WATER_TERMINAL)
		var h := Vector2(velocity.x, velocity.z)
		if h.length() > FLOW_MAX_SPEED:
			h = h.normalized() * FLOW_MAX_SPEED
			velocity.x = h.x
			velocity.z = h.y
	_move_horizontal(world, velocity.x * delta, 0.0)
	_move_horizontal(world, 0.0, velocity.z * delta)
	position.y += velocity.y * delta
	grounded = false
	# 水底支撑：缓沉物落到水底固体顶面后停住吸附。没有这个判定，
	# 物品会沉进固体格 -> 所在格变非水 -> 普通物理的掩埋逃逸把物品
	# 顶回水中 -> 再次缓沉，循环往复表现为"沉底后抽搐"
	if velocity.y <= 0.0:
		var floor_top := _footprint_floor_top(world, position.y - HALF_HEIGHT)
		if floor_top > -INF:
			position.y = floor_top + HALF_HEIGHT
			velocity.y = 0.0
			grounded = true
	if not grounded:
		spin_angle += SPIN_SPEED * 0.4 * delta


func ready_for_pickup(player_center: Vector3) -> bool:
	if age < pickup_delay:
		return false
	return _within(player_center, PICKUP_RADIUS_H, PICKUP_RADIUS_V)


func despawn_ready() -> bool:
	return age >= DESPAWN_SECONDS


func _within(player_center: Vector3, radius_h: float, radius_v: float) -> bool:
	var delta := position - player_center
	return Vector2(delta.x, delta.z).length() <= radius_h \
			and absf(delta.y) <= radius_v


# ---- 碰撞（体素点探测）----

func _move_horizontal(world: VoxelWorld, dx: float, dz: float) -> void:
	if is_zero_approx(dx) and is_zero_approx(dz):
		return
	var target := position + Vector3(dx, 0.0, dz)
	# 贴脚探测：落地滑行时也能检测前方墙体（可滑入 1 格高缝隙上方）
	var probe_y := position.y - HALF_HEIGHT + 0.06
	if _corners_solid_at_y(world, target, probe_y):
		velocity.x = 0.0
		velocity.z = 0.0
		return
	position = target


func _move_vertical(world: VoxelWorld, dy: float) -> void:
	var target_y := position.y + dy
	if dy <= 0.0:
		var bottom := target_y - HALF_HEIGHT
		var floor_top := _footprint_floor_top(world, bottom)
		if floor_top > -INF:
			# 落到足迹内最高"可落地面"的顶面（格顶 = 格坐标 + 1）
			position.y = floor_top + HALF_HEIGHT
			velocity.y = 0.0
			grounded = true
			return
	else:
		var top := target_y + HALF_HEIGHT
		if _corners_solid_at_y(world, position, top):
			position.y = floorf(top) - HALF_HEIGHT
			velocity.y = 0.0
			return
	position.y = target_y


## 足迹支撑半径（support_radius）四角列中"可落地面"的最高顶面；
## 无则返回 -INF。可落地面 = 探测高度处的格实心**且其上一格为空气**
##（真表面）——墙列上下皆实心，不是落脚面。支撑用小盒（视觉半宽）
## 语义：物品以中心区域停在地面，视觉可以悬出边缘（MC 同款）。
func _footprint_floor_top(world: VoxelWorld, y: float) -> float:
	var best := -INF
	var cell_y := floori(y)
	for sign_v in CORNER_SIGNS:
		var cell := Vector3i(
				floori(position.x + sign_v.x * support_radius),
				cell_y,
				floori(position.z + sign_v.y * support_radius))
		if _solid_at(world, cell) and not _solid_at(world, cell + Vector3i(0, 1, 0)):
			best = maxf(best, float(cell_y + 1))
	return best


## 足迹角点（全视觉足迹）陷在实心格内时，沿最小穿透水平轴推出格外。
## 正常移动由水平探测阻止进入；此函数兜底"出生即重叠"
##（Q 扔向墙角时出生点贴墙）与放置方块等静止嵌入场景。
func _push_out_solid(world: VoxelWorld) -> void:
	var cell_y := floori(position.y - HALF_HEIGHT + 0.06)
	var best_len := INF
	var best_push := Vector3.ZERO
	for sign_v in CORNER_SIGNS:
		var px := position.x + sign_v.x * footprint_radius
		var pz := position.z + sign_v.y * footprint_radius
		var cx := floori(px)
		var cz := floori(pz)
		if not _solid_at(world, Vector3i(cx, cell_y, cz)):
			continue
		var to_left := px - cx
		var to_right := cx + 1.0 - px
		var to_back := pz - cz
		var to_front := cz + 1.0 - pz
		var push := Vector3(to_right + 0.001, 0.0, 0.0)
		var length := to_right
		if to_left < length:
			push = Vector3(-(to_left + 0.001), 0.0, 0.0)
			length = to_left
		if to_back < length:
			push = Vector3(0.0, 0.0, -(to_back + 0.001))
			length = to_back
		if to_front < length:
			push = Vector3(0.0, 0.0, to_front + 0.001)
			length = to_front
		if length < best_len:
			best_len = length
			best_push = push
	if best_len < INF:
		position += best_push
		if absf(best_push.x) > 0.0:
			velocity.x = 0.0
		if absf(best_push.z) > 0.0:
			velocity.z = 0.0


## 探测 center 四个水平角在高度 y 所在格是否任一实心。
## 角点距离取 footprint_radius（碰撞覆盖视觉足迹）。
func _corners_solid_at_y(world: VoxelWorld, center: Vector3, y: float) -> bool:
	var cell_y := floori(y)
	for sign in CORNER_SIGNS:
		if _solid_at(world, Vector3i(
				floori(center.x + sign.x * footprint_radius),
				cell_y,
				floori(center.z + sign.y * footprint_radius))):
			return true
	return false


## 自身中心格变实心（放置方块掩埋）：抬升到该格顶面，向上速度不清零为负。
func _escape_if_embedded(world: VoxelWorld) -> void:
	if _solid_at(world, _cell(position)):
		position.y = floorf(position.y) + 1.0 + HALF_HEIGHT
		velocity.y = maxf(velocity.y, 0.0)


static func _cell(pos: Vector3) -> Vector3i:
	return Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))


## 实心判定：y < 0 视为实心（世界底）；世界顶以上空气；其余查注册表
## collision 字段（空气/未加载区块均非实心——冻结门禁在管理器）。
## 树干占位格（BRANCH，collision:false）追加探针询问——主干段实心
##（掉落物撞得上树），枝干段仍穿透（枝无碰撞，与玩家一致）。
## 非 BRANCH 格不问探针（空气等大宗查询短路，Callable 调用有开销）。
func _solid_at(world: VoxelWorld, cell: Vector3i) -> bool:
	if cell.y < 0:
		return true
	if cell.y >= world.config.world_height_blocks():
		return false
	var id := world.get_block(cell)
	if world.registry.definition_for_id(id).get("collision", false):
		return true
	if id != VoxelTypes.BRANCH_ID:
		return false
	return trunk_solid_probe.is_valid() and trunk_solid_probe.call(cell)


# ---- 序列化（稳定名称，与背包同一原则 §2.2）----

func serialize(registry: ItemRegistry) -> Dictionary:
	return {
		"item": registry.name_for_id(item_id),
		"count": count,
		"pos": [position.x, position.y, position.z],
		"vel": [velocity.x, velocity.y, velocity.z],
		"age": age,
		"delay": pickup_delay,
		"spin": spin_angle,
		"phase": spin_phase,
	}


## 未知物品名 / 非正数量 / 坐标形状不对返回 null（调用方跳过）。
## 数量截断到 max_stack。
static func deserialize(data: Dictionary, registry: ItemRegistry) -> ItemDrop:
	var id := registry.id_for_name(String(data.get("item", "")))
	if id < 0:
		return null
	var count := clampi(int(data.get("count", 0)), 0, registry.max_stack(id))
	if count <= 0:
		return null
	var pos: Array = data.get("pos", [])
	var vel: Array = data.get("vel", [])
	if pos.size() != 3 or vel.size() != 3:
		return null
	var drop := ItemDrop.new()
	drop.item_id = id
	drop.count = count
	drop.position = Vector3(
			float(pos[0]), float(pos[1]), float(pos[2]))
	drop.velocity = Vector3(
			float(vel[0]), float(vel[1]), float(vel[2]))
	drop.age = maxf(float(data.get("age", 0.0)), 0.0)
	drop.pickup_delay = maxf(float(data.get("delay", 0.0)), 0.0)
	# spin/phase 为姿态扩展键：旧档（v1 掉落存档）缺省 0，兼容
	drop.spin_angle = float(data.get("spin", 0.0))
	drop.spin_phase = float(data.get("phase", 0.0))
	return drop
