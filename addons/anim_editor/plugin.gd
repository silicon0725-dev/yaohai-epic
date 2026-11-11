@tool
extends EditorPlugin

const DockScript := preload("res://addons/anim_editor/anim_editor_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "动作编辑器"
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
