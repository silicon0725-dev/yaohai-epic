## Stage D 主场景：无限流式体素世界 + 增量存档
##（开发文档 §12 阶段 D；交付物：可持续游玩的体素世界存档）。
## 启动时读取 world.json 恢复种子/配置/玩家状态；运行中 ChunkManager
## 卸载修改区块即落盘、定时自动保存、退出时全量写盘（§9.2）。
extends Node3D

const PLAYER_SCENE := preload("res://player/player.tscn")
const NativeTerrainBridgeRef := preload("res://meshing/native_terrain_bridge.gd")

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
var voxel_light: Node  # VoxelLightSystem（preload 绕开类缓存）
var cave_fog: Node  # 洞口体积雾管理器（preload 绕开类缓存）
const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
var tree_manager: Node  # TreeManager（preload 绕开类缓存）
const TreeManagerScript := preload("res://systems/trees/tree_manager.gd")
var water_ripples: Node  # WaterRipples（preload 绕开类缓存）
const WaterRipplesScript := preload("res://world/water_ripples.gd")
var save_system: WorldSave
var player: PlayerController
var water_reflection: Node  # 水面镜像反射（preload 绕开类缓存）
## 主场景 Environment（镜像相机 SubViewport 需自己的环境光/天空——
## 环境按 viewport 划分，共享同一资源即可）
var _environment: Environment

var _hud_label: Label
var _hud_accumulator := 0.0
## CPU/GPU 同源波时钟（OceanWaves.global_time 的本地镜像）
var _wave_clock := 0.0
var _last_storm_scale := -1.0  # uniform 脏检查（storm 变化才重发）
var _last_ripple_tex = null  # 涟漪纹理/中心脏检查
var _last_ripple_center = null
const OceanWavesScript := preload("res://presentation/ocean_waves.gd")

## 加载阶段（预生成 + 预加载 + 加载界面）：进入游戏前把初始视距
## 全部生成并网格化（预算放宽），is_idle 达成后淡出释放玩家——
## 消除"进游戏头几秒边走边卡"
const LoadingOverlayScript := preload("res://presentation/loading_overlay.gd")
## 加载期放宽的管线预算（无游戏渲染压力，提交可以放开吃）
const LOAD_GEN_BUDGET := 32
const LOAD_MESH_BUDGET := 12
const LOAD_MAX_IN_FLIGHT := 64
## 最短展示时长（防闪屏）与总超时（防卡死进不去）
const LOAD_MIN_TIME := 0.8
const LOAD_TIMEOUT := 45.0

var _loading := false
var _loading_time := 0.0
var _loading_target := 1
var _loading_overlay = null  # LoadingOverlay（preload 无类型）


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
	# C# 桥主线程预热（探测 + 建 NativeTerrain/tile 表缓存）——worker
	# 首调并发写静态字典的竞态在启动突发期可致哈希表损坏（审查发现）
	NativeTerrainBridgeRef.prewarm(
			config.world_seed, config.world_height_blocks())
	NativeMeshBridge.prewarm(registry)

	# --greedy 命令行参数切换网格算法（§6.3 对比/测试用）
	for arg in OS.get_cmdline_user_args():
		if arg == "--greedy":
			greedy_meshing_requested = true

	var atlas_image := TextureAtlasLoader.generate_atlas_image()
	ItemIcons.set_atlas(atlas_image)
	var atlas := TextureAtlasLoader.texture_from_image(atlas_image)
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
	chunk_renderer.cutout_material = materials.material_for("cutout")

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
	# 掉落物撞得上树干：掉落走体素碰撞感知不到树 StaticBody，
	# 主干实心由树管理器实时查询补齐（枝干无碰撞，与玩家一致）
	drop_manager.trunk_solid_probe = tree_manager.is_solid_for_items
	chunk_manager.on_chunk_active_cb = tree_manager.on_chunk_active
	chunk_manager.on_chunk_unloaded_cb = tree_manager.on_chunk_unloaded
	chunk_manager.extra_meta_provider = _tree_and_drops_bundle

	# 水流动模拟：挖掘/放置扰动水位元胞自动机（v2）
	water_flow = WaterFlow.new()
	add_child(water_flow)
	water_flow.setup(world)

	# 体素光照（光照阶段 2）：天光/方块光传播 + 挖掘放置局部失效，
	# 光照变化经 mesh_dirty 走现有重网格管线
	voxel_light = VoxelLightScript.new()
	add_child(voxel_light)
	voxel_light.setup(world)
	chunk_manager.light_init_cb = voxel_light.init_chunk_light
	chunk_manager.on_chunk_data_ready_cb = voxel_light.on_chunk_ready

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
	_begin_loading()


