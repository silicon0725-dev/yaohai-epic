## 方块实体渲染器基类：区块网格跳过型方块（render_type cross/model）
## 的实体生命周期——放置/拆除生成清除、区块激活扫描重建（存档恢复
## 顺序无关）、区块卸载清除。火把（TorchRenderer）与提灯
##（LanternRenderer）共用以实体管线（树系统同款生命周期模式）。
## 子类覆盖 _build_model()（返回 Mesh；null 则不生成）与可选
## _cell_offset()。无 class_name——子类 extends 本文件路径。
extends Node

var world: VoxelWorld
var _block_id := -1  # 子类 setup 注入（VoxelTypes 常量）
## Vector3i -> MeshInstance3D（逐实例路径）或 int 实例下标
##（MultiMesh 路径——审查二轮 C8：高密度方块实体 200 支 × 3 surface
## = 600 draw call，MultiMesh 化后 3 个；_by_cell 语义不变，count()/
## 区块卸载遍历两路径通用）
var _by_cell := {}
var _mesh: Mesh
var _use_multimesh := false
var _mm: MultiMesh
var _cell_by_index: Array = []  # MultiMesh 实例下标 -> Vector3i（swap 用）
## 实例 transform 本地镜像（与 _cell_by_index 平行）：headless 测试下
## MultiMesh 的 set/get_instance_transform 是渲染服务器存根（读写全
## 零），swap 只能靠本地数据；真机下与 _mm 双写保持一致
var _xforms_by_index: Array = []


func setup(p_world: VoxelWorld, p_block_id: int,
		p_use_multimesh := false) -> void:
	world = p_world
	_block_id = p_block_id
	_mesh = _build_model()
	_use_multimesh = p_use_multimesh and _mesh != null
	if _use_multimesh:
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.mesh = _mesh
		_mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
	world.block_changed.connect(_on_block_changed)
	# 批量通道（树清理等）：cells 全部已 AIR 化——在册实体即幽灵
	#（曾不订阅=未来批量删火把留幽灵实体，审查二轮 L1）
	world.blocks_changed_batch.connect(_on_blocks_batch)


## 批量变更：格已全部 AIR 化——在册实体即幽灵，逐格 despawn
func _on_blocks_batch(cells: Array) -> void:
	for pos_v in cells:
		_despawn(pos_v)


## 子类覆盖：构建本方块的实体模型（返回 null 则永不生成）
func _build_model() -> Mesh:
	return null


## 子类覆盖：格原点偏移（如火把贴墙 -attach*6/16）
func _cell_offset(_attach: Vector3i) -> Vector3:
	return Vector3.ZERO


## 区块激活：扫描方块表补建实体（加载顺序无关——含存档恢复）
func on_chunk_active(coord: Vector3i) -> void:
	var chunk: ChunkData = world.chunks.get(coord)
	if chunk == null:
		return
	var s := chunk.dimensions.x
	for i in chunk.volume():
		if chunk.block_ids[i] == _block_id:
			var z := i / (s * s)
			var rem := i - z * s * s
			var y := rem / s
			var x := rem - y * s
			var local := Vector3i(x, y, z)
			_spawn(coord * s + local, parse_attach(chunk.get_state(local)))


## 区块卸载：实体一并移除（重激活时由扫描重建）
func on_chunk_unloaded(coord: Vector3i) -> void:
	var s := world.config.chunk_size
	var base := coord * s
	for cell in _by_cell.keys():
		if cell.x >= base.x and cell.x < base.x + s \
				and cell.y >= base.y and cell.y < base.y + s \
				and cell.z >= base.z and cell.z < base.z + s:
			_despawn(cell)


func _on_block_changed(pos: Vector3i, old_id: int, new_id: int) -> void:
	if new_id == _block_id:
		# 延迟到帧末：放置端在 set_block 之后才写 attach 状态
		#（set_block 会清状态），立即生成读不到贴墙方向
		_spawn_deferred.call_deferred(pos)
	elif old_id == _block_id:
		_despawn(pos)


func _spawn_deferred(pos: Vector3i) -> void:
	var attach := Vector3i.ZERO
	var st := world.get_block_state(pos)
	if st.has("attach"):
		attach = parse_attach(st)
	_spawn(pos, attach)


func parse_attach(state: Dictionary) -> Vector3i:
	var raw := String(state.get("attach", ""))
	if raw.is_empty():
		return Vector3i.ZERO
	var parts := raw.split(",")
	if parts.size() != 3:
		return Vector3i.ZERO
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))


