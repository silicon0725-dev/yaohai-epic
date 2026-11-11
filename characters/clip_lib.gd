## 动画片段（Clip）数据结构 + 采样 + 程序化内置动作。
##
## Clip = {
##   "name": String, "length": float(秒), "loop": bool,
##   "tracks": { 关节名: {"times": PackedFloat32Array,
##                        "quats": Array[Quaternion],   # 规范局部旋转（绝对）
##                        "poss":  PackedVector3Array}}, # 绑定平移的偏移 delta
##   "events": [{"time": float, "name": String}]  # 可选
## }
## ⚠ poss 语义 = delta（绝对局部平移 = pivot 差 + delta）——曾因程序化
## 动作把 0 当绝对值存，Head 关节丢失 0.52 格脖子平移"头下移进胸腔"
##（2026-11-06 用户实机抓到）；动作层按权重叠加 delta。
## 轨缺失的关节 = 绑定姿态（单位旋转 + pivot 差平移，由消费者补）。
## 采样 = 四元数 slerp + 平移 lerp，段外保持端值（无缓动，EF 同款 nlerp 语义）。
##
## 程序化内置动作：自研数值动画（许可洁净），规范骨架单位帧下
## 局部欧拉直接可读：+X 摆动 = 肢体向前（角色面向 -Z）。
@tool
extends RefCounted


static func sample_track(track: Dictionary, t: float) -> Array:
	var times: PackedFloat32Array = track["times"]
	var quats: Array = track["quats"]
	var poss: PackedVector3Array = track["poss"]
	var n := times.size()
	if n == 0:
		return [Quaternion(), Vector3.ZERO]
	if t <= times[0]:
		return [quats[0], poss[0]]
	if t >= times[n - 1]:
		return [quats[n - 1], poss[n - 1]]
	for i in range(1, n):
		if t <= times[i]:
			var span := maxf(times[i] - times[i - 1], 1e-6)
			var a := (t - times[i - 1]) / span
			return [quats[i - 1].slerp(quats[i], a),
					poss[i - 1].lerp(poss[i], a)]
	return [quats[n - 1], poss[n - 1]]


static func clip_end_time(clip: Dictionary) -> float:
	return float(clip.get("length", 0.0))


## ---- 程序化动作构建 ----

static func _q(x_deg: float, y_deg: float = 0.0, z_deg: float = 0.0) -> Quaternion:
	# 与 Godot 欧拉一致：先 Y 后 X 后 Z（单轴为主，多轴用于出拳/持物微调）
	var b := Basis(Vector3(0, 1, 0), deg_to_rad(y_deg)) \
			* Basis(Vector3(1, 0, 0), deg_to_rad(x_deg)) \
			* Basis(Vector3(0, 0, 1), deg_to_rad(z_deg))
	return b.get_rotation_quaternion()


static func _new_clip(name: String, length: float, loop: bool) -> Dictionary:
	return {"name": name, "length": length, "loop": loop, "tracks": {}}


static func _key(clip: Dictionary, joint: String, t: float,
		q: Quaternion, p: Vector3) -> void:
	if not clip["tracks"].has(joint):
		clip["tracks"][joint] = {"times": PackedFloat32Array(),
				"quats": [], "poss": PackedVector3Array()}
	var track: Dictionary = clip["tracks"][joint]
	track["times"].append(t)
	track["quats"].append(q)
	track["poss"].append(p)


## 站立呼吸：3s 循环（0 与 3 同姿态保证无缝）。
static func proc_idle() -> Dictionary:
	var c := _new_clip("idle", 3.0, true)
	_key(c, "Chest", 0.0, _q(0), Vector3.ZERO)
	_key(c, "Chest", 1.5, _q(2.0), Vector3.ZERO)
	_key(c, "Chest", 3.0, _q(0), Vector3.ZERO)
	for side in ["_L", "_R"]:
		_key(c, "Arm" + side, 0.0, _q(0), Vector3.ZERO)
		_key(c, "Arm" + side, 1.5, _q(1.5 if side == "_L" else 1.5), Vector3.ZERO)
		_key(c, "Arm" + side, 3.0, _q(0), Vector3.ZERO)
	_key(c, "Head", 0.0, _q(0, -3), Vector3.ZERO)
	_key(c, "Head", 1.5, _q(0, 3), Vector3.ZERO)
	_key(c, "Head", 3.0, _q(0, -3), Vector3.ZERO)
	return c


