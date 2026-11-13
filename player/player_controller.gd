## 第一人称玩家控制器（开发文档 §12 阶段 B + 物品层 + 网格背包）。
## 碰撞体：两格高一格宽的胶囊（半径 0.4、总高 2.0），无可见模型。
## 移动/跳跃基于 CharacterBody3D + 区块 concave 碰撞；
## 交互基于体素 DDA 射线（physics/voxel_raycast.gd）。
## 网格背包（GridInventory）：物品占多格（镐 1×2 可旋转），快捷栏 =
## 网格内 8×2 分区（键 1-8 选列）；E 键开关背包界面，点击拿起/放下，
## 拖拽中 R/滚轮旋转，落点脚印预览（可放白/不可放红），悬停脚印白高亮，
## 放下有倾斜→摆正落定动画（参考：塔科夫式网格库存）。
class_name PlayerController
extends CharacterBody3D

const WALK_SPEED := 4.5
const SPRINT_SPEED := 8.0
const JUMP_VELOCITY := 8.5
const GRAVITY := 24.0
const MOUSE_SENSITIVITY := 0.0022
const PITCH_LIMIT := 1.5
const EYE_HEIGHT := 0.7        # 相机在胶囊中心上方 0.7（脚部以上 1.7）
const REACH := 5.0
## 中心低于此高度 = 脚已进入基岩层以下：穿模或走出已加载边缘，
## 一律回出生点（基岩不可挖，正常游玩不可能低于此高度）。
const MIN_VALID_CENTER_Y := 1.5

## 新类全局缓存不刷新（约束卡）：一律 preload 引用。
const GridInv := preload("res://items/grid_inventory.gd")
const PlayerAvatar := preload("res://characters/player_avatar.gd")

## 网格背包 UI 常量（格 = 分区格；HUD 快捷栏格独立稍大）
const HOTBAR_COLS := 8         # 快捷栏列数（键 1-8）
const CELL := 46               # 背包格边长（px）
const CELL_GAP := 3            # 格缝（px）
const HUD_SLOT := 52           # 底部 HUD 快捷栏格边长（px）

# 游泳（v4 水世界）：水中重力/终端速度减小、Space 上浮、移速打折
const WATER_GRAVITY := 5.0
const WATER_TERMINAL := 3.0
const SWIM_UP_SPEED := 3.2
const WATER_SPEED_FACTOR := 0.6

# 丢弃（Q / Ctrl+Q）：朝视线方向抛出，保护期内不磁吸不拾取
const DROP_THROW_SPEED := 5.0
const DROP_ARC_UP := 1.2
const DROP_PICKUP_DELAY := 1.0

# ---- 移动手感 v2（轻微惯性 + 跳跃增强 + 镜头反馈）----
const ACCEL_GROUND := 46.0    # 地面加速（m/s²）：走速 0.1s 达成
const DECEL_GROUND := 62.0    # 地面制动（松键 ~0.13s 滑停）
const ACCEL_AIR := 13.0       # 空中操控（惯性保留，只微调方向）
const DRAG_AIR := 0.9         # 空中无输入的水平阻尼（滑翔感）
const COYOTE_TIME := 0.12     # 走出边缘后仍可跳的宽限
const JUMP_BUFFER := 0.15     # 落地前按跳的预输入窗
const JUMP_CUT := 0.55        # 提前松开跳跃：上升速度乘数（短跳）
const FOV_SPRINT_ADD := 5.0   # 冲刺 FOV 拉镜增量（度）
const FOV_LERP_RATE := 6.0
const BOB_WALK_AMP := 0.032   # 头部摆动振幅（米，保守防 3D 眩晕）
const BOB_SPRINT_AMP := 0.055
const BOB_FREQ_WALK := 1.7    # 步频（Hz）
const BOB_FREQ_SPRINT := 2.3
const LAND_DIP_SCALE := 0.022 # 落地下沉：每 m/s 超额下落速度的相机下沉
const LAND_DIP_MAX := 0.26
const LAND_DIP_DECAY := 9.0

# 落定动画（放置成功：倾斜→摆正 + 缩放回落）
const SETTLE_SECONDS := 0.16

# 相机模式（F5 循环）：0 第一人称 / 1 第三人称背后 / 2 第二人称面前 /
# 3 越肩（TPS）。外置机位共用：体素 DDA 遮挡收缩（快收慢回弹防抖）
const CAM_DIST := [0.0, 3.2, 3.6, 2.1]   # 各模式目标距离（米）
const CAM_MIN_DIST := 0.5                # 收缩下限（别怼进头里）
const CAM_COLLIDE_PAD := 0.3             # 命中面回退余量
const CAM_PULL_IN := 9.0                 # 遮挡收拢限速（>跑速 8 防穿墙；防阈值角瞬跳）
const OCCLUDE_RECOVER := 3.0             # 遮挡解除回弹速率（慢于收拢——快收慢放）
const CAM_LERP := 14.0
const SHOULDER_X := 0.55                 # 越肩：机位向角色右侧偏（角色居画面左）
const SHOULDER_Y := 0.15
const DODGE_DECAY := 22.0                # 闪避冲量衰减（快冲快收）
const DODGE_DOUBLE_TAP := 0.28           # 双击方向键判定窗口（秒）

var world: VoxelWorld
var spawn_point := Vector3.ZERO

var item_registry: ItemRegistry
## GridInventory（不标窄类型：preload 类作类型注解在 headless 下不稳）。
var inventory
## 掉落实体管理器（主场景注入；为空时掉落兜底直接入包，独立场景可用）
var drop_manager: DropManager

## 选中的快捷栏列（0..HOTBAR_COLS-1；列内容 = 覆盖该列的条目中起始
## 行最小者优先，见 GridInventory.hotbar_pick）。
var selected_col := 0
var _pitch := 0.0
## 背包界面打开时暂停交互（移动仍可用）。
var inventory_open := false

## 角色化身（YSM 模型 + 动画；F6 切模型包）
var avatar
## 相机模式：0 第一人称 / 1 第三人称背后 / 2 第三人称面前（F5 循环）
var camera_mode := 0
# 手感状态（v2）
var _coyote := 0.0
var _jump_buf := 0.0
var _space_prev := false
var _was_grounded := true
var _bob_phase := 0.0
var _bob_y := 0.0
var _bob_x := 0.0
var _land_dip := 0.0
var _fov_base := 0.0
var _sprinting := false
var _cam_dist := 3.2

# 挖掘进度状态（目标方块切换/松开左键即重置）
var _mine_active := false
var _mine_target := Vector3i.ZERO
var _mine_elapsed := 0.0
var _mine_seconds := 0.0
var _mine_drops := false