func _spawn(cell: Vector3i, attach: Vector3i) -> void:
	if _mesh == null:
		return
	var pos := Vector3(cell) + _cell_offset(attach)
	if _use_multimesh:
		var xf := Transform3D(Basis(), pos)
		# 已存在 -> 重定位（延迟生成/状态后补时重入）
		var idx: int = _by_cell.get(cell, -1)
		if idx >= 0:
			_mm.set_instance_transform(idx, xf)
			_xforms_by_index[idx] = xf
			return
		var n := _mm.instance_count
		_mm.instance_count = n + 1  # 增容保留既有数据（引擎语义）
		_mm.set_instance_transform(n, xf)
		_by_cell[cell] = n
		_cell_by_index.append(cell)
		_xforms_by_index.append(xf)
		return
	# 已存在 -> 重定位（延迟生成/状态后补时重入）
	var exist: MeshInstance3D = _by_cell.get(cell)
	if exist != null:
		exist.position = pos
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.position = pos
	add_child(mi)
	_by_cell[cell] = mi


func _despawn(cell: Vector3i) -> void:
	if _use_multimesh:
		var idx: int = _by_cell.get(cell, -1)
		if idx < 0:
			return
		# 与末位实例交换再截断（保持 0..count-1 连续活跃；比零缩放
		# 隐藏省实例缓冲与顶点着色成本）。transform 用本地镜像取末位
		#（headless 下 get_instance_transform 是存根读不回）
		var last := _xforms_by_index.size() - 1
		if idx < last:
			var last_cell: Vector3i = _cell_by_index[last]
			var last_xf: Transform3D = _xforms_by_index[last]
			_mm.set_instance_transform(idx, last_xf)
			_xforms_by_index[idx] = last_xf
			_cell_by_index[idx] = last_cell
			_by_cell[last_cell] = idx
		_xforms_by_index.remove_at(last)
		_cell_by_index.remove_at(last)
		_mm.instance_count = last
		_by_cell.erase(cell)
		return
	var mi: MeshInstance3D = _by_cell.get(cell)
	if mi != null:
		mi.queue_free()
		_by_cell.erase(cell)


## 调试/测试：当前实体数
func count() -> int:
	return _by_cell.size()


## 盒子表面数组（min/max 局部 0..1 格内；绕序 0,2,1 / 0,3,2——
## Godot 正面顺时针）。子类模型构件共用。
static func box_surface(mn: Vector3, mx: Vector3) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var faces := [
		[Vector3(1, 0, 0), Vector3(mx.x, mn.y, mx.z), Vector3(mx.x, mn.y, mn.z),
			Vector3(mx.x, mx.y, mn.z), Vector3(mx.x, mx.y, mx.z)],
		[Vector3(-1, 0, 0), Vector3(mn.x, mn.y, mn.z), Vector3(mn.x, mn.y, mx.z),
			Vector3(mn.x, mx.y, mx.z), Vector3(mn.x, mx.y, mn.z)],
		[Vector3(0, 1, 0), Vector3(mn.x, mx.y, mx.z), Vector3(mx.x, mx.y, mx.z),
			Vector3(mx.x, mx.y, mn.z), Vector3(mn.x, mx.y, mn.z)],
		[Vector3(0, -1, 0), Vector3(mn.x, mn.y, mn.z), Vector3(mx.x, mn.y, mn.z),
			Vector3(mx.x, mn.y, mx.z), Vector3(mn.x, mn.y, mx.z)],
		[Vector3(0, 0, 1), Vector3(mn.x, mn.y, mx.z), Vector3(mx.x, mn.y, mx.z),
			Vector3(mx.x, mx.y, mx.z), Vector3(mn.x, mx.y, mx.z)],
		[Vector3(0, 0, -1), Vector3(mx.x, mn.y, mn.z), Vector3(mn.x, mn.y, mn.z),
			Vector3(mn.x, mx.y, mn.z), Vector3(mx.x, mx.y, mx.z)],
	]
	for f in faces:
		var base := vertices.size()
		var normal: Vector3 = f[0]
		for c in 4:
			vertices.append(f[1 + c])
			normals.append(normal)
		indices.append(base)
		indices.append(base + 2)
		indices.append(base + 1)
		indices.append(base)
		indices.append(base + 3)
		indices.append(base + 2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays
