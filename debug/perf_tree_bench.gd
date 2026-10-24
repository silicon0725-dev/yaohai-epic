## 树系统性能基准（perf_tree_bench）：定位"改树后卡顿"的瓶颈归属。
## 固定条件：真实存档副本、固定机位（同 light_bench 锚点，可与
## light_bench 底噪对照）、窗口 1280x720、VSync 关、5s 预热 + 15s 采集。
## 矩阵（同一进程内切换，切前恢复基线）：
##   full            现状（树干 + 冠阴影代理 + 木质锥台代理 + 太阳阴影）
##   no_shadow_proxy 隐藏全部 CrownShadow/WoodShadow（SHADOWS_ONLY 代理成本）
##   no_trees        隐藏全部树视觉（树整体绘制成本，含代理）
##   no_sun_shadow   太阳阴影关（阴影贴图总成本，含地形自阴影）
##   walk_full       相机匀速飞行（移动建树/卸树 hitch：看 p95/p99/max）
##   walk_no_trees   同上但树全隐（hitch 是否树相关）
## 运行（Forward+）：godot --path . res://debug/perf_tree_bench.tscn
## 运行（对照）：godot --path . --rendering-method gl_compatibility \
##   res://debug/perf_tree_bench.tscn
extends Node

const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld3"
const WARMUP := 5.0
const COLLECT := 15.0
const WALK_SPEED := 8.0

var main_ref: Node
var bench_cam: Camera3D
var anchor := Vector3(51.11, 0.0, -96.06)
var _deltas: PackedFloat64Array = []
var _draws_sum := 0
var _prims_sum := 0
var _draw_frames := 0
var _phase := "load"
var _timer := 0.0
var _configs: Array = []
var _cfg_idx := -1
var _results: Array = []
var _sun: DirectionalLight3D = null
var _cam_home := Vector3.ZERO


func _ready() -> void:
	print("renderer_method=", RenderingServer.get_current_rendering_method())
	print("video_adapter=", RenderingServer.get_video_adapter_name())
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	if not DirAccess.dir_exists_absolute(ROOT):
		var d := DirAccess.open("user://saves")
		d.make_dir_recursive_absolute(ROOT)
		d.copy_absolute(SRC + "/world.json", ROOT + "/world.json")
		d.make_dir_recursive_absolute(ROOT + "/chunks")
		var sc := DirAccess.open(SRC + "/chunks")
		var tc := DirAccess.open(ROOT + "/chunks")
		for f in sc.get_files():
			tc.copy_absolute(sc.get_current_dir() + "/" + f,
					tc.get_current_dir() + "/" + f)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.save_root = ROOT
	add_child(main)
	main_ref = main
	var waited := 0
	while waited < 2400:
		await get_tree().process_frame
		waited += 1
		if waited >= 120 and main.chunk_manager.is_idle():
			break
	print("world ready")
	anchor.y = float(_ground_y_at(anchor)) + 1.5
	bench_cam = Camera3D.new()
	add_child(bench_cam)
	_cam_home = anchor + Vector3(0, 14, 30)
	bench_cam.global_position = _cam_home
	bench_cam.look_at(anchor, Vector3.UP)
	bench_cam.current = true
	main.chunk_manager.focus = bench_cam
	_sun = _find_sun()
	_print_tree_stats()
	# 矩阵可用命令行参数过滤：--bench=walk 只跑走动归因三档
	var filter := ""
	var view_override := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bench="):
			filter = arg.trim_prefix("--bench=")
		elif arg.begins_with("--view="):
			view_override = int(arg.trim_prefix("--view="))
	if view_override > 0:
		main.chunk_manager.view_distance = view_override
		print("view_distance=", view_override)
	var modes: Array = ["full", "no_shadow_proxy", "no_trees",
			"no_sun_shadow", "walk_full", "walk_no_trees",
			"walk_no_tree_build"]
	for mode in modes:
		if filter == "" or (filter == "walk") == mode.begins_with("walk_"):
			_configs.append({"mode": mode})
	_phase = "next_config"
	_timer = 0.0


func _process(delta: float) -> void:
	_timer += delta
	match _phase:
		"next_config":
			_start_next_config()
		"warmup":
			if _timer >= WARMUP:
				_deltas = PackedFloat64Array()
				_draws_sum = 0
				_prims_sum = 0
				_draw_frames = 0
				_phase = "collect"
				_timer = 0.0
		"collect":
			_deltas.append(delta)
			_walk_step(delta)
			_draws_sum += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			_prims_sum += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			_draw_frames += 1
			if _timer >= COLLECT:
				_finish_config()


func _walk_step(delta: float) -> void:
	var mode: String = _configs[_cfg_idx].mode
	if not mode.begins_with("walk_"):
		return
	bench_cam.global_position += Vector3(0, 0, -1) * WALK_SPEED * delta


func _start_next_config() -> void:
	_cfg_idx += 1
	if _cfg_idx >= _configs.size():
		_report()
		get_tree().quit(0)
		return
	_restore_baseline()
	var mode: String = _configs[_cfg_idx].mode
	var tm: Node = main_ref.tree_manager
	for tree_id in tm._trees:
		var entry: Dictionary = tm._trees[tree_id]
		var mi: MeshInstance3D = entry.get("mesh_node")
		if mi == null or not is_instance_valid(mi):
			continue
		if mode == "no_trees" or mode == "walk_no_trees":
			mi.visible = false
		elif mode == "no_shadow_proxy":
			for child in mi.get_children():
				if child is MeshInstance3D:
					child.visible = false
	if mode == "no_sun_shadow" and _sun != null:
		_sun.shadow_enabled = false
	if mode == "walk_no_tree_build":
		# 断开树生命周期钩子：新 chunk 激活不再建树（含数据构建），
		# 已建树保留显示——与 walk_full 的差 = 树构建成本
		main_ref.chunk_manager.on_chunk_active_cb = Callable()
		main_ref.chunk_manager.on_chunk_unloaded_cb = Callable()
	if mode.begins_with("walk_"):
		bench_cam.global_position = _cam_home
	print("BENCH start mode=%s" % mode)
	_phase = "warmup"
	_timer = 0.0


