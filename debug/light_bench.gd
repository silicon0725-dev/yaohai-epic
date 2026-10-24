## 光照阶段 1 性能基准：LightManager 批量局部光源压力测试。
## 固定条件：固定机位、固定窗口 1280x720、关闭 VSync、同一真实存档、
## 每档 5s 预热 + 15s 采集。矩阵：N∈{32,64,128,256} × 阴影∈{off,budget,all}，
## 外加 256 灯半数超距（量化距离裁剪实际收益）。
## 运行：godot --path . res://debug/light_bench.tscn （必须窗口化）
extends Node

const LightManagerScript := preload("res://systems/lighting/light_manager.gd")
const SRC := "user://saves/world1"
const ROOT := "user://tmp_userworld2"
## 每档采集参数（秒）
const WARMUP := 5.0
const COLLECT := 15.0
## 灯网格间距（米）；网格以锚点为中心
const SPACING := 4.0

var lm: Node3D
var bench_cam: Camera3D
var main_ref: Node
var anchor := Vector3(51.11, 0.0, -96.06)
var _deltas: PackedFloat64Array = []
var _draws_sum := 0
var _prims_sum := 0
var _draw_frames := 0
var _phase := "load"
var _timer := 0.0
var _configs: Array = []
var _cfg_idx := -1
var _light_ids: Array = []
var _results: Array = []


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
			tc.copy_absolute(sc.get_current_dir() + "/" + f, tc.get_current_dir() + "/" + f)
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
	# 固定机位：锚点后上方俯瞰灯阵
	bench_cam = Camera3D.new()
	add_child(bench_cam)
	bench_cam.global_position = anchor + Vector3(0, 14, 30)
	bench_cam.look_at(anchor, Vector3.UP)
	bench_cam.current = true
	main.chunk_manager.focus = bench_cam
	lm = LightManagerScript.new()
	lm.name = "BenchLightManager"
	add_child(lm)
	lm.camera = bench_cam
	# 矩阵：N x 阴影模式 + 裁剪对照
	for n in [32, 64, 128, 256]:
		_configs.append({"n": n, "mode": "off"})
		_configs.append({"n": n, "mode": "budget"})
		_configs.append({"n": n, "mode": "all"})
	_configs.append({"n": 256, "mode": "off", "half_far": true})
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
			_draws_sum += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			_prims_sum += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			_draw_frames += 1
			if _timer >= COLLECT:
				_finish_config()


func _start_next_config() -> void:
	_cfg_idx += 1
	if _cfg_idx >= _configs.size():
		_report()
		get_tree().quit(0)
		return
	for id in _light_ids:
		lm.remove_light(id)
	_light_ids.clear()
	var cfg: Dictionary = _configs[_cfg_idx]
	var n: int = cfg.n
	var budget := 0
	if cfg.mode == "budget":
		budget = 2
	elif cfg.mode == "all":
		budget = n
	lm.configure({"shadow_budget": budget})
	var half := n / 2
	var side := int(ceil(sqrt(float(n))))
	for i in n:
		var gx := i % side
		var gz := i / side
		var pos := Vector3(
				anchor.x + (gx - side / 2.0) * SPACING,
				0.0,
				anchor.z + (gz - side / 2.0) * SPACING)
		var far: bool = cfg.get("half_far", false) and i >= half
		if far:
			pos += Vector3(0, 0, -140)  # 推出 max_distance(64m) 之外
		pos.y = float(_ground_y_at(pos)) + 1.5
		_light_ids.append(lm.add_light({
			"type": "omni",
			"position": pos,
			"color": Color(1.0, 0.85, 0.6),
			"energy": 1.5,
			"range": 8.0,
			"shadow_requested": cfg.mode != "off",
		}))
	print("BENCH start n=%d mode=%s half_far=%s" % [n, cfg.mode, cfg.get("half_far", false)])
	_phase = "warmup"
	_timer = 0.0


func _finish_config() -> void:
	var cfg: Dictionary = _configs[_cfg_idx]
	var ds := _deltas.duplicate()
	ds.sort()
	var mean_fps := 0.0
	for d in ds:
		mean_fps += 1.0 / d
	mean_fps /= ds.size()
	var p50: float = ds[ds.size() / 2]
	var p95: float = ds[int(ds.size() * 0.95)]
	var st: Dictionary = lm.get_stats()
	var line := "BENCH result n=%d mode=%s half_far=%s fps=%.1f p50_ms=%.2f p95_ms=%.2f draws=%.0f prims=%.1fM active=%d shadowed=%d" % [
		cfg.n, cfg.mode, cfg.get("half_far", false), mean_fps,
		p50 * 1000.0, p95 * 1000.0,
		float(_draws_sum) / _draw_frames,
		float(_prims_sum) / _draw_frames / 1000000.0,
		st.active, st.shadowed,
	]
	print(line)
	_results.append(line)
	_phase = "next_config"
	_timer = 0.0


func _report() -> void:
	print("=== light_bench 汇总 ===")
	for r in _results:
		print(r)


func _ground_y_at(at: Vector3) -> int:
	var world: VoxelWorld = main_ref.world
	for y in range(60, 4, -1):
		var id: int = world.get_block(Vector3i(int(floor(at.x)), y, int(floor(at.z))))
		if id != 0:
			return y
	return 12
