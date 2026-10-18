## 网格数组 -> ArrayMesh / MeshInstance3D（开发文档 §6.2 第 5 步）。
## 引擎对象（ArrayMesh、MeshInstance3D）的创建集中在主线程调用方；
## Stage A 为同步构建，阶段 C 改为后台计算纯数组、主线程提交资源（§10.1）。
## 网格版本号（防止旧任务覆盖新网格）在阶段 C 引入。
class_name MeshBuilder
extends RefCounted


static func arrays_to_mesh(mesh_arrays: Dictionary, material: Material) -> ArrayMesh:
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
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


static func create_chunk_instance(mesh: ArrayMesh, position: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	return instance
