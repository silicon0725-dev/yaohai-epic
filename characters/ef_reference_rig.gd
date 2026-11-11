## Epic Fight 风格动画的参考绑定骨架 + 加载/重定向。
##
## ⚠ 许可边界：本文件只内嵌 **20 关节绑定姿态常量**（四元数+平移，
## 从 EF biped 骨架布局换算的接口事实数据），不含其网格/动画资产。
## 动画 JSON 由用户自行放入 user://anim_ef/（Epic Fight 资产为
## All-Rights-Reserved，不得入库、不得随项目分发）。
##
## 数学（源码核对 epicfight 1.21.1 JsonAssetLoader/OpenMatrix4f）：
## - matrix 格式：每轨 {name, time[], transform[][16]}，矩阵按原样读
##   （列向量约定，平移在 12/13/14 元素——用 biped 骨架锚点实测验证）；
##   Root 轨有效局部 = Rx(-90°)·M_json（Blender→MC 根修正），其余轨 = M_json
##   （源码 getTransformSheet 乘 invLocal 恰与 getAnimationBoundMatrix 的
##   JOINT_LOCAL 相消，净效果=局部矩阵直读）；
## - attributes 格式：transform=[{loc,rot,sca}]，rot=(w,x,y,z) 序且取
##   **共轭**（xyz 取负）；有效局部 = L_bind·T(loc)·R(conj)——动画增量
##   叠在 bind 局部之上（源码合成序 PARENT·JOINT_LOCAL·ANIMATION，
##   attributes 不乘 invLocal/B2MC：B2MC 已烘进 armature bind 常量）；
## - 绑定世界 B_j = B_parent·bindLocal_j（MC 空间）；
## - 世界增量 Δ_j = W_j·B_j⁻¹；MC→本引擎刚体空间共轭 D = R180y·Δ·R180y
##   （MC 模型经 RotY(180°) 渲染、本引擎 YSM 绑定即"建模空间"）；
## - 目标姿态 G_j = T(pivot_j)·R(D_j)（绑定=单位帧骨架，蒙皮顶点已烘绑定）；
## - 局部姿态 pose_j = G_parent⁻¹·G_j → 存四元数+平移（逐键烘焙）。
@tool
extends RefCounted

const JOINTS := [
	"Root", "Thigh_R", "Leg_R", "Knee_R", "Thigh_L", "Leg_L", "Knee_L",
	"Torso", "Chest", "Head",
	"Shoulder_R", "Arm_R", "Hand_R", "Tool_R", "Elbow_R",
	"Shoulder_L", "Arm_L", "Hand_L", "Tool_L", "Elbow_L",
]
const PARENTS := [-1, 0, 1, 1, 0, 4, 4, 0, 7, 8, 8, 10, 11, 12, 11, 8, 15, 16, 17, 16]

