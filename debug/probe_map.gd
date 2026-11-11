## 粗地图：±2560 范围、64 格步长，ASCII 打出海/陆分布，用来挑"隔着大水看对岸"的机位。
##   godot --headless --path . -s debug/probe_map.gd
extends SceneTree

const STEP := 64
const SPAN := 2560


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main = scene.instantiate()
	get_root().add_child(main)
	await process_frame
	var gen = main.get("generator")
	var sea: int = gen.sea_level
	print("SEA=", sea, " step=", STEP)
	var header := "      "
	var x := -SPAN
	while x <= SPAN:
		header += "%d" % (absi(x / STEP) % 10)
		x += STEP
	print(header)
	var z := -SPAN
	while z <= SPAN:
		var row := "%6d" % z
		x = -SPAN
		while x <= SPAN:
			var h: int = gen.column_height(x, z)
			if h <= sea:
				row += "~"
			elif h < sea + 8:
				row += "."
			elif h < sea + 40:
				row += "o"
			elif h < sea + 100:
				row += "O"
			else:
				row += "#"
			x += STEP
		print(row)
		z += STEP
	quit(0)
