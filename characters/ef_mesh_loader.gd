## Epic Fight mesh JSON（animmodels）→ ArrayMesh 静态加载器。
##
## ⚠ 许可边界：EF/DMC mesh 资产 All-Rights-Reserved **不入库**——模型由
## 用户自放 user://anim_ef/weapon/（与动画同模式），本文件只含格式逻辑。
##
## 格式（epicfight 1.21.1 JsonAssetLoader.loadSkinnedMesh + VertexBuilder
## 源码核对）：
## - vertices.{positions,normals,uvs,vcounts,weights,vindices}，均
##   {stride, count, array} 扁平数组；positions/normals 为 **Blender 空间**
##   （加载须乘 BLENDER_TO_MINECRAFT_COORD=Rx(-90°)）；
## - parts.<name>.array 每三元组 = (position_idx, uv_idx, normal_idx)
##   （VertexBuilder.create 源码），每 3 个三元组一个三角形；
## - vindices 每顶点 (joint, weight_idx) 对——武器模型通常单关节
##   （blade=Tool_R/13、on_torso=Torso/7、in_sheath=Tool_L/18）。
##
## 变换链（复刻 EF 静态蒙皮 M_j·B_j⁻¹·v，静态 M=B；EF 数据面 -Z
## =引擎系，无 R180 共轭——同 ef_reference_rig.retarget）：
##   v_engine_local = B_joint⁻¹ · Rx(-90°) · v_blender
## 挂接端 transform = 关节 global（EXTRA=identity）——与 EF 原生渲染
## 完全同构，持刀几何由数据自带（不额外加姿态旋转）。
@tool
extends RefCounted

const EfRef := preload("res://characters/ef_reference_rig.gd")


## 加载武器 mesh。bind_joint = 该模型 vindices 指向的 EF 关节名
##（把顶点变换到该关节 bind 局部）。axis_snap=true 时把"握段"（局部
## y∈[-0.2,0]）几何中心平移到原点——DMC 刀建模轴心悬在离 Tool_R 原
## 点 z≈-0.71 处（建模参考位=bind 骨架侧方），不平移则刀离手 0.7m。
## 返回 {} 失败 / {mesh, aabb}。
static func load_mesh(path: String, bind_joint: String,
		axis_snap := false) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not parsed.has("vertices"):
		return {}
	var v: Dictionary = parsed["vertices"]
	var pos_o: Dictionary = v.get("positions", {})
	var nrm_o: Dictionary = v.get("normals", {})
	var uv_o: Dictionary = v.get("uvs", {})
	var parts: Dictionary = v.get("parts", {})
	if pos_o.is_empty() or uv_o.is_empty() or parts.is_empty():
		return {}
	var poss: Array = pos_o["array"]
	var nrms: Array = nrm_o.get("array", [])
	var uvs: Array = uv_o["array"]
	# 变换：B2MC(Rx-90) → B_joint⁻¹ → R180y（MC→本引擎）
	var jidx: int = EfRef.JOINTS.find(bind_joint)
	if jidx < 0:
		return {}
	var bworld: Array = EfRef.bind_worlds()
	var bj: Transform3D = Transform3D(Basis(bworld[jidx]["q"]), bworld[jidx]["p"])
	# ⚠ 与 retarget 同空间：EF 数据面 -Z=引擎系，不乘 R180（retarget
	# 去 R180 后此处曾残留——刀向差 180°（藏身后/翘肩后，实机判读+
	# FK 复现定位）；bind 逆保留（Tool_R bind≈Rx179° 不可省）。
	var to_local := bj.affine_inverse()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uv_arr := PackedVector2Array()
	var indices := PackedInt32Array()
	var dedup := {}
	var p_mc := Vector3.ZERO
	for part in parts.values():
		var arr: Array = part.get("array", [])
		var n_tri := arr.size() / 9  # 每顶点 3 索引 ×3 顶点
		for t in n_tri:
			var tri := PackedInt32Array()
			for k in 3:
				var vi: int = t * 9 + k * 3
				var key := "%d/%d/%d" % [int(arr[vi]), int(arr[vi + 1]), int(arr[vi + 2])]
				if dedup.has(key):
					tri.append(int(dedup[key]))
					continue
				var pi: int = int(arr[vi]) * 3
				p_mc = to_local * Vector3(float(poss[pi]), float(poss[pi + 1]),
						float(poss[pi + 2]))
				var n := Vector3.UP
				if nrms.size() > int(arr[vi + 2]) * 3 + 2:
					var ni: int = int(arr[vi + 2]) * 3
					n = to_local.basis * Vector3(float(nrms[ni]),
							float(nrms[ni + 1]), float(nrms[ni + 2]))
				var ui: int = int(arr[vi + 1]) * 2
				var new_i := verts.size()
				verts.append(p_mc)
				norms.append(n.normalized())
				uv_arr.append(Vector2(float(uvs[ui]), 1.0 - float(uvs[ui + 1])))
				dedup[key] = new_i
				tri.append(new_i)
			# EF 面序=逆时针（外向）；Godot 前面=顺时针 → 翻转
			indices.append(tri[0])
			indices.append(tri[2])
			indices.append(tri[1])
	if indices.is_empty():
		return {}
	if axis_snap:
		# 握段中心 → 原点（x/z）+ 沿 +Y 平移 0.87（建模单位）：镡（柄刃
		# 交界，建模 y≈-0.78）贴拳心前 0.07m、刀柄（y -1.26~-0.75）穿过
		# 拳头、刀尖前伸 ~0.97m——实机三角化判读定标（曾握在刀身中段：
		# 镡在拳后 0.36m/柄尾拳后 0.63m）。
		var acc := Vector3.ZERO
		var n := 0
		for pv in verts:
			if pv.y > -0.2 and pv.y < 0.0:
				acc += pv
				n += 1
		if n > 0:
			var c := acc / float(n)
			var off := Vector3(c.x, -0.95, c.z)
			for vi2 in verts.size():
				verts[vi2] -= off
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uv_arr
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "aabb": mesh.get_aabb()}


## 武器材质：主纹理 albedo + _l 层 emission（DMC 发光刀纹）。
## 可见性强化：DMC 阎魔刀=黑刃蓝纹，夜景下纯 albedo 几乎不可见（用户
## 实机"看不到刀"、判读量得刀身 1-2px 暗线）——提亮 tint+高金属低粗
## 糙度借环境高光+发光层 2.5×，暗场景可见、原纹理观感保留。
static func make_material(tex_dir: String, tex_name: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var base := "%s/textures/%s" % [tex_dir, tex_name]
	if FileAccess.file_exists(base):
		var img := Image.load_from_file(base)
		if img != null:
			mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.albedo_color = Color(1.55, 1.55, 1.6)
	mat.metallic = 0.7
	mat.roughness = 0.3
	var lum := base.get_basename() + "_l.png"
	if FileAccess.file_exists(lum):
		var l_img := Image.load_from_file(lum)
		if l_img != null:
			mat.emission_enabled = true
			mat.emission_texture = ImageTexture.create_from_image(l_img)
			mat.emission_energy_multiplier = 2.5
	return mat