# UI 引用
@onready var camera: Camera3D = $Camera
var _hotbar_panel: PanelContainer
var _hb_col_panels: Array[Panel] = []
var _hb_col_icons: Array[TextureRect] = []
var _hb_col_counts: Array[Label] = []
var _item_label: Label
var _progress_bar: ColorRect
var _progress_fill: ColorRect
var _inventory_screen: Control
## zone -> {root, cells(y×x), hover, preview, layer}（网格分区 UI）
var _zones := {}
## uid -> Control（条目节点；落定动画定位用）
var _entry_nodes := {}
## 拖拽状态：{entry, rotated, from_zone, from_x, from_y}；空字典 = 未拖拽。
var _drag := {}
var _drag_icon: Control
## 最近悬停格（旋转拖拽物后重算预览用）：{zone,x,y} 或空。
var _hover_cell := {}
var _dodge_vel := Vector3.ZERO   # 闪避冲量（世界系，衰减叠加到速度）
var _last_tap := {}              # 方向键 → 上次按下时刻（双击闪避判定）
## 水下全屏色调（v4 水世界）
var _underwater_tint: ColorRect


func _ready() -> void:
	camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	_fov_base = camera.fov
	camera.make_current()
	inventory = GridInv.new(item_registry)
	inventory.changed.connect(_refresh_hud)
	avatar = PlayerAvatar.new()
	add_child(avatar)
	# 玩家原点=胶囊中心（脚在 -1.0）；模型原点在脚底——下移一格贴地
	#（曾整体浮空一格，用户实机抓到）
	avatar.position = Vector3(0.0, -1.0, 0.0)
	avatar.setup(self, world)
	_build_hud()
	_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
			_pitch = clampf(
					_pitch - event.relative.y * MOUSE_SENSITIVITY,
					-PITCH_LIMIT, PITCH_LIMIT)
			camera.rotation = Vector3(_pitch, 0.0, 0.0)
		elif not _drag.is_empty():
			_drag_icon.global_position = \
					_drag_icon.get_global_mouse_position() - _drag_icon.size / 2
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 未锁定时第一次点击仅锁定视角，不触发挖掘
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
						and not inventory_open:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				elif avatar != null and avatar.is_armed():
					# 拔刀：左键=三段连击（挖掘收刀后恢复）
					avatar.attack()
				elif avatar != null and not _raycast_from_camera()["hit"]:
					# 对空挥拳 = 拳击连击反馈（有目标时走挖掘动作）
					avatar.play_punch()
			MOUSE_BUTTON_RIGHT:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
						and not inventory_open:
					_try_place()
			MOUSE_BUTTON_WHEEL_UP:
				if not inventory_open:
					_cycle_selection(-1)
				elif not _drag.is_empty():
					_rotate_drag()
			MOUSE_BUTTON_WHEEL_DOWN:
				if not inventory_open:
					_cycle_selection(1)
				elif not _drag.is_empty():
					_rotate_drag()
	elif event is InputEventKey and event.pressed:
		# 双击方向键 = 闪避（拔刀态；0.28s 窗口内同键二击）
		var tap_dir := _dodge_dir_name(event.keycode)
		if tap_dir != "" and not event.echo:
			var now := Time.get_ticks_msec() / 1000.0
			if _last_tap.has(tap_dir) \
					and now - float(_last_tap[tap_dir]) <= DODGE_DOUBLE_TAP:
				if avatar != null:
					avatar.dodge(tap_dir)
				_last_tap.erase(tap_dir)
			else:
				_last_tap[tap_dir] = now
		match event.keycode:
			KEY_E:
				_toggle_inventory()
			KEY_Q:
				# Q 扔 1 个，Ctrl+Q 扔整堆（背包界面打开时不响应）
				if not inventory_open:
					_drop_held(event.ctrl_pressed)
			KEY_R:
				# 拖拽中旋转（多格物品）
				if not _drag.is_empty():
					_rotate_drag()
			KEY_ESCAPE:
				if inventory_open:
					_toggle_inventory()
				else:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F5:
				_cycle_camera()
			KEY_F6:
				if avatar != null:
					avatar.cycle_model()
			KEY_F7:
				# 拔刀/收刀（EF yamato 动作集：连击/闪避/持刀移动）
				# 战斗系统下线中（avatar.COMBAT_ENABLED）——入口关闭
				if avatar != null and avatar.COMBAT_ENABLED:
					avatar.set_armed(not avatar.is_armed())
			KEY_1, KEY_2, KEY_3, KEY_4, \
			KEY_5, KEY_6, KEY_7, KEY_8:
				if not inventory_open:
					_select(_key_to_col(event.keycode))


## 双击闪避方向名（WASD → 前后左右）。
func _dodge_dir_name(key: Key) -> String:
	match key:
		KEY_W:
			return "forward"
		KEY_S:
			return "back"
		KEY_A:
			return "left"
		KEY_D:
			return "right"
		_:
			return ""


