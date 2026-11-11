## BVH 动作加载 + 重定向到规范 20 关节骨架（Clip 格式）。
##
## 数据源：CMU Motion Capture Database（cgspeed Daz-friendly BVH 版）。
## 许可：CMU 官方 "free for all uses"（请求署名 Carnegie Mellon University
## Graphics Lab）——**转换后的 Clip 数据可入库分发**（assets/anims/cmu/）。
## 用户也可自放 *.bvh 到 user://anim_bvh/ 运行时自动加载注册。
##
## 数学（与 ef_reference_rig.gd 同框架）：
## - BVH 世界链 W_j = W_parent · T(offset_j) · R_j（通道序 Z·Y·X，角度制）；
## - 绑定世界 B_j = 首帧世界（CMU BVH 首帧旋转全零 = 绑定姿态）；
## - 世界增量 Δ_j = W_j · B_j⁻¹；
## - 坐标系共轭 D = R180y · Δ · R180y⁻¹——CMU 演员左手 +X/面向 +Z
##   （ToeBase offset z>0 实测），本引擎左手 -X/面向 -Z，绕 Y 180° 恰好
##   同翻转（与 EF 的 MC 空间共轭同款）；
## - canonical 局部 = 纯旋转：q = D_parent⁻¹·D_j、p_out = 0（poss=delta
##   语义全管线唯一；骨架位置=绑定骨长链，由动画器 FK 携带父旋转——
##   与 EF 原生蒙皮同构。曾按 T(绑定 pivot)·R(D) 几何式取平移 delta，
##   父旋转被抵消进局部平移＝关节钉死绑定链、部件原地拧）；
## - Root 位移：BVH 根平移相对首帧 delta（英寸→米×腿长比，R180 共轭）。
##
## 骨架映射（CMU 31 骨 → canonical 20 关节；EF 命名解剖错位同款：
## canonical Hand=肘、Tool=腕）：
##   Hips→Root；Left/RightUpLeg→Thigh_L/R；Left/RightLeg→Leg_L/R
##   （脚/脚趾随小腿刚性，脚踝细节丢弃）；Spine→Torso、Spine1→Chest
##   （LowerBack 旋转并入 Spine 世界链）；Head→Head（Neck 链并入）；
##   Left/RightShoulder→Shoulder_L/R；Arm→Arm；ForeArm→Hand（肘）；
##   Hand→Tool（腕）；手指/拇指丢弃（模型无指骨）。
##   Knee_L/R、Elbow_L/R 为占位关节无对应轨，沿用绑定局部。
@tool
extends RefCounted

const EfRef := preload("res://characters/ef_reference_rig.gd")

## CMU 骨名 → canonical 关节名（无条目=丢弃；关节无轨=沿用绑定）。
const BONE_MAP := {
	"Hips": "Root",
	"LeftUpLeg": "Thigh_L", "LeftLeg": "Leg_L",
	"RightUpLeg": "Thigh_R", "RightLeg": "Leg_R",
	"Spine": "Torso", "Spine1": "Chest",
	"Head": "Head",
	"LeftShoulder": "Shoulder_L", "LeftArm": "Arm_L",
	"LeftForeArm": "Hand_L", "LeftHand": "Tool_L",
	"RightShoulder": "Shoulder_R", "RightArm": "Arm_R",
	"RightForeArm": "Hand_R", "RightHand": "Tool_R",
}

## CMU BVH 长度单位实测 0.1m 制（首帧髋高 17.5 → 1.75m 身高自洽，
## 腿 9 单位=0.9m；英寸制下 0.44m 髋高不合理）。
const UNIT_TO_M := 0.1