func _restore_baseline() -> void:
	var tm: Node = main_ref.tree_manager
	for tree_id in tm._trees:
		var entry: Dictionary = tm._trees[tree_id]
		var mi: MeshInstance3D = entry.get("mesh_node")
		if mi == null or not is_instance_valid(mi):
			continue
		mi.visible = true
		for child in mi.get_children():
			if child is MeshInstance3D:
				child.visible = true
	if _sun != null:
		_sun.shadow_enabled = true


func _finish_config() -> void:
	var mode: String = _configs[_cfg_idx].mode
	var ds := _deltas.duplicate()
	ds.sort()
	var mean_fps := 0.0
	for d in ds:
		mean_fps += 1.0 / d
	mean_fps /= ds.size()
	var p50: float = ds[ds.size() / 2]
	var p95: float = ds[int(ds.size() * 0.95)]
	var p99: float = ds[int(ds.size() * 0.99)]
	var mx: float = ds[ds.size() - 1]
	var line := "BENCH result mode=%s fps=%.1f p50_ms=%.2f p95_ms=%.2f p99_ms=%.2f max_ms=%.2f draws=%.0f prims=%.1fM" % [
		mode, mean_fps, p50 * 1000.0, p95 * 1000.0, p99 * 1000.0,
		mx * 1000.0,
		float(_draws_sum) / _draw_frames,
		float(_prims_sum) / _draw_frames / 1000000.0,
	]
	print(line)
	# 流式管线统计：区分后台积压 / 主线程提交堵 / 调度开销
	var cm: Node = main_ref.chunk_manager
	var dirty := 0
	for coord in main_ref.world.chunks:
		var ch = main_ref.world.chunks[coord]
		if ch.mesh_dirty or ch.collision_dirty:
			dirty += 1
	print("  stream chunks=%d dirty=%d in_flight=%d faces=%d player_y=%.1f" % [
		main_ref.world.chunk_count(), dirty, cm.in_flight_count(),
		main_ref.chunk_renderer.total_faces,
		main_ref.player.global_position.y if main_ref.player != null else -999.0])
	_results.append(line)
	_phase = "next_config"
	_timer = 0.0


func _report() -> void:
	print("=== perf_tree_bench 汇总 ===")
	for r in _results:
		print(r)


func _find_sun() -> DirectionalLight3D:
	for child in main_ref.get_children():
		if child is DirectionalLight3D:
			return child
	return null


func _print_tree_stats() -> void:
	var tm: Node = main_ref.tree_manager
	var trees: Dictionary = tm._trees
	var trunk_tris := 0
	var proxy_tris := 0
	var proxy_count := 0
	for tree_id in trees:
		var entry: Dictionary = trees[tree_id]
		var mi: MeshInstance3D = entry.get("mesh_node")
		if mi == null or not is_instance_valid(mi):
			continue
		trunk_tris += _mesh_tris(mi.mesh)
		for child in mi.get_children():
			if child is MeshInstance3D:
				proxy_tris += _mesh_tris(child.mesh)
				proxy_count += 1
	print("tree_stats trees=%d trunk_tris=%d proxy_nodes=%d proxy_tris=%d" % [
		trees.size(), trunk_tris, proxy_count, proxy_tris])
	# 树构建内部耗时分布（样本树重跑纯函数，usec/棵均值）
	const TreeMeshBuilderS := preload("res://systems/trees/tree_mesh_builder.gd")
	const TreeGeneratorS := preload("res://systems/trees/tree_generator.gd")
	const TreeSpeciesS := preload("res://systems/trees/tree_species.gd")
	var samples: Array = []
	for tree_id in trees:
		samples.append(trees[tree_id]["instance"])
		if samples.size() >= 8:
			break
	if samples.is_empty():
		return
	var t_gen := 0
	var t_mesh := 0
	var t_shadow := 0
	var t_leaves := 0
	var t_gen_all := 0
	for inst in samples:
		var sp: TreeSpecies = TreeSpeciesS.new()
		var t0 := Time.get_ticks_usec()
		TreeGeneratorS.generate(sp, 1, inst.origin)
		t_gen += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		TreeMeshBuilderS.build_mesh(inst)
		t_mesh += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		TreeMeshBuilderS.build_shadow_mesh(inst)
		t_shadow += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		TreeGeneratorS.leaf_shadow_cells(inst)
		t_leaves += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		TreeGeneratorS.generate(sp, 1, Vector3i(999999, 1, 999999))
		t_gen_all += Time.get_ticks_usec() - t0
	var n := samples.size()
	print("build_cost_usetree generate=%d build_mesh=%d shadow_mesh=%d leaf_shadow=%d" % [
		t_gen / n, t_mesh / n, t_shadow / n, t_leaves / n])


func _mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3
	return tris


func _ground_y_at(at: Vector3) -> int:
	var world: VoxelWorld = main_ref.world
	for y in range(60, 4, -1):
		var id: int = world.get_block(Vector3i(int(floor(at.x)), y,
				int(floor(at.z))))
		if id != 0:
			return y
	return 12
