## Stage D 主场景：无限流式体素世界 + 增量存档
##（开发文档 §12 阶段 D；交付物：可持续游玩的体素世界存档）。
## 启动时读取 world.json 恢复种子/配置/玩家状态；运行中 ChunkManager
## 卸载修改区块即落盘、定时自动保存、退出时全量写盘（§9.2）。
extends Node3D

const PLAYER_SCENE := preload("res://player/player.tscn")
const NativeTerrainBridgeRef := preload("res://meshing/native_terrain_bridge.gd")

const WORLD_SEED := 1337
## 新世界的垂直区块数（512 格高；老存档由 meta 恢复其原值）。
const NEW_WORLD_CHUNKS_Y := 32
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
var torch_renderer: Node  # 火把实体渲染器（preload 绕开类缓存）
var lantern_renderer: Node  # 提灯实体渲染器（模型方块轮）
const VoxelLightScript := preload("res://systems/lighting/voxel_light.gd")
var tree_manager: Node  # TreeManager（preload 绕开类缓存）
const TreeManagerScript := preload("res://systems/trees/tree_manager.gd")
var water_ripples: Node  # WaterRipples（preload 绕开类缓存）
var distant_shell: Node  # DistantShell 远景山壳（preload 绕开类缓存）
const WaterRipplesScript := preload("res://world/water_ripples.gd")
const DistantShellScript := preload("res://presentation/distant_shell.gd")
var sound_manager: Node  # SoundManager（preload 绕开类缓存）
const SoundManagerScript := preload("res://systems/sound/sound_manager.gd")
var weather_system: Node  # WeatherSystem 天气（preload 绕开类缓存）
const WeatherSystemScript := preload("res://systems/weather/weather_system.gd")
var save_system: WorldSave
var player: PlayerController
var water_reflection: Node  # 水面镜像反射（preload 绕开类缓存）
## 主场景 Environment（镜像相机 SubViewport 需自己的环境光/天空——
## 环境按 viewport 划分，共享同一资源即可）
var _environment: Environment
var _sky: Sky  # 日夜循环改 sky_material 颜色