## 步行：1s 循环。腿 ±30°、膝摆动相最大 -55°、臂反向 ±22°、躯干扭 ±4°、
## 根上下 ±0.03（双脚过步相最低）。
static func proc_walk() -> Dictionary:
	var c := _new_clip("walk", 1.0, true)
	var hip := 30.0
	var arm := 22.0
	var knee := 55.0
	for ph in range(5):
		var t := float(ph) * 0.25
		var s := 1.0 if ph < 4 else 0.0  # ph4=ph0
		var phase := t * TAU
		var l_swing := sin(phase) * hip
		var r_swing := -l_swing
		var bob := -absf(cos(phase)) * 0.03
		_key(c, "Root", t, _q(0), Vector3(0, bob, 0))
		_key(c, "Thigh_L", t, _q(l_swing), Vector3.ZERO)
		_key(c, "Thigh_R", t, _q(r_swing), Vector3.ZERO)
		# 膝：摆动腿（大腿由后向前经过零位时）弯曲最大
		var l_knee := -maxf(0.0, cos(phase)) * knee if l_swing >= 0.0 else -0.1 * knee
		var r_knee := -maxf(0.0, -cos(phase)) * knee if r_swing >= 0.0 else -0.1 * knee
		_key(c, "Leg_L", t, _q(l_knee), Vector3.ZERO)
		_key(c, "Leg_R", t, _q(r_knee), Vector3.ZERO)
		_key(c, "Arm_L", t, _q(-l_swing * arm / hip), Vector3.ZERO)
		_key(c, "Arm_R", t, _q(-r_swing * arm / hip), Vector3.ZERO)
		_key(c, "Torso", t, _q(0, l_swing * 0.13), Vector3.ZERO)
	return c


## 奔跑：0.6667s 循环（步频对齐 EF run 的常用节奏）、躯干前倾 10°、
## 摆臂 ±45°、肘部常弯、根起伏 ±0.05。
static func proc_run() -> Dictionary:
	var c := _new_clip("run", 0.6667, true)
	var hip := 48.0
	var knee := 75.0
	for ph in range(5):
		var t := float(ph) * 0.25 * 0.6667
		var phase := float(ph if ph < 4 else 0) * 0.25 * TAU
		var l_swing := sin(phase) * hip
		var r_swing := -l_swing
		var bob := -absf(cos(phase)) * 0.05
		_key(c, "Root", t, _q(-10.0), Vector3(0, bob, 0))
		_key(c, "Thigh_L", t, _q(l_swing), Vector3.ZERO)
		_key(c, "Thigh_R", t, _q(r_swing), Vector3.ZERO)
		var l_knee := -maxf(0.0, cos(phase)) * knee - 15.0
		var r_knee := -maxf(0.0, -cos(phase)) * knee - 15.0
		_key(c, "Leg_L", t, _q(l_knee), Vector3.ZERO)
		_key(c, "Leg_R", t, _q(r_knee), Vector3.ZERO)
		_key(c, "Arm_L", t, _q(-l_swing * 0.95, 0, 6.0), Vector3.ZERO)
		_key(c, "Arm_R", t, _q(-r_swing * 0.95, 0, -6.0), Vector3.ZERO)
		_key(c, "Hand_L", t, _q(45.0), Vector3.ZERO)
		_key(c, "Hand_R", t, _q(45.0), Vector3.ZERO)
		_key(c, "Torso", t, _q(0, l_swing * 0.15), Vector3.ZERO)
	return c