## 进入加载阶段：冻结玩家（输入/物理停摆，渲染保持），放宽管线
## 预算预生成+预网格初始视距，进度条由 _loading_tick 驱动。
var _saved_budgets := {}  # 加载期放宽的预算，结束时原样恢复
func _begin_loading() -> void:
	_loading = true
	_loading_time = 0.0
	var spawn_col := Vector2i(
			VoxelCoords.floordiv(
					int(player.global_position.x), config.chunk_size),
			VoxelCoords.floordiv(
					int(player.global_position.z), config.chunk_size))
	var columns := ChunkManager.desired_columns(
			spawn_col, chunk_manager.view_distance)
	_loading_target = maxi(1, columns.size() * config.chunks_y)
	_saved_budgets = {
		"gen": chunk_manager.gen_commit_budget,
		"mesh": chunk_manager.mesh_commit_budget,
		"inflight": chunk_manager.max_in_flight,
	}
	chunk_manager.gen_commit_budget = LOAD_GEN_BUDGET
	chunk_manager.mesh_commit_budget = LOAD_MESH_BUDGET
	chunk_manager.max_in_flight = LOAD_MAX_IN_FLIGHT
	player.process_mode = Node.PROCESS_MODE_DISABLED
	_loading_overlay = LoadingOverlayScript.new()
	add_child(_loading_overlay)


## 加载推进：统计已激活区块占比；is_idle 且超过最短展示时长即完成。
## 超时兜底强制进入（带告警——单任务卡死不应锁死玩家）。
func _loading_tick(delta: float) -> void:
	_loading_time += delta
	var active := 0
	for coord in world.chunks:
		if world.chunks[coord].state == ChunkState.State.ACTIVE:
			active += 1
	var pct := clampf(float(active) / float(_loading_target), 0.0, 1.0)
	var phase := "生成地形与构建网格…  %d / %d" % [active, _loading_target]
	if chunk_manager.in_flight_count() == 0 and active >= _loading_target:
		phase = "即将进入世界…"
	_loading_overlay.set_progress(pct, phase)
	var idle_reached: bool = chunk_manager.in_flight_count() == 0 \
			and active >= _loading_target
	if (idle_reached and _loading_time >= LOAD_MIN_TIME) \
			or _loading_time >= LOAD_TIMEOUT:
		if not idle_reached:
			push_warning("加载超时（%.1fs，就绪 %d/%d），强制进入" % [
				_loading_time, active, _loading_target])
		_finish_loading()


## 加载完成：恢复管线预算、释放玩家、淡出界面。
func _finish_loading() -> void:
	_loading = false
	# 恢复 _begin_loading 存下的原值（曾硬编码 8/3/32 与
	# ChunkManager 默认值重复定义——改一处必漏一处）
	chunk_manager.gen_commit_budget = int(_saved_budgets.get("gen", 8))
	chunk_manager.mesh_commit_budget = int(_saved_budgets.get("mesh", 3))
	chunk_manager.max_in_flight = int(_saved_budgets.get("inflight", 32))
	player.process_mode = Node.PROCESS_MODE_INHERIT
	var overlay = _loading_overlay
	_loading_overlay = null
	if overlay != null:
		overlay.finish()


