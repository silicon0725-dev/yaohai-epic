## 区块渲染器（开发文档 §2.1 网格表现层 / §6.4 / §8.3 / §10.1）：
## RenderingServer / PhysicsServer3D 直连——每区块不再创建
## MeshInstance3D + StaticBody3D + CollisionShape3D 节点。
## 高视距下数千区块 × 3 节点的场景树开销（变换传播、遍历、
## name 字符串分配、queue_free 结算）是主线程固定成本；RS/PS
## 直连后主线程只做 ArrayMesh/Shape 资源组装与 RID 提交。
## 生命周期：ChunkManager 决定何时注册/移除/应用网格，本类只在
## 主线程创建与替换引擎资源（工作线程只产出纯数组）。
## ArrayMesh / ConcavePolygonShape3D 是 Resource：RID 由引擎资源
## 管理，条目持引用防提前释放，替换/移除时随引用断开自动回收。
class_name ChunkRenderer
extends Node3D

var world: VoxelWorld
var material: Material
## 水面材质（§6.5 独立半透明表面）；为空时不建水面
var water_material: Material
var water_side_material: Material
## 树叶镂空材质（cutout 表面；为空时叶面不建独立表面）
var cutout_material: Material

var total_faces := 0

## coord -> {inst, body, mesh, shape, faces, has_collision}
var _entries := {}
var _scenario: RID
var _space: RID
var _chunk_faces := {}  # Vector3i -> int


func setup(p_world: VoxelWorld, p_material: Material) -> void:
	world = p_world
	material = p_material


func _ready() -> void:
	_bind_servers()


func _bind_servers() -> void:
	if _scenario.is_valid():
		return
	var w3d := get_world_3d()
	if w3d != null:
		_scenario = w3d.scenario
		_space = w3d.space


## 为区块创建渲染实例与静态碰撞体（纯 RID，无节点）。
func register_chunk(coord: Vector3i) -> void:
	if _entries.has(coord):
		return
	_bind_servers()
	var origin := Vector3(
			VoxelCoords.chunk_origin(coord, world.config.chunk_size))
	var inst := RenderingServer.instance_create()
	if _scenario.is_valid():
		RenderingServer.instance_set_scenario(inst, _scenario)
	RenderingServer.instance_set_transform(inst, Transform3D(Basis(), origin))
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	if _space.is_valid():
		PhysicsServer3D.body_set_space(body, _space)
	PhysicsServer3D.body_set_state(
			body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), origin))
	_entries[coord] = {
		"inst": inst,
		"body": body,
		"mesh": null,
		"shape": null,
		"has_collision": false,
	}


## 该区块当前是否持有碰撞形状（ChunkManager 碰撞圈补建判定用）。
func has_collision(coord: Vector3i) -> bool:
	var entry: Dictionary = _entries.get(coord, {})
	return not entry.is_empty() and entry.has_collision


## 主线程提交：由网格数组创建 ArrayMesh 与碰撞形状并赋给 RID。
## rebuild_collision=false（纯水位变化/碰撞圈外）时跳过昂贵的
## ConcavePolygonShape3D 顶点汤重建——水没有碰撞体，固体面未变。
func apply_mesh(
		coord: Vector3i, mesh_arrays: Dictionary, rebuild_collision := true
) -> void:
	var entry: Dictionary = _entries.get(coord, {})
	if entry.is_empty():
		return
	var opaque: int = mesh_arrays.get("indices", PackedInt32Array()).size()
	var water: int = mesh_arrays.get("water_indices", PackedInt32Array()).size()
	var water_side: int = mesh_arrays.get(
			"water_side_indices", PackedInt32Array()).size()
	var cutout: int = mesh_arrays.get(
			"cutout_indices", PackedInt32Array()).size()
	var mesh: ArrayMesh
	if opaque > 0 or water > 0 or water_side > 0 or cutout > 0:
		mesh = MeshBuilder.arrays_to_mesh(
				mesh_arrays, material, water_material, water_side_material,
				cutout_material)
	else:
		mesh = ArrayMesh.new()  # 空区块：无表面
	# 先切 instance base 再换引用：旧 mesh 资源随引用断开自动释放
	RenderingServer.instance_set_base(entry.inst, mesh.get_rid())
	entry.mesh = mesh
	if rebuild_collision:
		var shape := ChunkCollisionBuilder.build_collision_shape(mesh_arrays)
		PhysicsServer3D.body_clear_shapes(entry.body)
		PhysicsServer3D.body_add_shape(entry.body, shape.get_rid())
		entry.shape = shape
		entry.has_collision = true
	var new_faces := (opaque + water + water_side + cutout) / 6
	total_faces += new_faces - int(_chunk_faces.get(coord, 0))
	_chunk_faces[coord] = new_faces


## 卸载：释放该区块的 RID（mesh/shape 资源随引用断开自动回收）。
func remove_chunk(coord: Vector3i) -> void:
	var entry: Dictionary = _entries.get(coord, {})
	if entry.is_empty():
		return
	RenderingServer.free_rid(entry.inst)
	PhysicsServer3D.free_rid(entry.body)
	entry.mesh = null
	entry.shape = null
	_entries.erase(coord)
	total_faces -= int(_chunk_faces.get(coord, 0))
	_chunk_faces.erase(coord)