## 跳跃（单次 0.45s）：蓄蹲(0)→蹬伸(0.18)→滞空(0.45)。
static func proc_jump() -> Dictionary:
	var c := _new_clip("jump", 0.45, false)
	_key(c, "Root", 0.0, _q(0), Vector3(0, -0.12, 0))
	_key(c, "Root", 0.18, _q(-6.0), Vector3(0, 0.02, 0))
	_key(c, "Root", 0.45, _q(-4.0), Vector3.ZERO)
	for side in ["_L", "_R"]:
		var sgn := 1.0 if side == "_L" else -1.0
		_key(c, "Thigh" + side, 0.0, _q(42.0), Vector3.ZERO)
		_key(c, "Thigh" + side, 0.18, _q(-8.0), Vector3.ZERO)
		_key(c, "Thigh" + side, 0.45, _q(-18.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.0, _q(-70.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.18, _q(-5.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.45, _q(-45.0), Vector3.ZERO)
		_key(c, "Arm" + side, 0.0, _q(-35.0, 0, 10.0 * sgn), Vector3.ZERO)
		_key(c, "Arm" + side, 0.18, _q(150.0, 0, 20.0 * sgn), Vector3.ZERO)
		_key(c, "Arm" + side, 0.45, _q(120.0, 0, 30.0 * sgn), Vector3.ZERO)
	_key(c, "Torso", 0.0, _q(-14.0), Vector3.ZERO)
	_key(c, "Torso", 0.18, _q(4.0), Vector3.ZERO)
	_key(c, "Torso", 0.45, _q(2.0), Vector3.ZERO)
	return c


## 下落/滞空待机：0.8s 循环，四肢微扑。
static func proc_fall() -> Dictionary:
	var c := _new_clip("fall", 0.8, true)
	for side in ["_L", "_R"]:
		var sgn := 1.0 if side == "_L" else -1.0
		_key(c, "Arm" + side, 0.0, _q(35.0, 0, 25.0 * sgn), Vector3.ZERO)
		_key(c, "Arm" + side, 0.4, _q(55.0, 0, 35.0 * sgn), Vector3.ZERO)
		_key(c, "Arm" + side, 0.8, _q(35.0, 0, 25.0 * sgn), Vector3.ZERO)
		_key(c, "Thigh" + side, 0.0, _q(-15.0), Vector3.ZERO)
		_key(c, "Thigh" + side, 0.4, _q(-25.0), Vector3.ZERO)
		_key(c, "Thigh" + side, 0.8, _q(-15.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.0, _q(-35.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.4, _q(-55.0), Vector3.ZERO)
		_key(c, "Leg" + side, 0.8, _q(-35.0), Vector3.ZERO)
	return c


## 游泳：1.2s 循环。整体俯卧（根 -85°）、双臂交替风车、腿上下打水。
static func proc_swim() -> Dictionary:
	var c := _new_clip("swim", 1.2, true)
	_key(c, "Root", 0.0, _q(-85.0), Vector3(0, -0.35, 0))
	_key(c, "Root", 1.2, _q(-85.0), Vector3(0, -0.35, 0))
	_key(c, "Head", 0.0, _q(70.0), Vector3.ZERO)
	_key(c, "Head", 1.2, _q(70.0), Vector3.ZERO)
	for ph in range(5):
		var t := float(ph) * 0.3
		var a := float(ph if ph < 4 else 0) * 0.25 * TAU
		# 左臂风车领先右臂 180°
		_key(c, "Arm_L", t, _q(rad_to_deg(a)), Vector3.ZERO)
		_key(c, "Arm_R", t, _q(rad_to_deg(a + PI)), Vector3.ZERO)
		_key(c, "Hand_L", t, _q(20.0), Vector3.ZERO)
		_key(c, "Hand_R", t, _q(20.0), Vector3.ZERO)
		var kick := sin(a * 2.0) * 22.0
		_key(c, "Thigh_L", t, _q(10.0 + kick * 0.4), Vector3.ZERO)
		_key(c, "Thigh_R", t, _q(10.0 - kick * 0.4), Vector3.ZERO)
		_key(c, "Leg_L", t, _q(-25.0 - kick * 0.3), Vector3.ZERO)
		_key(c, "Leg_R", t, _q(-25.0 + kick * 0.3), Vector3.ZERO)
	return c


## 挖掘（上身循环 0.5s）：右臂抡-停-落。
static func proc_dig() -> Dictionary:
	var c := _new_clip("dig", 0.5, true)
	_key(c, "Arm_R", 0.0, _q(-60.0, 0, -10.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.2, _q(-75.0, 0, -15.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.35, _q(35.0, 0, 0.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.5, _q(-60.0, 0, -10.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.0, _q(30.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.2, _q(45.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.35, _q(10.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.5, _q(30.0), Vector3.ZERO)
	_key(c, "Torso", 0.0, _q(0, -6.0), Vector3.ZERO)
	_key(c, "Torso", 0.2, _q(-6.0, -10.0), Vector3.ZERO)
	_key(c, "Torso", 0.35, _q(6.0, 8.0), Vector3.ZERO)
	_key(c, "Torso", 0.5, _q(0, -6.0), Vector3.ZERO)
	return c


## 空手三连击（单次 0.9s）：左刺-右直-右勾，躯干协同扭转。
static func proc_punch() -> Dictionary:
	var c := _new_clip("punch", 0.9, false)
	c["events"] = [
		{"time": 0.08, "name": "hit_1"},
		{"time": 0.35, "name": "hit_2"},
		{"time": 0.65, "name": "hit_3"},
	]
	# 左刺
	_key(c, "Arm_L", 0.0, _q(0), Vector3.ZERO)
	_key(c, "Arm_L", 0.08, _q(78.0, 12.0, 0.0), Vector3.ZERO)
	_key(c, "Arm_L", 0.25, _q(10.0), Vector3.ZERO)
	_key(c, "Hand_L", 0.0, _q(0), Vector3.ZERO)
	_key(c, "Hand_L", 0.08, _q(8.0), Vector3.ZERO)
	_key(c, "Hand_L", 0.25, _q(0), Vector3.ZERO)
	_key(c, "Torso", 0.0, _q(0), Vector3.ZERO)
	_key(c, "Torso", 0.08, _q(0, 14.0), Vector3.ZERO)
	_key(c, "Torso", 0.25, _q(0, -4.0), Vector3.ZERO)
	# 右直 + 右勾
	_key(c, "Arm_R", 0.25, _q(0), Vector3.ZERO)
	_key(c, "Arm_R", 0.35, _q(82.0, -10.0, 0.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.5, _q(15.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.65, _q(60.0, -35.0, 0.0), Vector3.ZERO)
	_key(c, "Arm_R", 0.9, _q(0), Vector3.ZERO)
	_key(c, "Hand_R", 0.25, _q(0), Vector3.ZERO)
	_key(c, "Hand_R", 0.35, _q(10.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.65, _q(35.0), Vector3.ZERO)
	_key(c, "Hand_R", 0.9, _q(0), Vector3.ZERO)
	_key(c, "Torso", 0.35, _q(0, -16.0), Vector3.ZERO)
	_key(c, "Torso", 0.5, _q(0, -6.0), Vector3.ZERO)
	_key(c, "Torso", 0.65, _q(0, -20.0), Vector3.ZERO)
	_key(c, "Torso", 0.9, _q(0), Vector3.ZERO)
	return c


## 内置动作全表（名称 → Clip）。
static func builtin_clips() -> Dictionary:
	return {
		"idle": proc_idle(),
		"walk": proc_walk(),
		"run": proc_run(),
		"jump": proc_jump(),
		"fall": proc_fall(),
		"swim": proc_swim(),
		"dig": proc_dig(),
		"punch": proc_punch(),
	}