func _process(delta: float) -> void:
	# 波时钟推进 + 同步到水面 shader（CPU 采样与 GPU 渲染同源）；
	# storm_scale 当前恒 1.0，只在变化时重发（每帧 4 次 uniform 重发
	# 是无谓开销——审查发现）
	_wave_clock += delta
	OceanWavesScript.global_time = _wave_clock
	if chunk_renderer != null:
		var storm := OceanWavesScript.storm_scale
		for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
			if mat != null:
				mat.set_shader_parameter("u_time", _wave_clock)
				if storm != _last_storm_scale:
					mat.set_shader_parameter("storm_scale", storm)
		if storm != _last_storm_scale:
			_last_storm_scale = storm
	_update_ripples(delta)
	_hud_accumulator += delta
	if _loading:
		_loading_tick(delta)
	_update_hud()
	_update_exposure(delta)


## 眼适应（iterationT 式人眼明暗适应；Godot 4 无内建自动曝光——
## 用玩家所在格的体素光照近似画面亮度驱动 tonemap_exposure，
## 零 GPU 回读）。露天光足时曝光 1.0（已验收观感不动），洞内平滑
## 抬到 EXPOSURE_MAX_LIFT；平滑速率 ~1.2/s 对应 iterationT 的
## SMOOTH_EXPOSURE 1.0s。口味旋钮（var 供 capture/测试调）：嫌洞内
## 变亮就把 MAX_LIFT 调回 1.0
var EXPOSURE_MAX_LIFT := 2.2
const EXPOSURE_SPEED := 1.2
var _exposure := 1.0
func _update_exposure(delta: float) -> void:
	if player == null or _environment == null:
		return
	var cell := Vector3i(
			floori(player.global_position.x),
			floori(player.global_position.y),
			floori(player.global_position.z))
	var chunk: ChunkData = world.chunks.get(
			VoxelCoords.world_to_chunk(cell, config.chunk_size))
	if chunk == null:
		return
	var local := VoxelCoords.world_to_local(cell, config.chunk_size)
	var light_level := float(maxi(
			chunk.get_sky_light(local), chunk.get_block_light(local))) / 15.0
	var t := smoothstep(0.15, 0.7, light_level)
	var target := lerpf(EXPOSURE_MAX_LIFT, 1.0, t)
	_exposure = lerpf(_exposure, target, 1.0 - exp(-EXPOSURE_SPEED * delta))
	_environment.tonemap_exposure = _exposure


## HUD：0.25s 节流刷新统计（曾藏在 _update_ripples 尾部 early-return
## 之后——按函数名拆模块时会漏，审查发现，独立成函数）
func _update_hud() -> void:
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
	# 同步涟漪纹理与窗口参数到水面材质（纹理对象与常量窗口只在变化时
	# 重发——每帧 6 次 uniform 重发是无谓开销，审查发现）
	for mat in [chunk_renderer.water_material, chunk_renderer.water_side_material]:
		if mat != null:
			var rtex = water_ripples.texture()
			if rtex != _last_ripple_tex:
				mat.set_shader_parameter("ripple_map", rtex)
			var rcenter = water_ripples.texture_center()
			if rcenter != _last_ripple_center:
				mat.set_shader_parameter("ripple_center", rcenter)
			mat.set_shader_parameter("ripple_window", WaterRipplesScript.WINDOW)
	_last_ripple_tex = water_ripples.texture()
	_last_ripple_center = water_ripples.texture_center()