func _physics_process(delta: float) -> void:
	if world == null:
		return
	# 兜底先行：摔到基岩层以下（穿模/掉出加载边缘）回出生点。
	# 必须在脚下区块门禁之前，否则门禁的 return 会把玩家永远冻在无效位置。
	if global_position.y < MIN_VALID_CENTER_Y:
		global_position = spawn_point
		velocity = Vector3.ZERO
		return
	# 流式加载保底：脚下区块未就绪（ACTIVE）时冻结物理，防止坠落
	var standing := VoxelCoords.world_to_chunk(
			global_position, world.config.chunk_size)
	var standing_chunk := world.get_chunk(standing)
	if standing_chunk == null or standing_chunk.state != ChunkState.State.ACTIVE:
		velocity = Vector3.ZERO
		return
	_update_mining(delta)
	var speed := SPRINT_SPEED \
			if Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
	# 水的两级判定（MC 语义），基于实际水位（water_surface_at：
	# 向上扫表面格 + 级别高度）：
	# - 涉水（浸深 > 0.1）：移速折扣 + 水流推力生效——踩进一格深的
	#   浅滩走路变慢、会被水流冲走，但保持正常重力与跳跃（能跳出
	#   浅滩，Space 是跳不是上浮）；
	# - 深水（浸深 > 0.9）：才切换游泳物理（弱重力缓沉、Space 上浮）。
	#   0.9 取在源水 0.875 与整格 1.0 之间，贴格边界抖动不闪断。
	var feet_y := global_position.y - 1.0
	var feet_cell := Vector3i(
			floori(global_position.x),
			floori(feet_y + 0.05),
			floori(global_position.z))
	var immersion := WaterFlow.water_surface_at(world, feet_cell) - feet_y
	var wading := immersion > 0.1
	var deep_water := immersion > 0.9
	if wading:
		speed *= WATER_SPEED_FACTOR
	# 本节点只有偏航，basis.z/basis.x 已在水平面上
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x
	var motion := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		motion += forward
	if Input.is_physical_key_pressed(KEY_S):
		motion -= forward
	if Input.is_physical_key_pressed(KEY_D):
		motion += right
	if Input.is_physical_key_pressed(KEY_A):
		motion -= right
	motion.y = 0.0
	if motion.length_squared() > 0.0:
		motion = motion.normalized() * speed
	# 闪避冲量叠加（拔刀双击方向；局部→世界，指数衰减 ~0.35s）
	var dodge_add := Vector3.ZERO
	if avatar != null:
		var imp: Vector3 = avatar.take_dodge_impulse()
		if imp != Vector3.ZERO:
			_dodge_vel = global_transform.basis * imp
		if _dodge_vel != Vector3.ZERO:
			dodge_add = _dodge_vel
			_dodge_vel = _dodge_vel.move_toward(Vector3.ZERO,
					DODGE_DECAY * delta)
	# 手感 v2：目标速度 → 加速/制动逼近（地面快、空中弱保惯性）；
	# 闪避冲量在平滑后叠加（不被巡航速度上限吞掉）
	var grounded := is_on_floor()
	_sprinting = Input.is_physical_key_pressed(KEY_SHIFT) \
			and motion != Vector3.ZERO
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	if grounded or deep_water:
		var rate := DECEL_GROUND if motion == Vector3.ZERO \
				else ACCEL_GROUND
		horiz = horiz.move_toward(motion, rate * delta)
	elif motion != Vector3.ZERO:
		horiz = horiz.move_toward(motion, ACCEL_AIR * delta)
	else:
		horiz = horiz.move_toward(Vector3.ZERO, DRAG_AIR * delta)
	horiz += dodge_add
	velocity.x = horiz.x
	velocity.z = horiz.z
	var vy_before := velocity.y
	if deep_water:
		# 游泳：弱重力 + 缓沉，Space 上浮；水上跳出由跳速衰减自然处理。
		# 玩家不被水流冲走（用户决策）：只有掉落物会被水流冲向下游
		velocity.y = maxf(velocity.y - WATER_GRAVITY * delta, -WATER_TERMINAL)
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = move_toward(velocity.y, SWIM_UP_SPEED, 24.0 * delta)
		_coyote = 0.0
	else:
		var space := Input.is_physical_key_pressed(KEY_SPACE)
		if space and not _space_prev:
			_jump_buf = JUMP_BUFFER
		else:
			_jump_buf = maxf(_jump_buf - delta, 0.0)
		if grounded:
			_coyote = COYOTE_TIME
		else:
			_coyote = maxf(_coyote - delta, 0.0)
		# 土狼时间（刚离地）或地面 → 缓冲的跳跃触发
		if _jump_buf > 0.0 and (grounded or _coyote > 0.0):
			velocity.y = JUMP_VELOCITY
			_jump_buf = 0.0
			_coyote = 0.0
			grounded = false
		elif grounded and space:
			velocity.y = JUMP_VELOCITY  # 按住连跳（原行为）
		# 可变跳高：上升中松开 Space 削速度（短跳）
		if _space_prev and not space and velocity.y > 2.0:
			velocity.y *= JUMP_CUT
		_space_prev = space
		if not grounded:
			velocity.y -= GRAVITY * delta
	# 落地轻沉：离地→着地瞬间按超额下落速度叠冲击（指数回弹）
	if is_on_floor() and not _was_grounded and vy_before < -3.0:
		_land_dip = minf(_land_dip
				+ (-vy_before - 3.0) * LAND_DIP_SCALE + 0.03,
				LAND_DIP_MAX)
	_was_grounded = is_on_floor()
	move_and_slide()
	_update_underwater_tint()
	if avatar != null:
		avatar.visible = camera_mode != 0
		avatar.update_locomotion(velocity, is_on_floor(), deep_water, delta)
		avatar.set_mining(_mine_active and _mine_seconds != INF)


# ---- 挖掘（按住累积进度，§8.2 + 物品层规则）----

func _update_mining(delta: float) -> void:
	var holding := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not inventory_open
	if not holding:
		_reset_mining()
		return
	var hit := _raycast_from_camera()
	if not hit.hit:
		_reset_mining()
		return
	var target: Vector3i = hit.block_pos
	if not _mine_active or target != _mine_target:
		_mine_active = true
		_mine_target = target
		_mine_elapsed = 0.0
		var info := BlockMining.break_info(
				world.get_block(target), world.registry, _held_tool())
		if not bool(info["breakable"]):
			# 不可破坏（基岩等）：记住目标并把时长置无穷——后续帧
			# target 未变直接跳过（曾每物理帧重复 break_info+mine 空转）
			_mine_active = true
			_mine_target = target
			_mine_elapsed = 0.0
			_mine_seconds = INF
			_mine_drops = false
			return
		_mine_seconds = float(info["seconds"])
		_mine_drops = bool(info["drops"])
	_mine_elapsed += delta
	if _mine_elapsed >= _mine_seconds:
		_break_block(target)
		_reset_mining()


func _break_block(block_pos: Vector3i) -> void:
	var drops := BlockMining.mine(
			world, block_pos, item_registry, _mine_drops)
	for drop in drops:
		_dispatch_drop(int(drop["item_id"]), int(drop["count"]), block_pos)


## 挖掘产物优先生成地面掉落实体（方块中心 + 随机散射）；
## 实体层不可用（独立场景 / 实体满）时兜底直接入包（旧语义）。
func _dispatch_drop(item_id: int, count: int, block_pos: Vector3i) -> void:
	if drop_manager != null and drop_manager.spawn_scatter(
			item_id, count,
			Vector3(block_pos) + Vector3(0.5, 0.5, 0.5)):
		return
	var leftover: int = inventory.add(item_id, count)
	if leftover > 0:
		push_warning("背包已满，%d 个物品丢失" % leftover)


## 玩家身边丢弃一堆物品（关背包时手中还有条目）。返回是否成功落地。
func _scatter_at_player(item_id: int, count: int) -> bool:
	if drop_manager == null:
		return false
	var forward_dir := -global_transform.basis.z
	return drop_manager.spawn_scatter(item_id, count,
			global_position + Vector3(0.0, 1.2, 0.0) + forward_dir * 0.6, 1.0)


# ---- 丢弃（Q 扔 1 个 / Ctrl+Q 扔整堆，朝视线方向抛出）----

