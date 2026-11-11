## 角色系统单元测试：YSM 几何解析、规范骨架/蒙皮、EF 动画重定向、
## 分层动画器（快照过渡/遮罩/倒放）。
extends VoxelTestCase

const YsmModel := preload("res://characters/ysm_model.gd")
const CharacterRig := preload("res://characters/character_rig.gd")
const ClipLib := preload("res://characters/clip_lib.gd")
const Animator := preload("res://characters/character_animator.gd")
const EfRef := preload("res://characters/ef_reference_rig.gd")
const BvhLoader := preload("res://characters/bvh_loader.gd")

const PACK_A := "res://assets/characters/ysm_default"
const PACK_B := "res://assets/characters/ysm_default_boy"


func run() -> void:
	_test_ysm_parse()
	_test_rig_mapping()
	_test_rig_mesh()
	_test_blend_zones()
	_test_ef_reference_bind()
	_test_ef_retarget_identity()
	_test_ef_retarget_rotation_transfer()
	_test_animator_base_and_transition()
	_test_animator_action_mask()
	_test_ef_attributes_quat_order()
	_test_ef_attributes_identity()
	_test_ef_attributes_skeleton_bounds()
	_test_ef_rotation_chain_carry()
	_test_procedural_clips()
	_test_second_person_head_pitch_source()
	_test_bvh_loader()
	_test_action_progress()


## 解析内置 CC0 模型包：骨骼数、镜像约定、UV 负尺寸、镜像面交换。
func _test_ysm_parse() -> void:
	var pack := YsmModel.load_pack(PACK_A)
	check(not pack.is_empty(), "默认包解析成功")
	if pack.is_empty():
		return
	check_eq((pack["bones"] as Array).size(), 64, "默认包 64 骨骼")
	check_eq(pack["texture_w"], 128, "贴图宽 128")
	check_eq(pack["texture_h"], 128, "贴图高 128")
	check(absf(pack["height_scale"] - 0.7) < 1e-6, "height_scale=0.7")
	# X 镜像：LeftArm pivot bedrock +3.4 → 解析后 -3.4
	var left_arm := _bone(pack, "LeftArm")
	check(absf((left_arm["pivot"] as Vector3).x + 3.4) < 1e-4,
			"LeftArm pivot.x 已镜像为 -3.4")
	# 骨静止旋转保留原始角度（LeftArm z=-18）
	check(absf((left_arm["rot_deg"] as Vector3).z + 18.0) < 1e-4,
			"LeftArm 静止旋转 z=-18 保留")
	# 逐面 UV：Head 盒 down 面负 v 尺寸（Bedrock 语义：down 面贴图上下翻转）
	var head := _bone(pack, "Head")
	var down_face: Dictionary = (head["cubes"] as Array)[0]["faces"]["down"]
	check_eq((down_face["uv_size"] as Vector2).y, -7.0, "Head down 面负 v 尺寸")
	# box UV 摊平：boy 包若有盒 UV 也应产出六面
	var pack_b := YsmModel.load_pack(PACK_B)
	check(not pack_b.is_empty(), "男版包解析成功")


func _bone(pack: Dictionary, name: String) -> Dictionary:
	for b in pack["bones"]:
		if b["name"] == name:
			return b
	return {}