## 绑定局部（MC 空间，Root 已含 Rx(-90°) 根修正）。
## 来源：EF biped armature hierarchy 逐关节换算（脚本生成）。
const BIND_QUAT := [
	Quaternion(0, 0, 0, 1),                                    # Root
	Quaternion(-1, -0.0, 0, 0.000000250),                      # Thigh_R
	Quaternion(-0.0, 0.000000500, -0.0, 1),                    # Leg_R
	Quaternion(0.707106428, 0, -0.0, 0.707107135),             # Knee_R
	Quaternion(-1, -0.0, 0, 0.000000250),                      # Thigh_L
	Quaternion(-0.0, 0.000000500, -0.0, 1),                    # Leg_L
	Quaternion(0.707106428, 0, -0.0, 0.707107135),             # Knee_L
	Quaternion(0, 0, 0, 1),                                    # Torso
	Quaternion(0, 0, 0, 1),                                    # Chest
	Quaternion(0, 0, 0, 1),                                    # Head
	Quaternion(-0.571345577, -0.416610407, -0.571345577, 0.416610407),  # Shoulder_R
	Quaternion(-0.416610407, -0.571345577, 0.416610407, 0.571345577),   # Arm_R
	Quaternion(-0.055057008, 0, -0.0, 0.998483213),            # Hand_R
	Quaternion(-0.999958933, 0, -0.0, 0.009062712),            # Tool_R
	Quaternion(-0.0, -0.707106781, 0.707106781, 0),            # Elbow_R
	Quaternion(-0.571345577, 0.416610407, 0.571345577, 0.416610407),    # Shoulder_L
	Quaternion(-0.416610407, 0.571345577, -0.416610407, 0.571345577),   # Arm_L
	Quaternion(-0.055057022, 0, -0.0, 0.998483212),            # Hand_L
	Quaternion(-0.999958933, 0, -0.0, 0.009062706),            # Tool_L
	Quaternion(-0.0, -0.707106781, 0.707106781, 0),            # Elbow_L
]
const BIND_POS := [
	Vector3(-0.000005, 0.763972, -0.000946),
	Vector3(0.124994, -0.002831, -0.000012),
	Vector3(0, 0.374720, 0),
	Vector3(0, 0.374720, 0),
	Vector3(-0.125006, -0.002831, -0.000012),
	Vector3(-0.000000, 0.374720, 0),
	Vector3(-0.000000, 0.374720, 0),
	Vector3(0, 0.050000, 0),
	Vector3(0, 0.300000, 0),
	Vector3(0, 0.400000, 0),
	Vector3(0, 0.400000, 0),
	Vector3(-0.000000, 0.393860, 0),
	Vector3(0, 0.300000, -0.000000),
	Vector3(-0.000000, 0.272858, 0),
	Vector3(0, 0.300000, -0.000000),
	Vector3(0, 0.400000, 0),
	Vector3(-0.000000, 0.393860, 0),
	Vector3(0, 0.300000, 0),
	Vector3(-0.000000, 0.272858, -0.000000),
	Vector3(0, 0.300000, 0),
]

const C_QUAT := Quaternion(-0.7071067811865476, 0, 0, 0.7071067811865476)
const R180_QUAT := Quaternion(Vector3(0, 1, 0), PI)
const EF_LEG_LENGTH := 0.764  # Root 绑定高度（根位移缩放基准）


