## YSM（Yes Steve Model）模型包解析器——Bedrock 几何格式（GeckoLib 同源）。
## 数据层：只做解析与约定换算，不建节点（建骨架/网格见 character_rig.gd）。
##
## 坐标约定（源码核对：ModernYSM YSMFolderDeserializer + compat YSMGeoModel）：
## - 像素 → 方块 ÷16；pivot.x 取负（Bedrock X 镜像）；
## - 骨骼/盒件旋转欧拉序 ZYX（先 X 后 Y 后 Z），角度 x/y 取负、z 不取负；
## - UV：v 向下、左上原点，uv_size 可为负（翻转采样）；盒 UV 摊平布局同 Bedrock；
## - mirror（盒或骨）：不交换 u 采样方向，但东西两面的贴图矩形互换。
## 新类全局缓存不刷新（约束卡）：一律 preload 引用，不用 class_name。
@tool
extends RefCounted

const PX := 1.0 / 16.0

## 面角表（p1..p8 编号见 _cube_corners）：外侧看逆时针。
## MC 面名对应 Bedrock：north=-Z（模型前方）。
const FACE_CORNERS := {
	"north": [3, 7, 5, 1],
	"south": [8, 4, 2, 6],
	"east": [7, 8, 6, 5],
	"west": [4, 3, 1, 2],
	"up": [4, 8, 7, 3],
	"down": [1, 5, 6, 2],
}
const FACE_NORMALS := {
	"north": Vector3(0, 0, -1),
	"south": Vector3(0, 0, 1),
	"east": Vector3(1, 0, 0),
	"west": Vector3(-1, 0, 0),
	"up": Vector3(0, 1, 0),
	"down": Vector3(0, -1, 0),
}


## 解析模型包目录：ysm.json + models/main.json（几何）+ 贴图清单。
## 返回 {
##   name, height_scale, width_scale, default_texture,
##   texture_w, texture_h,
##   bones: [ {name, parent, pivot(Vector3 px 已镜像), rot_deg, mirror, cubes} ],
##   textures: {贴图名(无扩展): 绝对路径}, pack_dir }
static func load_pack(pack_dir: String) -> Dictionary:
	var pack_dir_norm := pack_dir.rstrip("/")
	var meta: Dictionary = _read_json("%s/ysm.json" % pack_dir_norm)
	if meta.is_empty():
		push_error("ysm.json 缺失: %s" % pack_dir_norm)
		return {}
	var props: Dictionary = meta.get("properties", {})
	var files: Dictionary = meta.get("files", {}).get("player", {})
	var main_model: String = String(files.get("model", {}).get("main", ""))
	if main_model.is_empty():
		push_error("ysm.json 缺 files.player.model.main")
		return {}
	var geo: Dictionary = _read_json("%s/%s" % [pack_dir_norm, main_model])
	if geo.is_empty():
		push_error("几何文件缺失: %s" % main_model)
		return {}
	var geo_entry: Dictionary = geo.get("minecraft:geometry", [{}])[0]
	var desc: Dictionary = geo_entry.get("description", {})
	var bones := []
	for bone in geo_entry.get("bones", []):
		bones.append(_parse_bone(bone))
	var textures := {}
	for rel in files.get("texture", []):
		var tex_name := String(rel).get_file().get_basename()
		var abs := "%s/%s" % [pack_dir_norm, String(rel)]
		if FileAccess.file_exists(abs):
			textures[tex_name] = abs
	return {
		"name": String(meta.get("metadata", {}).get("name", pack_dir_norm.get_file())),
		"height_scale": float(props.get("height_scale", 0.7)),
		"width_scale": float(props.get("width_scale", 0.7)),
		"default_texture": String(props.get("default_texture", "")),
		"texture_w": int(desc.get("texture_width", 64)),
		"texture_h": int(desc.get("texture_height", 64)),
		"bones": bones,
		"textures": textures,
		"pack_dir": pack_dir_norm,
	}


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _parse_bone(bone: Dictionary) -> Dictionary:
	var cubes := []
	for cube in bone.get("cubes", []):
		cubes.append(_parse_cube(cube, bool(bone.get("mirror", false))))
	return {
		"name": String(bone.get("name", "")),
		"parent": String(bone.get("parent", "")),
		# 像素空间（已镜像 x），方块换算与缩放在 rig 侧统一做
		"pivot": _pivot_px(bone.get("pivot", [0.0, 0.0, 0.0])),
		"rot_deg": _vec3(bone.get("rotation", [0.0, 0.0, 0.0])),
		"mirror": bool(bone.get("mirror", false)),
		"cubes": cubes,
	}


