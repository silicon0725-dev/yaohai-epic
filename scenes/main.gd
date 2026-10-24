## Stage D 主场景：无限流式体素世界 + 增量存档
##（开发文档 §12 阶段 D；交付物：可持续游玩的体素世界存档）。
## 启动时读取 world.json 恢复种子/配置/玩家状态；运行中 ChunkManager
## 卸载修改区块即落盘、定时自动保存、退出时全量写盘（§9.2）。
extends Node3D

const PLAYER_SCENE := preload("res://player/player.tscn")

const WORLD_SEED := 1337
## 默认存档目录（集成检查可改写 save_root 隔离）。
const DEFAULT_SAVE_ROOT := "user://saves/world1"
## 默认出生点（世界方块坐标，仅新世界使用；老世界用存档位置）。
const SPAWN_BLOCK := Vector2i(34, 34)

var save_root := DEFAULT_SAVE_ROOT
var greedy_meshing_requested := false

var config: WorldConfig
var registry: VoxelRegistry
var item_registry: ItemRegistry
var world: VoxelWorld
var generator: TerrainGenerator
var chunk_renderer: ChunkRenderer
var chunk_manager: ChunkManager
var drop_manager: DropManager
var water_flow: WaterFlow
var tree_manager: Node  # TreeManager（preload 绕开类缓存）
const TreeManagerScript := preload("res://systems/trees/tree_manager.gd")
var water_ripples: Node  # WaterRipples（preload 绕开类缓存）
const WaterRipplesScript := preload("res://world/water_ripples.gd")
var save_system: WorldSave
var player: PlayerController

var _hud_label: Label
var _hud_accumulator := 0.0
## CPU/GPU 同源波时钟（OceanWaves.global_time 的本地镜像）
var _wave_clock := 0.0
const OceanWavesScript := preload("res://presentation/ocean_waves.gd")


func _ready() -> void:
	registry = VoxelTypes.build_default_registry()
	item_registry = ItemTypes.build_default_item_registry(registry)
	save_system = WorldSave.new(save_root, registry)

	# 读档优先：种子/配置/玩家状态来自存档（§9.1）
	config = WorldConfig.new()
	var player_state := {}
	var meta := save_system.load_meta()
	if meta.is_empty():
		config.world_seed = WORLD_SEED
	else:
		config.world_seed = int(meta.get("world_seed", WORLD_SEED))
		var saved_config: Dictionary = meta.get("world_config", {})
		config.chunk_size = int(saved_config.get("chunk_size", config.chunk_size))
		config.chunks_y = int(saved_config.get("chunks_y", config.chunks_y))
		if not SaveMigrations.is_generator_current(meta):
			push_warning("存档生成算法版本与当前不同：未修改区域将用新算法重建（§5.1）")
		player_state = meta.get("player_state", {})

	world = VoxelWorld.new(config, registry)
	generator = TerrainGenerator.new(config)

	# --greedy 命令行参数切换网格算法（§6.3 对比/测试用）
	for arg in OS.get_cmdline_user_args():
		if arg == "--greedy":
			greedy_meshing_requested = true

	var atlas := TextureAtlasLoader.generate_atlas_texture()
	ItemIcons.set_atlas(TextureAtlasLoader.generate_atlas_image())
	DropVisuals.configure(atlas)
	var materials := VoxelMaterialRegistry.new(atlas)
	chunk_renderer = ChunkRenderer.new()
	add_child(chunk_renderer)
	var terrain_material: Material
	if greedy_meshing_requested:
		terrain_material = materials.create_greedy_material(atlas)
	else:
		terrain_material = materials.material_for("opaque")
	chunk_renderer.setup(world, terrain_material)
	chunk_renderer.water_material = materials.create_water_material()
	chunk_renderer.water_side_material = materials.create_water_side_material()

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(world, registry, generator, chunk_renderer)
	chunk_manager.use_greedy_meshing = greedy_meshing_requested
	chunk_manager.save_system = save_system

	# 掉落实体层：挖掘产物落地、磁吸自动拾取，随 world.json 持久化
	drop_manager = DropManager.new()
	add_child(drop_manager)
	drop_manager.setup(world, item_registry)
	drop_manager.apply_save_state(meta.get("drops", []))
	# extra_meta_provider 在树系统接线处统一设置

	# 结构化树系统：独立网格树干 + 引用计数生命周期 + 砍伐
	tree_manager = TreeManagerScript.new()
	add_child(tree_manager)
	tree_manager.setup(world, registry, item_registry)
	tree_manager.apply_save_state(meta)
	tree_manager.drop_spawner = func(item_id: int, count: int, pos: Vector3) -> void:
		drop_manager.spawn_drop(item_id, count, pos)
	chunk_manager.on_chunk_active_cb = tree_manager.on_chunk_active
	chunk_manager.on_chunk_unloaded_cb = tree_manager.on_chunk_unloaded
	chunk_manager.extra_meta_provider = _tree_and_drops_bundle
	BlockMining.tree_callback = tree_manager.on_branch_broken

	# 水流动模拟：挖掘/放置扰动水位元胞自动机（v2）
	water_flow = WaterFlow.new()
	add_child(water_flow)
	water_flow.setup(world)

	# 互动涟漪（Physics Mod 波动方程模拟的移植）：玩家/掉落物扰动水面
	water_ripples = WaterRipplesScript.new()
	add_child(water_ripples)

	_setup_environment()

	# 预热出生/存档位置的区块列，再放置玩家
	var spawn_block := SPAWN_BLOCK
	if player_state.has("position"):
		var saved_position: Array = player_state["position"]
		if saved_position.size() == 3:
			spawn_block = Vector2i(
					int(saved_position[0]), int(saved_position[2]))
	else:
		# 新世界：固定出生点可能在海里——螺旋外扩找海平面以上的陆地列
		spawn_block = _find_land_spawn(spawn_block)
	var spawn_column := Vector2i(
			VoxelCoords.floordiv(spawn_block.x, config.chunk_size),
			VoxelCoords.floordiv(spawn_block.y, config.chunk_size))
	chunk_manager.load_column_now(spawn_column)

	_spawn_player(spawn_block)
	if not player_state.is_empty():
		player.apply_save_state(player_state)
	else:
		# 新世界：起始装备（旧档迁移在 apply_save_state 内处理）
		player.inventory.apply_starting_kit(ItemTypes.STARTING_KIT)
	chunk_manager.player_state_provider = player.get_save_state
	chunk_manager.focus = player
	_setup_hud()


