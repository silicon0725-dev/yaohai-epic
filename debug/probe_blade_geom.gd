## 临时：产品路径叶片几何真值——单草块 chunk，打印首叶各关键宽度
extends SceneTree


func _init() -> void:
	var registry: VoxelRegistry = VoxelTypes.build_default_registry()
	var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16))
	chunk.set_block(Vector3i(8, 5, 8), VoxelTypes.GRASS_ID)
	var nb27: Array = []
	nb27.resize(27)
	var arr: Dictionary = ChunkMesher._build_gd(registry, chunk, nb27)
	var v: PackedVector3Array = arr.get("cross_vertices", PackedVector3Array())
	print("cross verts=", v.size())
	# 首 8 顶点 = 首叶 4 关键（左右成对）
	for ci in 4:
		var a: Vector3 = v[ci * 2]
		var b: Vector3 = v[ci * 2 + 1]
		print("key%d L=%s R=%s width=%.4f" % [ci, a, b, (b - a).length()])
	quit(0)
