## 树叶渲染验收：找最近树叶簇，近景拍白天观感（cutout 孔洞/明暗）。
##   godot --path . res://debug/capture_leaves.tscn
extends Node

const CaptureLib := preload("res://debug/capture_lib.gd")

var main_ref: Node
var _phase := 0
var _wait := 0.0
var _found := Vector3i.ZERO
var _center := Vector3.ZERO
var _cam: Camera3D
var _torch := Vector3i.ZERO


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1280, 720)
	main_ref = CaptureLib.boot_isolated(self, "leaves_test")


func _process(delta: float) -> void:
	_wait += delta
	match _phase:
		0:
			if _wait > 12.0 and not main_ref._loading:
				_setup()
				_phase = 1
				_wait = 0.0
		1:
			if _wait > 1.0:
				CaptureLib.shoot(get_viewport(), "debug/leaves_v1_day.png")
				# 午夜 + 树干旁火把：验证枝干受方块光（合并式顶点色）
				main_ref._time_of_day = 0.75
				var world: VoxelWorld = main_ref.world
				var tp := _find_trunk_side(world, _found)
				var ok := BlockPlacement.place(world, tp,
						VoxelTypes.TORCH_ID,
						AABB(Vector3(1000, 1000, 1000), Vector3.ONE),
						Vector3i.UP)
				print("TRUNK torch place=", ok, " at ", tp)
				_torch = tp
				# 标记是同步的：放置后立即查脏集合
				print("MARK dirty_after_place=",
						main_ref.tree_manager._light_dirty)
				_cam.position = _center + Vector3(-2.5, 0.2, -2.5)
				_cam.look_at(Vector3(tp) + Vector3(0.5, 0.4, 0.5), Vector3.UP)
				_phase = 2
				_wait = 0.0
		2:
			if _wait > 2.5 and main_ref.chunk_manager.is_idle():
				CaptureLib.shoot(get_viewport(), "debug/leaves_v1_midnight_trunk.png")
				# 平视树干近景：验证树干面受火把暖光（合并式顶点色）。
				# 沿火把列向上找枝干格（树干基可能高于地面 1 格）
				var trunk := Vector3i.ZERO
				var world2: VoxelWorld = main_ref.world
				for dy in range(0, 12):
					var probe := _torch + Vector3i(0, dy, 0)
					for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
							Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
						var nb: int = world2.get_block(probe + d)
						if nb == VoxelTypes.BRANCH_ID or nb == VoxelTypes.LOG_ID:
							trunk = probe + d
							print("TRUNK hit dy=", dy, " id=", nb)
							break
					if trunk != Vector3i.ZERO:
						break
				print("TRUNK cell=", trunk)
				if trunk != Vector3i.ZERO:
					var dir := Vector3(_torch - trunk)
					dir.y = 0.0
					dir = dir.normalized()
					var base := Vector3(trunk.x, _torch.y, trunk.z)
					_cam.position = base + dir * 3.0 + Vector3(0, 0.8, 0)
					_cam.look_at(base + Vector3(0, 0.6, 0), Vector3.UP)
				_phase = 3
				_wait = 0.0
		3:
			if _wait > 1.5:
				CaptureLib.shoot(get_viewport(), "debug/leaves_v1_trunk_close.png")
				# 引擎内探针：脏标记状态 / 光照值 / 树网格顶点色
				var tm: Node = main_ref.tree_manager
				print("PROBE dirty=", tm._light_dirty,
						" wait=", tm._light_dirty_wait)
				var wl: VoxelWorld = main_ref.world
				var csz: int = wl.config.chunk_size
				var torch_cell := Vector3i(53, 23, 2)
				var tck: ChunkData = wl.get_chunk(Vector3i(
						torch_cell.x / csz, torch_cell.y / csz,
						torch_cell.z / csz))
				var tlocal: Vector3i = torch_cell - Vector3i(
						tck.chunk_coord.x * csz, tck.chunk_coord.y * csz,
						tck.chunk_coord.z * csz)
				print("PROBE light torch_cell=",
						tck.get_block_light(tlocal))
				var tree = tm.get_tree_at(Vector3i(52, 23, 2))
				print("PROBE tree_found=", tree != null)
				if tree != null:
					var mi: MeshInstance3D = tm._trees[tree.tree_id]["mesh_node"]
					if mi != null:
						var m: Mesh = mi.mesh
						for sfi in m.get_surface_count():
							var arr := m.surface_get_arrays(sfi)
							var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
							var verts: PackedVector3Array = arr[
									Mesh.ARRAY_VERTEX]
							var warm := 0
							var near_torch := 0
							var sample_cols: Array[String] = []
							for vi in verts.size():
								var wp: Vector3 = verts[vi] + mi.position
								if wp.distance_to(Vector3(53.5, 23.5, 2.5)) \
										< 2.5:
									near_torch += 1
									if cols.size() > vi:
										if cols[vi].r - cols[vi].b > 0.2:
											warm += 1
										if sample_cols.size() < 3:
											sample_cols.append(str(cols[vi]))
							print("PROBE surf=%d verts=%d colors=%d near_torch=%d warm=%d sample=%s"
									% [sfi, verts.size(), cols.size(),
									near_torch, warm, ", ".join(sample_cols)])
				# 调试切片：火把周围 x-y 面（z=4 行），定位树干精确位置
				var w3: VoxelWorld = main_ref.world
				for yy in range(33, 19, -1):
					var row := ""
					for xx in range(49, 59):
						var b: int = w3.get_block(Vector3i(xx, yy, 4))
						row += ("#" if b == VoxelTypes.LOG_ID
								else ("|" if b == VoxelTypes.BRANCH_ID
								else ("L" if b == VoxelTypes.LEAVES_ID
								else ("T" if b == VoxelTypes.TORCH_ID
								else ("." if b == VoxelTypes.AIR_ID else "o")))))
					print("SLICE y=%d z=4 x49-58: %s" % [yy, row])
				# 水平切片：树冠下方找主干柱足印
				for zz in range(2, 14):
					var row2 := ""
					for xx in range(48, 62):
						var b2: int = w3.get_block(Vector3i(xx, 24, zz))
						row2 += ("#" if b2 == VoxelTypes.LOG_ID
								else ("|" if b2 == VoxelTypes.BRANCH_ID
								else ("." if b2 == VoxelTypes.AIR_ID else "o")))
					print("HSLICE y=24 z=%2d x48-61: %s" % [zz, row2])
				print("DONE")
				get_tree().quit(0)
	if _wait > 60.0:
		print("TIMEOUT phase=", _phase)
		get_tree().quit(1)


