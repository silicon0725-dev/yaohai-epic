## 第一人称玩家控制器（开发文档 §12 阶段 B + 物品层）。
## 碰撞体：两格高一格宽的胶囊（半径 0.4、总高 2.0），无可见模型。
## 移动/跳跃基于 CharacterBody3D + 区块 concave 碰撞；
## 交互基于体素 DDA 射线（physics/voxel_raycast.gd）。
## 物品层：背包（快捷栏 = 前 HOTBAR_SLOTS 格）驱动挖掘工具与放置消耗；
## 按住左键累积挖掘进度（BlockMining.break_info 决定时长与掉落资格），
## E 键开关背包界面（点击拿起/放下/交换堆）。
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

const TOTAL_SLOTS := 24
const HOTBAR_SLOTS := 12
const SLOT_PIXELS := 44

# 游泳（v4 水世界）：水中重力/终端速度减小、Space 上浮、移速打折
const WATER_GRAVITY := 5.0
const WATER_TERMINAL := 3.0
const SWIM_UP_SPEED := 3.2
const WATER_SPEED_FACTOR := 0.6

# 丢弃（Q / Ctrl+Q）：朝视线方向抛出，保护期内不磁吸不拾取
const DROP_THROW_SPEED := 5.0
const DROP_ARC_UP := 1.2
const DROP_PICKUP_DELAY := 1.0

var world: VoxelWorld
var spawn_point := Vector3.ZERO

var item_registry: ItemRegistry
var inventory: Inventory
## 掉落实体管理器（主场景注入；为空时掉落兜底直接入包，独立场景可用）
var drop_manager: DropManager

var selected_index := 0
var _pitch := 0.0
## 背包界面打开时暂停交互（移动仍可用）。
var inventory_open := false

# 挖掘进度状态（目标方块切换/松开左键即重置）
var _mine_active := false
var _mine_target := Vector3i.ZERO
var _mine_elapsed := 0.0
var _mine_seconds := 0.0
var _mine_drops := false

# UI 引用
@onready var camera: Camera3D = $Camera
var _hotbar_panel: PanelContainer
var _slot_panels: Array[Panel] = []
var _slot_icons: Array[TextureRect] = []
var _slot_counts: Array[Label] = []
var _item_label: Label
var _progress_bar: ColorRect
var _progress_fill: ColorRect
var _inventory_screen: Control
var _inv_slot_panels: Array[Panel] = []
var _inv_slot_icons: Array[TextureRect] = []
var _inv_slot_counts: Array[Label] = []
## 背包界面里被拿起的堆（跟随鼠标），-1 = 未拿起。
var _cursor_stack := {"item_id": -1, "count": 0}
var _cursor_icon: TextureRect
var _cursor_count: Label
## 水下全屏色调（v4 水世界）
var _underwater_tint: ColorRect


