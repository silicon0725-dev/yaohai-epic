@tool
extends EditorPlugin

const DockScript := preload("res://addons/voxel_registry_dock/registry_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "方块注册表"
	add_control_to_dock(DOCK_SLOT_LEFT_UL, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
