## MC/Blockbench 模型 JSON 加载器：解析 Minecraft 方块模型
##（elements 多盒几何，Blockbench 同源格式——Pastoral 等写实包用它
## 给方块配真 3D 形体）→ ArrayMesh（每盒件六面带贴图 UV，按贴图引用
## 分表面共享材质）。坐标语义与实体火把同族：from/to 以 1/16 格为
## 单位、y 向上；uv 为 0..16 贴图空间（v 向下，与 Godot UV 同构）。
## 无 class_name（全局类缓存坑）——调用方 preload。
extends RefCounted

## 8 角点编码：bit2=x(bit4) bit1=y(bit2) bit0=z(bit1)，0=mn 1=mx
const CORNER_BITS := [
	Vector3i(0, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 1, 0), Vector3i(0, 1, 1),
	Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(1, 1, 0), Vector3i(1, 1, 1),
]

## MC 面名 -> [法线, 4 角索引（外侧看逆时针存储、配 (0,2,1)(0,3,2)
## 绕序 = Godot 正面）]，角序即 UV 角序（左下/右下/右上/左上）
const FACES := {
	"east": [Vector3i(1, 0, 0), [5, 4, 6, 7]],
	"west": [Vector3i(-1, 0, 0), [0, 1, 3, 2]],
	"up": [Vector3i(0, 1, 0), [3, 7, 6, 2]],
	"down": [Vector3i(0, -1, 0), [0, 4, 5, 1]],
	"south": [Vector3i(0, 0, 1), [1, 5, 7, 3]],
	"north": [Vector3i(0, 0, -1), [4, 0, 2, 6]],
}


## 解析模型并构建 ArrayMesh（表面材质已设置：albedo 贴图 Nearest +
## alpha scissor——镂空贴图如紫水晶簇安全，不透明贴图不受影响）。
## pack_dir：材质包 assets/minecraft 目录（绝对或 res://）；
## model_rel：相对路径，如 "models/block/lantern.json"。
static func build_mesh(pack_dir: String, model_rel: String) -> ArrayMesh:
	var model := _load_merged(pack_dir, model_rel, 4)
	if model.is_empty() or not model.has("elements"):
		push_warning("MC 模型无 elements: " + model_rel)
		return null
	var textures: Dictionary = model.get("textures", {})
	# 贴图引用 -> 顶点/UV 桶（同贴图合并为一个表面）
	var buckets := {}
	for element in model["elements"]:
		var rot: Dictionary = element.get("rotation", {})
		for face_name in element.get("faces", {}):
			var spec: Dictionary = element["faces"][face_name]
			if not FACES.has(face_name):
				continue
			var tex_ref := String(spec.get("texture", ""))
			var resolved: String = _resolve_texture(tex_ref, textures, 0)
			if not buckets.has(resolved):
				buckets[resolved] = _new_bucket()
			_append_face(buckets[resolved], element, spec, FACES[face_name], rot)
	var mesh := ArrayMesh.new()
	var mat_cache := {}
	for resolved in buckets:
		var mat: StandardMaterial3D = mat_cache.get(resolved)
		if mat == null:
			mat = _make_material(pack_dir, resolved)
			mat_cache[resolved] = mat
		var arrays: Array = _bucket_arrays(buckets[resolved])
		if arrays != null:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh


static func _new_bucket() -> Dictionary:
	return {"vertices": PackedVector3Array(), "normals": PackedVector3Array(),
		"uvs": PackedVector2Array(), "indices": PackedInt32Array()}


## 面几何：盒件 from/to（1/16 格）六角点 + 可选元素旋转（绕 origin
## 的单轴 ±45 内旋转，Blockbench 同款语义）
static func _append_face(
		bucket: Dictionary, element: Dictionary, spec: Dictionary,
		face: Array, rot: Dictionary
) -> void:
	var from: Array = element.get("from", [0.0, 0.0, 0.0])
	var to: Array = element.get("to", [16.0, 16.0, 16.0])
	var mn := Vector3(float(from[0]) / 16.0, float(from[1]) / 16.0,
			float(from[2]) / 16.0)
	var mx := Vector3(float(to[0]) / 16.0, float(to[1]) / 16.0,
			float(to[2]) / 16.0)
	var uv: Array = spec.get("uv", [0.0, 0.0, 16.0, 16.0])
	var u0 := float(uv[0]) / 16.0
	var v0 := float(uv[1]) / 16.0
	var u1 := float(uv[2]) / 16.0
	var v1 := float(uv[3]) / 16.0
	# UV 角序配面角序：左下/右下/右上/左上（v 向下）
	var face_uvs := [
		Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0)]
	var normal: Vector3 = face[0]
	var base: int = bucket["vertices"].size()
	for c in 4:
		var bits: Vector3i = CORNER_BITS[face[1][c]]
		var pos := Vector3(
				mx.x if bits.x == 1 else mn.x,
				mx.y if bits.y == 1 else mn.y,
				mx.z if bits.z == 1 else mn.z)
		if not rot.is_empty():
			pos = _rotate(pos, rot)
		bucket["vertices"].append(pos)
		bucket["normals"].append(normal if rot.is_empty()
				else _rotate_dir(normal, rot))
		bucket["uvs"].append(face_uvs[c])
	bucket["indices"].append(base)
	bucket["indices"].append(base + 2)
	bucket["indices"].append(base + 1)
	bucket["indices"].append(base)
	bucket["indices"].append(base + 3)
	bucket["indices"].append(base + 2)


