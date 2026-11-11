## 壳几何探针（headless）：分类 GenerateShellMesh 的三角形法线，找
## 非轴对齐（剪切/斜切）面、侧壁高度分布、同级重复面。
##   godot --headless --path . -s debug/probe_shell_geom.gd
extends SceneTree

const Bridge := preload("res://meshing/native_terrain_bridge.gd")
const GenScript := preload("res://generation/terrain_generator.gd")
const ConfigScript := preload("res://core/world_config.gd")
const ShellLevels := [4, 8, 16, 32]


func _initialize() -> void:
	await process_frame
	if not Bridge.available():
		print("NO NATIVE")
		quit(1)
		return
	var cfg = ConfigScript.new()
	cfg.chunks_y = 32
	var gen = GenScript.new(cfg)
	var sea: int = gen.sea_level
	print("SEA=", sea, " H=", cfg.world_height_blocks())
	var center := _find_shore(gen, sea)
	print("CENTER=", center, " h=", gen.column_height(center.x, center.y))
	var native = Bridge.get_native(1337, cfg.world_height_blocks())
	var mesh: Mesh = native.GenerateShellMesh(center.x, center.y)
	print("surfaces=", mesh.get_surface_count())
	for si in range(1, mesh.get_surface_count()):
		_analyze(mesh, si, ShellLevels[si - 1], sea)
	quit(0)


## 在 (34,34) 附近找"岸线中心"：自身是水、西侧 30 格内有陆地。
func _find_shore(gen, sea: int) -> Vector2i:
	for r in range(0, 60):
		for a in 32:
			var ang: float = TAU * a / 32.0
			var cx: int = int(34.0 + cos(ang) * r * 8.0)
			var cz: int = int(34.0 + sin(ang) * r * 8.0)
			if gen.column_height(cx, cz) > sea - 2:
				continue
			# 向东 24 格内出现陆地 = 岸
			for d in range(4, 25, 4):
				if gen.column_height(cx + d, cz) > sea + 1:
					return Vector2i(cx - 40, cz)
	return Vector2i(34, 34)


func _analyze(mesh: Mesh, si: int, S: int, sea: int) -> void:
	var arrays: Array = mesh.surface_get_arrays(si)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var nt := idx.size() / 3
	var up := 0
	var wall_x := 0
	var wall_z := 0
	var slant := 0
	var slant_samples: Array[String] = []
	var wall_h := {}
	for t in nt:
		var a := v[idx[t * 3]]
		var b := v[idx[t * 3 + 1]]
		var c := v[idx[t * 3 + 2]]
		var n := norms[idx[t * 3]]
		var ax := absf(n.x)
		var ay := absf(n.y)
		var az := absf(n.z)
		if ay > 0.99:
			up += 1
		elif ax > 0.99:
			wall_x += 1
		elif az > 0.99:
			wall_z += 1
		else:
			slant += 1
			if slant_samples.size() < 6:
				slant_samples.append("A=%s B=%s C=%s N=%s" % [a, b, c, n])
		# 侧壁高度统计（按三角形顶点 y 跨）
		if ax > 0.99 or az > 0.99:
			var hi := maxf(maxf(a.y, b.y), c.y)
			var lo := minf(minf(a.y, b.y), c.y)
			var dh := int(round(hi - lo))
			wall_h[dh] = wall_h.get(dh, 0) + 1
	# 实际几何法线（不用法线通道）：检查三角形是否共面竖直
	var sheared := 0
	var samples2: Array[String] = []
	for t in mini(nt, 200000):
		var a := v[idx[t * 3]]
		var b := v[idx[t * 3 + 1]]
		var c := v[idx[t * 3 + 2]]
		var gn := (b - a).cross(c - a)
		if gn.length() < 0.0001:
			sheared += 1
			if samples2.size() < 4:
				samples2.append("degenerate %s %s %s" % [a, b, c])
			continue
		gn = gn.normalized()
		var ax := absf(gn.x)
		var ay := absf(gn.y)
		var az := absf(gn.z)
		var is_axis := ax > 0.99 or ay > 0.99 or az > 0.99
		# 竖直面：法线水平分量为主（即使斜切也抓到）
		if not is_axis and (a.y != b.y or b.y != c.y):
			sheared += 1
			if samples2.size() < 6:
				samples2.append("shear %s %s %s" % [a, b, c])
	print("--- level S=%d  verts=%d tris=%d" % [S, v.size(), nt])
	print("    up=%d  wall+X/-X=%d  wall+Z/-Z=%d  SLANTED=%d  sheared=%d"
			% [up, wall_x, wall_z, slant, sheared])
	print("    wall height hist: ", wall_h)
	for s in slant_samples:
		print("    SLANT ", s)
	for s in samples2:
		print("    SHEAR ", s)
