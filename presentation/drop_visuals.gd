## 掉落实体视觉资源（表现层，模仿 Better Dropped Items Renewed）。
## 方块物品渲染为 3D 迷你方块（0.25 格，六面图集贴图，与地形网格器
## 同一套面表/UV/绕序约定）；材料/工具渲染为站立平面四边形
##（贴图复用 ItemIcons.world_sprite_for，像素画已去底）。
## 网格与材质按 ID 缓存；图集纹理由主场景 configure() 注入一次，
## 未注入时回退品红材质（资源缺失显式暴露，§11.2）。
class_name DropVisuals
extends RefCounted

## 迷你方块边长（MC 物品实体的方块模型缩放）
const CUBE_SIZE := 0.25
## 平面物品边长（沿用图标观感）与挤出厚度（MC 2D 物品模型的
## "厚贴图"：每个不透明像素挤出一个小方柱）
const FLAT_SIZE := 0.38
const FLAT_THICKNESS := 0.03

const _INV_COLS := 1.0 / float(TextureAtlasLoader.COLS)
const _INV_ROWS := 1.0 / float(TextureAtlasLoader.ROWS)

static var _atlas_texture: Texture2D
static var _atlas_material: StandardMaterial3D
static var _cube_mesh_cache := {}   # block_id -> ArrayMesh
static var _extruded_cache := {}    # item_id -> ArrayMesh
static var _flat_materials := {}    # item_id -> StandardMaterial3D


## 主场景在图集纹理生成后注入（与 ItemIcons.set_atlas 同时机）。
static func configure(atlas_texture: Texture2D) -> void:
	_atlas_texture = atlas_texture
	_atlas_material = null
	_cube_mesh_cache.clear()