## 元素旋转：绕 origin 的 axis 轴转 angle 度（MC 限定 ±45）
static func _rotate(pos: Vector3, rot: Dictionary) -> Vector3:
	var origin_arr: Array = rot.get("origin", [8.0, 8.0, 8.0])
	var origin := Vector3(float(origin_arr[0]) / 16.0,
			float(origin_arr[1]) / 16.0, float(origin_arr[2]) / 16.0)
	var basis := _rot_basis(String(rot.get("axis", "y")),
			deg_to_rad(float(rot.get("angle", 0.0))))
	return origin + basis * (pos - origin)


static func _rotate_dir(dir: Vector3, rot: Dictionary) -> Vector3:
	return _rot_basis(String(rot.get("axis", "y")),
			deg_to_rad(float(rot.get("angle", 0.0)))) * dir


static func _rot_basis(axis: String, rad: float) -> Basis:
	match axis:
		"x":
			return Basis(Vector3(1, 0, 0), rad)
		"z":
			return Basis(Vector3(0, 0, 1), rad)
		_:
			return Basis(Vector3(0, 1, 0), rad)


static func _bucket_arrays(bucket: Dictionary) -> Variant:
	if bucket["indices"].is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = bucket["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = bucket["normals"]
	arrays[Mesh.ARRAY_TEX_UV] = bucket["uvs"]
	arrays[Mesh.ARRAY_INDEX] = bucket["indices"]
	return arrays


static func _make_material(pack_dir: String, resolved: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 1.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	if not resolved.is_empty():
		var path := _texture_path(pack_dir, resolved)
		if FileAccess.file_exists(path) or ResourceLoader.exists(path):
			var img := Image.load_from_file(path)
			if img != null:
				# MC 动画贴图（16×N 垂直帧条，配 .mcmeta）：静态采样会
				# 把全部帧挤进 0..1 UV——面横跨帧边界采到邻帧 texel
				#（提灯金属框采到第 2 帧亮窗而洗白）。裁第一帧 = MC
				# 静态观感（动画翻页后续接 .mcmeta 解析再做）
				if img.get_height() > img.get_width() \
						and img.get_height() % img.get_width() == 0:
					var frame := Image.create_empty(img.get_width(),
							img.get_width(), false, img.get_format())
					frame.blit_rect(img, Rect2i(0, 0, img.get_width(),
							img.get_width()), Vector2i.ZERO)
					img = frame
				mat.albedo_texture = ImageTexture.create_from_image(img)
				return mat
	mat.albedo_color = Color.MAGENTA  # 缺贴图显式暴露（§11.2 回退策略）
	return mat


static func _texture_path(pack_dir: String, resolved: String) -> String:
	return "%s/textures/%s.png" % [pack_dir, resolved]


## "#N" 引用链解析（textures 表内互相引用，限深防环）
static func _resolve_texture(ref: String, textures: Dictionary, depth: int) -> String:
	if depth > 4 or not ref.begins_with("#"):
		return ref
	var key := ref.substr(1)
	return _resolve_texture(String(textures.get(key, "")), textures, depth + 1)


## 加载并沿 parent 链合并（parent 提供 elements/textures 默认值，
## 子层覆盖 textures；elements 取链中最深定义者——MC 语义）
static func _load_merged(pack_dir: String, model_rel: String, depth: int) -> Dictionary:
	var path := "%s/%s" % [pack_dir, model_rel]
	if not FileAccess.file_exists(path) or depth < 0:
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		return {}
	var model: Dictionary = parsed
	if model.has("parent"):
		var parent_rel := String(model["parent"])
		if not parent_rel.is_empty() and parent_rel != "builtin/generated" \
				and parent_rel != "builtin/entity":
			var parent: Dictionary = _load_merged(pack_dir,
					"models/%s.json" % parent_rel, depth - 1)
			if not parent.is_empty():
				if not model.has("elements") and parent.has("elements"):
					model["elements"] = parent["elements"]
				var merged_tex: Dictionary = parent.get("textures", {}).duplicate()
				merged_tex.merge(model.get("textures", {}), true)
				model["textures"] = merged_tex
	return model