func _drop_held(whole_stack: bool) -> void:
	if drop_manager == null or inventory == null:
		return  # 无实体层（独立场景）：丢弃不可用，物品留在包里
	var entry := _selected_entry()
	if entry.is_empty():
		return
	var count := int(entry["count"]) if whole_stack else 1
	var item_id := int(entry["item_id"])
	inventory.remove_at_entry(entry, count)
	# 从眼睛沿视线抛出（含俯仰）；保护期覆盖飞行时间，防止瞬吸回
	var look := -camera.global_transform.basis.z
	drop_manager.spawn_drop(
			item_id, count,
			camera.global_position + look * 0.6,
			look * DROP_THROW_SPEED + Vector3.UP * DROP_ARC_UP,
			DROP_PICKUP_DELAY)


func _reset_mining() -> void:
	_mine_active = false
	_mine_elapsed = 0.0


## 当前选中快捷栏列的条目（空列返回空字典）。
func _selected_entry() -> Dictionary:
	if inventory == null:
		return {}
	return inventory.hotbar_pick(selected_col)


func _held_tool() -> Dictionary:
	if item_registry == null or inventory == null:
		return {}
	var entry := _selected_entry()
	return item_registry.tool_for(int(entry.get("item_id", -1)))


# ---- 放置（消耗手持物品）----

func _try_place() -> void:
	var entry := _selected_entry()
	if entry.is_empty():
		return
	var block_id := item_registry.place_block_id(int(entry["item_id"]))
	if block_id < 0:
		return  # 手持的不是放置类物品（工具/材料）
	var hit := _raycast_from_camera()
	if not hit.hit or hit.normal == Vector3i.ZERO:
		return
	var placed_pos: Vector3i = hit.block_pos + hit.normal
	if BlockPlacement.place(world, placed_pos,
			block_id, _player_aabb(), hit.normal):
		inventory.remove_at_entry(entry, 1)
		_snap_onto_placed_block(placed_pos)
	else:
		# 放置被拒要有反馈（无支撑/与身体重叠）——静默拒绝曾被
		# 用户误读为"模型丢失"
		var parent_node := get_parent()
		if parent_node != null and parent_node.has_method("show_hint"):
			parent_node.show_hint("无法放置：位置无支撑或与身体重叠")


## 垫脚：下落中往脚下放方块（放置瞬间不与身体重叠——通过检查），
## 但碰撞体 1-2 帧后才出现，玩家此时已落进该格 → 嵌进方块卡在
## 空中（实机报告）。放置成功后若新格水平重叠且脚部在其高度区间
## 内，把玩家抬到方块顶站上（MC 式搭塔）；速度清零防挣脱抖动
func _snap_onto_placed_block(cell: Vector3i) -> void:
	var pa := _player_aabb()
	var feet := global_position.y - 1.0
	var h_overlap: bool = pa.end.x > float(cell.x) \
			and pa.position.x < float(cell.x + 1) \
			and pa.end.z > float(cell.z) \
			and pa.position.z < float(cell.z + 1)
	if h_overlap and feet > float(cell.y) - 0.1 \
			and feet < float(cell.y + 1) - 0.05:
		global_position.y = float(cell.y + 1) + 1.0 + 0.01
		velocity.y = 0.0


func _raycast_from_camera() -> Dictionary:
	return VoxelRaycast.raycast(
			world,
			camera.global_position,
			-camera.global_transform.basis.z,
			REACH)


## 玩家占用空间（胶囊的外接盒，略保守但足够防卡自身）
func _player_aabb() -> AABB:
	return AABB(
			global_position - Vector3(0.4, 1.0, 0.4),
			Vector3(0.8, 2.0, 0.8))


# ---- 选择（快捷栏列：键 1-8 / 滚轮循环）----

func _key_to_col(keycode: int) -> int:
	return keycode - KEY_1


func _select(col: int) -> void:
	selected_col = clampi(col, 0, HOTBAR_COLS - 1)
	_refresh_hud()


func _cycle_selection(direction: int) -> void:
	selected_col = posmod(selected_col + direction, HOTBAR_COLS)
	_refresh_hud()


# ---- HUD 构建（纯代码，与项目无外部资源约定一致）----

func _build_hud() -> void:
	var hud: CanvasLayer = $HUD

	# 快捷栏：底部中心一排（列语义）。显式锚点矩形——MINSIZE 预设在
	# _ready 时容器尚未布局出最小尺寸，会得到 0 尺寸把槽位全部压扁。
	_hotbar_panel = PanelContainer.new()
	var hb_style := StyleBoxFlat.new()
	hb_style.bg_color = Color(0.06, 0.06, 0.08, 0.55)
	hb_style.set_corner_radius_all(6)
	hb_style.set_content_margin_all(4)
	_hotbar_panel.add_theme_stylebox_override("panel", hb_style)
	var hb_width := HOTBAR_COLS * HUD_SLOT + (HOTBAR_COLS - 1) * 4 + 8
	var hb_height := HUD_SLOT + 8
	_hotbar_panel.anchor_left = 0.5
	_hotbar_panel.anchor_right = 0.5
	_hotbar_panel.anchor_top = 1.0
	_hotbar_panel.anchor_bottom = 1.0
	@warning_ignore("integer_division")
	_hotbar_panel.offset_left = -hb_width / 2
	@warning_ignore("integer_division")
	_hotbar_panel.offset_right = hb_width / 2
	_hotbar_panel.offset_top = -hb_height - 14
	_hotbar_panel.offset_bottom = -14
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_hotbar_panel.add_child(row)
	hud.add_child(_hotbar_panel)
	for i in HOTBAR_COLS:
		var slot := _make_hud_slot(i == selected_col)
		slot.add_child(_make_hud_slot_icon())
		var count := _make_count_label()
		slot.add_child(count)
		row.add_child(slot)
		_hb_col_panels.append(slot)
		_hb_col_icons.append(slot.get_child(0))
		_hb_col_counts.append(count)

	# 手持物品名：快捷栏上方
	_item_label = Label.new()
	_item_label.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE)
	_item_label.offset_top -= HUD_SLOT + 40
	_item_label.offset_bottom -= HUD_SLOT + 40
	_item_label.add_theme_font_size_override("font_size", 15)
	_item_label.add_theme_color_override("font_color", Color.WHITE)
	_item_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_item_label.add_theme_constant_override("outline_size", 4)
	hud.add_child(_item_label)

	# 挖掘进度条：准星下方
	_progress_bar = ColorRect.new()
	_progress_bar.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_progress_bar.offset_left = -30
	_progress_bar.offset_right = 30
	_progress_bar.offset_top = 26
	_progress_bar.offset_bottom = 32
	_progress_bar.color = Color(0, 0, 0, 0.55)
	_progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_progress_bar)
	_progress_fill = ColorRect.new()
	_progress_fill.color = Color(0.95, 0.85, 0.3, 0.9)
	_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_bar.add_child(_progress_fill)

	_build_inventory_screen(hud)

	# 水下色调：全屏半透明蓝，鼠标穿透，默认隐藏
	_underwater_tint = ColorRect.new()
	_underwater_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_underwater_tint.color = Color(0.10, 0.30, 0.55, 0.30)
	_underwater_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_underwater_tint.visible = false
	hud.add_child(_underwater_tint)


