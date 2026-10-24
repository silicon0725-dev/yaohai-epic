## 区块碰撞构建（开发文档 §8.3）：把可见面剔除后的三角面
## 转为 ConcavePolygonShape3D。可见面即实际可接触的表面，
## 因此碰撞几何与渲染网格同源但作为独立资源调度
##（collision_dirty 与 mesh_dirty 分开标记）。
class_name ChunkCollisionBuilder
extends RefCounted


static func build_collision_shape(mesh_arrays: Dictionary) -> ConcavePolygonShape3D:
	var vertices: PackedVector3Array = mesh_arrays.get(
			"vertices", PackedVector3Array())
	var indices: PackedInt32Array = mesh_arrays.get(
			"indices", PackedInt32Array())
	# 树叶面在 cutout 桶（独立渲染表面）——碰撞仍同源：合并两桶
	#（叶碰撞不能丢：玩家要能站树冠、掉落物落树冠）
	var cutout: PackedInt32Array = mesh_arrays.get(
			"cutout_indices", PackedInt32Array())
	# ConcavePolygonShape3D.faces 为三角形顶点汤（3 顶点一组，无索引）
	var faces := PackedVector3Array()
	faces.resize(indices.size() + cutout.size())
	for i in indices.size():
		faces[i] = vertices[indices[i]]
	var off: int = indices.size()
	for i in cutout.size():
		faces[off + i] = vertices[cutout[i]]
	var shape := ConcavePolygonShape3D.new()
	# 注：faces 属性在 4.7 不可直接赋值，需经 set_faces()
	shape.set_faces(faces)
	# 背面也参与碰撞：流式重建替换形状的瞬间或高速穿角时，
	# 玩家可能进入网格内部；凹面形状默认只碰撞正面会导致直接坠穿世界。
	shape.backface_collision = true
	return shape