var _hud_label: Label
var _hud_accumulator := 0.0
## CPU/GPU 同源波时钟（OceanWaves.global_time 的本地镜像）
var _wave_clock := 0.0
var _last_storm_scale := -1.0  # uniform 脏检查（storm 变化才重发）
var _last_ripple_tex = null  # 涟漪纹理/中心脏检查
var _last_ripple_center = null
var _ripple_window_sent := false  # 常量窗口首帧一次（D11）
var _hint_text := ""
var _hint_expire := 0.0
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
		config.chunks_y = NEW_WORLD_CHUNKS_Y
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
	chunk_renderer.cross_material = materials.material_for("cutout_cross")

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
	# 砍伐记录→生成器参数链（apply 之后 _cut_events 已载入；砍树后
	# 新入队任务经 provider 拿最新快照——重生成区块按记录剪枝树占位）
	chunk_manager.tree_cuts_provider = func() -> Dictionary:
		return tree_manager.cut_events_by_root()
	tree_manager.drop_spawner = func(item_id: int, count: int, pos: Vector3) -> void:
		if drop_manager.spawn_drop(item_id, count, pos) == null:
			# 掉落实体满 128：直接入背包兜底（与挖掘 _dispatch_drop 同
			# 语义——曾整棵树产物静默丢失，审查 5-F4）
			var leftover: int = player.inventory.add(item_id, count)
			if leftover > 0:
				push_warning("背包已满，%d 个伐木产物丢失" % leftover)
	# 主干动画倒伏倒向砍树的人（DT 语义）
	tree_manager.player_provider = func() -> Node3D:
		return player
	# 光照脏重烘等区块管线空闲（光照传播异步落定）再执行
	tree_manager.idle_check = func() -> bool:
		return chunk_manager.is_idle()
	# 玩家编辑区块插队重网格（放置/挖掘即时反馈）
	world.edit_dirty_cb = chunk_manager._on_player_edit
	# 掉落物撞得上树干：掉落走体素碰撞感知不到树 StaticBody，
	# 主干实心由树管理器实时查询补齐（枝干无碰撞，与玩家一致）
	drop_manager.trunk_solid_probe = tree_manager.is_solid_for_items

	# 声音系统：脚步（程序化材质族）+ 环境音景（MAtmos 式条件流）+
	# 方块交互音；总线运行时创建，headless dummy 全链路安全
	sound_manager = SoundManagerScript.new()
	add_child(sound_manager)
	sound_manager.setup(world, registry)

	const TorchRendererScript := preload("res://presentation/torch_renderer.gd")
	torch_renderer = TorchRendererScript.new()
	add_child(torch_renderer)
	torch_renderer.setup(world, VoxelTypes.TORCH_ID, true)
	lantern_renderer = preload(
			"res://presentation/lantern_renderer.gd").new()
	add_child(lantern_renderer)
	lantern_renderer.setup(world, VoxelTypes.LANTERN_ID)
	# 区块激活/卸载回调分发（单 Callable 槽——树/火把/提灯实体共用）：
	# 火把实体渲染见 presentation/torch_renderer.gd（chunk cross
	# 路径曾用户实机不可见，绕行实体管线）；提灯见 lantern_renderer
	chunk_manager.on_chunk_active_cb = func(coord: Vector3i) -> void:
		tree_manager.on_chunk_active(coord)
		torch_renderer.on_chunk_active(coord)
		lantern_renderer.on_chunk_active(coord)
	chunk_manager.on_chunk_unloaded_cb = func(coord: Vector3i) -> void:
		tree_manager.on_chunk_unloaded(coord)
		torch_renderer.on_chunk_unloaded(coord)
		lantern_renderer.on_chunk_unloaded(coord)
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
	# 光照变化块插队重网格（ef-000001 验收 A：挖掘后明暗即时性）
	voxel_light.mesh_dirty_cb = Callable(chunk_manager,
			"_on_light_mesh_dirty")

	# 互动涟漪（Physics Mod 波动方程模拟的移植）：玩家/掉落物扰动水面
	water_ripples = WaterRipplesScript.new()
	add_child(water_ripples)

	# 天气系统（阶段 1：状态机 + 天空/太阳/环境联动 + 程序化雨声）
	weather_system = WeatherSystemScript.new()
	add_child(weather_system)

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
	# 调试注入（实机验收用）：--give <物品名> <数量>（user args，与
	# --greedy 同机制传参）——例：-- --give core:torch 64。新档旧档
	# 都生效，无参数零副作用
	for i in OS.get_cmdline_user_args().size():
		if OS.get_cmdline_user_args()[i] == "--give" \
				and i + 2 < OS.get_cmdline_user_args().size():
			var args := OS.get_cmdline_user_args()
			var give_id := item_registry.id_for_name(args[i + 1])
			var give_n := int(args[i + 2])
			if give_id >= 0 and give_n > 0:
				var leftover: int = player.inventory.add(give_id, give_n)
				print("[give] %s ×%d 入包（背包满剩 %d）" % [
					args[i + 1], give_n, leftover])
	chunk_manager.player_state_provider = player.get_save_state
	chunk_manager.focus = player
	# 远景山壳（Voxy LOD 金字塔思想）：把有效视距推到 4096 格——
	# 在玩家就位后接线（壳中心跟随玩家焦点，首帧后台构建）
	distant_shell = DistantShellScript.new()
	add_child(distant_shell)
	distant_shell.setup(world, player, _environment)
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
	# v9 垂直流式：进度分母按列活跃带估算（512 世界非 32 层全载；
	# estimate 内部含玩家带并做了带缓存预热）
	_loading_target = chunk_manager.estimate_band_chunks(columns) \
			if config.chunks_y > ChunkManager.LEGACY_FULL_COLUMN_LAYERS \
			else maxi(1, columns.size() * config.chunks_y)
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
	# 加载遮罩期跳过全部渲染侧子系统（审查二轮 D15）：波时钟/涟漪/
	# HUD 文本/曝光/日夜在遮罩后面白跑（加载 7s × 每帧掉落遍历+统计
	# 格式化）。时钟暂停 → 加载完成波从暂停处继续（无相位跳变）；
	# 首帧全量恢复（HUD/曝光从默认起步，与冷启动一致）
	if _loading:
		_loading_tick(delta)
		_update_hint(delta)
		return
	# 波时钟推进 + 同步到水面 shader（CPU 采样与 GPU 渲染同源）；
	# storm_scale 当前恒 1.0，只在变化时重发（每帧 4 次 uniform 重发
	# 是无谓开销——审查发现）
	_wave_clock += delta
	OceanWavesScript.global_time = _wave_clock
	if chunk_renderer != null:
		if _water_mats.is_empty():
			for m in [chunk_renderer.water_material,
					chunk_renderer.water_side_material]:
				if m is ShaderMaterial:
					_water_mats.append(m)
		var storm := OceanWavesScript.storm_scale
		for mat in _water_mats:
			mat.set_shader_parameter("u_time", _wave_clock)
			if storm != _last_storm_scale:
				mat.set_shader_parameter("storm_scale", storm)
		if storm != _last_storm_scale:
			_last_storm_scale = storm
	_update_ripples(delta)
	_hud_accumulator += delta
	_update_hud()
	_update_hint(delta)
	_update_exposure(delta)
	_update_day_night(delta)