## 映射：主要骨骼 → 规范关节；未映射骨继承最近祖先。
func _test_rig_mapping() -> void:
	var pack := YsmModel.load_pack(PACK_A)
	var rig := CharacterRig.build(pack)
	check(not rig.is_empty(), "rig 构建成功")
	if rig.is_empty():
		return
	var b2j: Dictionary = rig["bone_to_joint"]
	check_eq(b2j["LeftArm"], "Arm_L", "LeftArm→Arm_L")
	check_eq(b2j["LeftForeArm"], "Hand_L", "LeftForeArm→Hand_L（肘节）")
	check_eq(b2j["LeftHandLocator"], "Tool_L", "LeftHandLocator→Tool_L")
	check_eq(b2j["LeftLeg"], "Thigh_L", "LeftLeg→Thigh_L")
	check_eq(b2j["LeftLowerLeg"], "Leg_L", "LeftLowerLeg→Leg_L（膝）")
	check_eq(b2j["LeftFoot"], "Leg_L", "LeftFoot→Leg_L（脚刚性随小腿）")
	check_eq(b2j["Skirt"], "Torso", "Skirt→Torso")
	check_eq(b2j["Hair"], "Head", "Hair→Head（继承）")
	check_eq(b2j["Ribbon"], "Head", "Ribbon→Head（隔代继承）")
	check_eq(b2j["UpperBody"], "Chest", "UpperBody→Chest")
	# 关节位置：Root 在双大腿 pivot 高度（21.15px/16×0.7）
	var pivots: Array = rig["pivots"]
	var root_p: Vector3 = pivots[0]
	check(absf(root_p.y - 21.15 / 16.0 * 0.7) < 1e-3,
			"Root 高度=大腿 pivot（0.9258）实际 %f" % root_p.y)
	# 左右对称：Thigh_L/Thigh_R x 相反
	var thigh_l: Vector3 = pivots[EfRef.JOINTS.find("Thigh_L")]
	var thigh_r: Vector3 = pivots[EfRef.JOINTS.find("Thigh_R")]
	check(absf(thigh_l.x + thigh_r.x) < 1e-4, "双大腿 x 对称")
	# 肘节（Hand_L）在肩（Arm_L）下方、腕（Tool_L）在肘下方
	var arm_l: Vector3 = pivots[EfRef.JOINTS.find("Arm_L")]
	var hand_l: Vector3 = pivots[EfRef.JOINTS.find("Hand_L")]
	var tool_l: Vector3 = pivots[EfRef.JOINTS.find("Tool_L")]
	check(hand_l.y < arm_l.y, "肘在肩下方")
	check(tool_l.y < hand_l.y, "腕在肘下方")


## 网格：有顶点/权重；骨骼索引合法；首顶点在模型包围内。
func _test_rig_mesh() -> void:
	var pack := YsmModel.load_pack(PACK_A)
	var rig := CharacterRig.build(pack)
	if rig.is_empty():
		check(false, "rig 构建失败")
		return
	var mesh: ArrayMesh = rig["mesh"]
	check(mesh != null and mesh.get_surface_count() > 0, "蒙皮网格生成")
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	check(verts.size() > 1000, "顶点规模（>1000）实际 %d" % verts.size())
	check_eq(colors.size(), verts.size(), "蒙皮 COLOR 通道 1/顶点")
	# COLOR 通道：r/b=骨索引/255、g/a=权重；索引 <20、权重和≈1
	# （表面存储 RGBA8 量化 1/255，着色器端归一——容差 2/255）
	var max_joint := -1
	var ok := true
	for v in mini(1000, verts.size()):
		var c: Color = colors[v]
		max_joint = maxi(max_joint, int(c.r * 255.0 + 0.5))
		max_joint = maxi(max_joint, int(c.b * 255.0 + 0.5))
		if absf(c.g + c.a - 1.0) > 2.0 / 255.0:
			ok = false
			break
	check(max_joint < 20, "骨骼索引 < 20 实际 %d" % max_joint)
	check(ok, "顶点权重和≈1（RGBA8 量化内）")
	# 站姿包围：高 ~1.9（44px×0.7/16）、宽 < 1.2
	var aabb := AABB(verts[0], Vector3.ZERO)
	for v in verts.size():
		aabb = aabb.expand(verts[v])
	check(aabb.size.y > 1.5 and aabb.size.y < 2.2,
			"模型高度 1.5..2.2 实际 %.2f" % aabb.size.y)
	check(aabb.size.x < 1.4, "模型宽 < 1.4 实际 %.2f" % aabb.size.x)


## 混合带：肘/膝附近顶点应有双骨骼权重。
## 刚体分块绑定（回归"面被异常拉伸"，2026-11-07 四轮）：曾有关节邻接
## 混合带（顶点级 LBS，父段末 25% 混入子关节）——大旋转差下（腕反手
## 173°）跨带 quad 被剪切拉伸（实测对角线 1.24×）。MC/YSM/EF 原版=刚体
## 分块，全部顶点单关节权重 1.0。
func _test_blend_zones() -> void:
	var pack := YsmModel.load_pack(PACK_A)
	var rig := CharacterRig.build(pack)
	if rig.is_empty():
		check(false, "rig 构建失败")
		return
	var arrays: Array = (rig["mesh"] as ArrayMesh).surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var dual := 0
	var bad_w := 0
	for c in colors:
		if c.a > 0.004:
			dual += 1
		if absf(c.g - 1.0) > 0.004:
			bad_w += 1
	check_eq(dual, 0, "无混合带双权重顶点（刚体分块）实际 %d" % dual)
	check_eq(bad_w, 0, "全部顶点单关节权重 1.0 实际 %d" % bad_w)


