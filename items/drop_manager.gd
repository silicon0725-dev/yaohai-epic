## 掉落实体管理器（物品层表现 + 生命周期编排）。
## 每物理帧：推进 ItemDrop 物理（区块未就绪即冻结，与玩家同一门禁）、
## 磁吸与拾取入包（背包放不下则掉落原地保留）、同步视觉表现；
## 周期合并近距离同类堆；超时（活跃时间 5 分钟）消散。
## 状态随 world.json 持久化（经 ChunkManager.extra_meta_provider 注入，
## 键 "drops"），重启后原位恢复；旧档无该键即无掉落。
##
## 视觉模仿 Better Dropped Items Renewed（表现见 presentation/drop_visuals.gd）：
##   - 方块物品 = 3D 迷你方块；材料/工具 = 挤出厚度的像素模型
##     （每个不透明像素一个小方柱）。两类共用同一套姿态管线
##     （空中翻滚/触地补间/支撑半径/碰撞足迹），仅落地角度不同：
##     方块端正竖立（底面贴地、竖直 90°、保留偏航），平面物品
##     平躺贴地（面朝上 + 偏航）；无悬浮 bob——物品贴地而非飘浮
##   - count > 1 默认散布若干随机偏移的小模型（Mod 默认），可开
##     NEAT_STACKING 让平面物品竖直叠成一摞（Mod 可选项）
class_name DropManager
extends Node3D

## 实体上限：超出后 spawn 拒绝，调用方回退直接入包（旧语义兜底）。
const MAX_DROPS := 128
const MERGE_INTERVAL := 0.5
const MERGE_RADIUS := 0.6
## count > 1 的散布副本上限（含主模型；Mod 对大堆同样不无限渲染）
const MAX_SCATTER_MODELS := 5
## 整齐堆叠模式的层数上限与层高（Mod 层高 3/32）
const MAX_STACK_LAYERS := 8
const STACK_LAYER := 0.09375
## 散布随机偏移幅度（Mod：3D ±0.15，2D 取其一半）
const SCATTER_3D := 0.15
const SCATTER_2D := 0.075
## 2D 散布副本的逐层抬升与随机倾角幅度
const SCATTER_2D_RISE := 0.0625
## 平面物品整齐堆叠开关（对应 Mod 的 itemPhysic2DRenderMode，默认关）
const NEAT_STACKING := false
## 单轴翻滚模型（ItemPhysic 式）：站立 -> 平躺的固定基准倾角
const TIP_FROM_STANDING := PI / 2.0
## 方块触地缓动时长（秒）：滚到最近的面贴地角度（<= 45°）
const LAND_TWEEN_SECONDS := 0.25

var world: VoxelWorld
var item_registry: ItemRegistry
## 拾取目标（玩家节点，取胶囊中心）
var pickup_target: Node3D
## 拾取背包（放不下时掉落留在原地，腾出空间后自动拾取）
var pickup_inventory: Inventory
## 树干实心探针（TreeManager.is_solid_for_items；main 接线）——
## 掉落物体素点碰撞感知不到树的 StaticBody，主干实心由此补齐，
## 否则对着树丢东西会穿树
var trunk_solid_probe: Callable = Callable()

var _drops: Array[ItemDrop] = []
var _visuals: Array[Node3D] = []
## 各掉落当前已渲染的模型数（count 变化时重建散布/堆叠副本）
var _visual_counts: Array[int] = []
## 触地缓动状态（t = 1 表示已到位；标量角插值，无四元数路径）
var _was_grounded: Array[bool] = []
var _landing_t: Array[float] = []
var _landing_theta_from: Array[float] = []
var _landing_theta_target: Array[float] = []
var _last_support: Array[float] = []
var _merge_accumulator := 0.0
var _rng := RandomNumberGenerator.new()


func setup(p_world: VoxelWorld, p_registry: ItemRegistry) -> void:
	world = p_world
	item_registry = p_registry


func _ready() -> void:
	_rng.randomize()


func _physics_process(delta: float) -> void:
	process_drops(delta)


## 只读访问掉落列表（涟漪冲量注入等遍历查询）。
func drops() -> Array[ItemDrop]:
	return _drops


func drop_count() -> int:
	return _drops.size()


## 调试/检查用只读访问。
func drop_at(index: int) -> ItemDrop:
	if index < 0 or index >= _drops.size():
		return null
	return _drops[index]


# ---- 生成 ----

