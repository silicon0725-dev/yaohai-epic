## 蒙皮拉伸审计（SceneTree）：CPU 复刻数据纹理蒙皮
## v' = Σ w_i · (G_i · T(−pivot_i)) · v，对指定动画帧统计每个 quad
## 蒙皮后对角线长度 / 绑定对角线长度 —— 顶点级 LBS 混合带在大旋转差
## 下的面剪切拉伸量化（用户实机"面被异常拉伸"）。
## 运行：godot --headless --path . -s res://debug/audit_skin_stretch.gd
extends SceneTree

const YsmModel := preload("res://characters/ysm_model.gd")
const CharacterRig := preload("res://characters/character_rig.gd")
const Animator := preload("res://characters/character_animator.gd")
const EfRef := preload("res://characters/ef_reference_rig.gd")

const PACK_A := "res://assets/characters/ysm_default"
const KEYS := [
	["biped/yamato/living/yamato_idle", 1.0],   # 反手待机 Tool≈174°
	["biped/yamato/living/yamato_run", 0.25],   # 摆臂/摆腿峰段
	["biped/yamato/attack/yamato_combo_a_1", 0.5],
]


func _init() -> void:
	var abs_path := ProjectSettings.globalize_path("user://anim_ef")
	if DirAccess.open(abs_path) == null:
		print("!! 无 anim_ef，退出")
		quit(1)
		return
	var rig: Dictionary = CharacterRig.build(YsmModel.load_pack(PACK_A))
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	var pivots: Array = rig["pivots"]
	var arrays: Array = (rig["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# 顶点 → (joint,weight) 两条（COLOR r/g + b/a）
	var vj0 := PackedInt32Array()
	var vj1 := PackedInt32Array()
	var vw0 := PackedFloat32Array()
	var vw1 := PackedFloat32Array()
	for c in colors:
		vj0.append(int(round(c.r * 255.0)))
		vj1.append(int(round(c.b * 255.0)))
		vw0.append(c.g)
		vw1.append(c.a)
	var raw: Dictionary = EfRef._load_file("%s/%s.json"
			% [abs_path, KEYS[0][0]])
	var anim := Animator.new()
	anim.setup(rig, {"c": EfRef.retarget(raw, rig)})
	for kv in KEYS:
		var t_hit: float = kv[1]
		# 落到该时刻：重置后推进
		anim.set_base("c", 1.0, false, 0.0)
		var acc := 0.0
		while acc < t_hit + 0.25:
			anim.update(1.0 / 30.0)
			acc += 1.0 / 30.0
		var pose: Dictionary = anim.update(0.0)
		var globals := []
		var skins := []
		globals.resize(joints.size())
		skins.resize(joints.size())
		for i in joints.size():
			var e: Dictionary = pose[joints[i]]
			var local := Transform3D(Basis(e["q"]), e["p"])
			var g: Transform3D = local if parents[i] < 0 \
					else (globals[parents[i]] as Transform3D) * local
			globals[i] = g
			skins[i] = g * Transform3D(Basis(), -pivots[i])
		var worst := 0.0
		var worst_pair := ""
		var dual_ratio := 0
		var quad_count := indices.size() / 6
		for q in quad_count:
			var i0: int = indices[q * 6]
			var moved_v := []
			var dual := false
			for vi in [i0, indices[q * 6 + 1], indices[q * 6 + 2],
					indices[q * 6 + 3]]:
				var v: Vector3 = verts[vi]
				var p0: Vector3 = (skins[vj0[vi]] as Transform3D) * v
				if vw1[vi] > 0.004:
					dual = true
					var p1: Vector3 = (skins[vj1[vi]] as Transform3D) * v
					moved_v.append(p0.lerp(p1, vw1[vi]))
				else:
					moved_v.append(p0)
			if dual:
				dual_ratio += 1
			# quad 两条对角线 (角序 0,2 与 1,3)
			var d_bind := maxf((verts[i0] - verts[indices[q * 6 + 2]]).length(),
					(verts[indices[q * 6 + 1]] - verts[indices[q * 6 + 3]]).length())
			var d_skin := maxf((moved_v[0] - moved_v[2]).length(),
					(moved_v[1] - moved_v[3]).length())
			var r: float = d_skin / maxf(d_bind, 1e-6)
			if dual and r > worst:
				worst = r
				worst_pair = "%s+%s w=%.2f" % [joints[vj0[i0]], joints[vj1[i0]],
						vw1[i0]]
		print("%-44s t=%.2f  混合quad=%d  最差对角线拉伸=%.2f×（%s）" % [
				kv[0], t_hit, dual_ratio, worst, worst_pair])
	print("判读：>1.3× = 肉眼可见面剪切拉伸；MC/YSM/EF 原版=刚体分块无混合")
	quit(0)
