## 加载动画状态机隔离诊断：直接实例化 LoadingOverlay，
## 3s 内驱动进度 0→1，finish() 后逐 0.15s 打印内部相位。
## 运行：godot --path . res://debug/probe_loading_anim.tscn
extends Node

var overlay = null
var _t0 := 0.0
var _finished_asked := false


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	const OverlayScript := preload("res://presentation/loading_overlay.gd")
	overlay = OverlayScript.new()
	add_child(overlay)
	_t0 = Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0 - _t0
	if t < 3.0:
		overlay.set_progress(t / 3.0, "诊断 %d%%" % int(t / 3.0 * 100))
	elif not _finished_asked:
		_finished_asked = true
		overlay.finish()
		print("t=3.0 finish() 调用")
	if _finished_asked:
		if not is_instance_valid(overlay):
			print("t=%.2f OVERLAY_FREED" % t)
		else:
			var cube = overlay._cube
			print("t=%.2f phase=%d pt=%.3f spawned=%d falling=%d" % [
				t, cube._phase, cube._phase_t, cube._spawned,
				cube._falling.size()])
	if t > 6.0:
		get_tree().quit(0)