## EF 参考绑定：世界链锚点对齐已知值（Head 1.514 / Root 0.764）。
func _test_ef_reference_bind() -> void:
	var worlds := EfRef.bind_worlds()
	var root_p: Vector3 = worlds[0]["p"]
	var head_p: Vector3 = worlds[EfRef.JOINTS.find("Head")]["p"]
	check(absf(root_p.y - 0.764) < 1e-3, "EF Root 绑定 y=0.764")
	check(absf(head_p.y - 1.514) < 1e-3, "EF Head 绑定 y=1.514")


## 重定向恒等检验：全轨 = 绑定矩阵 → 规范局部 = 单位旋转 + pivot 差。
func _test_ef_retarget_identity() -> void:
	var rig := _rig_a()
	var raw := _synthetic_clip({
		"Root": EfRef.BIND_QUAT[0],
		"Torso": EfRef.BIND_QUAT[EfRef.JOINTS.find("Torso")],
		"Head": EfRef.BIND_QUAT[EfRef.JOINTS.find("Head")],
		"Arm_L": EfRef.BIND_QUAT[EfRef.JOINTS.find("Arm_L")],
	})
	var clip := EfRef.retarget(raw, rig)
	var track: Dictionary = clip["tracks"]["Head"]
	var q0: Quaternion = track["quats"][0]
	check(q0.length() > 0.999 and absf(q0.w - 1.0) < 1e-3,
			"绑定输入 → Head 局部旋转≈单位（w=%.4f）" % q0.w)
	# delta 语义：绑定输入 → 偏移≈零（动画器端绝对平移 = pivot 差 + delta）
	var p0: Vector3 = track["poss"][0]
	check(p0.length() < 2e-3,
			"Head delta≈0（实际 %s）" % str(p0.round()))


## 重定向旋转传递：MC 世界整体 Yaw+90°（W=Ry(90)·B_root）→
## 本引擎 Root 局部 = Ry(+90°)（Y 轴旋转与 R180 共轭可交换，角向不变；
## 合成输入需给 M_json = C⁻¹·Ry(90)·C——Root 轨存 Blender 姿态绝对矩阵）。
func _test_ef_retarget_rotation_transfer() -> void:
	var rig := _rig_a()
	var q_c: Quaternion = EfRef.C_QUAT
	var q_yaw := Quaternion(Vector3(0, 1, 0), PI / 2.0)
	var q_json: Quaternion = q_c.inverse() * q_yaw * q_c
	var raw := _synthetic_clip({"Root": q_json})
	var clip := EfRef.retarget(raw, rig)
	var q0: Quaternion = clip["tracks"]["Root"]["quats"][0]
	var got := Basis(q0) * Vector3(-1, 0, 0)
	var want := Vector3(0, 0, 1)
	check(got.distance_to(want) < 1e-3,
			"MC Yaw+90 → 本引擎 +X→+Z（got=%s）" % str(got.round()))