func _make_hud_slot(selected: bool) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(HUD_SLOT, HUD_SLOT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.65)
	style.set_corner_radius_all(4)
	style.set_border_width_all(2)
	style.border_color = Color(1, 0.9, 0.4) if selected else Color(0.5, 0.5, 0.55)
	panel.add_theme_stylebox_override("panel", style)
	return panel


## 槽位图标：四边内缩 4px，不遮挡槽位边框（选中高亮）与圆角。
func _make_hud_slot_icon() -> TextureRect:
	var icon := TextureRect.new()
	icon.anchor_left = 0.0
	icon.anchor_right = 1.0
	icon.anchor_top = 0.0
	icon.anchor_bottom = 1.0
	icon.offset_left = 4
	icon.offset_top = 4
	icon.offset_right = -4
	icon.offset_bottom = -4
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


func _make_count_label() -> Label:
	var label := Label.new()
	label.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE)
	label.offset_left = -26
	label.offset_top = -20
	label.offset_right = -3
	label.offset_bottom = -3
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _refresh_hud() -> void:
	for i in HOTBAR_COLS:
		_apply_entry_display(
				_hb_col_panels[i], _hb_col_icons[i], _hb_col_counts[i],
				inventory.hotbar_pick(i))
		var style: StyleBoxFlat = _hb_col_panels[i].get_theme_stylebox("panel")
		style.border_color = Color(1, 0.9, 0.4) if i == selected_col \
				else Color(0.5, 0.5, 0.55)
	var entry := _selected_entry()
	if entry.is_empty():
		_item_label.text = ""
	else:
		_item_label.text = item_registry.display_name(int(entry["item_id"]))
	if _inventory_screen != null and is_instance_valid(_inventory_screen):
		_refresh_inventory_screen()


## 槽位显示（HUD 快捷栏 / 拖拽图标共用）：空条目清空，有货显图标+数量。
func _apply_entry_display(
		panel: Panel, icon: TextureRect, count: Label,
		entry: Dictionary) -> void:
	if entry.is_empty():
		icon.texture = null
		count.text = ""
		return
	icon.texture = ItemIcons.icon_for(
			int(entry["item_id"]), item_registry)
	count.text = str(entry["count"]) if int(entry["count"]) > 1 else ""


# ---- 背包界面（E 开关；网格拖拽：拿起/放下/旋转/合并）----

func _build_inventory_screen(hud: CanvasLayer) -> void:
	_inventory_screen = Control.new()
	_inventory_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inventory_screen.visible = false
	_inventory_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(_inventory_screen)

	# 半透明遮罩：拖拽中点击 = 把手中条目丢到身边地面
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.35)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	_inventory_screen.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inventory_screen.add_child(center)
	var frame := PanelContainer.new()
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.169, 0.169, 0.188, 0.96)
	frame_style.set_corner_radius_all(8)
	frame_style.set_content_margin_all(16)
	frame.add_theme_stylebox_override("panel", frame_style)
	center.add_child(frame)
	var layout := HBoxContainer.new()
	layout.add_theme_constant_override("separation", 20)
	frame.add_child(layout)

	# -- 左：合成面板（配方列表，点击合成一次）--
	layout.add_child(_build_crafting_panel())

	# -- 中：主网格 8×9 + 快捷栏 8×2（隔缝）--
	var middle := VBoxContainer.new()
	middle.add_theme_constant_override("separation", 12)
	layout.add_child(middle)
	middle.add_child(_build_zone(GridInv.Zone.MAIN, 8, 9))
	middle.add_child(_build_zone(GridInv.Zone.HOTBAR, 8, 2))

	# -- 右：GEAR 穿戴预留容器 4×4 --
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	layout.add_child(right)
	var gear_title := Label.new()
	gear_title.text = "Gear"
	gear_title.add_theme_font_size_override("font_size", 15)
	gear_title.add_theme_color_override("font_color", Color(0.75, 0.72, 0.62))
	right.add_child(gear_title)
	right.add_child(_build_zone(GridInv.Zone.GEAR, 4, 4))

	# 跟随鼠标的拖拽条目图标
	_drag_icon = Control.new()
	_drag_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_icon.z_index = 10
	_drag_icon.visible = false
	_inventory_screen.add_child(_drag_icon)


## 构建一个网格分区：深色内嵌格阵 + 悬停高亮层 + 落点预览层 + 条目层。
func _build_zone(zone: int, cols: int, rows: int) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(
			cols * CELL + (cols - 1) * CELL_GAP,
			rows * CELL + (rows - 1) * CELL_GAP)
	var cell_style := StyleBoxFlat.new()
	cell_style.bg_color = Color(0.086, 0.086, 0.102, 0.95)
	cell_style.set_corner_radius_all(2)
	var cells: Array = []
	for y in rows:
		var row_cells: Array = []
		for x in cols:
			var cell := Panel.new()
			cell.position = Vector2(
					x * (CELL + CELL_GAP), y * (CELL + CELL_GAP))
			cell.size = Vector2(CELL, CELL)
			cell.add_theme_stylebox_override("panel", cell_style)
			cell.gui_input.connect(_on_cell_input.bind(zone, x, y))
			cell.mouse_entered.connect(_on_cell_hover.bind(zone, x, y))
			cell.mouse_exited.connect(_on_cell_exit.bind(zone))
			root.add_child(cell)
			row_cells.append(cell)
		cells.append(row_cells)
	# 落点预览（z 4）与悬停脚印高亮（z 5）在条目层（z 6）之下
	var preview := ColorRect.new()
	preview.color = Color(1, 1, 1, 0.25)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.z_index = 4
	preview.visible = false
	root.add_child(preview)
	var hover := ColorRect.new()
	hover.color = Color(1, 1, 1, 0.22)
	hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover.z_index = 5
	hover.visible = false
	root.add_child(hover)
	var layer := Control.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.z_index = 6
	root.add_child(layer)
	_zones[zone] = {
		"root": root, "cells": cells,
		"hover": hover, "preview": preview, "layer": layer,
	}
	return root