## 扫描目录（递归）加载 EF 动画 JSON（跳过 data/、pov/ 子目录——
## 客户端属性分文件，本引擎不消费）。返回 {相对路径名: raw_clip}。
## raw_clip = {name, loop, length, tracks: {joint: {"times": [], "mats": [Basis×2?]}}}
## 原始矩阵暂存为 [Quaternion, Vector3]（分解后），Root 轨标记 root=true。
static func load_dir(dir_path: String) -> Dictionary:
	var out := {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	_scan(dir_path, "", out)
	return out


static func _scan(root: String, rel: String, out: Dictionary) -> void:
	var dir := DirAccess.open("%s/%s" % [root, rel] if rel != "" else root)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var rel_path := "%s/%s" % [rel, name] if rel != "" else name
		if dir.current_is_dir():
			# data/ 与 pov/ 是客户端属性分文件（分层/遮罩/第一人称），跳过
			if not (name == "data" or name == "pov"):
				_scan(root, rel_path, out)
		elif name.get_extension() == "json":
			var raw := _load_file("%s/%s" % [root, rel_path])
			if not raw.is_empty():
				out[rel_path.get_basename()] = raw
		name = dir.get_next()


## 单文件：{name(相对名), loop, length, tracks}。
## loop 缺省 true（living 循环为主，一次性动作由播放器按 mask 控）。
static func _load_file(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not parsed.has("animation"):
		return {}
	var anim: Array = parsed["animation"]
	var format := String(parsed.get("format", "matrix"))
	var tracks := {}
	var length := 0.0
	for track in anim:
		var joint_name := String(track.get("name", ""))
		if not JOINTS.has(joint_name) and joint_name != "Coord":
			continue
		var times: Array = track.get("time", [])
		var transforms: Array = track.get("transform", [])
		if times.size() == 0 or times.size() != transforms.size():
			continue
		var quats := []
		var poss := []
		for i in times.size():
			var t := float(times[i])
			length = maxf(length, t)
			if format == "attributes":
				var o: Dictionary = transforms[i]
				var loc := _vec3(o.get("loc", [0, 0, 0]))
				var rot: Array = o.get("rot", [1, 0, 0, 0])
				# ⚠ rot=(w,x,y,z) 序且 xyz 取负＝共轭（EF 源码级语义：
				# JsonAssetLoader.getTransformSheet ATTRIBUTES 分支
				# fromPrimitives(-rot[1..3], rot[0])）。存的是姿态骨增量，
				# 有效局部 = L_bind·T(loc)·R(conj)（getAnimationBoundMatrix
				# 合成序 PARENT·JOINT_LOCAL·ANIMATION）。曾①按 (x,y,z,w)
				# 序解析成绕 X 180°（全帧错位）；②改对序后原样取（=漏共轭，
				# 方向反）且当绝对局部旋转（=丢 bind 旋转：肩/大腿 180°、
				# Tool ~180° 绑定全塌）——深链关节锯齿折叠、头侧倾脱节
				#（用户实机"错位、扭曲"截图，EF 1.21.1 源码核对定谳）。
				quats.append(Quaternion(
						-float(rot[1]), -float(rot[2]),
						-float(rot[3]), float(rot[0])))
				# loc=纯姿态增量（retarget 叠 bind 局部之上）；曾当绝对
				# 平移 → 骨长丢失 → 关节飞散 6-50m（拧麻花，已修）
				poss.append(loc)
			else:
				var m := _mat_from_flat(transforms[i])
				quats.append(_quat_from_matrix(m))
				poss.append(Vector3(m[0][3], m[1][3], m[2][3]))
		# Coord 轨 = 独立根位移通道（ActionAnimation 专用）；
		# 本引擎暂不消费 EF 战斗根位移（动作库自研阶段），挂名备查
		if joint_name == "Coord":
			continue
		tracks[joint_name] = {
			"times": times,
			"quats": quats,
			"poss": poss,
		}
	if tracks.is_empty():
		return {}
	return {
		"name": path.get_file().get_basename(),
		"loop": true,
		"length": length,
		"tracks": tracks,
		"attr_space": format == "attributes",  # 姿态增量格式（局部=L_bind·增量）
	}


static func _vec3(arr) -> Vector3:
	if not (arr is Array) or (arr as Array).size() < 3:
		return Vector3.ZERO
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _mat_from_flat(flat: Array) -> Array:
	return [[float(flat[0]), float(flat[1]), float(flat[2]), float(flat[3])],
		[float(flat[4]), float(flat[5]), float(flat[6]), float(flat[7])],
		[float(flat[8]), float(flat[9]), float(flat[10]), float(flat[11])],
		[0.0, 0.0, 0.0, 1.0]]


static func _quat_from_matrix(m: Array) -> Quaternion:
	var b := Basis(
			Vector3(m[0][0], m[1][0], m[2][0]),
			Vector3(m[0][1], m[1][1], m[2][1]),
			Vector3(m[0][2], m[1][2], m[2][2]))
	return b.get_rotation_quaternion().normalized()


## 绑定世界（MC 空间）：链式合成 BIND_QUAT/BIND_POS。
static func bind_worlds() -> Array:
	var out := []
	out.resize(JOINTS.size())
	for i in JOINTS.size():
		var q: Quaternion = BIND_QUAT[i]
		var p: Vector3 = BIND_POS[i]
		var parent: int = PARENTS[i]
		if parent >= 0:
			var pq: Quaternion = out[parent]["q"]
			q = pq * q
			p = out[parent]["p"] + out[parent]["basis"] * p
		out[i] = {"q": q, "basis": Basis(q), "p": p}
	return out


## MC 空间绑定世界（Root 含 C 修正，与世界链同构）——retarget 分母用；
## bind_worlds 原版（Root 无 C）保留锚点语义（Head y=1.514 接口数据）。
static func bind_worlds_root_c() -> Array:
	var out := []
	for i in JOINTS.size():
		var q: Quaternion = BIND_QUAT[i]
		var p: Vector3 = BIND_POS[i]
		if PARENTS[i] < 0:
			q = C_QUAT * q  # Root 修正随链传播到全部子骨
		else:
			var pq: Quaternion = out[PARENTS[i]]["q"]
			q = pq * q
			p = out[PARENTS[i]]["p"] + out[PARENTS[i]]["basis"] * p
		out.append({"q": q, "basis": Basis(q), "p": p})
	return out


## 重定向 raw_clip → 本引擎 Clip（canonical 局部姿态逐键烘焙）。
## rig = character_rig 产出的骨架数据 {joints, parents, pivots(世界绑定)}。
## 无轨关节沿用绑定局部（随父运动，不塌缩）；Root 位移按腿长比缩放。
static func retarget(raw_clip: Dictionary, rig: Dictionary) -> Dictionary:
	var joints: Array = rig["joints"]
	var pivots: Array = rig["pivots"]
	var is_attr := bool(raw_clip.get("attr_space", false))
	var leg_ratio: float = pivots[0].y / EF_LEG_LENGTH
	# 分母与分子 W 同空间：attributes 世界链=MC 空间标准 bind 链
	#（Root 恒等——恒等输入 Δ≡0 的充要）；matrix 分子 Root 含 C
	# 故分母同构（root_c）。曾给 attributes 配 rest 恒等旋转链分母
	#（bind_worlds_blender）——那是把 attributes 误读成"绝对局部旋转"
	# 时代的配套错误，语义修正后一并废弃。
	var bworld := bind_worlds() if is_attr else bind_worlds_root_c()
	# 键时刻 = 全轨时间戳并集（各关节同步采样）
	var keys := _union_times(raw_clip["tracks"])
	var out_times := PackedFloat32Array()
	var out_quats := {}   # joint -> Array[Quaternion]
	var out_poss := {}    # joint -> Array[Vector3]（Packed 值语义，收尾统一打包）
	for t in keys:
		# 1) MC 空间动画世界 W_j：attributes 局部 = L_bind·T(loc)·R(conj)
		#（EF 源 getAnimationBoundMatrix：动画增量叠 bind 局部之上）；
		# matrix 局部 = 原样矩阵、Root 再左乘 C。
		var w := {}
		for i in joints.size():
			var track: Dictionary = raw_clip["tracks"].get(joints[i], {})
			var q_anim := Quaternion()
			var p_anim := Vector3.ZERO
			if not track.is_empty():
				var sampled := _sample_raw(track, t)
				q_anim = sampled[0]
				p_anim = sampled[1]
			var q_local: Quaternion = (BIND_QUAT[i] * q_anim) if is_attr else q_anim
			var p_local: Vector3 = (BIND_POS[i] + Basis(BIND_QUAT[i]) * p_anim) if is_attr else p_anim
			var parent: int = PARENTS[i]
			if parent < 0:
				if not is_attr:
					# Rx(-90°) Blender→MC 根修正（matrix 分支专用；attributes
					# 的 B2MC 已烘进 armature bind 常量，动画轨不重复乘）
					q_local = C_QUAT * q_local
				w[i] = {"q": q_local, "p": p_local}
			else:
				var pq: Quaternion = w[parent]["q"]
				w[i] = {"q": pq * q_local,
						"p": w[parent]["p"] + Basis(pq) * p_local}
		# 2) 逐关节 Δ→目标局部；Root 位移（本引擎空间、腿长比）。
		# ⚠ EF 数据空间=面向 -Z，与本引擎同面（armature 官方 bind 实证：
		# Tool_R 右腕 x=+0.375——面 -Z 时右=+X；数据自证：combo 突刺
		# -Z=前、knockback +Z=后）——**不做 R180 共轭、不翻 x/z**。
		# 曾沿用 CMU 的 R180：恒等输入两解同值测不出，对称动作（idle/
		# 摆腿）镜像不可见，不对称大位移动作暴露——突刺朝后 0.9m（用户
		# 实机"攻击四肢错位"+截图判读模型朝相机漂移）+挥刀左右镜像
		#（判读"双手互换"）。CMU/BVH 面 +Z（ToeBase 实测）保留 R180。
		var d_cache := {}
		var root_off := Vector3.ZERO
		for i in joints.size():
			d_cache[i] = w[i]["q"] * bworld[i]["q"].inverse()
		var delta_p_mc: Vector3 = w[0]["p"] - bworld[0]["p"]
		# EF 原版语义：Root 水平位移由实体移动消费（MoveCoord 驱动物理
		# 刚体），姿态只保留竖直分量——原样写入会让网格脱离胶囊/相机
		#（攻击前冲 0.9m 朝镜头撞、接段归零弹回，实机判读 2m 漂移）。
		# 后续接 root motion 时从这里取水平分量驱动 controller。
		root_off = Vector3(0.0, delta_p_mc.y, 0.0) * leg_ratio
		for i in joints.size():
			var jname: String = joints[i]
			var parent: int = PARENTS[i]
			var q_out: Quaternion
			var p_out: Vector3  # delta（见 clip_lib 语义）：绝对 = pivot 差 + delta
			if parent < 0:
				q_out = (d_cache[0] as Quaternion).normalized()
				p_out = root_off
			else:
				# 纯旋转局部：q = D_p⁻¹·D_j、p_out = 0——骨架位置 = 绑定
				# 骨长链，由动画器 FK 携带父旋转（子骨偏移随父姿态转动，
				# 与 EF 原生蒙皮同构）。曾用 T(绑定 pivot)·R(D) 的"几何式
				# 局部化"取 p_out = rel.origin − Δpivot：该式把父旋转抵消
				# 进局部平移，FK 还原后关节恒钉在绑定链位置、仅各自原地
				# 旋转——多关节大幅旋转动作（knockback 平躺、挥砍收臂）
				# 渲染成部件原地拧＝用户实机"错位、扭曲"的残余真身。
				# 更早期"root_off 旋进每节骨长"的爆炸式同样已废。
				# normalized：BIND 常量非严格单位，乘积模亏缺会被
				# angle_to 放大成假转角（恒等输入曾测得 0.04°）。
				q_out = ((d_cache[parent] as Quaternion).inverse()
						* (d_cache[i] as Quaternion)).normalized()
				p_out = Vector3.ZERO
			if not out_quats.has(jname):
				out_quats[jname] = []
				out_poss[jname] = []
			(out_quats[jname] as Array).append(q_out)
			(out_poss[jname] as Array).append(p_out)
		out_times.append(float(t))
	var tracks := {}
	for jname in out_quats:
		tracks[jname] = {
			"times": out_times,
			"quats": out_quats[jname],
			"poss": PackedVector3Array(out_poss[jname]),
		}
	return {
		"name": String(raw_clip.get("name", "ef_clip")),
		"length": maxf(float(raw_clip.get("length", 0.0)), 0.001),
		"loop": bool(raw_clip.get("loop", true)),
		"tracks": tracks,
	}


static func _union_times(tracks: Dictionary) -> Array:
	var set := {}
	for jname in tracks:
		for t in tracks[jname]["times"]:
			set[float(t)] = true
	var arr := set.keys()
	arr.sort()
	return arr


## 原始轨采样（键间线性：四元数 nlerp 近似 EF 的 nlerp 插值、平移 lerp）。
static func _sample_raw(track: Dictionary, t: float) -> Array:
	var times: Array = track["times"]
	var quats: Array = track["quats"]
	var poss: Array = track["poss"]
	if t <= float(times[0]):
		return [quats[0], poss[0]]
	if t >= float(times[times.size() - 1]):
		return [quats[times.size() - 1], poss[times.size() - 1]]
	for i in range(1, times.size()):
		if t <= float(times[i]):
			var t0 := float(times[i - 1])
			var t1 := float(times[i])
			var a := (t - t0) / maxf(t1 - t0, 1e-6)
			return [quats[i - 1].slerp(quats[i], a), poss[i - 1].lerp(poss[i], a)]
	return [quats[times.size() - 1], poss[times.size() - 1]]
