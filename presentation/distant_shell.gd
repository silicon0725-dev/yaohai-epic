## 远景山壳（Voxy LOD 金字塔思想的纯函数特化）。
## 视距外的同心环带低精度地形壳（230→4096 格，步长 4/8/16/32
## 金字塔），把有效可视距离从 chunk 视距圈（256 格）推到一个
## 大陆波长（4096 格）——山系与海岸线首次同框。
## 数据 = TerrainGenerator.column_profile 直接查询（纯函数，无烘焙
## 无存储，Voxy 的 LMDB 缓存对我们无意义）；C# 侧一次产 ArrayMesh
##（光照烘顶点色，材质 UNSHADED——避免 GDScript 组装 13 万顶点），
## 每环一个 surface = 4 draw call。玩家跨 64 格后台重建全壳。
## 缝合策略：统一 512 扇区（相邻环带边界顶点 XZ 重合）+ 整体下沉
## 2 格且内缘在视距圈内侧（chunk 网格从上方覆盖交界）。
extends Node

const Bridge := preload("res://meshing/native_terrain_bridge.gd")
const ShellShader := preload("res://presentation/distant_shell.gdshader")

## 玩家跨多少格才重建（壳中心跟随步进）。
const REBUILD_STEP := 64
## 壳外缘半径（格）——雾终点与相机 far 由此联动。
const SHELL_RADIUS := 4096.0

var _native = null
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _focus: Node3D = null
var _center := Vector2i(0x7FFFFFFF, 0x7FFFFFFF)  # 未建标记
var _building := false
var _task_done := false
var _pending_mesh: Mesh = null
var _pending_center := Vector2i.ZERO


## main 接线期调用（显式参数——测试可注入替身）：建渲染节点 + 材质；
## 首建由首帧 _physics_process 触发（worker 池就绪，0.2s 后台构建）。
func setup(p_world, p_player: Node3D, p_environment) -> void:
	if not Bridge.available():
		return
	Bridge.prewarm(p_world.config.world_seed,
			p_world.config.world_height_blocks())
	_native = Bridge.get_native(p_world.config.world_seed)
	if _native == null:
		return
	_focus = p_player

	# ShaderMaterial（u_day 联动）：光照烘在顶点色（C# grid 差分
	# 法线 × 太阳方向），UNSHADED 跳过场景灯；u_day 由 main 日夜轮
	# 下发（夜里压暗——StandardMaterial 恒亮会在夜里"自发光"）
	var material := ShaderMaterial.new()
	material.shader = ShellShader
	_material = material

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)

	# 壳外缘 4096 > 相机默认 far 4000——放远裁剪面
	var cam: Camera3D = _find_camera(p_player)
	if cam != null:
		cam.far = SHELL_RADIUS * 2.0
	# 雾随壳半径：begin 0.45×R（1843 格）+ curve 1.6（中段薄远处浓）
	# ——500-1800 格清晰可辨（"平面贴图感"反馈后回推；发光根因
	# 已修死：雾色=地平线天色，进雾只会混向天色不会亮于天），
	# end 0.92×R（浓雾正好在地平线前吞掉壳外缘）
	if p_environment != null:
		p_environment.fog_depth_begin = SHELL_RADIUS * 0.45
		p_environment.fog_depth_end = SHELL_RADIUS * 0.92
		p_environment.fog_depth_curve = 1.6


## 玩家节点下找相机（player_controller 的 $Camera；探针替身挂任意位置）。
func _find_camera(player: Node3D):
	if player == null:
		return null
	for child in player.get_children():
		if child is Camera3D:
			return child
	return null


## 日夜状态下发（main._update_day_night 每帧调）：u_day 压暗因子 +
## 真实太阳方向（太阳漫反射在 shader 实时算——烘焙固定方向会在
## 黄昏/夜里与场景错位成"发光"）。
func set_day_factor(v: float, sun_dir := Vector3(0.5, 0.89, 0.25)) -> void:
	if _material != null:
		_material.set_shader_parameter("u_day", v)
		_material.set_shader_parameter("u_sun_dir", sun_dir)


func _exit_tree() -> void:
	# 在途 worker 任务的 UAF 防护：_build_task 首行检查后即返回
	_native = null
	_mesh_instance = null


func _physics_process(_delta: float) -> void:
	if _native == null or _focus == null:
		return
	# 提交完成的后台构建（主线程：引擎资源替换）
	if _task_done:
		_task_done = false
		_building = false
		if _mesh_instance != null:
			_mesh_instance.mesh = _pending_mesh
		_pending_mesh = null
	# 玩家跨 REBUILD_STEP 触发重建（上一次构建完成才接新任务——
	# 连续移动时 chained：提交即发现中心已偏，再启一轮）
	if not _building:
		var col := Vector2i(
				int(floor(_focus.global_position.x / REBUILD_STEP)),
				int(floor(_focus.global_position.z / REBUILD_STEP)))
		if col != _center:
			_center = col
			_start_build(col * REBUILD_STEP
					+ Vector2i(REBUILD_STEP / 2, REBUILD_STEP / 2))


func _start_build(center: Vector2i) -> void:
	_building = true
	_task_done = false
	WorkerThreadPool.add_task(_build_task.bind(center))


## worker 线程：C# 采样四环带产 ArrayMesh（只读噪声，线程安全）。
## 退出期防护：_exit_tree 已置空 _native——首行短路，任务空跑返回。
func _build_task(center: Vector2i) -> void:
	if _native == null:
		return
	var mesh: Mesh = _native.GenerateShellMesh(center.x, center.y)
	if mesh != null:
		_pending_mesh = mesh
		_pending_center = center
	_task_done = true
