## 打印壳网格每个 surface 的数组构成与法线是否一致（圆盘扇纹定位用）
##   godot --headless --path . -s debug/probe_shell_arrays.gd
extends SceneTree

const Bridge := preload("res://meshing/native_terrain_bridge.gd")


func _initialize() -> void:
	Bridge.prewarm(1337, 512)
	var native = Bridge.get_native(1337, 512)
	var mesh: ArrayMesh = native.GenerateShellMesh(90, -234)
	print("surfaces=", mesh.get_surface_count())
	for si in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n = arr[Mesh.ARRAY_NORMAL]
		var nn: PackedVector3Array = n if n != null else PackedVector3Array()
		var up := 0
		var down := 0
		var other := 0
		for i in nn.size():
			if nn[i].y > 0.9:
				up += 1
			elif nn[i].y < -0.9:
				down += 1
			else:
				other += 1
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		print("surface ", si, " verts=", v.size(), " normals=", nn.size(),
				" up=", up, " down=", down, " other=", other,
				" idx=", idx.size())
	quit(0)
