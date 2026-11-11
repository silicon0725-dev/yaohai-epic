## 海岸 LOD 剖面探针：把 GenerateShellMesh 的格参数在 GDScript 里复算，
## 打印穿过海岸线的横剖面（hMax / 量化 hq / tops / 群系 / 露出水面的墙高）
##   godot --headless --path . -s debug/probe_coast2.gd
extends SceneTree

const CaptureLib := preload("res://debug/capture_lib.gd")
const LEVELS := [4, 8, 16, 32]

var main_ref: Node


func _init() -> void:
	_run()


## 复算单格参数：[hMax, waterN, tops, biome]
func _cell(gen, bx: int, bz: int, S: int, sea: int) -> Array:
	var vs: int = max(1, S / 2)
	var q: int = max(1, S / 4)
	var hMax := -2147483648
	var waterN := 0
	for sz in 2:
		for sx in 2:
			var px: int = bx + (q if sx == 0 else S - 1 - q)
			var pz: int = bz + (q if sz == 0 else S - 1 - q)
			var h: int = gen.column_height(px, pz)
			if h > hMax:
				hMax = h
			if h <= sea:
				waterN += 1
	if waterN == 4:
		return [hMax, waterN, sea - 1, 0]
	if waterN > 0:
		return [hMax, waterN, sea - 2, 2]
	return [hMax, waterN, max(hMax / vs * vs, sea + vs), 1]


func _run() -> void:
	main_ref = CaptureLib.boot_isolated(get_root(), "probe_coast")
	var t0 := Time.get_ticks_msec()
	while main_ref == null or main_ref.generator == null:
		await process_frame
		if Time.get_ticks_msec() - t0 > 30000:
			print("TIMEOUT boot")
			quit(1)
			return
	var gen = main_ref.generator
	var sea: int = gen.sea_level
	var cz := -220
	print("SEA=", sea, " scanline cz=", cz, " along +X")
	for S in LEVELS:
		var vs: int = max(1, S / 2)
		# 先找岸线（水→陆过渡）
		var shore := 99999
		var cx := -200
		while cx <= 400:
			var c := _cell(gen, cx, cz, S, sea)
			if c[3] != 0:
				shore = cx
				break
			cx += max(4, S)
		print("\n=== S=%d vs=%d shore_cx=%d ===" % [S, vs, shore])
		print("   cx   hMax  wN biome  tops  wallAboveSea")
		cx = shore - 3 * max(4, S)
		while cx <= shore + 3 * S:
			var c := _cell(gen, cx, cz, S, sea)
			var wall := ""
			if c[3] != 0:
				wall = str(c[2] - (sea - 1))
			print("%5d %6d %3d %5d %5d   %s" % [cx, c[0], c[1], c[3], c[2], wall])
			cx += max(4, S)
	quit(0)
