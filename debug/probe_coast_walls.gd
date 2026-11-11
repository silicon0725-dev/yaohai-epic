## 找"陡岸贴水"的格：远景壳 S=32 级里，某全陆格的 2×2 采样 hMax 远高于海平面，
## 而它 4 邻里有整格全水的格子 —— 旧代码（vs=S/2、钳 sea+vs）在这种地方会立起
## 一整片从坡顶直落海面的竖墙（用户截图的灰板幕帘）。
##   godot --headless --path . -s debug/probe_coast_walls.gd
extends SceneTree

const S := 32
const Q := 8          # S/4 内缩采样，与 GenerateShellMesh 的 q 一致
const SEA := 64

var gen


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main = scene.instantiate()
	get_root().add_child(main)
	await process_frame
	gen = main.get("generator")
	print("SEA=", gen.sea_level_for(512))

	var cache := {}
	var best: Array = []
	for iz in range(-48, 48):
		for ix in range(-48, 48):
			var info := _cell(cache, ix, iz)
			if info.x < 0:
				continue
			if info.waterN != 0:
				continue
			var has_water := false
			for k in 4:
				var nb := _cell(cache, ix + (1 if k == 0 else -1 if k == 1 else 0),
					iz + (1 if k == 2 else -1 if k == 3 else 0))
				if nb.x >= 0 and nb.waterN == 4:
					has_water = true
					break
			if not has_water:
				continue
			var wall: int = int(info.hMax) - (SEA - 1)
			if wall < 10:
				continue
			best.append({"x": info.bx, "z": info.bz, "hMax": info.hMax,
				"wall": wall, "ix": ix, "iz": iz})
	best.sort_custom(func(a, b): return a.wall > b.wall)
	print("spots=", best.size())
	for i in min(8, best.size()):
		var s = best[i]
		print("  wall=%d hMax=%d at (%d,%d)" % [s.wall, s.hMax, s.x, s.z])
	if best.is_empty():
		quit(0)
		return
	# 给出三个机位：岸外 260/420/700 格、低机位朝岸看
	var s = best[0]
	for d in [260.0, 420.0, 700.0]:
		print("VANTAGE cam=(%d, %d, %d) target=(%d, %d, %d)" % [
			int(s.x - d), SEA + 18, int(s.z - 60.0),
			s.x, s.hMax, s.z])
	quit(0)


func _cell(cache: Dictionary, ix: int, iz: int) -> Dictionary:
	var key := "%d_%d" % [ix, iz]
	if cache.has(key):
		return cache[key]
	var bx := ix * S
	var bz := iz * S
	if absi(bx) > 1600 or absi(bz) > 1600:
		var skip := {"x": -1}
		cache[key] = skip
		return skip
	var hMax := -1
	var waterN := 0
	for sz in 2:
		for sx in 2:
			var h: int = gen.column_height(bx + (Q if sx == 0 else S - 1 - Q),
				bz + (Q if sz == 0 else S - 1 - Q))
			if h > hMax:
				hMax = h
			if h <= SEA:
				waterN += 1
	var info := {"x": bx, "z": bz, "bx": bx, "bz": bz, "hMax": hMax, "waterN": waterN}
	cache[key] = info
	return info