## ---- 日夜循环 ----
## t ∈ [0,1)：0=日出、0.25=正午、0.5=日落、0.75=午夜。周期 480s
##（MC 20min 太长，首版白天/黑夜各 4min——口味旋钮）。
## 架构：天光数值恒 15 不重传播/不重网格（MC 同款），夜暗在渲染端
## 由 u_day 系数乘天光顶点色通道（COLOR.a=s³）；方块光暖色通道
## （COLOR.rgb）不乘——夜晚火把/提灯自动接管照明。
const DAY_LENGTH := 480.0
const NIGHT_SKY := 0.22  # 午夜天光系数下限（MC 月夜可读度）
const SUN_ENERGY := 1.2
const MOON_ENERGY := 0.2
# BSL 白天太阳冷白 / 落日暖橙 / 月光蓝
const DAY_SUN := Color(0.77, 0.86, 1.0)
const DUSK_SUN := Color(1.0, 0.62, 0.32)
const MOON_SUN := Color(0.55, 0.65, 1.0)
# 天空顶/地平线与环境的昼夜两端（BSL 白天蓝 → 深夜藏青）
const DAY_SKY_TOP := Color(0.28, 0.46, 0.72)
const DAY_SKY_HORIZON := Color(0.62, 0.72, 0.84)
const NIGHT_SKY_TOP := Color(0.012, 0.02, 0.055)
const NIGHT_SKY_HORIZON := Color(0.045, 0.06, 0.11)
const DAY_AMBIENT := Color(0.29, 0.41, 0.61)
const NIGHT_AMBIENT := Color(0.16, 0.19, 0.30)
# 阴天天空/环境色（BSL 写实取向：灰蓝不脏；天气系统向此插值）
const OVERCAST_SKY_TOP := Color(0.40, 0.44, 0.51)
const OVERCAST_SKY_HORIZON := Color(0.54, 0.57, 0.62)
const OVERCAST_AMBIENT := Color(0.34, 0.38, 0.46)
# 远景雾色初值（运行时每帧被地平线天色覆盖，见 _update_day_night）
const DAY_FOG := Color(0.62, 0.74, 0.90)
var _time_of_day := 0.1  # 起始上午
var _sun: DirectionalLight3D
## u_day / u_wind_time 下发材质表（_update_day_night 首帧惰性收集——
## renderer 材质 registry 就绪后不再变）
var _u_day_mats: Array = []
var _wind_mats: Array = []
## 天空色上次写入的 day01（C5 脏检查；-1 = 首帧强制写）
var _last_sky_day01 := -1.0
var _last_weather01 := -1.0  # 天气暗度上次写入（同上脏检查）
## 水面材质表（u_time/storm/sun_direction/涟漪参数多段下发共用——
## 每帧三处字面量数组分配曾是隐性 GC 压力，审查二轮 D11）
var _water_mats: Array = []


