## debug 验收场景公共库——杜绝整文件复制脚手架（capture_shadow2..16
## 共 16 份近似副本 ~1600 行就是教训）。新验收场景只写差异部分：
##
##   var main := CaptureLib.boot_isolated(self, "my_test")
##   ... await/等 main._loading == false ...
##   CaptureLib.shoot("debug/xxx_v1.png")
##   print(CaptureLib.fps_summary(_samples))
extends RefCounted


## 实例化主场景 + 隔离存档（每轮验收从零世界开始）。
static func boot_isolated(parent: Node, save_name: String) -> Node:
	var main = load("res://scenes/main.tscn").instantiate()
	main.save_root = "user://saves/%s" % save_name
	WorldSave.new(main.save_root, null).erase_all()
	parent.add_child(main)
	return main


## 截图到路径（调用方约定：重拍必须换新文件名——CDN 缓存坑）。
static func shoot(viewport: Viewport, path: String) -> void:
	var img := viewport.get_texture().get_image()
	img.save_png(path)
	print("SHOT ", path)


## FPS 摘要（_physics_process 里 append(Engine.get_frames_per_second())）。
static func fps_summary(samples: Array) -> String:
	if samples.is_empty():
		return "n/a"
	var total := 0.0
	for f in samples:
		total += f
	return "avg=%.1f (n=%d)" % [total / samples.size(), samples.size()]


## 从出生点向外螺旋找开阔水列（列高 <= SEA_LEVEL - min_depth）。
static func find_water_column(gen, min_depth: int = 2) -> Vector2i:
	var water := Vector2i(34, 34)
	for r in range(1, 40):
		for a in 16:
			var ang := TAU * a / 16.0
			var cx := int(34 + cos(ang) * r * 6.0)
			var cz := int(34 + sin(ang) * r * 6.0)
			if gen.column_height(cx, cz) <= TerrainGenerator.SEA_LEVEL - min_depth:
				return Vector2i(cx, cz)
	return water


## 从水点向 (+x,+z) 走到第一个陆地列（岸位机位用）。
static func find_shore_from(gen, water: Vector2i) -> Vector2i:
	var shore := water + Vector2i(4, 4)
	for i in 40:
		if gen.column_height(shore.x, shore.y) > TerrainGenerator.SEA_LEVEL:
			break
		shore += Vector2i(1, 1)
	return shore