func _ready() -> void:
	camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	camera.make_current()
	inventory = Inventory.new(item_registry, TOTAL_SLOTS, HOTBAR_SLOTS)
	inventory.changed.connect(_refresh_hud)
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
		elif inventory_open and _cursor_icon != null:
			_cursor_icon.global_position = \
					_cursor_icon.get_global_mouse_position() - Vector2(16, 16)
			_cursor_count.global_position = \
					_cursor_count.get_global_mouse_position() - Vector2(4, 4)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 未锁定时第一次点击仅锁定视角，不触发挖掘
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
						and not inventory_open:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			MOUSE_BUTTON_RIGHT:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
						and not inventory_open:
					_try_place()
			MOUSE_BUTTON_WHEEL_UP:
				if not inventory_open:
					_cycle_selection(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if not inventory_open:
					_cycle_selection(1)
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_E:
				_toggle_inventory()
			KEY_Q:
				# Q 扔 1 个，Ctrl+Q 扔整堆（背包界面打开时不响应）
				if not inventory_open:
					_drop_held(event.ctrl_pressed)
			KEY_ESCAPE:
				if inventory_open:
					_toggle_inventory()
				else:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, \
			KEY_6, KEY_7, KEY_8, KEY_9, KEY_0:
				if not inventory_open:
					_select(_key_to_slot(event.keycode))


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
	velocity.x = motion.x
	velocity.z = motion.z
	if deep_water:
		# 游泳：弱重力 + 缓沉，Space 上浮；水上跳出由跳速衰减自然处理。
		# 玩家不被水流冲走（用户决策）：只有掉落物会被水流冲向下游
		velocity.y = maxf(velocity.y - WATER_GRAVITY * delta, -WATER_TERMINAL)
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = move_toward(velocity.y, SWIM_UP_SPEED, 24.0 * delta)
	elif not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = JUMP_VELOCITY
	move_and_slide()
	_update_underwater_tint()


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
	var leftover := inventory.add(item_id, count)
	if leftover > 0:
		push_warning("背包已满，%d 个物品丢失" % leftover)


## 玩家身边丢弃一堆物品（关背包时手中还有堆）。返回是否成功落地。
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
	if inventory.is_empty(selected_index):
		return
	var count := inventory.count_at(selected_index) if whole_stack else 1
	var item_id := inventory.item_id_at(selected_index)
	inventory.remove_at(selected_index, count)
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


func _held_tool() -> Dictionary:
	if item_registry == null or inventory == null:
		return {}
	return item_registry.tool_for(inventory.item_id_at(selected_index))


# ---- 放置（消耗手持物品）----

func _try_place() -> void:
	if inventory.is_empty(selected_index):
		return
	var block_id := item_registry.place_block_id(
			inventory.item_id_at(selected_index))
	if block_id < 0:
		return  # 手持的不是放置类物品（工具/材料）
	var hit := _raycast_from_camera()
	if hit.hit and hit.normal != Vector3i.ZERO \
			and BlockPlacement.place(
					world,
					hit.block_pos + hit.normal,
					block_id,
					_player_aabb(),
					hit.normal):
		inventory.remove_at(selected_index, 1)


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


# ---- 选择 ----

func _key_to_slot(keycode: int) -> int:
	if keycode == KEY_0:
		return 9
	return keycode - KEY_1


func _select(index: int) -> void:
	selected_index = clampi(index, 0, HOTBAR_SLOTS - 1)
	_refresh_hud()


func _cycle_selection(direction: int) -> void:
	selected_index = posmod(selected_index + direction, HOTBAR_SLOTS)
	_refresh_hud()


# ---- HUD 构建（纯代码，与项目无外部资源约定一致）----

func _build_hud() -> void:
	var hud: CanvasLayer = $HUD

	# 快捷栏：底部中心一排。显式锚点矩形——MINSIZE 预设在 _ready 时
	# 容器尚未布局出最小尺寸，会得到 0 尺寸把槽位全部压扁。
	_hotbar_panel = PanelContainer.new()
	var hb_style := StyleBoxFlat.new()
	hb_style.bg_color = Color(0.06, 0.06, 0.08, 0.55)
	hb_style.set_corner_radius_all(6)
	hb_style.set_content_margin_all(4)
	_hotbar_panel.add_theme_stylebox_override("panel", hb_style)
	var hb_width := HOTBAR_SLOTS * SLOT_PIXELS + (HOTBAR_SLOTS - 1) * 4 + 8
	var hb_height := SLOT_PIXELS + 8
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
	for i in HOTBAR_SLOTS:
		var slot := _make_slot_panel(i == selected_index)
		slot.add_child(_make_slot_icon())
		var count := _make_count_label()
		slot.add_child(count)
		row.add_child(slot)
		_slot_panels.append(slot)
		_slot_icons.append(slot.get_child(0))
		_slot_counts.append(count)

	# 手持物品名：快捷栏上方
	_item_label = Label.new()
	_item_label.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE)
	_item_label.offset_top -= SLOT_PIXELS + 40
	_item_label.offset_bottom -= SLOT_PIXELS + 40
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


func _make_slot_panel(selected: bool) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(SLOT_PIXELS, SLOT_PIXELS)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.65)
	style.set_corner_radius_all(4)
	style.set_border_width_all(2)
	style.border_color = Color(1, 0.9, 0.4) if selected else Color(0.5, 0.5, 0.55)
	panel.add_theme_stylebox_override("panel", style)
	return panel


## 槽位图标：四边内缩 4px，不遮挡槽位边框（选中高亮）与圆角。
func _make_slot_icon() -> TextureRect:
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
	label.offset_left = -24
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
	for i in HOTBAR_SLOTS:
		_apply_slot_display(
				_slot_panels[i], _slot_icons[i], _slot_counts[i],
				inventory.slot(i))
		var style: StyleBoxFlat = _slot_panels[i].get_theme_stylebox("panel")
		style.border_color = Color(1, 0.9, 0.4) if i == selected_index \
				else Color(0.5, 0.5, 0.55)
	if inventory.is_empty(selected_index):
		_item_label.text = ""
	else:
		_item_label.text = item_registry.display_name(
				inventory.item_id_at(selected_index))
	if _inventory_screen != null and is_instance_valid(_inventory_screen):
		_refresh_inventory_screen()


func _apply_slot_display(
		panel: Panel, icon: TextureRect, count: Label, stack: Dictionary) -> void:
	if stack.is_empty():
		icon.texture = null
		count.text = ""
		return
	icon.texture = ItemIcons.icon_for(
			int(stack["item_id"]), item_registry)
	count.text = str(stack["count"]) if int(stack["count"]) > 1 else ""


# ---- 背包界面（E 开关；点击拿起/放下/交换/合并堆）----

