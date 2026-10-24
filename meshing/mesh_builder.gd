## 网格数组 -> ArrayMesh / MeshInstance3D（开发文档 §6.2 第 5 步）。
## 引擎对象（ArrayMesh、MeshInstance3D）的创建集中在主线程调用方；
## Stage A 为同步构建，阶段 C 改为后台计算纯数组、主线程提交资源（§10.1）。
## 网格版本号（防止旧任务覆盖新网格）在阶段 C 引入。
class_name MeshBuilder
extends RefCounted


## water_material 非空且存在 water_indices 时追加半透明表面；再存在
## water_side_indices 时追加第三个表面（水侧面专用背面剔除材质——
## 下落水柱四个侧面都朝空气，双面材质会从一侧看到远侧背面，
## 半透明双层叠加成"浮空背面"；侧面只出正面，顶/底面保持双面
## 供潜水视角从下往上看水面）。
static func arrays_to_mesh(
		mesh_arrays: Dictionary, material: Material,
		water_material: Material = null,
		water_side_material: Material = null
) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_arrays.get("vertices", PackedVector3Array())
	arrays[Mesh.ARRAY_NORMAL] = mesh_arrays.get("normals", PackedVector3Array())
	arrays[Mesh.ARRAY_TEX_UV] = mesh_arrays.get("uvs", PackedVector2Array())
	if mesh_arrays.has("uv2"):
		# Greedy Meshing：UV2 携带 tile 原点，配合平铺着色器
		arrays[Mesh.ARRAY_TEX_UV2] = mesh_arrays["uv2"]
	arrays[Mesh.ARRAY_INDEX] = mesh_arrays.get("indices", PackedInt32Array())
	var mesh := ArrayMesh.new()
	# 临时校验：水表面 COLOR 与顶点数不匹配会丢三角形（洞排查）
	var wc: PackedColorArray = mesh_arrays.get("water_colors", PackedColorArray())
	var wv: PackedVector3Array = mesh_arrays.get("water_vertices", PackedVector3Array())
	if not wc.is_empty() and wc.size() != wv.size():
		push_error("WATER COLOR MISMATCH: colors %d verts %d" % [wc.size(), wv.size()])
	var sc: PackedColorArray = mesh_arrays.get("water_side_colors", PackedColorArray())
	var sv: PackedVector3Array = mesh_arrays.get("water_side_vertices", PackedVector3Array())
	if not sc.is_empty() and sc.size() != sv.size():
		push_error("SIDE COLOR MISMATCH: colors %d verts %d" % [sc.size(), sv.size()])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	if water_material != null and mesh_arrays.get("water_indices",
			PackedInt32Array()).size() > 0:
		var water_arrays := []
		water_arrays.resize(Mesh.ARRAY_MAX)
		water_arrays[Mesh.ARRAY_VERTEX] = mesh_arrays.get(
				"water_vertices", PackedVector3Array())
		water_arrays[Mesh.ARRAY_NORMAL] = mesh_arrays.get(
				"water_normals", PackedVector3Array())
		water_arrays[Mesh.ARRAY_INDEX] = mesh_arrays.get(
				"water_indices", PackedInt32Array())
		water_arrays[Mesh.ARRAY_COLOR] = mesh_arrays.get(
				"water_colors", PackedColorArray())
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, water_arrays)
		mesh.surface_set_material(1, water_material)
	if water_side_material != null and mesh_arrays.get("water_side_indices",
			PackedInt32Array()).size() > 0:
		var side_arrays := []
		side_arrays.resize(Mesh.ARRAY_MAX)
		side_arrays[Mesh.ARRAY_VERTEX] = mesh_arrays.get(
				"water_side_vertices", PackedVector3Array())
		side_arrays[Mesh.ARRAY_NORMAL] = mesh_arrays.get(
				"water_side_normals", PackedVector3Array())
		side_arrays[Mesh.ARRAY_INDEX] = mesh_arrays.get(
				"water_side_indices", PackedInt32Array())
		side_arrays[Mesh.ARRAY_COLOR] = mesh_arrays.get(
				"water_side_colors", PackedColorArray())
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, side_arrays)
		mesh.surface_set_material(2, water_side_material)
	return mesh


static func create_chunk_instance(mesh: ArrayMesh, position: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	return instance
