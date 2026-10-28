extends SceneTree
func _initialize():
	var env := Environment.new()
	var names := []
	for p in env.get_property_list():
		names.append(p["name"])
	print("PROPS|", "|".join(PackedStringArray(names)))
	quit(0)