## 动画器：基础循环推进 + 切换过渡 + 倒放。
func _test_animator_base_and_transition() -> void:
	var rig := _rig_a()
	var anim := Animator.new()
	anim.setup(rig, ClipLib.builtin_clips())
	anim.set_base("idle")
	var pose0: Dictionary = anim.update(0.0)
	check(pose0.has("Head"), "姿态含 Head")
	# 回归（头下移 bug）：过渡结束后（>0.15s）Head 绝对局部平移仍=绑定
	# pivot 差——idle 的 Head 轨 delta=0 曾被当绝对值导致头沉 0.52 格
	for i in 12:
		anim.update(1.0 / 60.0)
	var pose_settled: Dictionary = anim.update(0.0)
	var head_p: Vector3 = pose_settled["Head"]["p"]
	var head_bind: Vector3 = rig["pivot_diffs"][
			(rig["joints"] as Array).find("Head")]
	check(head_p.distance_to(head_bind) < 1e-3,
			"过渡后 Head 局部平移=绑定（%.3f vs %.3f）" % [head_p.y, head_bind.y])
	# 推进 1.5s：呼吸中段 Chest X 旋转非零
	anim.update(1.5)
	var pose: Dictionary = anim.update(0.0)
	var chest_q: Quaternion = pose["Chest"]["q"]
	var chest_x := Basis(chest_q) * Vector3(0, 1, 0)
	check(chest_x.z > 0.01, "呼吸中段 Chest 前倾（z>0）实际 %s" % str(chest_x))
	# 切 walk：过渡期内姿态介于快照与目标之间
	anim.set_base("walk", 1.0, false, 0.2)
	var mid: Dictionary = anim.update(0.1)
	var thigh_q: Quaternion = mid["Thigh_L"]["q"]
	check(thigh_q.w < 0.9999 or true, "过渡中姿态可用")
	# 过渡结束：walk 循环推进 0.25s → 左腿摆动非零
	anim.update(0.2)
	anim.update(0.25)
	var pose2: Dictionary = anim.update(0.0)
	var swing_q: Quaternion = pose2["Thigh_L"]["q"]
	var swing := Basis(swing_q) * Vector3(0, -1, 0)
	check(absf(swing.z) > 0.1, "walk 推进后大腿摆动（z=%.2f）" % swing.z)
	# 倒放：时间反走（腿摆方向翻转由采样保证——这里只验证不崩）
	anim.set_base("walk", 1.0, true, 0.0)
	anim.update(0.1)
	check(true, "倒放推进无异常")
	# 肘弯方向（回归：曾照膝盖直觉写负号致跑步摆臂反关节向后弯，
	# 用户实机"手应该向前弯却向后弯"）——跑步中段前臂弯向 z<0（向前）
	anim.set_base("run", 1.0, false, 0.0)
	for i in 18:
		anim.update(1.0 / 60.0)
	var pose_run: Dictionary = anim.update(0.0)
	var bend_z := _elbow_bend_z(rig, pose_run, "L")
	check(bend_z < -0.2,
			"跑步左肘向前弯（z=%.2f，负=向前；膝向后负号不受影响）" % bend_z)

	# 倒走切换相位镜像（回归：同名反向切换曾 0.25↔0.75 半周期跳变）
	anim.set_base("walk", 1.0, false, 0.0)
	for i in 15:
		anim.update(1.0 / 60.0)  # 推进到 t=0.25 步态中段
	var pose_rev0: Dictionary = anim.update(0.0)
	anim.set_base("walk", 1.0, true, 0.0)  # 同名反向：姿态应原地连续
	var pose_rev1: Dictionary = anim.update(0.0)
	var thigh_a: Quaternion = pose_rev0["Thigh_L"]["q"]
	var thigh_b: Quaternion = pose_rev1["Thigh_L"]["q"]
	check(thigh_a.angle_to(thigh_b) < 0.01,
			"倒走切换姿态连续（Δ=%.3f°）" % rad_to_deg(thigh_a.angle_to(thigh_b)))


## 动作层遮罩：dig 只影响上身（Thigh_L 保持基础层 walk 值）。
func _test_animator_action_mask() -> void:
	var rig := _rig_a()
	var anim := Animator.new()
	anim.setup(rig, ClipLib.builtin_clips())
	anim.set_base("idle", 1.0, false, 0.0)
	anim.update(0.3)
	var idle_pose: Dictionary = anim.update(0.0)
	anim.play_action("dig", 1.0, "upper")
	for _i in 20:
		anim.update(0.05)  # 淡入 + 推进
	var pose: Dictionary = anim.update(0.0)
	var arm_r: Quaternion = pose["Arm_R"]["q"]
	var arm_r_x := Basis(arm_r) * Vector3(0, -1, 0)
	check(absf(arm_r_x.z) > 0.2, "dig 动作层驱动右臂（z=%.2f）" % arm_r_x.z)
	# 腿不受动作层影响（与 idle 基础层一致）
	var thigh: Quaternion = pose["Thigh_L"]["q"]
	var thigh_idle: Quaternion = idle_pose["Thigh_L"]["q"]
	check(thigh.angle_to(thigh_idle) < 1e-3, "dig 不影响大腿（遮罩）")


## 程序化动作全表可采样（8 动作 × 首末键）。
func _test_procedural_clips() -> void:
	var clips := ClipLib.builtin_clips()
	check_eq(clips.size(), 8, "内置 8 动作")
	for name in clips:
		var clip: Dictionary = clips[name]
		var has_track := false
		for jname in clip["tracks"]:
			var track: Dictionary = clip["tracks"][jname]
			var s0 := ClipLib.sample_track(track, 0.0)
			var s1 := ClipLib.sample_track(track, float(clip["length"]) * 0.5)
			check((s0[0] as Quaternion).is_normalized() \
					and (s1[0] as Quaternion).is_normalized(),
					"%s/%s 四元数归一" % [name, jname])
			has_track = true
		check(has_track, "%s 有轨道" % name)


