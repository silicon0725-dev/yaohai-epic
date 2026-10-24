@tool
extends EditorPlugin

# Ocean3D Lite editor plugin: registers the Ocean autoload when the
# plugin is enabled. Remove Lite before installing the full version
# of Ocean3D (they provide the same classes and autoload).

const AUTOLOAD_NAME := "Ocean"
const AUTOLOAD_PATH := "res://addons/ocean3d_lite/ocean.gd"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