## 方块物品的 3D 迷你方块网格（中心在原点）。
static func cube_mesh_for(block_id: int, registry: VoxelRegistry) -> ArrayMesh:
	if _cube_mesh_cache.has(block_id):
		return _cube_mesh_cache[block_id]
	var textures: Dictionary = registry.definition_for_id(block_id).get(
			"textures", {})
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half := CUBE_SIZE * 0.5
	for face in ChunkMesher.FACES:
		# 面表约定与地形网格一致：角点/UV/绕序（Godot 正面 = 顺时针）
		var corners: Array = face["corners"]
		var corner_uvs: Array = face["corner_uvs"]
		var tile_name := String(textures.get(
				face["face_kind"], textures.get("side", "")))
		var tile := TextureAtlasLoader.tile_grid(tile_name)
		var origin := Vector2(
				float(tile.x) * _INV_COLS, float(tile.y) * _INV_ROWS)
		var base := vertices.size()
		for c in 4:
			var corner: Vector3 = corners[c]
			vertices.append(Vector3(
					corner.x * CUBE_SIZE - half,
					corner.y * CUBE_SIZE - half,
					corner.z * CUBE_SIZE - half))
			normals.append(Vector3(face["normal"]))
			var cuv: Vector2 = corner_uvs[c]
			uvs.append(Vector2(
					origin.x + cuv.x * _INV_COLS,
					origin.y + cuv.y * _INV_ROWS))
		indices.append_array(PackedInt32Array([
			base, base + 2, base + 1,
			base, base + 3, base + 2,
		]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, atlas_material())
	_cube_mesh_cache[block_id] = mesh
	return mesh


## 平面物品的挤出网格：每个不透明像素挤出一个小方柱（MC 2D 物品
## 模型的"厚贴图"观感），整体位于 XY 平面（法线沿 Z），中心在原点。
## 侧面只在轮廓边缘生成（相邻像素透明处），顶/底每像素各一面。
static func extruded_mesh_for(
		item_id: int, item_registry: ItemRegistry) -> ArrayMesh:
	if _extruded_cache.has(item_id):
		return _extruded_cache[item_id]
	var image := ItemIcons.sprite_image_for(item_id, item_registry)
	var res := image.get_width()
	var pixel := FLAT_SIZE / float(res)
	var half := FLAT_SIZE * 0.5
	var half_t := FLAT_THICKNESS * 0.5
	var inv := 1.0 / float(res)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var opaque := func(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < res and y < res \
				and image.get_pixel(x, y).a >= 0.5
	for gy in res:
		for gx in res:
			if not opaque.call(gx, gy):
				continue
			# 图像 y 向下 -> 网格 y 向上；像素矩形与对应 UV 矩形
			var x0 := gx * pixel - half
			var x1 := x0 + pixel
			var y1 := half - gy * pixel
			var y0 := y1 - pixel
			var u0 := gx * inv
			var u1 := u0 + inv
			var v0 := gy * inv
			var v1 := v0 + inv
			# 正面（-Z，贴图正向）与背面（+Z，轮廓反向）
			_emit_quad(vertices, normals, uvs, indices,
					Vector3(x1, y0, -half_t), Vector3(x0, y0, -half_t),
					Vector3(x0, y1, -half_t), Vector3(x1, y1, -half_t),
					Vector3.BACK,
					Vector2(u1, v1), Vector2(u0, v1),
					Vector2(u0, v0), Vector2(u1, v0))
			_emit_quad(vertices, normals, uvs, indices,
					Vector3(x1, y1, half_t), Vector3(x0, y1, half_t),
					Vector3(x0, y0, half_t), Vector3(x1, y0, half_t),
					Vector3.FORWARD,
					Vector2(u1, v0), Vector2(u0, v0),
					Vector2(u0, v1), Vector2(u1, v1))
			# 四向侧边：仅轮廓处（邻居透明）生成，UV 取该像素边缘色
			if not opaque.call(gx, gy - 1):
				_emit_quad(vertices, normals, uvs, indices,
						Vector3(x0, y1, half_t), Vector3(x1, y1, half_t),
						Vector3(x1, y1, -half_t), Vector3(x0, y1, -half_t),
						Vector3.UP,
						Vector2(u0, v0), Vector2(u1, v0),
						Vector2(u1, v1), Vector2(u0, v1))
			if not opaque.call(gx, gy + 1):
				_emit_quad(vertices, normals, uvs, indices,
						Vector3(x1, y0, half_t), Vector3(x0, y0, half_t),
						Vector3(x0, y0, -half_t), Vector3(x1, y0, -half_t),
						Vector3.DOWN,
						Vector2(u1, v0), Vector2(u0, v0),
						Vector2(u0, v1), Vector2(u1, v1))
			if not opaque.call(gx + 1, gy):
				_emit_quad(vertices, normals, uvs, indices,
						Vector3(x1, y1, half_t), Vector3(x1, y0, half_t),
						Vector3(x1, y0, -half_t), Vector3(x1, y1, -half_t),
						Vector3.RIGHT,
						Vector2(u1, v0), Vector2(u1, v1),
						Vector2(u1, v1), Vector2(u1, v0))
			if not opaque.call(gx - 1, gy):
				_emit_quad(vertices, normals, uvs, indices,
						Vector3(x0, y0, half_t), Vector3(x0, y1, half_t),
						Vector3(x0, y1, -half_t), Vector3(x0, y0, -half_t),
						Vector3.LEFT,
						Vector2(u0, v1), Vector2(u0, v0),
						Vector2(u0, v0), Vector2(u0, v1))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, flat_material_for(item_id, item_registry))
	_extruded_cache[item_id] = mesh
	return mesh


## 发射一个四边形：角点沿外轮廓排列（cross(b-a, c-b) = 外法线），
## 索引绕序与地形网格器一致（Godot 正面 = 面外侧看顺时针）。
static func _emit_quad(
		vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		normal: Vector3, ua: Vector2, ub: Vector2,
		uc: Vector2, ud: Vector2
) -> void:
	var base := vertices.size()
	vertices.append_array(PackedVector3Array([a, b, c, d]))
	for i in 4:
		normals.append(normal)
	uvs.append_array(PackedVector2Array([ua, ub, uc, ud]))
	indices.append_array(PackedInt32Array([
		base, base + 2, base + 1,
		base, base + 3, base + 2,
	]))


## 平面物品材质（按物品缓存；双面 + alpha 裁切，近像素画观感）。
static func flat_material_for(
		item_id: int, item_registry: ItemRegistry) -> Material:
	if _flat_materials.has(item_id):
		return _flat_materials[item_id]
	var material := StandardMaterial3D.new()
	material.albedo_texture = ItemIcons.world_sprite_for(item_id, item_registry)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.roughness = 1.0
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	# 平面贴图背光面在阴影下会过暗（近剪影），不接收阴影保持可读性
	material.disable_receive_shadows = true
	_flat_materials[item_id] = material
	return material


## 迷你方块共享的图集材质（受光照，与地形一致）。
static func atlas_material() -> Material:
	if _atlas_material != null:
		return _atlas_material
	var material := StandardMaterial3D.new()
	if _atlas_texture == null:
		push_warning("DropVisuals 未注入图集纹理，迷你方块回退品红")
		material.albedo_color = Color.MAGENTA
	else:
		material.albedo_texture = _atlas_texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.roughness = 1.0
	material.metallic = 0.0
	_atlas_material = material  # 回退材质同样缓存（保持单例语义）
	return material