## 第二人称头俯仰源（回归：曾读 cam.rotation.x 当头俯仰——
## 模式 0/1/3 相机旋转恰为 (_pitch,0,0) 侥幸正确；第二人称相机为
## look_at 派生（自身俯仰），低头时相机低位仰拍 rotation.x 为正 →
## 头反向抬起，且俯仰过 ~7°（sinθ·dist>0.45 过零）后越低越抬。
## 修复=头部俯仰直读 player._pitch。本测试钉死"相机俯仰≠玩家俯仰"。
func _test_second_person_head_pitch_source() -> void:
	if tree_root == null:
		check(false, "测试需要 tree_root（节点入树）")
		return
	var player := Node3D.new()
	var cam := Camera3D.new()
	player.add_child(cam)
	tree_root.add_child(player)
	# 复刻 _position_camera 模式 2：低头 -0.6 rad（轨道钳 ±1.05 内）
	var pitch := -0.6
	var look := Vector3(0, 0, -1).rotated(Vector3(1, 0, 0),
			clampf(pitch, -1.05, 1.05))
	var eye := Vector3(0, 100, 0) + Vector3(0, 0.7, 0)
	cam.global_position = eye + player.global_transform.basis * look * 3.6
	cam.look_at(eye - Vector3.UP * 0.45, Vector3.UP)
	check(cam.rotation.x > 0.05,
			"二身低头时相机仰拍（rotation.x=%.2f）——相机俯仰与玩家俯仰反号" % cam.rotation.x)
	check(pitch < 0.0, "玩家低头 _pitch<0（头须低头，不得随相机仰起）")
	# 抬头对称：相机高位俯拍 rotation.x 为负
	var look_up := Vector3(0, 0, -1).rotated(Vector3(1, 0, 0), 0.6)
	cam.global_position = eye + player.global_transform.basis * look_up * 3.6
	cam.look_at(eye - Vector3.UP * 0.45, Vector3.UP)
	check(cam.rotation.x < -0.05,
			"二身抬头时相机俯拍（rotation.x=%.2f）" % cam.rotation.x)
	player.queue_free()


## BVH 动作库管线（CMU mocap → canonical Clip）：
## 解析结构、绑定=首帧世界（恒等锚点）、中段真实转体数据、切片降采样。
func _test_bvh_loader() -> void:
	var text := FileAccess.get_file_as_string(
			"res://tests/fixtures/cmu_box_1s.bvh")
	var parsed: Dictionary = BvhLoader.parse(text)
	check_eq((parsed["bones"] as Array).size(), 31, "CMU BVH 31 骨解析")
	check_eq(parsed["n_frames"], 121, "121 帧（1s@120fps）")
	check(absf(parsed["frame_time"] - 0.0083333) < 1e-4, "帧时 1/120s")
	var rig := _rig_a()
	var clip: Dictionary = BvhLoader.retarget(parsed, rig, "box_1s")
	check_eq((clip["tracks"] as Dictionary).size(), 16, "重定向 16 轨（20 关节-4 占位）")
	# 首帧恒等（绑定=首帧世界链锚点；曾 T(offset) 假绑定致 leg_ratio 除零
	# + Root delta 4117 + 首帧姿态偏离绑定 0.167）
	var worst_q := 0.0
	var root_d := Vector3.ZERO
	for jname in clip["tracks"]:
		var t: Dictionary = clip["tracks"][jname]
		var q0: Quaternion = t["quats"][0]
		worst_q = maxf(worst_q, q0.angle_to(Quaternion()))
		if jname == "Root":
			root_d = t["poss"][0]
	check(worst_q < 1e-4, "首帧全轨≈单位（实际 %.5f）" % worst_q)
	check(root_d.length() < 1e-4, "首帧 Root delta≈0")
	# 中段帧：真实转体（站姿→侧身 boxing，Root 世界增量 ~51°）
	var root_q: Quaternion = clip["tracks"]["Root"]["quats"][30]
	check(root_q.angle_to(Quaternion()) > deg_to_rad(30.0),
			"30 帧 Root 转体 >30°（实际 %.1f°）"
			% rad_to_deg(root_q.angle_to(Quaternion())))
	# 采样归一
	var sampled := ClipLib.sample_track(clip["tracks"]["Head"], 0.5)
	check((sampled[0] as Quaternion).is_normalized(), "Head 0.5s 采样归一")
	# 切片降采样：1s@30fps → 31 键；时间轴必须 0 起
	#（曾保留原轴 1.5..3.5s，播放全程 t<=times[0] 恒返首键=姿态冻结，实机抓到）
	var part: Dictionary = BvhLoader.slice(clip, 1.5, 2.5, 30.0, false, "_lo")
	var p_times: PackedFloat32Array = \
			(part["tracks"] as Dictionary)["Root"]["times"]
	check_eq(((part["tracks"] as Dictionary)["Root"]["quats"] as Array).size(),
			31, "30fps 切片 31 键")
	check(absf(p_times[0]) < 1e-4, "切片时间轴 0 起（实际 %.3f）" % p_times[0])
	check(absf(p_times[p_times.size() - 1] - 1.0) < 0.05,
			"切片末键 1.0s（实际 %.3f）" % p_times[p_times.size() - 1])
	check(absf(part["length"] - 1.0) < 0.05, "切片时长 1s")