func _setup() -> void:
	# 扫已加载区块找树叶簇中心
	var best := -1
	for coord in main_ref.world.chunks:
		var chunk: ChunkData = main_ref.world.chunks[coord]
		var s := chunk.dimensions.x
		for i in chunk.volume():
			if chunk.block_ids[i] == VoxelTypes.LEAVES_ID:
				var z := i / (s * s)
				var rem := i - z * s * s
				var y := rem / s
				var x := rem - y * s
				var cell := Vector3i(x, y, z)
				var d: int = 24 - (absi(cell.x - 8) + absi(cell.z - 8))
				if d > best:
					best = d
					_found = chunk.chunk_coord * s + cell
	print("LEAVES at ", _found)
	if best < 0:
		_found = Vector3i(34, 40, 34)  # 兜底：出生点附近
	_center = Vector3(_found) + Vector3(0.5, 0.5, 0.5)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.position = _center + Vector3(-2.5, 0.8, -2.5)
	_cam.look_at(_center, Vector3.UP)
	if main_ref.player != null:
		main_ref.player.global_position = _cam.position


## 找主干格旁的贴地空气格（火把位）：优先 LOG 主干，退而求其次细枝
func _find_trunk_side(world: VoxelWorld, near: Vector3i) -> Vector3i:
	for target in [VoxelTypes.LOG_ID, VoxelTypes.BRANCH_ID]:
		var hit := _find_block_side(world, near, target)
		if hit != Vector3i.ZERO:
			return hit
	return Vector3i.ZERO


func _find_block_side(world: VoxelWorld, near: Vector3i, block_id: int) -> Vector3i:
	var s: int = world.config.chunk_size
	var fallback := Vector3i.ZERO
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		for i in chunk.volume():
			if chunk.block_ids[i] != block_id:
				continue
			var z := i / (s * s)
			var rem := i - z * s * s
			var y := rem / s
			var x := rem - y * s
			var cell := chunk.chunk_coord * s + Vector3i(x, y, z)
			if Vector3(cell).distance_to(Vector3(near)) > 12.0:
				continue
			for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
					Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				# 沿这列向下找贴地空气格（火把需要地面支撑）
				var col: Vector3i = cell + d
				var steps := 0
				while world.get_block(col) == VoxelTypes.AIR_ID \
						and steps < 32:
					var below: Vector3i = col + Vector3i(0, -1, 0)
					if world.get_block(below) != VoxelTypes.AIR_ID:
						if fallback == Vector3i.ZERO:
							fallback = col
						# 主干列优先：本格正下方也是同类块（垂直连续柱）
						if world.get_block(cell + Vector3i(0, -1, 0)) \
								== block_id:
							return col
						break
					col = below
					steps += 1
	return fallback