## 精确生成（速度/延迟显式指定，测试与存档恢复用）。失败返回 null。
func spawn_drop(
		item_id: int,
		count: int,
		at: Vector3,
		velocity := Vector3.ZERO,
		delay := 0.5
) -> ItemDrop:
	if world == null or item_registry == null:
		return null
	if item_id < 0 or count <= 0:
		return null
	if _drops.size() >= MAX_DROPS:
		push_warning("掉落实体已达上限 %d，本次生成降级" % MAX_DROPS)
		return null
	var drop := ItemDrop.new()
	drop.item_id = item_id
	drop.count = mini(count, item_registry.max_stack(item_id))
	drop.position = at
	drop.velocity = velocity
	drop.pickup_delay = delay
	# 每实体随机相位（Mod 复用 vanilla bobOffset 作旋转相位）
	drop.spin_phase = _rng.randf() * TAU
	_apply_footprint(drop)
	_register(drop)
	return drop


## 挖掘/丢弃用：随机小散射（向上 + 水平随机）。返回是否成功生成。
func spawn_scatter(
		item_id: int, count: int, at: Vector3, delay := 0.5
) -> bool:
	var scatter := Vector3(
			_rng.randf_range(-1.2, 1.2),
			_rng.randf_range(1.6, 2.6),
			_rng.randf_range(-1.2, 1.2))
	return spawn_drop(item_id, count, at, scatter, delay) != null


func _register(drop: ItemDrop) -> void:
	_drops.append(drop)
	var visual := _build_visual(drop)
	_visuals.append(visual)
	_visual_counts.append(0)
	# 触地即保存档恢复的掉落不播补间（已在地面稳定姿态）
	_was_grounded.append(drop.grounded)
	_landing_t.append(1.0)
	_landing_theta_from.append(TIP_FROM_STANDING)
	_landing_theta_target.append(TIP_FROM_STANDING)
	_last_support.append(0.0)
	add_child(visual)


# ---- 每帧推进（_physics_process 委托；测试可直调）----

func process_drops(delta: float) -> void:
	var player_center = _player_center()
	var i := 0
	while i < _drops.size():
		var drop := _drops[i]
		if drop.despawn_ready():
			_remove_at(i)
			continue
		# 区块未就绪：冻结物理与 age（远离玩家的掉落不会场外消散）
		if _chunk_ready(drop):
			# 无磁吸（MC/BDIR 均无此机制）：物品落地即安放，
			# 走进拾取半径才拾取——磁吸曾把落地物品拉离地面，
			# 卡在坡上表现为"以随机倾角插进地里"
			drop.physics_step(world, delta, trunk_solid_probe)
			drop.age += delta
		# 拾取不要求所在区块就绪（顺手清走未加载边缘的掉落）
		if player_center != null and pickup_inventory != null \
				and drop.ready_for_pickup(player_center) \
				and pickup_inventory.can_fit(drop.item_id):
			var leftover := pickup_inventory.add(drop.item_id, drop.count)
			if leftover <= 0:
				_remove_at(i)
				continue
			drop.count = leftover  # 背包部分装下：剩余留在掉落里
		i += 1
	_merge_accumulator += delta
	if _merge_accumulator >= MERGE_INTERVAL:
		_merge_accumulator = 0.0
		_merge_pass()
	_sync_visuals(delta)


## 所在格区块是否就绪（世界顶以上的掉落看顶块，底以下不可能存在）。
func _chunk_ready(drop: ItemDrop) -> bool:
	var cell := ItemDrop._cell(drop.position)
	cell.y = clampi(cell.y, 0, world.config.chunks_y - 1)
	var chunk := world.get_chunk(
			VoxelCoords.world_to_chunk(cell, world.config.chunk_size))
	return chunk != null and chunk.state == ChunkState.State.ACTIVE


func _player_center():  # Variant：Vector3 或 null（无有效拾取目标）
	if pickup_target == null or not is_instance_valid(pickup_target):
		return null
	# 离树后 global_position 会告警并回退本地变换（同 player_controller）
	if pickup_target.is_inside_tree():
		return pickup_target.global_position
	return pickup_target.position


func _remove_at(index: int) -> void:
	_drops.remove_at(index)
	var visual := _visuals[index]
	_visuals.remove_at(index)
	_visual_counts.remove_at(index)
	_was_grounded.remove_at(index)
	_landing_t.remove_at(index)
	_landing_theta_from.remove_at(index)
	_landing_theta_target.remove_at(index)
	_last_support.remove_at(index)
	visual.queue_free()


## 近距离同类堆合并（遵守 max_stack，溢出留在数量较少的一方）。
func _merge_pass() -> void:
	var i := 0
	while i < _drops.size():
		var j := i + 1
		while j < _drops.size():
			var receiver := _drops[i]
			var other := _drops[j]
			var max_stack := item_registry.max_stack(receiver.item_id)
			if receiver.item_id == other.item_id \
					and receiver.count < max_stack \
					and receiver.position.distance_squared_to(other.position) \
					<= MERGE_RADIUS * MERGE_RADIUS:
				var moved := mini(max_stack - receiver.count, other.count)
				receiver.count += moved
				other.count -= moved
				if other.count <= 0:
					_remove_at(j)
					continue
			j += 1
		i += 1