func _update_day_night(delta: float) -> void:
	_time_of_day = fmod(_time_of_day + delta / DAY_LENGTH, 1.0)
	var t := _time_of_day
	var elev := sin(t * TAU)  # >0 白天（太阳高度 -1..1）
	var day01 := smoothstep(-0.12, 0.12, elev)  # 0 深夜 → 1 白昼
	var u_day := lerpf(NIGHT_SKY, 1.0, day01)
	if _sun == null:
		_sun = DirectionalLight3D.new()
		_sun.shadow_enabled = true
		_sun.shadow_bias = 0.02
		_sun.shadow_normal_bias = 0.0
		add_child(_sun)
		# 旧 _setup_environment 的太阳由这里接管（避免双光源）——
		# 保留其水面 sun_direction 下发逻辑于下方
	if elev >= 0.0:
		var rise := smoothstep(0.0, 0.25, elev)  # 日出/日落渐弱
		_sun.rotation_degrees = Vector3(-80.0 * elev, -35.0, 0.0)
		_sun.light_energy = SUN_ENERGY * rise
		# 掠地角时偏暖（BSL 日落橙）
		_sun.light_color = DAY_SUN.lerp(DUSK_SUN,
				1.0 - smoothstep(0.0, 0.18, elev))
		_sun.light_volumetric_fog_energy = 1.6 * rise
	else:
		var melev := -elev
		_sun.rotation_degrees = Vector3(-80.0 * melev, 145.0, 0.0)
		_sun.light_energy = MOON_ENERGY * smoothstep(0.0, 0.25, melev)
		_sun.light_color = MOON_SUN
		_sun.light_volumetric_fog_energy = 0.0  # 夜里没有太阳光束
	# 天气联动（阶段 1）：云层压太阳/月亮（连续参数驱动，零跳变）
	var w01 := 0.0
	if weather_system != null:
		w01 = weather_system.weather01
	_sun.light_energy *= 1.0 - 0.65 * w01
	# 天空/环境：昼端取 BSL 白天色，夜端藏青，阴天向灰蓝插值。
	# 脏检查（审查二轮 C5）：这些写入触发 radiance cubemap 重烘
	#（0.2-0.6ms GPU/次）——day01 变化 >0.002（或天气暗度 >0.005）才写
	#（晨昏约 2-3 次/s，白天/深夜稳态零写入；曾每帧重写 4 色全量重烘）
	if absf(day01 - _last_sky_day01) > 0.002 or _last_sky_day01 < 0.0 \
			or absf(w01 - _last_weather01) > 0.005:
		_last_sky_day01 = day01
		_last_weather01 = w01
		var sky_mat: ProceduralSkyMaterial = _sky.sky_material
		sky_mat.sky_top_color = DAY_SKY_TOP.lerp(NIGHT_SKY_TOP, 1.0 - day01) \
				.lerp(OVERCAST_SKY_TOP, w01)
		sky_mat.sky_horizon_color = DAY_SKY_HORIZON.lerp(
				NIGHT_SKY_HORIZON, 1.0 - day01).lerp(
				OVERCAST_SKY_HORIZON, w01)
		sky_mat.ground_bottom_color = sky_mat.sky_horizon_color
		sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
		_environment.ambient_light_color = DAY_AMBIENT.lerp(
				NIGHT_AMBIENT, 1.0 - day01).lerp(OVERCAST_AMBIENT, w01)
		# 深度雾色=当前地平线天色（大气透视的物理本义：远景混向天色）。
		# 曾用独立 DAY/NIGHT_FOG 常量 lerp day01——日落时天空已暗红而
		# 雾还亮蓝白，雾把远山推得比天空亮 = "远处发光"（PIL 真值实测
		# 山 25 > 天 19 抓到）；直接取 sky_horizon_color 全时段自动同步
		_environment.fog_light_color = sky_mat.sky_horizon_color
	# u_day 下发（地形双 shader + cross 双面变体 + 水双 shader + 树表面；
	# 脏检查省自然达成——每帧都在变，过渡期外 day 稳定值重发成本可忽略）
	# 材质表首帧惰性收集（每帧字面量数组分配曾是隐性 GC 压力）
	if _u_day_mats.is_empty():
		for m in [chunk_renderer.material, chunk_renderer.cutout_material,
				chunk_renderer.cross_material,
				chunk_renderer.water_material,
				chunk_renderer.water_side_material]:
			if m is ShaderMaterial:
				_u_day_mats.append(m)
	for mat in _u_day_mats:
		mat.set_shader_parameter("u_day", u_day)
	# 植被风摆时间（cutout + cross 双面变体：植物/草叶 UV2 权重驱动）
	var wind_t := Time.get_ticks_msec() * 0.001
	if _wind_mats.is_empty():
		for m in [chunk_renderer.cutout_material,
				chunk_renderer.cross_material]:
			if m is ShaderMaterial:
				_wind_mats.append(m)
	for wmat in _wind_mats:
		wmat.set_shader_parameter("u_wind_time", wind_t)
	tree_manager.set_day_factor(u_day)
	# 角色化身同通道（天光顶点色 × u_day）
	if player != null and player.avatar != null:
		player.avatar.set_day_factor(u_day)
	if sound_manager != null:
		sound_manager.set_day01(day01)
	# 水面反射的太阳方向（day/night 方位不同，随光重发）
	var sun_dir: Vector3 = -_sun.global_transform.basis.z.normalized()
	for mat in _water_mats:
		mat.set_shader_parameter("sun_direction", sun_dir)
	# 壳的 u_day + 太阳漫反射方向同源下发（光照实时算——烘焙固定
	# 正午方向在黄昏与场景错位成"发光"，恒亮夜里更明显；两轮实机反馈）
	if distant_shell != null:
		distant_shell.set_day_factor(u_day, sun_dir)


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
	# 自发光体（火把火焰/炭头）随曝光反除——否则洞内曝光抬升把
	# 色带整体削顶成黄白（色相塌缩，火焰观感发糊）
	torch_renderer.set_exposure(_exposure)


