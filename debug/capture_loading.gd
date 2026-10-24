## 加载流程冒烟：带显示跑 main.tscn，截 loading 中/完成后两帧 +
## 统计加载总时长。运行：godot --path . res://debug/capture_loading.tscn
extends Node

var main_ref: Node
var _shots := 0
var _t0 := 0.0
var _loading_seen := false


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = load("res://scenes/main.tscn").instantiate()
	add_child(main_ref)
	_t0 = Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	var elapsed := Time.get_ticks_msec() / 1000.0 - _t0
	if not _loading_seen and main_ref._loading:
		_loading_seen = true
		# loading 进行中截图（等进度条涨起来）
		await get_tree().create_timer(0.6).timeout
		if main_ref._loading:
			capture("debug/loading_mid_v8.png")
	if _shots == 0 and not main_ref._loading and _loading_seen:
		_shots = 1
		# finish() 后每 0.2s 连拍 14 帧构建收尾时间线（像素分类定参用）
		for k in 14:
			await get_tree().create_timer(0.2).timeout
			capture("debug/loading_seq_%02d.png" % (k + 1))
		print("LOADING total=%.1fs" % elapsed)
		get_tree().quit(0)
		return
	if elapsed > 90.0:
		print("LOADING TIMEOUT — main._loading=%s" % main_ref._loading)
		capture("debug/loading_timeout.png")
		get_tree().quit(1)


func capture(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT ", path)