func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.2
	# 太阳冷白（BSL lightDay 196,220,255）：白天阳光偏蓝而非中性白
	sun.light_color = Color(196.0 / 255.0, 220.0 / 255.0, 1.0)
	sun.shadow_enabled = true
	# 阴影偏置：默认 bias 0.1 / normal_bias 2.0 会把细窄枝段的投影
	# "推穿"，树影断成一节一节、节间漏光（俯拍对照：地面亮区
	# 13.2%→5.1%）。调低后无自阴影痤疮（体素面是平面，深度偏置
	# 0.02 已够兜底）
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 0.0
	# 体积雾洞口光束：太阳在雾中的散射能量。1.6 = 3.2 / 眼适应抬升
	# 倍率（~2.1×）——曾 3.2 是适应上线前调的，洞内曝光一抬光束过曝
	# 成白团（用户实机"太亮了"）；露天无雾不受此值影响
	sun.light_volumetric_fog_energy = 1.6
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
	# 体素光照（阶段 2，MC 深黑取向）：环境光回调到中等——顶点色
	# 乘在 albedo 上，环境光同样被顶点色缩放：露天阴影区顶点色=1，
	# 亮度由环境光兜底（树影/山影只是稍暗）；洞穴顶点色≈0，环境光
	# 进不去仍近黑。曾压到 0.02 让地表投影过黑（用户实测反馈）
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# BSL 白天环境光比值（120,172,255）→ 同亮度映射（保持平均能量
	# 与旧值一致，只改色相：中性灰蓝 → 明显偏蓝的天空环境光）
	environment.ambient_light_color = Color(0.29, 0.41, 0.61)
	environment.ambient_light_energy = 1.0
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# 体积雾（洞口光束，TG 公式）：全局密度 0——室外保持干净，雾只来自
	# 洞口 FogVolume（cave_fog.gd）；光束由引擎逐 froxel 太阳阴影积分
	# 切出。detail_spread 2.0 + 时间重投影 0.9 防体积网格块状边缘
	#（Sparse-GI TG_ATMOSPHERE 实测：<1 指数近处采样过稀 + 关重投影
	# 无 Halton 抖动 → 网格边界直接出现在光束中，两坑都要避）
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.0
	environment.volumetric_fog_anisotropy = 0.65  # HG 前向散射（逆光光束亮）
	environment.volumetric_fog_length = 48.0
	environment.volumetric_fog_detail_spread = 2.0
	environment.volumetric_fog_temporal_reprojection_enabled = true
	environment.volumetric_fog_temporal_reprojection_amount = 0.9
	environment.volumetric_fog_ambient_inject = 0.0
	environment.volumetric_fog_sky_affect = 0.0
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)
	_environment = environment  # 镜像相机 SubViewport 共用（环境 per-viewport）


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
	_setup_water_reflection()
	_setup_cave_fog()


## 洞口体积雾（光照阶段 2 收尾）：天光数据检测洞口光柱 → 维护洞口
## FogVolume 池，引擎体积雾太阳阴影积分切出光束（公式出处见
## cave_fog.gdshader 头注释）
func _setup_cave_fog() -> void:
	const CaveFogScript := preload("res://systems/lighting/cave_fog.gd")
	cave_fog = CaveFogScript.new()
	add_child(cave_fog)
	cave_fog.setup(world, player)


## 水面平面反射（真镜像相机）：实现拆至 presentation/water_reflection.gd
##（setup + 每帧同步自驱）。历史方案弃用史见该文件头注释与 git 历史。
func _setup_water_reflection() -> void:
	const WaterReflectionScript := preload("res://presentation/water_reflection.gd")
	water_reflection = WaterReflectionScript.new()
	add_child(water_reflection)
	# 反射平面 = 顶层水格 index + 块内水面高（公式单一来源；
	# 曾两处各写常量低 1 格——倒影断层三轮实机反馈的根因）
	water_reflection.setup(
			[chunk_renderer.water_material, chunk_renderer.water_side_material],
			[chunk_renderer.material, chunk_renderer.cutout_material],
			_environment,
			float(TerrainGenerator.SEA_LEVEL)
					+ ChunkMesher.water_surface_height(0))


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