## 分区内条目节点的像素原点（含格缝）。
func _cell_origin(zone: int, x: int, y: int) -> Vector2:
	return Vector2(x * (CELL + CELL_GAP), y * (CELL + CELL_GAP))


## 条目脚印的像素尺寸（含格缝）。
func _footprint_px(item_id: int, rotated: bool) -> Vector2:
	var fp: Vector2i = inventory.footprint(item_id, rotated)
	return Vector2(
			fp.x * CELL + (fp.x - 1) * CELL_GAP,
			fp.y * CELL + (fp.y - 1) * CELL_GAP)


## 全量重建各分区条目节点（changed 信号驱动；条目量级 <百，全量足够）。
func _rebuild_entries() -> void:
	_entry_nodes.clear()
	for zone in _zones:
		var layer: Control = _zones[zone]["layer"]
		for child in layer.get_children():
			child.queue_free()
		for e in inventory.entries_in(int(zone)):
			layer.add_child(_make_entry_node(e))


## 条目节点：正方形图标（旋转安全）+ 右下角数量。
func _make_entry_node(e: Dictionary) -> Control:
	var item_id := int(e["item_id"])
	var node := Control.new()
	node.position = _cell_origin(int(e["zone"]), int(e["x"]), int(e["y"]))
	node.size = _footprint_px(item_id, bool(e["rotated"]))
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var side := maxf(node.size.x, node.size.y) - 6.0
	var icon := TextureRect.new()
	icon.size = Vector2(side, side)
	icon.position = (node.size - Vector2(side, side)) / 2.0
	icon.pivot_offset = Vector2(side, side) / 2.0
	icon.rotation = PI / 2 if bool(e["rotated"]) else 0.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = ItemIcons.icon_for(item_id, item_registry)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(icon)
	var count := _make_count_label()
	node.add_child(count)
	count.text = str(e["count"]) if int(e["count"]) > 1 else ""
	_entry_nodes[int(e["uid"])] = node
	return node


func _refresh_inventory_screen() -> void:
	if not inventory_open:
		return
	_rebuild_entries()
	_refresh_crafting()


# ---- 格子事件（点击/悬停）----

func _on_cell_input(event: InputEvent, zone: int, x: int, y: int) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if _drag.is_empty():
		_begin_drag(zone, x, y)
	else:
		_attempt_drop(zone, x, y)


func _on_cell_hover(zone: int, x: int, y: int) -> void:
	_hover_cell = {"zone": zone, "x": x, "y": y}
	_update_zone_overlays(zone, x, y)


func _on_cell_exit(zone: int) -> void:
	_hover_cell = {}
	(_zones[zone]["hover"] as ColorRect).visible = false
	(_zones[zone]["preview"] as ColorRect).visible = false


## 悬停高亮 / 拖拽落点预览。未拖拽：物品脚印白高亮、空格无反馈
##（参考图语义）；拖拽中：预览脚印（可放白/不可放红）。
func _update_zone_overlays(zone: int, x: int, y: int) -> void:
	var ui: Dictionary = _zones[zone]
	var hover: ColorRect = ui["hover"]
	var preview: ColorRect = ui["preview"]
	hover.visible = false
	preview.visible = false
	if _drag.is_empty():
		var e: Dictionary = inventory.entry_at_cell(zone, x, y)
		if e.is_empty():
			return
		hover.position = _cell_origin(zone, int(e["x"]), int(e["y"]))
		hover.size = _footprint_px(int(e["item_id"]), bool(e["rotated"]))
		hover.color = Color(1, 1, 1, 0.22)
		hover.visible = true
	else:
		var item_id := int(_drag["entry"]["item_id"])
		preview.position = _cell_origin(zone, x, y)
		preview.size = _footprint_px(item_id, bool(_drag["rotated"]))
		var what: String = inventory.drop_check(
				_drag["entry"], zone, x, y, bool(_drag["rotated"]))
		preview.color = Color(1, 1, 1, 0.25) if what != "blocked" \
				else Color(1, 0.25, 0.2, 0.28)
		preview.visible = true


# ---- 拖拽（拿起 → 旋转 → 放下/弹回/丢地上）----

func _begin_drag(zone: int, x: int, y: int) -> void:
	var e: Dictionary = inventory.pickup(zone, x, y)
	if e.is_empty():
		return
	_drag = {
		"entry": e,
		"rotated": bool(e.get("rotated", false)),
		"from_zone": zone, "from_x": int(e["x"]), "from_y": int(e["y"]),
	}
	_refresh_drag_icon()


## 拖拽图标重建（拿起/旋转/部分并入后调用）。
func _refresh_drag_icon() -> void:
	for child in _drag_icon.get_children():
		child.queue_free()
	var e: Dictionary = _drag["entry"]
	var rotated: bool = _drag["rotated"]
	_drag_icon.size = _footprint_px(int(e["item_id"]), rotated)
	var side := maxf(_drag_icon.size.x, _drag_icon.size.y) - 6.0
	var icon := TextureRect.new()
	icon.size = Vector2(side, side)
	icon.position = (_drag_icon.size - Vector2(side, side)) / 2.0
	icon.pivot_offset = Vector2(side, side) / 2.0
	icon.rotation = PI / 2 if rotated else 0.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = ItemIcons.icon_for(int(e["item_id"]), item_registry)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_icon.add_child(icon)
	var count := _make_count_label()
	_drag_icon.add_child(count)
	count.text = str(e["count"]) if int(e["count"]) > 1 else ""
	_drag_icon.visible = true
	_drag_icon.global_position = \
			_drag_icon.get_global_mouse_position() - _drag_icon.size / 2


## 旋转拖拽物（1×1 物品无旋转意义，忽略）。
func _rotate_drag() -> void:
	var e: Dictionary = _drag["entry"]
	if item_registry.grid_size(int(e["item_id"])) == Vector2i.ONE:
		return
	_drag["rotated"] = not bool(_drag["rotated"])
	_refresh_drag_icon()
	if not _hover_cell.is_empty():
		_update_zone_overlays(
				int(_hover_cell["zone"]),
				int(_hover_cell["x"]), int(_hover_cell["y"]))


func _attempt_drop(zone: int, x: int, y: int) -> void:
	var e: Dictionary = _drag["entry"]
	# 并入已有堆时对目标堆做落定动画，先记下目标
	var merge_target: Dictionary = inventory.entry_at_cell(zone, x, y)
	var result: int = inventory.try_drop(
			e, zone, x, y, bool(_drag["rotated"]))
	match result:
		GridInv.DropResult.PLACED:
			var uid := int(e["uid"])
			_clear_drag()
			_play_settle(uid)
		GridInv.DropResult.MERGED:
			var uid := int(merge_target.get("uid", -1))
			_clear_drag()
			_play_settle(uid)
		GridInv.DropResult.PARTIAL:
			_refresh_drag_icon()  # 余量继续手持
		_:
			_bounce_back()


