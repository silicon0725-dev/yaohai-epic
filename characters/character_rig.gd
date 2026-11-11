## YSM 模型 → 规范 20 关节骨架 + 蒙皮网格（canonical rig）。
##
## 架构（借鉴 ysm_epicfight_compat 的成熟映射，骨架语义对齐 Epic Fight）：
## - 20 规范关节 = EF biped 同名同层（Root/Torso/Chest/Head/Thigh-Leg-Knee/
##   Shoulder-Arm-Hand-Tool-Elbow ×L/R），EF 风格动画可直接重定向（见
##   ef_reference_rig.gd）；
## - 骨骼名映射：标准化后直查表（arm=肩、forearm/hand=肘节、locator=腕具）、
##   未映射骨继承最近已映射祖先（发型/裙摆/面部随头胸刚性）；
## - 关节位置 = 各锚骨 pivot（世界绑定、含 height/width_scale）；
## - 骨架绑定帧=单位旋转（纯平移链），YSM 骨骼静止旋转全部烘进网格顶点；
##   蒙皮 1 顶点 ≤2 影响，关节邻接带 smoothstep 混合（肘/膝/腕/脖）。
@tool
extends RefCounted

const YsmModel := preload("res://characters/ysm_model.gd")
const EfRef := preload("res://characters/ef_reference_rig.gd")

const JOINTS: Array = EfRef.JOINTS
const PARENTS: Array = EfRef.PARENTS

## YSM 骨名（标准化）→ 规范关节。标准化 = 小写 + 去 _/空格 + 去尾数字
## + 去 _default 后缀（compat 同款）。左右成对省写（_L/_R 后缀展开）。
const NAME_MAP_BASE := {
	"root": "Root", "center": "Root",
	"allbody": "Torso", "body": "Torso", "waist": "Torso", "torso": "Torso",
	"downbody": "Torso", "hip": "Torso", "hips": "Torso", "pelvis": "Torso",
	"skirt": "Torso", "leg": "Torso",
	"upbody": "Chest", "upperbody": "Chest", "chest": "Chest",
	"breast": "Chest", "boob": "Chest", "collar": "Chest",
	"backpack": "Chest", "cape": "Chest", "elytra": "Chest",
	"elytralocator": "Chest", "arm": "Chest",
	"allhead": "Head", "head": "Head",
	"leftarm": "Arm", "armleft": "Arm",
	"rightarm": "Arm", "armright": "Arm",
	"leftforearm": "Hand", "forearmleft": "Hand",
	"rightforearm": "Hand", "forearmright": "Hand",
	# ⚠ 手骨=腕（Tool）：EF "Hand"=肘、"Tool"=腕（命名解剖错位）——
	# 曾把 righthand 映到 Hand（肘）：腕部旋转（idle 反手待机 173°/挥刀
	# 104°）只作用于无网格的 locator，手部方块跟着肘转＋Hand→Tool 邻接
	# 混合带把肘/腕两套大差异旋转剪切插值＝前臂末端方块扭曲（用户实机
	# "前肢顶端扭曲"）。forearm→Hand（肘）不变。
	"lefthand": "Tool", "handleft": "Tool",
	"righthand": "Tool", "handright": "Tool",
	"lefthandlocator": "Tool", "leftitem": "Tool", "itemleft": "Tool",
	"righthandlocator": "Tool", "rightitem": "Tool", "itemright": "Tool",
	"leftleg": "Thigh", "legleft": "Thigh",
	"rightleg": "Thigh", "legright": "Thigh",
	"leftlowerleg": "Leg", "lowerlegleft": "Leg", "leftcalf": "Leg",
	"rightlowerleg": "Leg", "lowerlegright": "Leg", "rightcalf": "Leg",
	"leftfoot": "Leg", "footleft": "Leg",
	"rightfoot": "Leg", "footright": "Leg",
}

static func normalize_name(name: String) -> String:
	var s := name.to_lower()
	s = s.replace("_", "").replace(" ", "")
	while s.length() > 1 and s[s.length() - 1].is_valid_int():
		s = s.substr(0, s.length() - 1)
	if s.ends_with("default"):
		s = s.substr(0, s.length() - "default".length())
	return s