## HUD：0.25s 节流刷新统计（曾藏在 _update_ripples 尾部 early-return
## 之后——按函数名拆模块时会漏，审查发现，独立成函数）
func _update_hud() -> void:
	if _hud_accumulator < 0.25 or _hud_label == null:
		return
	_hud_accumulator = 0.0
	var hint_line := ("[ " + _hint_text + " ]") if not _hint_text.is_empty() else ""
	_hud_label.text = "\n".join([
		hint_line,
		"BUILD 2026-11-14.天气1 — 若无此行=旧程序未重启",
		"Voxel Terrain MVP - Items Layer (inventory + tools + ground drops)",
		"chunks: %d    faces: %d    in-flight: %d    saved: %d    drops: %d" % [
			world.chunk_count(), chunk_renderer.total_faces,
			chunk_manager.in_flight_count(),
			save_system.saved_chunk_count(), drop_manager.drop_count()],
		"seed: %d    view: %d chunks    weather: %s" % [
			config.world_seed, chunk_manager.view_distance,
			weather_system.state_name() if weather_system != null else "-"],
		"Hold LMB mine (drops to ground) | walk over to auto-pickup | RMB place",
		"Q drop held | Ctrl+Q drop stack | 1-8/wheel select | E inventory | R rotate while dragging",
		"F5 camera (1st person / 3rd behind / 2nd front / shoulder) | F6 character model | F7 draw/sheathe katana",
		"WASD move | Space jump | Shift sprint | katana: LMB combo x3 | double-tap WASD dodge",
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
	# 同步涟漪纹理与窗口参数到水面材质（纹理/中心脏检查 + 常量窗口
	# 首帧一次——每帧 6 次 uniform 重发与 texture() 重复调用是无谓
	# 开销，审查 D11/D16）
	var rtex = water_ripples.texture()
	var rcenter = water_ripples.texture_center()
	for mat in _water_mats:
		if rtex != _last_ripple_tex:
			mat.set_shader_parameter("ripple_map", rtex)
		if rcenter != _last_ripple_center:
			mat.set_shader_parameter("ripple_center", rcenter)
		if not _ripple_window_sent:
			mat.set_shader_parameter("ripple_window", WaterRipplesScript.WINDOW)
	if not _ripple_window_sent:
		_ripple_window_sent = true
	_last_ripple_tex = rtex
	_last_ripple_center = rcenter


## HUD 短时提示（放置被拒等操作反馈——静默拒绝曾被用户误读成
## "模型丢失"，排查绕了大弯）
func show_hint(text: String) -> void:
	_hint_text = text
	_hint_expire = 2.5


## 背包界面开关时隐藏/恢复调试文字层（玩家控制器调用）：
## 调试画布层 1 低于玩家 HUD 层 10，但半透明面板盖不干净左侧
## 屏幕边缘带的亮字与透板残影，干脆整层隐藏
func set_debug_hud_visible(is_visible: bool) -> void:
	if _hud_label != null:
		_hud_label.visible = is_visible


func _update_hint(delta: float) -> void:
	if _hint_expire > 0.0:
		_hint_expire -= delta
		if _hint_expire <= 0.0:
			_hint_text = ""


func _setup_environment() -> void:
	# 太阳/月亮由 _update_day_night 接管（日夜循环轮）——此处只建
	# 天空与环境；阴影偏置经验值随 _sun 重建（bias 0.02：默认 0.1/2.0
	# 会把细窄枝段投影"推穿"成断节树影）
	_wave_clock = 0.0

	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	_sky = sky
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
	# 高视距配套（v8 巨型档地形）：距离雾遮加载边界——视距圈外地形
	# 戛然而止会露"世界边缘"，深度雾在视距 ~55% 处渐入、终点略小于
	# 视距圈。颜色取地平线天空色（雾天空不受染，保持天幕干净）；
	# 逆光散射让晨昏面向太阳的雾带微亮（BSL 大气透视取向）
	var view_end := float(chunk_manager.view_distance
			* config.chunk_size) * 0.92
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = DAY_FOG
	environment.fog_sun_scatter = 0.25
	environment.fog_sky_affect = 0.0
	environment.fog_depth_begin = view_end * 0.72
	environment.fog_depth_end = view_end
	environment.fog_depth_curve = 1.3
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)
	_environment = environment  # 镜像相机 SubViewport 共用（环境 per-viewport）


## 从候选点螺旋外扩，找海平面以上的陆地列（v4 起世界有海洋）。
## v8 大陆波长 4096 格——海可绵延上千格，24 圈（~200 格）大概率
## 全海；扩到 80 圈（~640 格）覆盖半个大陆波长。
func _find_land_spawn(start: Vector2i) -> Vector2i:
	if generator.column_height(start.x, start.y) > generator.sea_level:
		return start
	for radius in range(1, 80):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := start.x + int(round(cos(ang) * radius * 8.0))
			var cz := start.y + int(round(sin(ang) * radius * 8.0))
			if generator.column_height(cx, cz) > generator.sea_level:
				return Vector2i(cx, cz)
	push_warning("出生点 80 圈内未找到陆地，使用原出生点（可能落水）")
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
	if sound_manager != null:
		sound_manager.attach_player(player)
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
	cave_fog.setup(world, player, _environment)


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
			[chunk_renderer.material, chunk_renderer.cutout_material,
					chunk_renderer.cross_material],
			_environment,
			float(generator.sea_level)
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