# ---- 表现（ItemPhysic 式单轴翻滚模型）----

## 姿态由一个标量决定：总倾角 theta = TIP_FROM_STANDING + 翻滚角，
## 姿态四元数 = 偏航（每实体固定相位，绕世界 Y）∘ 绕世界 X 的 theta。
## 竖直支撑半径有闭式公式 extent(theta) = a|cos| + b|sin|
##（a=模型半长、b=半厚），对任意 theta 精确——没有四元数插值路径、
## 没有扫掠兜底，任何中间姿态都不可能插进地面（参照 ItemPhysic
## 源码：单一累计 XRot + 固定倾倒 + 悬空轴心）。
##   空中：theta 持续推进（方块与平面物品都翻滚，Mod 行为）；
##   落地：平面物品瞬间平贴（theta = 90°，Mod 为即时归零）；
##         方块缓动到最近的 90° 倍数（面贴地安放，Mod 的
##         oldRotation 懒转正，最多滚 45°）。
func _sync_visuals(delta: float) -> void:
	for i in _drops.size():
		var drop := _drops[i]
		var root := _visuals[i]
		var cube := cube_item(drop.item_id)
		var theta := _display_theta(i, drop, cube, delta)
		root.quaternion = Quaternion(Vector3.UP, drop.spin_phase) 				* Quaternion(Vector3(1.0, 0.0, 0.0), theta)
		var support := _extent(cube, theta)
		_was_grounded[i] = drop.grounded
		_last_support[i] = support
		root.position = Vector3(
				drop.position.x,
				drop.position.y + support - ItemDrop.HALF_HEIGHT,
				drop.position.z)
		if _visual_counts[i] != drop.count:
			# count 变化：重建副本并更新碰撞足迹（散布余量随之增减）
			_apply_footprint(drop)
			_rebuild_copies(drop, root)
			_visual_counts[i] = drop.count


## 当前显示总倾角（从站立基准起算）：空中自由推进；落地方块缓动到
## 最近的面贴地角度；落地平面物品瞬间平贴。theta 的支撑半径始终
## 走闭式公式，插值期间同样精确。
func _display_theta(i: int, drop: ItemDrop, cube: bool, delta: float) -> float:
	var theta := TIP_FROM_STANDING + drop.spin_angle
	if not drop.grounded:
		return theta
	if not cube:
		return TIP_FROM_STANDING  # 平面物品：落地即时平贴（Mod 行为）
	if not _was_grounded[i]:
		# 触地：缓存起播角与目标角（最近 90° 倍数，滚动 <= 45°）
		_landing_t[i] = 0.0
		_landing_theta_from[i] = theta
		_landing_theta_target[i] = snappedf(theta, PI / 2.0)
	if _landing_t[i] < 1.0:
		_landing_t[i] = minf(
				_landing_t[i] + delta / LAND_TWEEN_SECONDS, 1.0)
		var eased := _ease_out_cubic(_landing_t[i])
		return lerpf(_landing_theta_from[i], _landing_theta_target[i], eased)
	return _landing_theta_target[i]


## 模型绕 X 转 theta（从站立起算）后的竖直半跨度（精确闭式）：
## 绕 X 旋转的竖直截面是"高 x 厚"矩形，支撑 = 高半长|cosθ| + 厚半长|sinθ|；
## 站立 θ=0 取半高，平躺 θ=90° 取半厚，方块两向等长恒 0.125。
static func _extent(cube: bool, theta: float) -> float:
	var half_long := DropVisuals.CUBE_SIZE * 0.5 if cube \
			else DropVisuals.FLAT_SIZE * 0.5
	var half_short := DropVisuals.CUBE_SIZE * 0.5 if cube \
			else DropVisuals.FLAT_THICKNESS * 0.5
	return half_long * absf(cos(theta)) + half_short * absf(sin(theta))


static func _ease_out_cubic(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)


## 碰撞尺寸按物品类型置入：横向阻挡足迹 = 视觉对角（count>1 加散布
## 余量）——移动与静止推出兜底共同保证视觉不插进墙/台阶；竖直支撑
## 半径 = 视觉半宽小盒（MC 语义），旁边的墙不会被当成落脚面。
## count 变化时随副本重建一并更新。
func _apply_footprint(drop: ItemDrop) -> void:
	var cube := cube_item(drop.item_id)
	var half: float = DropVisuals.CUBE_SIZE * 0.5 if cube \
			else DropVisuals.FLAT_SIZE * 0.5
	# 横向阻挡 = 视觉对角（+ 副本散布余量），视觉不插进墙/台阶；
	# 竖直支撑 = 视觉半宽小盒（MC 语义），旁边的墙不会被当成落脚面
	drop.footprint_radius = half * sqrt(2.0)
	if drop.count > 1:
		drop.footprint_radius += SCATTER_3D if cube else SCATTER_2D
	drop.support_radius = half
	_apply_flotation(drop)


