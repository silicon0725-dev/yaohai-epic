@tool
extends EditorPlugin

const DockScript := preload("res://addons/atlas_preview_dock/atlas_preview_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "图集布局"
	add_control_to_dock(DOCK_SLOT_LEFT_BL, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