## 骨名 → 规范关节名（无映射返回 ""）。
static func joint_for_bone(name: String) -> String:
	var key := normalize_name(name)
	if NAME_MAP_BASE.has(key):
		var joint: String = NAME_MAP_BASE[key]
		if joint == "Root" or joint == "Torso" or joint == "Chest" \
				or joint == "Head":
			return joint
		# 成对关节：骨名含 left 决定左（其余含 right 或缺省=右）
		if key.find("left") >= 0:
			return joint + "_L"
		return joint + "_R"
	return ""


## 构建完整 rig。pack = ysm_model.load_pack 的返回值。
## 返回 {joints, parents, pivots, pivot_diffs, mesh, texture_path,
##   bone_to_joint, hand_locator_l/r, model_height, hip_y}；失败返回 {}。
static func build(pack: Dictionary) -> Dictionary:
	if pack.is_empty():
		return {}
	var bones: Array = pack["bones"]
	var by_name := {}
	for b in bones:
		by_name[b["name"]] = b
	# 1) 骨 → 关节（直查表 + 最近已映射祖先继承）
	var bone_joint := {}      # bone name -> joint name
	for b in bones:
		var direct := joint_for_bone(b["name"])
		if direct != "":
			bone_joint[b["name"]] = direct
	for b in bones:
		if bone_joint.has(b["name"]):
			continue
		var chain: String = b["parent"]
		while chain != "":
			if bone_joint.has(chain) and bone_joint[chain] != "":
				# 中间骨可能尚未解析（顺序无关：递归解析）
				bone_joint[b["name"]] = bone_joint[chain]
				break
			chain = String(by_name.get(chain, {}).get("parent", ""))
		if not bone_joint.has(b["name"]):
			bone_joint[b["name"]] = "Root"
	# 2) 世界绑定矩阵（父先子后；blocks 空间，缩放最后统一乘）
	var world := {}
	var y_scale: float = pack["height_scale"]
	var xz_scale: float = pack["width_scale"]
	for b in bones:
		var pivot: Vector3 = b["pivot"] / 16.0
		var rest := YsmModel.euler_basis(b["rot_deg"])
		var parent: String = b["parent"]
		# 骨骼变换 = T(pivot)·R·T(-pivot)（绕 pivot 旋转；平移链不累积）
		var local := Transform3D(Basis(), pivot) 				* Transform3D(rest, Vector3.ZERO) 				* Transform3D(Basis(), -pivot)
		if parent != "" and world.has(parent):
			world[b["name"]] = (world[parent] as Transform3D) * local
		else:
			world[b["name"]] = local
	# 3) 规范关节位置（锚骨 pivot → 世界绑定 → 缩放）
	var joint_of_bone_name := {}
	for bone_name in bone_joint:
		var joint_name: String = bone_joint[bone_name]
		if not joint_of_bone_name.has(joint_name):
			joint_of_bone_name[joint_name] = bone_name
	var pivots := []
	pivots.resize(JOINTS.size())
	# 锚骨 pivot（世界绑定原点，未缩放空间）
	var anchor := {}
	for j in JOINTS.size():
		var jname: String = JOINTS[j]
		var bone_name: String = joint_of_bone_name.get(jname, "")
		if bone_name != "" and world.has(bone_name):
			# 关节位置 = 骨骼世界矩阵作用于 pivot 点（世界矩阵原点≠pivot）
			var pivot_pt: Vector3 = by_name[bone_name]["pivot"] / 16.0
			anchor[jname] = (world[bone_name] as Transform3D) * pivot_pt
	# Root = 双大腿 pivot 均值（x/z 归零）
	var thigh_l: Vector3 = anchor.get("Thigh_L", Vector3(0.125, 24.0 / 16.0, 0))
	var thigh_r: Vector3 = anchor.get("Thigh_R", Vector3(-0.125, 24.0 / 16.0, 0))
	anchor["Root"] = Vector3(0.0, (thigh_l.y + thigh_r.y) * 0.5, 0.0)
	var chest: Vector3 = anchor.get("Chest", thigh_l.lerp(Vector3.UP * 1.4, 0.5))
	anchor["Torso"] = (anchor["Root"] as Vector3).lerp(chest, 0.15)
	if not anchor.has("Chest"):
		anchor["Chest"] = (anchor["Root"] as Vector3).lerp(
				anchor.get("Head", Vector3(0, 1.5, 0)), 0.5)
	# 叶关节/别名：Knee=Leg 位、Elbow=Hand 位、Shoulder=Arm 位、Tool=腕
	for side in ["_L", "_R"]:
		var leg_p: Vector3 = anchor.get("Leg" + side, anchor["Root"])
		anchor["Knee" + side] = leg_p
		var arm_p: Vector3 = anchor.get("Arm" + side, chest)
		anchor["Shoulder" + side] = arm_p
		var hand_p: Vector3 = anchor.get("Hand" + side, arm_p)
		anchor["Elbow" + side] = hand_p
		if not anchor.has("Tool" + side):
			anchor["Tool" + side] = hand_p
	# 应用整体缩放（x/z × width_scale、y × height_scale）
	for j in JOINTS.size():
		var p: Vector3 = anchor[JOINTS[j]]
		pivots[j] = Vector3(p.x * xz_scale, p.y * y_scale, p.z * xz_scale)
	# 4) 局部平移（骨架绑定帧=单位旋转）+ 世界绑定变换（Skin bind 用）
	var pivot_diffs := []
	pivot_diffs.resize(JOINTS.size())
	var bind_world := []
	bind_world.resize(JOINTS.size())
	for j in JOINTS.size():
		var parent: int = PARENTS[j]
		pivot_diffs[j] = pivots[j] - (pivots[parent] if parent >= 0 else Vector3.ZERO)
		if parent >= 0:
			bind_world[j] = (bind_world[parent] as Transform3D) 					* Transform3D(Basis(), pivot_diffs[j])
		else:
			bind_world[j] = Transform3D(Basis(), pivot_diffs[j])
	# 5) 蒙皮网格（顶点=世界绑定 × 整体缩放；法线逆转置缩放）
	var mesh := _build_mesh(pack, bones, world, bone_joint)
	if mesh == null:
		return {}
	# 手部挂点（世界绑定、已缩放）
	var hand_l: Vector3 = pivots[JOINTS.find("Tool_L")]
	var hand_r: Vector3 = pivots[JOINTS.find("Tool_R")]
	var max_y := 0.0
	for p in pivots:
		max_y = maxf(max_y, p.y)
	return {
		"joints": JOINTS.duplicate(),
		"parents": (PARENTS as Array).duplicate(),
		"pivots": pivots,
		"pivot_diffs": pivot_diffs,
		"bind_world": bind_world,
		"mesh": mesh,
		"texture_path": String(pack["textures"].get(
				String(pack["default_texture"]), "")),
		"bone_to_joint": bone_joint,
		"hand_locator_l": hand_l,
		"hand_locator_r": hand_r,
		"model_height": max_y,
		"hip_y": pivots[0].y,
	}