func _build_inventory_screen(hud: CanvasLayer) -> void:
	_inventory_screen = Control.new()
	_inventory_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inventory_screen.visible = false
	_inventory_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(_inventory_screen)

	# 半透明遮罩：点击空白不做事，仅视觉聚焦
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.35)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inventory_screen.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inventory_screen.add_child(center)
	var frame := PanelContainer.new()
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.1, 0.1, 0.13, 0.92)
	frame_style.set_corner_radius_all(6)
	frame_style.set_content_margin_all(12)
	frame.add_theme_stylebox_override("panel", frame_style)
	center.add_child(frame)
	var layout := HBoxContainer.new()
	layout.add_theme_constant_override("separation", 16)
	frame.add_child(layout)

	# -- 左：合成面板（配方列表，点击合成一次）--
	layout.add_child(_build_crafting_panel())
	# -- 右：物品格 --
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	layout.add_child(grid)
	for i in TOTAL_SLOTS:
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(SLOT_PIXELS, SLOT_PIXELS)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.14, 0.14, 0.17, 0.9)
		style.set_corner_radius_all(4)
		slot.add_theme_stylebox_override("panel", style)
		var icon := _make_slot_icon()
		slot.add_child(icon)
		var count := _make_count_label()
		slot.add_child(count)
		var index := i
		slot.gui_input.connect(_on_inventory_slot_input.bind(index))
		grid.add_child(slot)
		_inv_slot_panels.append(slot)
		_inv_slot_icons.append(icon)
		_inv_slot_counts.append(count)

	# 跟随鼠标的"手中堆"
	_cursor_icon = TextureRect.new()
	_cursor_icon.custom_minimum_size = Vector2(SLOT_PIXELS, SLOT_PIXELS)
	_cursor_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cursor_icon.stretch_mode = TextureRect.STRETCH_SCALE
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.z_index = 10
	_cursor_icon.visible = false
	_inventory_screen.add_child(_cursor_icon)
	_cursor_count = _make_count_label()
	_cursor_count.z_index = 11
	_cursor_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_count.visible = false
	_inventory_screen.add_child(_cursor_count)


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


func _refresh_inventory_screen() -> void:
	for i in TOTAL_SLOTS:
		_apply_slot_display(
				_inv_slot_panels[i], _inv_slot_icons[i], _inv_slot_counts[i],
				inventory.slot(i))
	_refresh_crafting()
	_refresh_cursor_stack()


func _refresh_cursor_stack() -> void:
	var carrying: bool = int(_cursor_stack["item_id"]) >= 0
	_cursor_icon.visible = carrying
	_cursor_count.visible = carrying
	if carrying:
		_cursor_icon.texture = ItemIcons.icon_for(
				int(_cursor_stack["item_id"]), item_registry)
		_cursor_count.text = str(_cursor_stack["count"]) \
				if int(_cursor_stack["count"]) > 1 else ""
		_cursor_icon.global_position = \
				_cursor_icon.get_global_mouse_position() - Vector2(16, 16)
		_cursor_count.global_position = \
				_cursor_count.get_global_mouse_position() - Vector2(4, 4)


func _on_inventory_slot_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if _cursor_stack["item_id"] < 0:
		# 拿起整堆
		if not inventory.is_empty(index):
			_cursor_stack = {
				"item_id": inventory.item_id_at(index),
				"count": inventory.count_at(index),
			}
			inventory.remove_at(index, inventory.count_at(index))
	else:
		var cursor_id := int(_cursor_stack["item_id"])
		if inventory.is_empty(index):
			# 放下整堆
			inventory.add(cursor_id, int(_cursor_stack["count"]))
			_cursor_stack = {"item_id": -1, "count": 0}
		elif inventory.item_id_at(index) == cursor_id:
			# 同类并入（放不下的留在手中）
			var space := item_registry.max_stack(cursor_id) \
					- inventory.count_at(index)
			var moved := mini(space, int(_cursor_stack["count"]))
			if moved > 0:
				inventory.add(cursor_id, moved)
				_cursor_stack["count"] = int(_cursor_stack["count"]) - moved
				if int(_cursor_stack["count"]) <= 0:
					_cursor_stack = {"item_id": -1, "count": 0}
		else:
			# 交换：手中堆与槽内堆互换
			var old: Dictionary = {
				"item_id": inventory.item_id_at(index),
				"count": inventory.count_at(index),
			}
			inventory.remove_at(index, old["count"])
			inventory.add(cursor_id, int(_cursor_stack["count"]))
			_cursor_stack = old
	_refresh_hud()


func _toggle_inventory() -> void:
	inventory_open = not inventory_open
	_inventory_screen.visible = inventory_open
	if inventory_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh_inventory_screen()
	else:
		# 关闭时若手中还有堆：丢到身边地面（实体层可用），
		# 否则放回背包（放不下则丢失并告警）
		if _cursor_stack["item_id"] >= 0:
			var held_id := int(_cursor_stack["item_id"])
			var held_count := int(_cursor_stack["count"])
			if not _scatter_at_player(held_id, held_count):
				var leftover := inventory.add(held_id, held_count)
				if leftover > 0:
					push_warning("背包已满，%d 个物品丢失" % leftover)
			_cursor_stack = {"item_id": -1, "count": 0}
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_reset_mining()


func _process(_delta: float) -> void:
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
		"selected_index": selected_index,
		"inventory": inventory.serialize(),
	}


## 从存档恢复（在已入树、脚下区块已预热后调用）。
## 旧档无 inventory 键：给起始装备（物品层上线时刻的迁移语义）。
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
	_select(int(state.get("selected_index", selected_index)))