## 浮水物品（ItemPhysic 的 swimming 分类简化：木制品家族）。
const FLOATER_ITEMS := ["core:log", "core:planks", "core:stick",
	"core:wooden_pickaxe"]


func _apply_flotation(drop: ItemDrop) -> void:
	drop.floats = FLOATER_ITEMS.has(item_registry.name_for_id(drop.item_id))


## 方块物品（place_block 可解析）判定（供足迹与表现共用）。
func cube_item(item_id: int) -> bool:
	return item_registry.place_block_id(item_id) >= 0


## 构建掉落的视觉根节点（主模型 + 数量副本）。
func _build_visual(drop: ItemDrop) -> Node3D:
	var root := Node3D.new()
	root.add_child(_make_model(drop))
	return root


## 单个模型节点：3D 迷你方块或挤出厚度的像素模型。模型中心即
## 节点原点——根节点的旋转因此绕模型自身中心进行（贴地高度由
## 根节点位置负责）。
func _make_model(drop: ItemDrop) -> MeshInstance3D:
	var model := MeshInstance3D.new()
	if cube_item(drop.item_id):
		model.mesh = DropVisuals.cube_mesh_for(
				item_registry.place_block_id(drop.item_id), world.registry)
	else:
		model.mesh = DropVisuals.extruded_mesh_for(
				drop.item_id, item_registry)
	return model


## 数量副本：散布模式（默认）或平面整齐堆叠（NEAT_STACKING）。
## 副本偏移以模型中心为基准（Mod 的偏移施加在已旋转的姿态系内），
## 用确定性随机（按掉落身份播种），帧间稳定、存档可复现。
func _rebuild_copies(drop: ItemDrop, root: Node3D) -> void:
	# 先脱离再释放：queue_free 要到帧末才真正移除，立即 remove_child
	# 保证本轮重建的副本计数正确（无场景树的测试环境同理）
	for child in root.get_children():
		if child.name.begins_with("copy"):
			root.remove_child(child)
			child.queue_free()
	var main: MeshInstance3D = root.get_child(0)
	main.position = Vector3.ZERO
	var cube := cube_item(drop.item_id)
	var rng := _copy_rng(drop)

	if NEAT_STACKING and not cube:
		# 竖直一摞向上生长：主模型在底（贴地），副本沿 local -z 逐层
		# +3/32（平躺姿态下 local -z = 世界向上）
		var layers := mini(drop.count, MAX_STACK_LAYERS)
		for i in range(1, layers):
			var layer := _make_model(drop)
			layer.name = "copy%d" % i
			layer.position.z = -i * STACK_LAYER
			root.add_child(layer)
		return

	var models := mini(drop.count, MAX_SCATTER_MODELS)
	for i in range(1, models):
		var copy := _make_model(drop)
		copy.name = "copy%d" % i
		if cube:
			# 3D 副本：水平 ±0.15 随机偏移，竖直只向上（向下会嵌地）
			copy.position = Vector3(
					rng.randf_range(-SCATTER_3D, SCATTER_3D),
					rng.randf_range(0.0, SCATTER_3D),
					rng.randf_range(-SCATTER_3D, SCATTER_3D))
		else:
			# 2D 副本：平躺姿态下 local x/y 是水平面、local z 朝下——
			# 水平随机散布，沿 -z 逐层抬升（世界向上）
			copy.position = Vector3(
					rng.randf_range(-SCATTER_2D, SCATTER_2D),
					rng.randf_range(-SCATTER_2D, SCATTER_2D),
					-SCATTER_2D_RISE * i)
		root.add_child(copy)


## 副本随机源：按掉落身份确定性播种（同掉落每帧/存档往返偏移一致）。
func _copy_rng(drop: ItemDrop) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = (drop.item_id * 7919 + 104729) \
			^ (int(drop.spin_phase * 1024.0) & 0x7FFFFFFF)
	return rng


# ---- 存档（world.json "drops" 键）----

## 供 ChunkManager.extra_meta_provider 调用。
func get_save_bundle() -> Dictionary:
	var data := []
	for drop in _drops:
		data.append(drop.serialize(item_registry))
	return {"drops": data}


## 从存档恢复。返回恢复的实体数（未知物品/坏数据跳过，超上限截断）。
func apply_save_state(drops_data: Array) -> int:
	var restored := 0
	for entry in drops_data:
		if _drops.size() >= MAX_DROPS:
			push_warning("存档掉落数超上限 %d，其余忽略" % MAX_DROPS)
			break
		if not (entry is Dictionary):
			continue
		var drop := ItemDrop.deserialize(entry, item_registry)
		if drop == null:
			continue
		_apply_footprint(drop)
		_register(drop)
		restored += 1
	return restored