## 放不下：弹回原位（拿起时的格子必已空出）+ 落定动画反馈。
func _bounce_back() -> void:
	var e: Dictionary = _drag["entry"]
	var ok: bool = inventory.try_drop(e, int(_drag["from_zone"]),
			int(_drag["from_x"]), int(_drag["from_y"]),
			bool(_drag["rotated"])) == GridInv.DropResult.PLACED
	if not ok:
		# 理论不可达（原位无人争抢）；兜底自动寻位防丢物品
		inventory.add(int(e["item_id"]), int(e["count"]))
	var uid := int(e["uid"])
	_clear_drag()
	_play_settle(uid)


## 拖拽中点击遮罩 / 关包时手中还有条目：丢到身边地面；
## 实体层不可用则弹回背包（放不下则丢失并告警）。
func _drop_drag_to_world() -> void:
	var e: Dictionary = _drag["entry"]
	var item_id := int(e["item_id"])
	var count := int(e["count"])
	if not _scatter_at_player(item_id, count):
		var leftover: int = inventory.add(item_id, count)
		if leftover > 0:
			push_warning("背包已满，%d 个物品丢失" % leftover)
	_clear_drag()


func _clear_drag() -> void:
	_drag = {}
	_drag_icon.visible = false
	for child in _drag_icon.get_children():
		child.queue_free()
	for zone in _zones:
		(_zones[zone]["preview"] as ColorRect).visible = false


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and not _drag.is_empty():
		_drop_drag_to_world()


## 落定动画：倾斜→摆正 + 缩放回落（参考图放置瞬间的姿态收拢）。
func _play_settle(uid: int) -> void:
	var node: Control = _entry_nodes.get(uid)
	if node == null or not is_instance_valid(node):
		return
	node.pivot_offset = node.size / 2.0
	var tween := node.create_tween()
	tween.set_parallel(true)
	tween.tween_property(node, "scale", Vector2.ONE,
			SETTLE_SECONDS).from(Vector2(1.12, 1.12)) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "rotation", 0.0,
			SETTLE_SECONDS).from(0.14) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _toggle_inventory() -> void:
	inventory_open = not inventory_open
	_inventory_screen.visible = inventory_open
	# 开背包时隐藏 HUD 快捷栏（背包面板自带快捷区且面板底边与之重叠）、
	# 物品名与准星；层级 10 高于 main 调试文字层（1），不再被其遮盖
	_hotbar_panel.visible = not inventory_open
	_item_label.visible = not inventory_open
	var crosshair := get_node_or_null("HUD/Crosshair")
	if crosshair != null:
		crosshair.visible = not inventory_open
	var parent_node := get_parent()
	if parent_node != null and parent_node.has_method("set_debug_hud_visible"):
		parent_node.set_debug_hud_visible(not inventory_open)
	if inventory_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh_inventory_screen()
	else:
		if not _drag.is_empty():
			_drop_drag_to_world()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_reset_mining()


# ---- 相机模式（F5 循环：第一/第三背后/第二面前/越肩）----

func _cycle_camera() -> void:
	camera_mode = (camera_mode + 1) % CAM_DIST.size()
	# 切模式从当前实际距离起步（防从远处瞬间拉近的跳变感）
	_cam_dist = minf(_cam_dist, float(CAM_DIST[camera_mode]))


## 按模式摆相机：
## - 第一人称：贴合眼位（化身隐藏）；
## - 外置三态：绕眼位轨道（背后=视线反向 / 面前=视线正向 / 越肩=背后+
##   右侧偏），遮挡体素 DDA 收缩（命中即收到命中面-0.3，解除按 3m/s
##   慢回弹——快收慢放是 TPS 防抖惯例）；位置指数平滑跟靶。
func _position_camera(delta: float) -> void:
	# 头部摆动（仅地面移动积累相位；走/跑分频幅）+ 落地下沉指数回弹
	var hspd := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hspd > 0.6:
		var sprinting_b := hspd > WALK_SPEED + 0.6
		var freq := BOB_FREQ_SPRINT if sprinting_b else BOB_FREQ_WALK
		var amp := BOB_SPRINT_AMP if sprinting_b else BOB_WALK_AMP
		_bob_phase += TAU * freq * delta
		_bob_y = sin(_bob_phase) * amp
		_bob_x = sin(_bob_phase * 0.5) * amp * 0.4
	else:
		var decay := exp(-8.0 * delta)
		_bob_y *= decay
		_bob_x *= decay
	_land_dip *= exp(-LAND_DIP_DECAY * delta)
	if camera_mode == 0:
		# 第一人称：眼位 + 摆动/落地沉（第三人称机位在外轨道，
		# bob 由化身动画本体表达，不叠机位）
		camera.position = Vector3(_bob_x,
				EYE_HEIGHT + _bob_y - _land_dip, 0.0)
		camera.rotation = Vector3(_pitch, 0.0, 0.0)
		return
	if world == null:
		return
	# 视线方向（玩家局部）：pitch 抬头为正；第二人称轨道俯仰钳 ±60°
	#（look_at 的 up 向量在极点退化，且正面视角不需要过顶）
	var orbit_pitch := _pitch
	if camera_mode == 2:
		orbit_pitch = clampf(_pitch, -1.05, 1.05)
	var look := Vector3(0.0, 0.0, -1.0).rotated(
			Vector3(1, 0, 0), orbit_pitch)
	var to_cam: Vector3 = -look if camera_mode != 2 else look
	var want := float(CAM_DIST[camera_mode])
	# 越肩侧偏：玩家右向（pitch 不改变右向）+ 微抬
	var offset := Vector3.ZERO
	if camera_mode == 3:
		offset = global_transform.basis.x * SHOULDER_X \
				+ Vector3.UP * SHOULDER_Y
	# 眼位（世界）→ 期望机位方向/距离（含侧偏）
	var eye := global_position + Vector3(0.0, EYE_HEIGHT, 0.0)
	var to_cam_world: Vector3 = global_transform.basis * to_cam
	var want_vec := to_cam_world * want + offset
	var want_len := want_vec.length()
	var dir := want_vec / maxf(want_len, 1e-4)
	# 遮挡收缩/回弹——两侧都限速（快收慢放）。
	# 收拢曾为瞬间直设：俯仰到阈值角时眼→机射线首次捅进树冠/坡地，
	# 目标距离一帧跳变 + 相机 14/s 跟入 = 视觉"头抽一下"（用户实机）。
	# 限速 9 m/s：0.3s 内完成 2.7m 收拢仍快于跑速 8 m/s（防穿墙不回退）。
	var hit := VoxelRaycast.raycast(world, eye, dir, want_len + 0.2)
	if hit.hit:
		var want_d := clampf(float(hit["distance"]) - CAM_COLLIDE_PAD,
				CAM_MIN_DIST, want_len)
		_cam_dist = move_toward(_cam_dist, want_d, CAM_PULL_IN * delta)
	else:
		_cam_dist = move_toward(_cam_dist, want_len,
				OCCLUDE_RECOVER * delta)
	var target_global := eye + dir * _cam_dist
	# 平滑逼近（指数）；模式切换大跳直接贴位
	var smooth := 1.0 - exp(-CAM_LERP * delta)
	camera.global_position = camera.global_position.lerp(
			target_global, smooth)
	if camera.global_position.distance_to(target_global) > 8.0:
		camera.global_position = target_global
	if camera_mode == 2:
		# 第二人称：相机角度始终面向人物（俯仰只移动机位高低，
		# 不带走视角——曾随 _pitch 转动导致看天/看地偏离角色）；
		# 瞄胸口（眼位下 0.45）：瞄准眼位时人物可视质心偏下
		camera.look_at(eye - Vector3.UP * 0.45, Vector3.UP)
	else:
		camera.rotation = Vector3(_pitch, 0.0, 0.0)


