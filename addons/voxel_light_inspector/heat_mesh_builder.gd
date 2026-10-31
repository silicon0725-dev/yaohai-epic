## 光照热力图网格构建（编辑器视口叠加）。
## 天光/方块光各用内嵌小立方（0.46 / 0.24 边长，同格双通道不穿模），
## 颜色亮度 = 值/15；只画非实心格（实心内部光照恒 0）。
## 天光上限默认 14：排除满日照 15 的大片噪声，专看洞口梯度/树荫/残留光。
## 另产出区块边框线网格（边界断层定位用）。
extends RefCounted

const VoxelTypesScript := preload("res://core/voxel_types.gd")

const SKY_COLOR := Color(0.62, 0.82, 1.0)
const BLOCK_COLOR := Color(1.0, 0.64, 0.25)
const SKY_EDGE := 0.46
const BLOCK_EDGE := 0.24

# 单元立方 6 面 × 4 角（中心在原点；材质双面渲染，绕序无关紧要）
const _FACES := [
	[Vector3(0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(0.5, -0.5, 0.5)],
	[Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, 0.5, 0.5), Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, -0.5, -0.5)],
	[Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5)],
	[Vector3(-0.5, -0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(0.5, -0.5, -0.5), Vector3(-0.5, -0.5, -0.5)],
	[Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5)],
	[Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5)],
]
const _QUAD := [0, 1, 2, 0, 2, 3]

# 区块 AABB 12 条边（角点次序见 _border_lines）
const _BOX_EDGES := [
	[0, 1], [1, 2], [2, 3], [3, 0],
	[4, 5], [5, 6], [6, 7], [7, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]


## opts: { sky, block, min_level, max_level }。
## 返回 { heat: ArrayMesh/null, border: ArrayMesh/null, cubes: int }。
static func build(world, opts: Dictionary) -> Dictionary:
	var size: int = world.config.chunk_size
	var min_level: int = clampi(int(opts.get("min_level", 1)), 1, 15)
	var max_level: int = clampi(int(opts.get("max_level", 14)), min_level, 15)
	var show_sky: bool = bool(opts.get("sky", true))
	var show_blk: bool = bool(opts.get("block", true))
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var cube_count := 0
	for coord in world.chunks:
		var chunk = world.chunks[coord]
		var origin := Vector3(chunk.chunk_coord) * float(size)
		var ids: PackedInt32Array = chunk.block_ids
		var lg: PackedByteArray = chunk.light
		for z in size:
			for y in size:
				var row := size * (y + size * z)
				for x in size:
					var i := row + x
					if VoxelTypesScript.light_opacity(ids[i]) >= 15:
						continue  # 实心格不画
					var center := origin + Vector3(x + 0.5, y + 0.5, z + 0.5)
					var sky := lg[i] >> 4
					if show_sky and sky >= min_level and sky <= max_level:
						_add_cube(verts, colors, indices,
								center, SKY_EDGE, _tint(SKY_COLOR, sky))
						cube_count += 1
					var blk := lg[i] & 0x0F
					if show_blk and blk >= min_level and blk <= max_level:
						_add_cube(verts, colors, indices,
								center, BLOCK_EDGE, _tint(BLOCK_COLOR, blk))
						cube_count += 1
	var result := {"cubes": cube_count, "heat": null, "border": null}
	if verts.size() > 0:
		result["heat"] = _mesh_from(verts, colors, indices)
	if bool(opts.get("borders", true)):
		result["border"] = _border_mesh(world, size)
	return result


## 值 1 也可见（亮度下限 0.3），15 全亮。
static func _tint(base: Color, value: int) -> Color:
	var s := 0.3 + 0.7 * (float(value) / 15.0)
	return Color(base.r * s, base.g * s, base.b * s, 1.0)


static func _add_cube(
		verts: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, center: Vector3, edge: float, tint: Color) -> void:
	var base := verts.size()
	for face in _FACES:
		for corner in face:
			verts.append(center + corner * edge)
			colors.append(tint)
	var vi := base
	for f in 6:
		for k in 6:
			indices.append(vi + _QUAD[k])
		vi += 4


static func _mesh_from(
		verts: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 区块边框线（每区块 12 条边 = 24 顶点线对）。
static func _border_mesh(world, size: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	for coord in world.chunks:
		var a := Vector3(chunk_coord_mult(coord, size))
		var corners := [
			a + Vector3(0, 0, 0), a + Vector3(size, 0, 0),
			a + Vector3(size, 0, size), a + Vector3(0, 0, size),
			a + Vector3(0, size, 0), a + Vector3(size, size, 0),
			a + Vector3(size, size, size), a + Vector3(0, size, size),
		]
		for e in _BOX_EDGES:
			verts.append(corners[e[0]])
			verts.append(corners[e[1]])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


static func chunk_coord_mult(coord: Vector3i, size: int) -> Vector3:
	return Vector3(coord.x * size, coord.y * size, coord.z * size)
