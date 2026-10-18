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
var save_system: WorldSave
var player: PlayerController

var _hud_label: Label
var _hud_accumulator := 0.0


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
	var materials := VoxelMaterialRegistry.new(atlas)
	chunk_renderer = ChunkRenderer.new()
	add_child(chunk_renderer)
	var terrain_material: Material
	if greedy_meshing_requested:
		terrain_material = materials.create_greedy_material(atlas)
	else:
		terrain_material = materials.material_for("opaque")
	chunk_renderer.setup(world, terrain_material)

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(world, registry, generator, chunk_renderer)
	chunk_manager.use_greedy_meshing = greedy_meshing_requested
	chunk_manager.save_system = save_system

	_setup_environment()

	# 预热出生/存档位置的区块列，再放置玩家
	var spawn_block := SPAWN_BLOCK
	if player_state.has("position"):
		var saved_position: Array = player_state["position"]
		if saved_position.size() == 3:
			spawn_block = Vector2i(
					int(saved_position[0]), int(saved_position[2]))
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
	_hud_accumulator += delta
	if _hud_accumulator < 0.25 or _hud_label == null:
		return
	_hud_accumulator = 0.0
	_hud_label.text = "\n".join([
		"Voxel Terrain MVP - Items Layer (inventory + tools + drops)",
		"chunks: %d    faces: %d    in-flight: %d    saved: %d" % [
			world.chunk_count(), chunk_renderer.total_faces,
			chunk_manager.in_flight_count(),
			save_system.saved_chunk_count()],
		"seed: %d    view: %d chunks (r)    world: infinite horizontal" % [
			config.world_seed, chunk_manager.view_distance],
		"Hold LMB mine | RMB place (uses item) | 1-9,0/wheel select | E inventory",
		"WASD move | Space jump | Shift sprint | Esc release mouse",
	])


func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

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


func _spawn_player(spawn_block: Vector2i) -> void:
	player = PLAYER_SCENE.instantiate()
	player.world = world
	# 物品注册表必须在 add_child（触发 _ready 建背包/HUD）之前注入
	player.item_registry = item_registry
	add_child(player)
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