func _process(delta: float) -> void:
	_position_camera(delta)
	# 冲刺 FOV 拉镜（全模式；平滑进出防突变）
	var want_fov := _fov_base + (FOV_SPRINT_ADD if _sprinting else 0.0)
	camera.fov = lerpf(camera.fov, want_fov,
			1.0 - exp(-FOV_LERP_RATE * delta))
	# 挖掘进度条实时刷新
	if _progress_fill == null:
		return
	if _mine_active and _mine_seconds > 0.0:
		var ratio := clampf(_mine_elapsed / _mine_seconds, 0.0, 1.0)
		_progress_bar.visible = true
		_progress_fill.size = Vector2(ratio * 60.0, 6.0)
	else:
		_progress_bar.visible = false


## 相机在水下时叠一层蓝色色调（v1：纯叠加，不做折射/雾）。
func _update_underwater_tint() -> void:
	if _underwater_tint == null:
		return
	var eye_cell := Vector3i(
			floori(camera.global_position.x),
			floori(camera.global_position.y),
			floori(camera.global_position.z))
	_underwater_tint.visible = world != null \
			and world.get_block(eye_cell) == VoxelTypes.WATER_ID


# ---- 合成面板（配方列表，点击合成一次；材料不足置灰）----

var _craft_rows: Array[Dictionary] = []


func _build_crafting_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(300, 0)
	panel.add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Craft"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
	panel.add_child(title)

	for recipe in CraftingRecipes.all():
		var row := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.16, 0.16, 0.19, 0.9)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(6)
		row.add_theme_stylebox_override("panel", style)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		row.add_child(hbox)

		var output: Array = recipe["output"]
		var output_id := item_registry.id_for_name(String(output[0]))
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(32, 32)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.texture = ItemIcons.icon_for(output_id, item_registry)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(icon)

		var text := Label.new()
		text.text = _recipe_text(recipe)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size = Vector2(0, 32)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_font_size_override("font_size", 13)
		text.add_theme_color_override("font_color", Color.WHITE)
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(text)

		var captured: Dictionary = recipe
		row.gui_input.connect(_on_craft_row_input.bind(captured))
		panel.add_child(row)
		_craft_rows.append({
			"recipe": recipe,
			"panel": row,
			"label": text,
		})
	return panel


## 配方行文本："Wooden Pickaxe\n3x Planks + 2x Stick"。
func _recipe_text(recipe: Dictionary) -> String:
	var items := item_registry
	var output: Array = recipe["output"]
	var output_id := items.id_for_name(String(output[0]))
	var parts := PackedStringArray()
	for entry: Array in recipe["inputs"]:
		var input_id := items.id_for_name(String(entry[0]))
		parts.append("%dx %s" % [int(entry[1]), items.display_name(input_id)])
	var count_text := "" if int(output[1]) == 1 else " x%d" % int(output[1])
	return "%s%s\n%s" % [
		items.display_name(output_id), count_text, " + ".join(parts)]


func _refresh_crafting() -> void:
	for row in _craft_rows:
		var craftable: bool = CraftingRecipes.can_craft(row["recipe"], inventory)
		(row["panel"] as Control).modulate.a = 1.0 if craftable else 0.45


func _on_craft_row_input(event: InputEvent, recipe: Dictionary) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		CraftingRecipes.craft(recipe, inventory)
		# inventory.changed 已触发整体刷新（含本面板可合成态）


# ---- 存档状态（§9.1 player_state）----

## 导出为可 JSON 化的字典（Vector3 转数组）。
## 退出保存时节点可能已离开场景树：离树后 global_position 会告警
## 并回退本地变换，本场景根无变换，两者等价，这里显式取本地位置。
func get_save_state() -> Dictionary:
	var pos := global_position if is_inside_tree() else position
	var spawn := spawn_point
	return {
		"position": [pos.x, pos.y, pos.z],
		"spawn_point": [spawn.x, spawn.y, spawn.z],
		"yaw": rotation.y,
		"pitch": camera.rotation.x,
		"selected_index": selected_col,
		"inventory": inventory.serialize(),
	}


## 从存档恢复（在已入树、脚下区块已预热后调用）。
## 旧档无 inventory 键：给起始装备（物品层上线时刻的迁移语义）；
## 旧档 inventory 为槽位数组：GridInventory.deserialize 自动迁移。
func apply_save_state(state: Dictionary) -> void:
	var position_data: Array = state.get("position", [])
	if position_data.size() == 3:
		global_position = Vector3(
				float(position_data[0]), float(position_data[1]), float(position_data[2]))
		velocity = Vector3.ZERO
	var spawn_data: Array = state.get("spawn_point", [])
	if spawn_data.size() == 3:
		spawn_point = Vector3(
				float(spawn_data[0]), float(spawn_data[1]), float(spawn_data[2]))
	rotation.y = float(state.get("yaw", rotation.y))
	camera.rotation.x = float(state.get("pitch", camera.rotation.x))
	if state.has("inventory"):
		inventory.deserialize(state["inventory"])
	else:
		inventory.apply_starting_kit(ItemTypes.STARTING_KIT)
	_select(int(state.get("selected_index", selected_col)))
