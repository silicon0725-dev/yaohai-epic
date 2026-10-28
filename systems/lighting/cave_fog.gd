## 洞口体积雾管理器：从体素天光数据检测"洞口光柱"（洞内有天光的
## 空气柱 = 阳光从开口射入的位置），在附近维护一池盒形 FogVolume。
## 光束本体由引擎体积雾的太阳阴影积分切出（cave_fog.gdshader 头注释），
## 这里只负责"雾放哪"。无 class_name（全局类缓存坑）——main preload。
extends Node

const MAX_VOLUMES := 6
## 检测半径（格，XZ）：绕玩家扫一圈柱
const SCAN_RADIUS := 20
## 检测窗（格）：玩家 y ± 窗口
const SCAN_WINDOW := 14
## 柱采样步长（每 2 柱取 1，成本减半；簇半径 >=2 格不受影响）
const COLUMN_STRIDE := 2
## 判定洞口光柱：空气 + 天光 >= 阈值 + 头顶 10 格内有实体顶盖
const SKY_THRESHOLD := 11
const CEILING_RANGE := 10
## 簇最小柱数（单柱多为边缘噪声，不出雾）
const CLUSTER_MIN_COLUMNS := 3
## 体积尺寸钳制（半轴，格）
const HALF_MIN := 2.5
const HALF_MAX := 6.0

var world: VoxelWorld
var _target: Node3D
var _volumes: Array = []
var _materials: Array = []
var _clock := 0.0
var _rescan_timer := 0.0
var _last_center := Vector3i(99999, 99999, 99999)
var _dirty := true


func setup(p_world: VoxelWorld, follow: Node3D) -> void:
	world = p_world
	_target = follow
	world.block_changed.connect(func(_p, _o, _n): _dirty = true)
	var shader := load("res://presentation/cave_fog.gdshader")
	for i in MAX_VOLUMES:
		var vol := FogVolume.new()
		vol.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
		vol.visible = false
		var mat := ShaderMaterial.new()
		mat.shader = shader
		vol.material = mat
		add_child(vol)
		_volumes.append(vol)
		_materials.append(mat)


func _process(delta: float) -> void:
	_clock += delta
	for mat in _materials:
		mat.set_shader_parameter("u_time", _clock)
	if _target == null or world == null:
		return
	_rescan_timer += delta
	var center := Vector3i(
			floori(_target.global_position.x),
			floori(_target.global_position.y),
			floori(_target.global_position.z))
	var moved := center.distance_squared_to(_last_center) > 36
	if (_dirty or moved) and _rescan_timer > 0.5:
		_dirty = false
		_rescan_timer = 0.0
		_last_center = center
		_apply(scan_for_mouths(world, center))


## 检测（纯函数，单测直调）：绕 center 扫柱，返回洞口簇列表
## [{center: Vector3, half: Vector3}]，按到 center 距离升序。
static func scan_for_mouths(p_world: VoxelWorld, center: Vector3i) -> Array:
	var chunk_size := p_world.config.chunk_size
	var marks := {}  # "x,z" -> {cells: [Vector3i], col: Vector2i}
	var y_lo := maxi(center.y - SCAN_WINDOW, 1)
	var y_hi := center.y + SCAN_WINDOW
	var x0 := center.x - SCAN_RADIUS
	var x1 := center.x + SCAN_RADIUS
	var z0 := center.z - SCAN_RADIUS
	var z1 := center.z + SCAN_RADIUS
	for wx in range(x0, x1 + 1, COLUMN_STRIDE):
		for wz in range(z0, z1 + 1, COLUMN_STRIDE):
			# 每柱自上而下找第一个"有天光的洞内空气"（顶盖下沿）
			for wy in range(y_hi, y_lo, -1):
				var pos := Vector3i(wx, wy, wz)
				if p_world.get_block(pos) != VoxelTypes.AIR_ID:
					continue
				if _sky_at(p_world, pos, chunk_size) < SKY_THRESHOLD:
					continue
				if not _has_ceiling(p_world, pos):
					continue
				# 找到了：该柱的顶盖光柱格。邻柱同柱合并成簇
				var key := "%d,%d" % [wx, wz]
				if not marks.has(key):
					marks[key] = []
				marks[key].append(pos)
				break  # 只取最顶一个（洞口上沿）
	return _cluster(marks, center)


static func _sky_at(p_world: VoxelWorld, pos: Vector3i, chunk_size: int) -> int:
	var chunk: ChunkData = p_world.chunks.get(
			VoxelCoords.world_to_chunk(pos, chunk_size))
	if chunk == null:
		return 0
	return chunk.get_sky_light(
			VoxelCoords.world_to_local(pos, chunk_size))


## 头顶 CEILING_RANGE 内有实体顶盖（洞内判定：露天没有）
static func _has_ceiling(p_world: VoxelWorld, pos: Vector3i) -> bool:
	for i in range(1, CEILING_RANGE + 1):
		var id := p_world.get_block(pos + Vector3i(0, i, 0))
		if id != VoxelTypes.AIR_ID and id != VoxelTypes.WATER_ID:
			return true
	return false


## 4 邻接泛洪聚类；簇输出盒中心与半轴（钳制），按距玩家升序
static func _cluster(marks: Dictionary, center: Vector3i) -> Array:
	var visited := {}
	var clusters := []
	for key in marks:
		if visited.has(key):
			continue
		var stack: Array = [key]
		visited[key] = true
		var cells: Array = []
		while not stack.is_empty():
			var k: String = stack.pop_back()
			var parts := k.split(",")
			var col := Vector2i(int(parts[0]), int(parts[1]))
			for c in marks[k]:
				cells.append(c)
			for d in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				var nk := "%d,%d" % [col.x + d.x * COLUMN_STRIDE,
						col.y + d.y * COLUMN_STRIDE]
				if marks.has(nk) and not visited.has(nk):
					visited[nk] = true
					stack.append(nk)
		if cells.size() < CLUSTER_MIN_COLUMNS:
			continue
		var sum := Vector3.ZERO
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := Vector3(-1e9, -1e9, -1e9)
		for c in cells:
			sum += Vector3(c)
			lo = lo.min(Vector3(c))
			hi = hi.max(Vector3(c))
		var mid := sum / float(cells.size())
		var half := (hi - lo) * 0.5
		half.x = clampf(half.x + 2.0, HALF_MIN, HALF_MAX)
		half.z = clampf(half.z + 2.0, HALF_MIN, HALF_MAX)
		half.y = clampf((hi.y - mid.y) + 3.0, HALF_MIN, HALF_MAX)
		clusters.append({
			"center": mid + Vector3(0.5, 0.5, 0.5),
			"half": half,
			"dist2": mid.distance_squared_to(Vector3(center)),
		})
	clusters.sort_custom(func(a, b): return a["dist2"] < b["dist2"])
	return clusters


func _apply(clusters: Array) -> void:
	for i in MAX_VOLUMES:
		var vol: FogVolume = _volumes[i]
		if i < clusters.size():
			var c: Dictionary = clusters[i]
			var center: Vector3 = c["center"]
			var half: Vector3 = c["half"]
			vol.size = half * 2.0
			vol.position = center
			vol.visible = true
			var mat: ShaderMaterial = _materials[i]
			mat.set_shader_parameter("center", center)
			mat.set_shader_parameter("half_extents", half)
		else:
			vol.visible = false


## 调试/测试：当前活跃体积数
func active_count() -> int:
	var n := 0
	for v in _volumes:
		if v.visible:
			n += 1
	return n