func _process(delta: float) -> void:
	# 波时钟推进 + 同步到水面 shader（CPU 采样与 GPU 渲染同源）
	_wave_clock += delta
	OceanWavesScript.global_time = _wave_clock
	if chunk_renderer != null:
		for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
			if mat != null:
				mat.set_shader_parameter("u_time", _wave_clock)
				mat.set_shader_parameter("storm_scale",
						OceanWavesScript.storm_scale)
	_update_ripples(delta)
	_hud_accumulator += delta


## 涟漪：窗口中心跟随玩家；玩家与掉落物在水中移动/入水注入冲量
##（Physics Mod 的实体扰动，玩家按速度掉落物按入水与移动）。
func _update_ripples(_delta: float) -> void:
	if water_ripples == null or player == null:
		return
	water_ripples.center = Vector2(
			player.global_position.x, player.global_position.z)
	# 冲量源：水中且在动的玩家
	var feet := Vector3i(
			floori(player.global_position.x),
			floori(player.global_position.y - 1.0),
			floori(player.global_position.z))
	if world.get_block(feet) == VoxelTypes.WATER_ID:
		var hv := Vector2(player.velocity.x, player.velocity.z).length()
		if hv > 0.5:
			water_ripples.add_impulse(
					Vector2(player.global_position.x, player.global_position.z),
					clampf(hv * 0.12, 0.05, 0.5), 0.5)
		if player.velocity.y < -3.0:  # 落水冲击
			water_ripples.add_impulse(
					Vector2(player.global_position.x, player.global_position.z),
					0.8, 0.9)
	# 冲量源：水中掉落物（入水冲击 + 漂流尾迹）
	for drop in drop_manager.drops():
		if not drop.in_water:
			continue
		var pos_xz := Vector2(drop.position.x, drop.position.z)
		if drop.splash_pending:
			# 入水冲击：强度随落速，大水花
			water_ripples.add_impulse(pos_xz,
					clampf(-drop.velocity.y * 0.15, 0.3, 0.9), 0.9)
			drop.splash_pending = false
		# 漂流尾迹：移动才注入（静止漂浮物不持续扰动水面）
		elif Vector2(drop.velocity.x, drop.velocity.z).length() > 0.3:
			water_ripples.add_impulse(pos_xz, 0.12, 0.4)
	# 同步涟漪纹理与窗口参数到水面材质
	for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
		if mat != null:
			mat.set_shader_parameter("ripple_map", water_ripples.texture())
			mat.set_shader_parameter("ripple_center",
					water_ripples.texture_center())
			mat.set_shader_parameter("ripple_window", WaterRipplesScript.WINDOW)
	if _hud_accumulator < 0.25 or _hud_label == null:
		return
	_hud_accumulator = 0.0
	_hud_label.text = "\n".join([
		"Voxel Terrain MVP - Items Layer (inventory + tools + ground drops)",
		"chunks: %d    faces: %d    in-flight: %d    saved: %d    drops: %d" % [
			world.chunk_count(), chunk_renderer.total_faces,
			chunk_manager.in_flight_count(),
			save_system.saved_chunk_count(), drop_manager.drop_count()],
		"seed: %d    view: %d chunks (r)    world: infinite horizontal" % [
			config.world_seed, chunk_manager.view_distance],
		"Hold LMB mine (drops to ground) | walk over to auto-pickup | RMB place",
		"Q drop held | Ctrl+Q drop stack | 1-9,0/wheel select | E inventory",
		"WASD move | Space jump | Shift sprint",
	])