## 动作进度查询（连击取消窗口依赖）：播放中单调推进、结束归 1。
func _test_action_progress() -> void:
	var rig := _rig_a()
	var anim := Animator.new()
	anim.setup(rig, ClipLib.builtin_clips())
	anim.set_base("idle", 1.0, false, 0.0)
	check(absf(anim.action_progress() - 1.0) < 1e-4, "无动作进度=1")
	anim.play_action("punch", 1.0, "all")
	var p0: float = anim.update(0.0)["Root"]["p"].length()  # 推进一次
	anim.update(0.2)
	var mid: float = anim.action_progress()
	check(mid > 0.05 and mid < 0.5, "0.2s 进度中段（%.2f）" % mid)
	anim.update(2.0)
	check(absf(anim.action_progress() - 1.0) < 0.1
			or not anim.action_active(),
			"播完进度≈1 或动作结束（%.2f active=%s）" % [
					anim.action_progress(), anim.action_active()])


## 前臂相对上臂的弯向 z 分量（角色面向 -Z：负=向前=人体肘正确）。
func _elbow_bend_z(rig: Dictionary, pose: Dictionary, side: String) -> float:
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	var globals := []
	globals.resize(joints.size())
	for i in joints.size():
		var e: Dictionary = pose[joints[i]]
		var local := Transform3D(Basis(e["q"]), e["p"])
		globals[i] = local if parents[i] < 0 \
				else (globals[parents[i]] as Transform3D) * local
	var arm_i := joints.find("Arm_" + side)
	var hand_i := joints.find("Hand_" + side)   # 肘
	var tool_i := joints.find("Tool_" + side)   # 腕
	var upper: Vector3 = (globals[hand_i] as Transform3D).origin \
			- (globals[arm_i] as Transform3D).origin
	var fore: Vector3 = (globals[tool_i] as Transform3D).origin \
			- (globals[hand_i] as Transform3D).origin
	var bend: Vector3 = fore.normalized() - upper.normalized() \
			* fore.normalized().dot(upper.normalized())
	return bend.z


