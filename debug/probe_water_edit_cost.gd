## 水中放/破方块卡顿归因探针：
## 对照测量 水中 vs 陆地 set_block 的同步耗时 + 操作后 90 帧帧时间尖峰
## + WaterFlow.tick 耗时。headless：godot --headless --path . -s 本脚本
extends Node

var main_ref: Node
var _phase := 0
var _wait := 0.0
var _frames: Array[float] = []
var _label := ""
var _tests: Array = []
var _ti := 0


func _ready() -> void:
	main_ref = load("res://scenes/main.tscn").instantiate()
	main_ref.save_root = "user://saves/probe_water_edit"
	WorldSave.new("user://saves/probe_water_edit", null).erase_all()
	add_child(main_ref)


func _process(delta: float) -> void:
	_wait += delta
	if _phase == 0:
		if _wait > 10.0 and not main_ref._loading:
			_setup()
			_phase = 1
			_wait = 0.0
	elif _phase == 1:
		_frames.append(delta)
		if _wait > 1.5:
			_finish_baseline()
			_phase = 2
			_wait = 0.0
	elif _phase == 2:
		_frames.append(delta)
		if _ti >= _tests.size():
			_report()
			get_tree().quit(0)
			return
		var t: Dictionary = _tests[_ti]
		if _wait > 1.2:
			_run_case(t)
			_ti += 1
			_wait = 0.0
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	var water := Vector2i(34, 34)
	for r in range(1, 40):
		var found := false
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := int(34 + cos(ang) * r * 6.0)
			var cz := int(34 + sin(ang) * r * 6.0)
			if main_ref.generator.column_height(cx, cz) \
					<= TerrainGenerator.SEA_LEVEL - 3:
				water = Vector2i(cx, cz)
				found = true
				break
		if found:
			break
	var sea := TerrainGenerator.SEA_LEVEL
	var land := Vector2i(water.x + 6, water.y + 6)
	for i in 40:
		if main_ref.generator.column_height(land.x, land.y) \
				> sea + 1:
			break
		land += Vector2i(1, 1)
	var land_y: int = main_ref.generator.column_height(land.x, land.y)
	var world: VoxelWorld = main_ref.world
	_tests = [
		{
			"label": "水中放方块",
			"pos": Vector3i(water.x, sea - 1, water.y),
			"id": VoxelTypes.STONE_ID,
		},
		{
			"label": "水中破方块",
			"pos": Vector3i(water.x, sea - 1, water.y),
			"id": VoxelTypes.AIR_ID,
		},
		{
			"label": "陆地放方块",
			"pos": Vector3i(land.x, land_y, land.y),
			"id": VoxelTypes.STONE_ID,
		},
		{
			"label": "陆地破方块",
			"pos": Vector3i(land.x, land_y, land.y),
			"id": VoxelTypes.AIR_ID,
		},
	]
	print("SETUP water=", water, " sea=", sea,
			" land=", land, " land_y=", land_y)
	print("水流系统存在=", main_ref.water_flow != null)


func _run_case(t: Dictionary) -> void:
	var world: VoxelWorld = main_ref.world
	var pos: Vector3i = t["pos"]
	_frames.clear()
	var t0 := Time.get_ticks_usec()
	world.set_block(pos, t["id"])
	var sync_us := Time.get_ticks_usec() - t0
	_label = t["label"]
	print("[%s] set_block 同步耗时=%d us  水流 pending=%d" % [
			_label, sync_us, main_ref.water_flow.pending_count()])
	# 水流 tick 单独计时（后续帧逐帧采样重网格提交开销）
	for i in 4:
		var tw := Time.get_ticks_usec()
		var n: int = main_ref.water_flow.tick()
		var dt := Time.get_ticks_usec() - tw
		if n > 0 or dt > 1000:
			print("  water_flow.tick #%d 变更=%d 耗时=%d us" % [i, n, dt])


func _finish_baseline() -> void:
	var mx := 0.0
	var over := 0
	for f in _frames:
		mx = max(mx, f)
		if f > 0.0167:
			over += 1
	print("基线 90 帧: max=%.1fms 超帧率帧数=%d" % [mx * 1000.0, over])


func _report() -> void:
	var mx := 0.0
	var over := 0
	for f in _frames:
		mx = max(mx, f)
		if f > 0.0167:
			over += 1
	print("末段帧统计（合并所有用例后 1.2s 窗口）: max=%.1fms 超16.7ms帧数=%d" % [
			mx * 1000.0, over])