static func _pivot_px(arr) -> Vector3:
	var v := _vec3(arr)
	return Vector3(-v.x, v.y, v.z)


static func _vec3(arr) -> Vector3:
	if not (arr is Array) or (arr as Array).size() < 3:
		return Vector3.ZERO
	return Vector3(
			float(arr[0]), float(arr[1]), float(arr[2]))


## 盒件：min/max 已含 inflate 与 x 镜像（px 空间）；faces 已解析成
## {面名: {uv: Vector2, uv_size: Vector2}}（盒 UV 摊平/逐面两种来源），
## mirror 时东西面贴图矩形互换（ModernYSM 同款语义）。
static func _parse_cube(cube: Dictionary, bone_mirror: bool) -> Dictionary:
	var origin := _vec3(cube.get("origin", [0.0, 0.0, 0.0]))
	var size := _vec3(cube.get("size", [0.0, 0.0, 0.0]))
	var inflate := float(cube.get("inflate", 0.0))
	# 镜像：x 最小角 = -(origin.x + size.x)
	var min_px := Vector3(-(origin.x + size.x) - inflate,
			origin.y - inflate, origin.z - inflate)
	var max_px := Vector3(-origin.x + inflate,
			origin.y + size.y + inflate, origin.z + size.z + inflate)
	var mirror: bool = bool(cube.get("mirror", false)) or bone_mirror
	var faces := {}
	var uv = cube.get("uv", null)
	if uv is Array:
		faces = _box_uv_rects(uv, size)
	elif uv is Dictionary:
		for face_name in uv:
			var spec: Dictionary = uv[face_name]
			if spec.has("uv") and spec.has("uv_size"):
				faces[face_name] = {
					"uv": _vec2(spec["uv"]),
					"uv_size": _vec2(spec["uv_size"]),
				}
	if mirror:
		var east = faces.get("east")
		var west = faces.get("west")
		if east != null:
			faces["west"] = east
		if west != null:
			faces["east"] = west
	return {
		"min": min_px,
		"max": max_px,
		"rot_deg": _vec3(cube.get("rotation", [0.0, 0.0, 0.0]))
				if cube.has("rotation") else Vector3.INF,
		"pivot": _pivot_px(cube["pivot"]) if cube.has("pivot") else null,
		"mirror": mirror,
		"faces": faces,
	}


static func _vec2(arr) -> Vector2:
	if not (arr is Array) or (arr as Array).size() < 2:
		return Vector2.ZERO
	return Vector2(float(arr[0]), float(arr[1]))


## 盒 UV 摊平布局（Bedrock 标准，尺寸取 floor，不含 inflate）。
## down 面高为负（贴图上下翻转采样）。
static func _box_uv_rects(uv_arr: Array, size: Vector3) -> Dictionary:
	var u := float(uv_arr[0])
	var v := float(uv_arr[1])
	var dx := float(floori(size.x))
	var dy := float(floori(size.y))
	var dz := float(floori(size.z))
	return {
		"east": {"uv": Vector2(u, v + dz), "uv_size": Vector2(dz, dy)},
		"north": {"uv": Vector2(u + dz, v + dz), "uv_size": Vector2(dx, dy)},
		"west": {"uv": Vector2(u + dz + dx, v + dz), "uv_size": Vector2(dz, dy)},
		"south": {"uv": Vector2(u + 2.0 * dz + dx, v + dz), "uv_size": Vector2(dx, dy)},
		"up": {"uv": Vector2(u + dz, v), "uv_size": Vector2(dx, dz)},
		"down": {"uv": Vector2(u + dz + dx, v), "uv_size": Vector2(dx, -dz)},
	}