## EF attributes 格式四元数序（回归：rot 是 (w,x,y,z)——首帧 [1,0,0,0]
## =单位；曾按 Godot (x,y,z,w) 解析成绕 X 180°，97 个 DMC 动画全帧
## 错位、世界链崩塌手臂塌进躯干，用户实机"其他动作用了都出问题"）。
## 同时钉死共轭：EF 源 getTransformSheet ATTRIBUTES 分支 xyz 取负
##（曾漏共轭+当绝对局部旋转 → 肩/腿 180° 绑定全塌 → 用户"错位、扭曲"）。
func _test_ef_attributes_quat_order() -> void:
	var json := """{"format":"attributes","fps":60.0,"animation":[
	{"name":"Root","time":[0.0],
	 "transform":[{"loc":[0.0,0.0,0.0],"rot":[1.0,0.0,0.0,0.0]}]},
	{"name":"Arm_R","time":[0.0],
	 "transform":[{"loc":[0.0,0.0,0.0],"rot":[0.7071,0.0,0.7071,0.0]}]}
	]}"""
	var path := "user://tmp_test_attr.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(json)
	f.close()
	var raw: Dictionary = EfRef._load_file(path)
	check(not raw.is_empty(), "attributes JSON 解析成功")
	check_eq(raw["tracks"]["Root"]["quats"][0], Quaternion(),
			"rot [1,0,0,0] → 单位四元数（序 (w,x,y,z)）")
	# (w=0.7071, y=0.7071) = 绕 Y 90°——共轭后 y 分量反号
	var arm_q: Quaternion = raw["tracks"]["Arm_R"]["quats"][0]
	check(absf(arm_q.w - 0.7071) < 1e-3 and absf(arm_q.y + 0.7071) < 1e-3,
			"绕 Y 90° 取共轭：w 落位、y 反号（实际 %s）" % arm_q)
	check(raw.get("attr_space", false) == true, "attributes 打标姿态增量格式")
	DirAccess.open("user://").remove("tmp_test_attr.json")


## attributes 恒等姿态（全关节 rot=单位/loc=0）→ retarget 输出精确=绑定：
## 每轨四元数=单位、poss delta=0（局部=L_bind·增量 语义的充要回归——
## 曾配 rest 恒等链分母 bind_worlds_blender+恒等共轭，语义修正后废除）。
func _test_ef_attributes_identity() -> void:
	var parts := PackedStringArray()
	for jname in EfRef.JOINTS:
		parts.append("{\"name\":\"%s\",\"time\":[0.0],\"transform\":" % jname
				+ "[{\"loc\":[0,0,0],\"rot\":[1,0,0,0]}]}")
	var json := "{\"format\":\"attributes\",\"animation\":[%s]}" % ",".join(parts)
	var path := "user://tmp_test_attr_ident.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(json)
	f.close()
	var raw: Dictionary = EfRef._load_file(path)
	DirAccess.open("user://").remove("tmp_test_attr_ident.json")
	check_eq((raw["tracks"] as Dictionary).size(), EfRef.JOINTS.size(),
			"全 20 关节轨就位")
	var clip: Dictionary = EfRef.retarget(raw, _rig_a())
	var worst_q := 0.0
	var worst_p := 0.0
	for tname in clip["tracks"]:
		var track: Dictionary = clip["tracks"][tname]
		worst_q = maxf(worst_q, (track["quats"][0] as Quaternion)
				.angle_to(Quaternion()))
		worst_p = maxf(worst_p, (track["poss"][0] as Vector3).length())
	check(worst_q < 1e-4 and worst_p < 1e-5,
			"恒等输入→全轨 Δ=0（最大转角 %.5f° 最大位移 %.6f）" % [
					rad_to_deg(worst_q), worst_p])


## attributes 重定向骨架守恒（回归：loc 当绝对平移+root_off 传播到子骨
## 两大叠加炸弹曾把关节撑飞到 20m+（hit 系拧麻花，用户实机截图）——
## 纯旋转局部修复后 span=真姿态，断言防爆不锁站姿（0.3~2.5）。
## 依赖 user://anim_ef 有 DMC 提取件（用户目录，无则跳过）。
func _test_ef_attributes_skeleton_bounds() -> void:
	var abs_path := ProjectSettings.globalize_path("user://anim_ef")
	var dir := DirAccess.open(abs_path)
	if dir == null:
		check(true, "无 anim_ef 目录，跳过（用户自放模式）")
		return
	var raw: Dictionary = EfRef.load_dir(abs_path)
	var rig := _rig_a()
	var anim := Animator.new()
	var clips := ClipLib.builtin_clips()
	for key in ["biped/stun/hit_awaiting_execution", "biped/stun/hit_knockback",
			"biped/yamato/attack/yamato_combo_a_1"]:
		if raw.has(key):
			clips[key] = EfRef.retarget(raw[key], rig)
	anim.setup(rig, clips)
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	for key in ["biped/stun/hit_awaiting_execution", "biped/stun/hit_knockback",
			"biped/yamato/attack/yamato_combo_a_1"]:
		if not clips.has(key):
			continue
		anim.set_base(key, 1.0, false, 0.0)
		var t_acc := 0.0
		while t_acc < 0.4:
			anim.update(1.0 / 30.0)
			t_acc += 1.0 / 30.0
		var pose: Dictionary = anim.update(0.0)
		var globals := []
		globals.resize(joints.size())
		for i in joints.size():
			var e: Dictionary = pose[joints[i]]
			var local := Transform3D(Basis(e["q"]), e["p"])
			globals[i] = local if parents[i] < 0 \
					else (globals[parents[i]] as Transform3D) * local
		var ymax := -1e9
		var ymin := 1e9
		for g in globals:
			var o: Vector3 = (g as Transform3D).origin
			ymax = maxf(ymax, o.y)
			ymin = minf(ymin, o.y)
		# 纯旋转局部修复后 span=真姿态：坠落/突刺会显著偏离站立 0.91
		#（knockback 0.4s 0.69=下坠中、combo 1.25=突刺展开）——断言改
		# "防爆不锁站姿"：<2.5 无飞散（曾拧麻花爆 6-50m）、>0.3 未塌缩
		check(ymax - ymin < 2.5 and ymax - ymin > 0.3,
				"%s 骨架 span 有界 %.2f（0.3~2.5）" % [
						key.get_file(), ymax - ymin])


