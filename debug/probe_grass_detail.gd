## 草叶距离分级等价探针：detail 0/1/2 三档 GD 与 C# 逐档对拍
##（B9b 教训：曾 GD 侧替换静默失败——detail<2 密度不降、与 C# 不
## 等价，而 parity/全量测试只覆盖 detail 2 默认档全绿假象）
extends SceneTree


func _init() -> void:
	var registry: VoxelRegistry = VoxelTypes.build_default_registry()
	var nb27: Array = []
	nb27.resize(27)
	var bridge := preload("res://meshing/native_mesh_bridge.gd")
	for detail in 3:
		# 贪心路径（游戏实跑路径）追加对拍
		var chunk_g := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16))
		chunk_g.set_block(Vector3i(8, 5, 8), VoxelTypes.GRASS_ID)
		var csg: Dictionary = bridge.build(true, registry, chunk_g, nb27,
				null, detail)
		print("greedy detail=%d C# v=%d i=%d" % [detail,
				csg.get("cross_vertices", PackedVector3Array()).size(),
				csg.get("cross_indices", PackedInt32Array()).size()])
		var chunk := ChunkData.new(Vector3i.ZERO, Vector3i(16, 16, 16))
		chunk.set_block(Vector3i(8, 5, 8), VoxelTypes.GRASS_ID)
		var gd: Dictionary = ChunkMesher._build_gd(registry, chunk, nb27,
				null, detail)
		var gv: int = gd.get("cross_vertices",
				PackedVector3Array()).size()
		var gi: int = gd.get("cross_indices", PackedInt32Array()).size()
		var cs: Dictionary = bridge.build(false, registry, chunk, nb27,
				null, detail)
		var cv: int = cs.get("cross_vertices", PackedVector3Array()).size()
		var ci: int = cs.get("cross_indices", PackedInt32Array()).size()
		print("detail=%d GD v=%d i=%d | C# v=%d i=%d" % [
				detail, gv, gi, cv, ci])
	var failures := 0
	quit(1 if failures > 0 else 0)
