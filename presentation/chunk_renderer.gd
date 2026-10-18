## 区块渲染器（开发文档 §2.1 网格表现层 / §6.4 / §8.3 / §10.1）：
## 持有每个活跃区块的 MeshInstance3D 与 StaticBody3D。
## 阶段 C 起为被动接口：由 ChunkManager 决定何时注册/移除/应用网格，
## 本类只在主线程创建与替换引擎资源（工作线程只产出纯数组）。
## 网格与碰撞来自同一份剔除后的面数据，但分别持有资源。
class_name ChunkRenderer
extends Node3D

var world: VoxelWorld
var material: Material

var total_faces := 0

var _mesh_instances := {}  # Vector3i -> MeshInstance3D
var _bodies := {}          # Vector3i -> StaticBody3D
var _chunk_faces := {}     # Vector3i -> int


func setup(p_world: VoxelWorld, p_material: Material) -> void:
	world = p_world
	material = p_material


## 为区块创建空节点（网格随后由 apply_mesh 填充）。
func register_chunk(coord: Vector3i) -> void:
	if _mesh_instances.has(coord):
		return
	var origin := Vector3(
			VoxelCoords.chunk_origin(coord, world.config.chunk_size))
	var body := StaticBody3D.new()
	body.position = origin
	body.name = "Collision_%d_%d_%d" % [coord.x, coord.y, coord.z]
	add_child(body)
	var collider := CollisionShape3D.new()
	body.add_child(collider)
	_bodies[coord] = body
	body.set_meta("collider", collider)

	var instance := MeshInstance3D.new()
	instance.position = origin
	instance.name = "Chunk_%d_%d_%d" % [coord.x, coord.y, coord.z]
	add_child(instance)
	_mesh_instances[coord] = instance


## 主线程提交：由网格数组创建 ArrayMesh 与碰撞形状并赋给节点。
func apply_mesh(coord: Vector3i, mesh_arrays: Dictionary) -> void:
	if not _mesh_instances.has(coord):
		return
	var mesh: ArrayMesh
	if mesh_arrays["indices"].size() > 0:
		mesh = MeshBuilder.arrays_to_mesh(mesh_arrays, material)
	else:
		mesh = ArrayMesh.new()  # 空区块：无表面
	_mesh_instances[coord].mesh = mesh
	var body: StaticBody3D = _bodies[coord]
	var collider: CollisionShape3D = body.get_meta("collider")
	collider.shape = ChunkCollisionBuilder.build_collision_shape(mesh_arrays)
	var new_faces: int = mesh_arrays["indices"].size() / 6
	total_faces += new_faces - int(_chunk_faces.get(coord, 0))
	_chunk_faces[coord] = new_faces


## 卸载：释放该区块的全部视觉与碰撞节点。
func remove_chunk(coord: Vector3i) -> void:
	if not _mesh_instances.has(coord):
		return
	_mesh_instances[coord].queue_free()
	_mesh_instances.erase(coord)
	_bodies[coord].queue_free()
	_bodies.erase(coord)
	total_faces -= int(_chunk_faces.get(coord, 0))
	_chunk_faces.erase(coord)