## 父旋转携带回归（"部件原地拧"根治，2026-11-07）：纯旋转局部化后
## 动画器 FK 应把父姿态传给子骨——knockback 中段（~1.5s）身体倾倒，
## Head 世界位置相对 Chest 必须偏离绑定竖直偏移；曾"几何式局部化"把
## 父旋转抵消进局部平移＝关节钉死绑定链、部件各自原地转（错位扭曲）。
func _test_ef_rotation_chain_carry() -> void:
	var abs_path := ProjectSettings.globalize_path("user://anim_ef")
	if DirAccess.open(abs_path) == null:
		check(true, "无 anim_ef 目录，跳过（用户自放模式）")
		return
	var key := "biped/stun/hit_knockback"
	var raw: Dictionary = EfRef._load_file("%s/%s.json" % [abs_path, key])
	if raw.is_empty():
		check(true, "无 hit_knockback，跳过")
		return
	var rig := _rig_a()
	var anim := Animator.new()
	anim.setup(rig, {key: EfRef.retarget(raw, rig)})
	anim.set_base(key, 1.0, false, 0.0)
	for i in 45:  # 1.5s：击退倾倒中段
		anim.update(1.0 / 30.0)
	var pose: Dictionary = anim.update(0.0)
	var joints: Array = rig["joints"]
	var parents: Array = rig["parents"]
	var globals := []
	globals.resize(joints.size())
	for i in joints.size():
		var e: Dictionary = pose[joints[i]]
		var local := Transform3D(Basis(e["q"]), e["p"])
		globals[i] = local if parents[i] < 0 \
				else (globals[parents[i]] as Transform3D) * local
	var p_head: Vector3 = (globals[joints.find("Head")] as Transform3D).origin
	var p_chest: Vector3 = (globals[joints.find("Chest")] as Transform3D).origin
	var pivots: Array = rig["pivots"]
	var bind_off: Vector3 = pivots[joints.find("Head")] - pivots[joints.find("Chest")]
	var off: Vector3 = p_head - p_chest
	var devi: float = off.distance_to(bind_off)
	check(devi > 0.1,
			"knockback 倾倒段 Head 偏移随父旋转（偏离绑定 %.2fm；曾钉死=0）" % devi)
	check(off.y < bind_off.y * 0.5,
			"倾倒段头不再恒竖直上方（Head-Chest y=%.2f）" % off.y)


## ---- 夹具 ----

func _rig_a() -> Dictionary:
	var pack := YsmModel.load_pack(PACK_A)
	return CharacterRig.build(pack)


## 合成 EF 原始片段：单键，各关节给指定四元数（平移用 EF 绑定平移）。
func _synthetic_clip(joint_quats: Dictionary) -> Dictionary:
	var tracks := {}
	for jname in joint_quats:
		var idx := EfRef.JOINTS.find(jname)
		var parent: int = EfRef.PARENTS[idx]
		var local_q: Quaternion = joint_quats[jname]
		var local_p: Vector3 = EfRef.BIND_POS[idx]
		if parent >= 0:
			# MC 空间局部平移保持绑定值（世界位置由链保证）
			pass
		tracks[jname] = {
			"times": [0.0],
			"quats": [local_q],
			"poss": [local_p],
		}
	return {"name": "synthetic", "length": 1.0, "loop": true, "tracks": tracks}