func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	# 水面波纹 shader 的太阳方向（UNSHADED 光照不进 shader，手动传）
	var sun_dir: Vector3 = -sun.global_transform.basis.z.normalized()
	for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
		if mat == null:
			continue
		mat.set_shader_parameter("sun_direction", sun_dir)
	_wave_clock = 0.0

	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 1.0
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)


## 从候选点螺旋外扩，找海平面以上的陆地列（v4 起世界有海洋）。
func _find_land_spawn(start: Vector2i) -> Vector2i:
	if generator.column_height(start.x, start.y) > TerrainGenerator.SEA_LEVEL:
		return start
	for radius in range(1, 24):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := start.x + int(round(cos(ang) * radius * 8.0))
			var cz := start.y + int(round(sin(ang) * radius * 8.0))
			if generator.column_height(cx, cz) > TerrainGenerator.SEA_LEVEL:
				return Vector2i(cx, cz)
	push_warning("出生点 24 圈内未找到陆地，使用原出生点（可能落水）")
	return start


func _spawn_player(spawn_block: Vector2i) -> void:
	player = PLAYER_SCENE.instantiate()
	player.world = world
	# 物品注册表必须在 add_child（触发 _ready 建背包/HUD）之前注入
	player.item_registry = item_registry
	player.drop_manager = drop_manager
	add_child(player)
	drop_manager.pickup_target = player
	drop_manager.pickup_inventory = player.inventory
	# 脚 = 出生列最高实心方块顶面 +1（预热后数据已就绪）
	var surface := 0
	for y in range(config.world_height_blocks() - 1, -1, -1):
		if registry.is_solid(world.get_block(Vector3i(spawn_block.x, y, spawn_block.y))):
			surface = y
			break
	# 脚部离地半格出生：避免与地面零间隙接触（流式重建替换
	# 碰撞形状的瞬间可能丢失接触导致穿模）
	player.global_position = Vector3(
			spawn_block.x + 0.5, surface + 2.5, spawn_block.y + 0.5)
	player.spawn_point = player.global_position


func _setup_hud() -> void:
	# 默认字体不含 CJK 字形，HUD 使用英文避免显示为方框。
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = Label.new()
	_hud_label.position = Vector2(12, 10)
	_hud_label.add_theme_font_size_override("font_size", 16)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(_hud_label)


## 树 + 掉落物合并 bundle（extra_meta_provider）。
func _tree_and_drops_bundle() -> Dictionary:
	var bundle := drop_manager.get_save_bundle()
	if tree_manager != null:
		bundle.merge(tree_manager.get_save_bundle())
	return bundle