## 蒙皮网格组装：逐骨逐盒逐面（透明面剔除/半透明双面），顶点带 4 骨骼权重。
static func _build_mesh(pack: Dictionary, bones: Array, world: Dictionary,
		bone_joint: Dictionary) -> ArrayMesh:
	var tex_path := String(pack["textures"].get(
			String(pack["default_texture"]), ""))
	var tex: Image = null
	if tex_path != "":
		tex = Image.load_from_file(tex_path)
	var y_scale: float = pack["height_scale"]
	var xz_scale: float = pack["width_scale"]
	var scale_v := func(p: Vector3) -> Vector3:
		return Vector3(p.x * xz_scale, p.y * y_scale, p.z * xz_scale)
	var inv_scale_n := Vector3(1.0 / xz_scale, 1.0 / y_scale, 1.0 / xz_scale)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones_arr := PackedInt32Array()
	var weights_arr := PackedFloat32Array()
	var indices := PackedInt32Array()
	var joint_index := {}
	for j in JOINTS.size():
		joint_index[JOINTS[j]] = j
	for b in bones:
		var w: Transform3D = world[b["name"]]
		var joint_name: String = bone_joint[b["name"]]
		var jid: int = joint_index.get(joint_name, 0)
		for cube in b["cubes"]:
			var corners_px: Array = YsmModel.cube_corners(cube)
			# 盒件旋转（绕盒 pivot，YSM 欧拉约定）
			var cube_rot: Basis = Basis()
			var cube_pivot := Vector3.ZERO
			if cube["pivot"] != null and (cube["rot_deg"] as Vector3) != Vector3.INF:
				cube_rot = YsmModel.euler_basis(cube["rot_deg"])
				cube_pivot = (cube["pivot"] as Vector3) / 16.0
			var corners_w := []
			for c_px in corners_px:
				var c: Vector3 = (c_px as Vector3) / 16.0
				if cube_rot != Basis():
					c = cube_pivot + cube_rot * (c - cube_pivot)
				corners_w.append(w * c)
			for face_name in cube["faces"]:
				var cls := "solid"
				if tex != null:
					var classes := YsmModel.classify_faces(cube, tex)
					cls = String(classes.get(face_name, "solid"))
				if cls == "cull":
					continue
				var uv_list: Array = YsmModel.face_uvs(
						cube, face_name, pack["texture_w"], pack["texture_h"])
				var corner_ids: Array = YsmModel.FACE_CORNERS[face_name]
				var base := verts.size()
				for k in 4:
					# FACE_CORNERS 为 p1..p8（1 基），corners_w 0 基
					var p: Vector3 = scale_v.call(corners_w[corner_ids[k] - 1])
					verts.append(p)
					var n: Vector3 = (w.basis * (cube_rot * YsmModel.FACE_NORMALS[face_name]))
					n = Vector3(n.x * inv_scale_n.x, n.y * inv_scale_n.y,
							n.z * inv_scale_n.z).normalized()
					norms.append(n)
					uvs.append(uv_list[k])
					bones_arr.append(jid)
					bones_arr.append(0)
					bones_arr.append(0)
					bones_arr.append(0)
					weights_arr.append(1.0)
					weights_arr.append(0.0)
					weights_arr.append(0.0)
					weights_arr.append(0.0)
				_emit_quad(indices, base, cls == "translucent")
	# 刚体分块绑定（MC/YSM/EF 原版语义：每方块 8 顶点同权重随单关节）。
	# 曾有关节邻接混合带（父段末 25% 顶点 smoothstep 混入子关节）——
	# 顶点级 LBS 在大旋转差下（腕反手 173°/低头）把跨带 quad 剪切拉伸
	# （实测对角线 1.24×=面积 ~1.5×，用户实机"面被异常拉伸"）。
	if indices.is_empty():
		return null
	# 蒙皮数据 → COLOR 通道（自研 GPU 蒙皮：r/b=骨索引/255、g/a=权重）
	var colors := PackedColorArray()
	for v in verts.size():
		colors.append(Color(
				bones_arr[v * 4] / 255.0, weights_arr[v * 4],
				bones_arr[v * 4 + 1] / 255.0, weights_arr[v * 4 + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Godot 正面=顺时针（从摄像机看）：四角按外侧逆时针存 → (0,2,1)(0,3,2)。
## 半透明面补一组反向索引（双面）。
static func _emit_quad(indices: PackedInt32Array, base: int, double_sided: bool) -> void:
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
	if double_sided:
		indices.append(base)
		indices.append(base + 1)
		indices.append(base + 2)
		indices.append(base)
		indices.append(base + 2)
		indices.append(base + 3)


## 组建 Skeleton3D 节点（绑定帧=单位旋转，rest=局部平移）。
static func make_skeleton(rig: Dictionary) -> Skeleton3D:
	var skel := Skeleton3D.new()
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	var diffs: Array = rig["pivot_diffs"]
	for i in joints.size():
		skel.add_bone(String(joints[i]))
	for i in joints.size():
		skel.set_bone_parent(i, int(parents[i]))
		var rest := Transform3D(Basis(), diffs[i])
		skel.set_bone_rest(i, rest)
		skel.set_bone_pose(i, rest)
	return skel