## 扫描目录加载 *.bvh → {文件名: Clip}（canonical，已重定向）。
static func load_dir(dir_path: String, rig: Dictionary) -> Dictionary:
	var out := {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.get_extension().to_lower() == "bvh":
			var clip := load_file("%s/%s" % [dir_path, name], rig)
			if not clip.is_empty():
				out[name.get_basename()] = clip
		name = dir.get_next()
	return out


static func load_file(path: String, rig: Dictionary) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("bvh: 读不到 %s" % path)
		return {}
	return retarget(parse(text), rig, path.get_file().get_basename())


## 解析 BVH 文本 → {bones:[{name,parent,offset}], channels:[骨序通道名数组],
## frames:PackedFloat32Array(行主序), n_frames, frame_time}。
## 仅支持 CMU 标准通道序（根 3 平移+Zrot/Yrot/Xrot，子骨 Z/Y/X 旋转序）。
static func parse(text: String) -> Dictionary:
	var bones: Array = []
	var channels: Array = []
	var stack: Array = []  # 骨骼索引栈
	var n_frames := 0
	var frame_time := 0.0
	var frames := PackedFloat32Array()
	var section := ""  # ""|hierarchy|motion
	var lines := text.split("\n")
	var li := 0
	while li < lines.size():
		var s := lines[li].strip_edges()
		if s.is_empty():
			li += 1
			continue
		if section == "":
			if s.begins_with("HIERARCHY"):
				section = "hierarchy"
			li += 1
			continue
		if section == "hierarchy":
			if s.begins_with("ROOT") or s.begins_with("JOINT"):
				var bname := s.split(" ")[1]
				bones.append({"name": bname,
						"parent": stack.back() if not stack.is_empty() else -1,
						"offset": Vector3.ZERO})
				stack.append(bones.size() - 1)
				channels.append([])
			elif s.begins_with("End Site"):
				# 末端点无通道：消费到匹配 '}'（不入骨架）
				var depth := 0
				while li < lines.size():
					var t := lines[li]
					if t.find("{") >= 0:
						depth += 1
					if t.find("}") >= 0:
						depth -= 1
						if depth <= 0:
							break
					li += 1
			elif s.begins_with("OFFSET"):
				var v := s.split(" ")
				if not stack.is_empty():
					(bones[stack.back()] as Dictionary)["offset"] = Vector3(
							float(v[1]), float(v[2]), float(v[3]))
			elif s.begins_with("CHANNELS"):
				var parts := s.split(" ")
				var n_chan := int(parts[1])
				var chans: Array = []
				for k in n_chan:
					chans.append(parts[2 + k])
				channels[stack.back()] = chans
				if chans != ["Zrotation", "Yrotation", "Xrotation"] \
						and chans != ["Xposition", "Yposition", "Zposition",
								"Zrotation", "Yrotation", "Xrotation"]:
					push_warning("bvh: 非标准通道序 %s（仅 ZYX 支持）" % str(chans))
			elif s == "}":
				if not stack.is_empty():
					stack.pop_back()
			elif s.begins_with("MOTION"):
				section = "motion"
			li += 1
			continue
		# motion 段
		if s.begins_with("Frames:"):
			n_frames = int(s.split(":")[1])
		elif s.begins_with("Frame Time:"):
			frame_time = float(s.split(":")[1])
		elif s[0].is_valid_float() or s[0] == "-" or s[0] == ".":
			for tok in s.split_floats(" ", false):
				frames.append(tok)
		li += 1
	return {
		"bones": bones, "channels": channels,
		"frames": frames, "n_frames": n_frames, "frame_time": frame_time,
	}


## 第 f 帧 BVH 世界链（Y-up，左手 +X，面向 +Z）。
## 通道序 Z·Y·X（角度制）；根平移通道=世界绝对位置（叠加根 offset）。
static func world_chain(parsed: Dictionary, f: int, bones: Array,
		channels: Array) -> Array:
	var frames: PackedFloat32Array = parsed["frames"]
	var stride: int = channels_total(channels)
	var base: int = f * stride
	var world: Array = []
	world.resize(bones.size())
	for bi in bones.size():
		var bone: Dictionary = bones[bi]
		var chans: Array = channels[bi]
		var rot := Vector3.ZERO
		var pos := Vector3.ZERO
		for k in chans.size():
			match chans[k]:
				"Zrotation": rot.z = frames[base + k]
				"Yrotation": rot.y = frames[base + k]
				"Xrotation": rot.x = frames[base + k]
				"Xposition": pos.x = frames[base + k]
				"Yposition": pos.y = frames[base + k]
				"Zposition": pos.z = frames[base + k]
		var basis := Basis(Vector3(0, 0, 1), deg_to_rad(rot.z)) \
				* Basis(Vector3(0, 1, 0), deg_to_rad(rot.y)) \
				* Basis(Vector3(1, 0, 0), deg_to_rad(rot.x))
		var local := Transform3D(basis, bone["offset"])
		if bone["parent"] < 0:
			local.origin = pos + (bone["offset"] as Vector3)
			world[bi] = local
		else:
			world[bi] = (world[bone["parent"]] as Transform3D) * local
	return world


## 重定向解析结果 → canonical Clip（与 clip_lib 语义一致）。
static func retarget(parsed: Dictionary, rig: Dictionary,
		clip_name: String) -> Dictionary:
	var bones: Array = parsed["bones"]
	var channels: Array = parsed["channels"]
	var frames: PackedFloat32Array = parsed["frames"]
	var n_frames: int = minf(parsed["n_frames"],
			frames.size() / maxi(channels_total(channels), 1))
	if n_frames < 2:
		push_warning("bvh %s: 帧数不足" % clip_name)
		return {}
	var stride: int = channels_total(channels)
	var frame_time: float = parsed["frame_time"]

	# CMU 骨名 → 骨索引；有映射的骨记录 canonical 关节名
	var cmu_to_canon := {}
	for bi in bones.size():
		var bname: String = bones[bi]["name"]
		if BONE_MAP.has(bname):
			cmu_to_canon[bi] = BONE_MAP[bname]

	# 绑定世界 = 第 0 帧世界链——CMU BVH 根世界位置来自通道平移而非
	# offset（根 offset=0），且首帧并非全零旋转（如 LeftUpLeg Zrot=-21°），
	# 首帧即绑定姿态（T(offset) 链假设曾致 leg_ratio 除零+首帧恒等破坏）。
	var bind_w: Array = world_chain(parsed, 0, bones, channels)

	# 缩放：演员髋高（首帧根 y 米化）→ 模型 Root pivot 高
	var leg_ratio: float = (rig["pivots"] as Array)[0].y \
			/ maxf((bind_w[0] as Transform3D).origin.y * UNIT_TO_M, 1e-4)

	# 逐帧采样键（保留全帧；导出工具负责切片/降采样）
	var out_quats := {}   # canonical 名 → Array[Quaternion]
	var out_poss := {}    # canonical 名 → Array[Vector3]（Packed 值语义：普通 Array 收尾打包）
	var out_times := PackedFloat32Array()
	var r180: Quaternion = EfRef.R180_QUAT
	var r180_inv: Quaternion = r180.inverse()
	for f in n_frames:
		# 1) BVH 世界链（Y-up，左手 +X，面向 +Z）
		var world: Array = world_chain(parsed, f, bones, channels)
		var d_canon := {}  # canonical 关节 → 共轭后世界增量四元数
		for bi in bones.size():
			# 2) 世界增量 + R180y 共轭
			if cmu_to_canon.has(bi):
				var delta: Transform3D = (world[bi] as Transform3D) \
						* (bind_w[bi] as Transform3D).affine_inverse()
				var dq: Quaternion = delta.basis.get_rotation_quaternion()
				d_canon[cmu_to_canon[bi]] = r180 * dq * r180_inv
		# 3) canonical 局部化（G=T(pivot)·R(D)；绑定=单位帧）
		var joints: Array = EfRef.JOINTS
		var parents: Array = EfRef.PARENTS
		var root_off := Vector3(
				-((world[0] as Transform3D).origin.x
						- (bind_w[0] as Transform3D).origin.x),
				((world[0] as Transform3D).origin.y
						- (bind_w[0] as Transform3D).origin.y),
				-((world[0] as Transform3D).origin.z
						- (bind_w[0] as Transform3D).origin.z)) \
				* UNIT_TO_M * leg_ratio
		for ji in joints.size():
			var jname: String = joints[ji]
			var q_out: Quaternion
			var p_out: Vector3
			if not d_canon.has(jname):
				continue  # 无轨关节沿用绑定（动画器补单位旋转+pivot 差）
			var dq_j: Quaternion = d_canon[jname]
			if parents[ji] < 0:
				q_out = dq_j
				p_out = root_off
			else:
				# 纯旋转局部（q=D_p⁻¹·D_j、p_out=0，绑定骨长链由 FK 携带
				# 父旋转）——曾用 T(绑定 pivot)·R(D) 几何式取平移 delta，
				# 把父旋转抵消进局部平移＝关节钉死绑定链、部件原地拧
				#（与 ef_reference_rig 同步修复，详见其注）。父在 CMU 无轨
				#（如 Knee 占位）→ 用父绑定姿态（Δ=单位）。
				var pq: Quaternion = d_canon.get(joints[parents[ji]],
						Quaternion())
				q_out = pq.inverse() * dq_j
				p_out = Vector3.ZERO
			if not out_quats.has(jname):
				out_quats[jname] = []
				out_poss[jname] = []
			(out_quats[jname] as Array).append(q_out)
			(out_poss[jname] as Array).append(p_out)
		out_times.append(float(f) * frame_time)
	var tracks := {}
	for jname in out_quats:
		tracks[jname] = {
			"times": out_times.duplicate(),
			"quats": out_quats[jname],
			"poss": PackedVector3Array(out_poss[jname]),
		}
	return {
		"name": clip_name,
		"length": out_times[out_times.size() - 1],
		"loop": false,
		"tracks": tracks,
	}


static func channels_total(channels: Array) -> int:
	var n := 0
	for c in channels:
		n += (c as Array).size()
	return n


## 切片 + 降采样导出新 Clip（t0/t1 秒，target_fps 抽帧；循环标记透传）。
static func slice(clip: Dictionary, t0: float, t1: float,
		target_fps: float = 30.0, loop := false, name_suffix: String = "") -> Dictionary:
	var src_times: PackedFloat32Array = \
			((clip["tracks"] as Dictionary).values()[0] as Dictionary)["times"]
	var step := 1.0 / maxf(target_fps, 1.0)
	var out := {"name": String(clip["name"]) + name_suffix,
			"length": maxf(t1 - t0, step), "loop": loop, "tracks": {}}
	for jname in clip["tracks"]:
		var track: Dictionary = clip["tracks"][jname]
		var times := PackedFloat32Array()
		var quats: Array = []
		var poss: Array = []
		var t := t0
		while t <= t1 + 1e-4:
			var k := _time_index(src_times, t)
			quats.append((track["quats"] as Array)[k])
			poss.append((track["poss"] as PackedVector3Array)[k])
			t += step
		# 首尾同姿（循环时）：末键=首键
		if loop and quats.size() > 1:
			var first_q: Quaternion = quats[0]
			var last_q: Quaternion = quats[quats.size() - 1]
			if last_q.angle_to(first_q) > 0.01:
				quats.append(first_q)
				poss.append(poss[0])
		for k in quats.size():
			# 时间轴重置为 0 起——曾保留原轴（1.5..3.5s）导致播放全程
			# t <= times[0] 恒返首键（姿态冻结 67°，实机抓到）
			times.append(float(k) * step)
		out["tracks"][jname] = {"times": times, "quats": quats,
				"poss": PackedVector3Array(poss)}
	out["length"] = (quats_size(out) - 1) * step
	return out


static func quats_size(clip: Dictionary) -> int:
	var tracks: Dictionary = clip["tracks"]
	if tracks.is_empty():
		return 0
	return ((tracks.values()[0] as Dictionary)["quats"] as Array).size()


static func _time_index(times: PackedFloat32Array, t: float) -> int:
	# 最近键（CMU 帧均匀，直接取整；容错首末）
	var idx := roundi(t / maxf((times[1] - times[0]) if times.size() > 1
			else 1.0, 1e-4))
	return clampi(idx, 0, times.size() - 1)