## YSM 欧拉约定 → Basis：Rz(z)·Ry(-y)·Rx(-x)（先 X 后 Y 后 Z）。
static func euler_basis(rot_deg: Vector3) -> Basis:
	var x := Basis(Vector3(1, 0, 0), deg_to_rad(-rot_deg.x))
	var y := Basis(Vector3(0, 1, 0), deg_to_rad(-rot_deg.y))
	var z := Basis(Vector3(0, 0, 1), deg_to_rad(rot_deg.z))
	return z * y * x


## 盒件 8 角（px 空间已镜像）：p1..p8 → 返回 8 元素数组（索引 0..7）。
## p1=(x1,y1,z1) p2=(x1,y1,z2) p3=(x1,y2,z1) p4=(x1,y2,z2)
## p5=(x2,y1,z1) p6=(x2,y1,z2) p7=(x2,y2,z1) p8=(x2,y2,z2)
static func cube_corners(cube: Dictionary) -> Array:
	var mn: Vector3 = cube["min"]
	var mx: Vector3 = cube["max"]
	var x1 := mn.x; var y1 := mn.y; var z1 := mn.z
	var x2 := mx.x; var y2 := mx.y; var z2 := mx.z
	return [
		Vector3(x1, y1, z1), Vector3(x1, y1, z2),
		Vector3(x1, y2, z1), Vector3(x1, y2, z2),
		Vector3(x2, y1, z1), Vector3(x2, y1, z2),
		Vector3(x2, y2, z1), Vector3(x2, y2, z2),
	]


## 面 4 角 UV（归一化）：角序配 FACE_CORNERS。
## 非 mirror：u 方向交换（ModernYSM 逐字复刻：if (!mirror) swap(u0,u1)）；
## v 恒 [v0,v0,v1,v1]（左上原点、v 向下——与 Godot UV 语义一致）。
static func face_uvs(cube: Dictionary, face_name: String,
		tex_w: int, tex_h: int) -> Array:
	var spec: Dictionary = cube["faces"][face_name]
	var uv: Vector2 = spec["uv"]
	var uv_size: Vector2 = spec["uv_size"]
	var u0 := uv.x / float(tex_w)
	var u1 := (uv.x + uv_size.x) / float(tex_w)
	var v0 := uv.y / float(tex_h)
	var v1 := (uv.y + uv_size.y) / float(tex_h)
	if not cube["mirror"]:
		var tmp := u0
		u0 = u1
		u1 = tmp
	return [
		Vector2(u0, v0), Vector2(u1, v0),
		Vector2(u1, v1), Vector2(u0, v1),
	]


## 贴图透明面剔除 + 半透明标记（YSMClientMapper 语义）：
## - 矩形内全 alpha=0 → 整面剔除（隐藏骨/占位面的常规做法）；
## - 存在 0<alpha<255 → 半透明面（需双面渲染）。
## 返回 {face_name: "cull"|"translucent"|"solid"}（面不在贴图矩形内默认 solid）。
static func classify_faces(cube: Dictionary, tex: Image) -> Dictionary:
	var out := {}
	for face_name in cube["faces"]:
		var spec: Dictionary = cube["faces"][face_name]
		var rect := Rect2i(
				Vector2i(int(floorf(minf(spec["uv"].x, spec["uv"].x + spec["uv_size"].x))),
						int(floorf(minf(spec["uv"].y, spec["uv"].y + spec["uv_size"].y)))),
				Vector2i(int(absi(int(spec["uv_size"].x))) + 1,
						int(absi(int(spec["uv_size"].y))) + 1))
		rect = rect.intersection(Rect2i(0, 0, tex.get_width(), tex.get_height()))
		if rect.has_area():
			var any_visible := false
			var any_partial := false
			for py in range(rect.position.y, rect.end.y):
				for px in range(rect.position.x, rect.end.x):
					var a := tex.get_pixel(px, py).a8
					if a > 0:
						any_visible = true
						if a < 255:
							any_partial = true
							break
				if any_partial:
					break
			if not any_visible:
				out[face_name] = "cull"
				continue
			out[face_name] = "translucent" if any_partial else "solid"
		else:
			out[face_name] = "solid"
	return out
