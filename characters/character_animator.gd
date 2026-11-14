## 分层动画器（纯逻辑 RefCounted，不挂节点——姿态写骨架由 avatar 做）。
##
## 层级：基础层（走/跑/待机/游泳等全身循环，含倒放与快慢速）+
## 动作层（挖/拳/跳等一次性动作，上身遮罩或全身，淡入淡出）+
## 快照过渡（切基础动画时从当前姿态 0.15s 混入，EF LinkAnimation 思路）+
## 头部注视（在最终局部姿态上后乘 yaw/pitch）。
@tool
extends RefCounted

const ClipLib := preload("res://characters/clip_lib.gd")

const TRANSITION_TIME := 0.15
const ACTION_FADE := 0.1

## 上身遮罩（动作层默认只驱动上半身，腿部保持基础层步态）。
const UPPER_JOINTS := {
	"Torso": true, "Chest": true, "Head": true,
	"Shoulder_L": true, "Arm_L": true, "Hand_L": true,
	"Tool_L": true, "Elbow_L": true,
	"Shoulder_R": true, "Arm_R": true, "Hand_R": true,
	"Tool_R": true, "Elbow_R": true,
}

var rig: Dictionary
var clips := {}

var _base_name := ""
var _base_time := 0.0
var _base_speed := 1.0
var _base_reversed := false

var _trans_active := false
var _trans_t := 0.0
var _trans_dur := TRANSITION_TIME
var _snap := {}

var _action := {}   # name/time/speed/mask/weight/target/events_fired/on_finished
var _last_pose := {}
var _head_yaw := 0.0
var _head_pitch := 0.0


func setup(rig_data: Dictionary, clip_map: Dictionary) -> void:
	rig = rig_data
	clips = clip_map
	_base_name = ""
	_last_pose = {}


## 切基础动画（同名只更新参数；异名触发快照过渡）。
func set_base(name: String, speed: float = 1.0, reversed: bool = false,
		transition: float = TRANSITION_TIME) -> void:
	if not clips.has(name):
		push_warning("animator: 缺动画 %s" % name)
		return
	if name == _base_name:
		if reversed != _base_reversed \
				and bool(clips[name].get("loop", true)) and _base_name != "":
			# 反向开关：镜像采样相位保持当帧姿态连续
			#（反向映射 t'=length-t，曾直接翻转导致 0.25↔0.75 半周期跳变）
			var length: float = float(clips[name]["length"])
			_base_time = fmod(length - _base_time, maxf(length, 1e-4))
		_base_speed = speed
		_base_reversed = reversed
		return
	_begin_transition(transition)
	_base_name = name
	_base_time = 0.0 if not _base_reversed else float(clips[name]["length"])
	_base_speed = speed
	_base_reversed = reversed


func base_name() -> String:
	return _base_name


func base_speed() -> float:
	return _base_speed


## 播一次性动作（挖/拳/技能）。mask："upper"|"all"。
func play_action(name: String, speed: float = 1.0, mask: String = "upper",
		on_finished: Callable = Callable(), hard := false) -> void:
	if not clips.has(name):
		push_warning("animator: 缺动作 %s" % name)
		return
	_action = {
		"name": name,
		"time": 0.0,
		"speed": speed,
		"mask": mask,
		"weight": 1.0 if hard else 0.0,
		"target": 1.0,
		"prev_time": 0.0,
		"on_finished": on_finished,
	}


func action_active() -> bool:
	return not _action.is_empty()


func action_name() -> String:
	return String(_action.get("name", ""))


## 动作进度（0..1；无动作=1）——连击取消窗口判定用。
func action_progress() -> float:
	if _action.is_empty():
		return 1.0
	var clip: Dictionary = clips.get(_action["name"], {})
	return float(_action["time"]) / maxf(float(clip.get("length", 1.0)), 1e-4)


func stop_action() -> void:
	if not _action.is_empty():
		_action["target"] = 0.0


func set_head_look(yaw_rad: float, pitch_rad: float) -> void:
	_head_yaw = yaw_rad
	_head_pitch = pitch_rad


## 推进并求值：返回 {关节名: Transform3D(局部姿态)}。
func update(delta: float) -> Dictionary:
	delta = maxf(delta, 0.0)
	_advance_base(delta)
	_advance_action(delta)
	var pose := _eval_base_pose()
	if not _action.is_empty():
		pose = _apply_action(pose)
	_apply_head_look(pose)
	if _trans_active:
		_trans_t += delta
		var alpha: float = clampf(_trans_t / maxf(_trans_dur, 1e-4), 0.0, 1.0)
		alpha = alpha * alpha * (3.0 - 2.0 * alpha)  # smoothstep
		pose = _apply_transition(pose, alpha)
		if alpha >= 1.0:
			_trans_active = false
			_snap = {}
	_last_pose = pose
	return pose


func _advance_base(delta: float) -> void:
	if _base_name == "" or not clips.has(_base_name):
		return
	var clip: Dictionary = clips[_base_name]
	var length: float = clip["length"]
	var dir := -1.0 if _base_reversed else 1.0
	_base_time += delta * _base_speed * dir
	if bool(clip["loop"]):
		if _base_time >= length:
			_base_time = fmod(_base_time, maxf(length, 1e-4))
		elif _base_time < 0.0:
			_base_time = length - fmod(-_base_time, maxf(length, 1e-4))
	else:
		_base_time = clampf(_base_time, 0.0, length)


func _advance_action(delta: float) -> void:
	if _action.is_empty():
		return
	_action["prev_time"] = _action["time"]
	_action["time"] = float(_action["time"]) + delta * float(_action["speed"])
	# 播完自动淡出（须在权重更新前判定——大 delta 单帧曾用旧 target=1
	# 算权重，w 停在 1 动作滞留不清理，测试"播完进度≈1"抓到）
	var clip: Dictionary = clips[_action["name"]]
	var length: float = clip["length"]
	if not bool(clip["loop"]) and float(_action["time"]) >= length:
		if float(_action["target"]) > 0.0:
			_action["target"] = 0.0
			var cb: Callable = _action["on_finished"]
			if cb.is_valid():
				cb.call()
	# 权重淡入淡出
	var w: float = _action["weight"]
	var target: float = _action["target"]
	w = move_toward(w, target, delta / maxf(ACTION_FADE, 1e-4))
	_action["weight"] = w
	# 事件（时间穿越触发，一次）
	for ev in clip.get("events", []):
		var t: float = ev["time"]
		if float(_action["prev_time"]) < t and float(_action["time"]) >= t:
			_fire_event(String(ev["name"]))
	if w <= 0.0 and target <= 0.0:
		_action = {}


func _fire_event(_event_name: String) -> void:
	pass  # 预留：命中帧回调（战斗阶段接线）


func _eval_base_pose() -> Dictionary:
	var pose := {}
	var joints: Array = rig["joints"]
	var diffs: Array = rig["pivot_diffs"]
	var clip: Dictionary = clips.get(_base_name, {})
	var t := _base_time
	if _base_reversed and not clip.is_empty() and bool(clip["loop"]):
		t = fmod(float(clip["length"]) - _base_time, float(clip["length"]))
	for i in joints.size():
		var jname: String = joints[i]
		var q := Quaternion()
		var p: Vector3 = diffs[i]
		var track: Dictionary = clip.get("tracks", {}).get(jname, {})
		if not track.is_empty():
			var sampled := ClipLib.sample_track(track, t)
			q = sampled[0]
			# poss = 绑定平移的偏移（delta）：绝对平移 = pivot 差 + delta
			p = diffs[i] + sampled[1]
		pose[jname] = {"q": q, "p": p}
	return pose


func _apply_action(pose: Dictionary) -> Dictionary:
	var clip: Dictionary = clips[_action["name"]]
	var w: float = _action["weight"]
	var t: float = _action["time"]
	if bool(clip["loop"]):
		# loop 片段时间回绕（与基础层 fmod 同语义）——曾无回绕，
		# dig（loop=true）0.5s 后 time 越界采样恒为末关键帧=挖掘
		# 动作冻结，审查 4-F2
		t = fmod(t, maxf(float(clip["length"]), 1e-4))
	var mask_all: bool = String(_action["mask"]) == "all"
	var tracks: Dictionary = clip["tracks"]
	for jname in pose:
		var in_mask: bool = mask_all or UPPER_JOINTS.has(jname)
		var track: Dictionary = tracks.get(jname, {})
		if not in_mask or track.is_empty():
			continue
		var sampled := ClipLib.sample_track(track, t)
		var base: Dictionary = pose[jname]
		pose[jname] = {
			"q": (base["q"] as Quaternion).slerp(sampled[0], w),
			# 动作层平移=偏移量按权重叠加（delta 语义同基础层）
			"p": (base["p"] as Vector3) + sampled[1] * w,
		}
	return pose


func _apply_head_look(pose: Dictionary) -> void:
	if not pose.has("Head") or (_head_yaw == 0.0 and _head_pitch == 0.0):
		return
	var head: Dictionary = pose["Head"]
	var extra := Quaternion(Vector3(0, 1, 0), _head_yaw) \
			* Quaternion(Vector3(1, 0, 0), _head_pitch)
	pose["Head"] = {"q": (head["q"] as Quaternion) * extra, "p": head["p"]}


func _apply_transition(pose: Dictionary, alpha: float) -> Dictionary:
	for jname in pose:
		if not _snap.has(jname):
			continue
		var from: Dictionary = _snap[jname]
		var to: Dictionary = pose[jname]
		pose[jname] = {
			"q": (from["q"] as Quaternion).slerp(to["q"], alpha),
			"p": (from["p"] as Vector3).lerp(to["p"], alpha),
		}
	return pose


func _begin_transition(transition: float) -> void:
	if _last_pose.is_empty():
		var pose := {}
		var joints: Array = rig["joints"]
		var diffs: Array = rig["pivot_diffs"]
		for i in joints.size():
			pose[joints[i]] = {"q": Quaternion(), "p": diffs[i]}
		_snap = pose
	else:
		_snap = _last_pose.duplicate(true)
	_trans_active = true
	_trans_t = 0.0
	_trans_dur = maxf(transition, 0.0)
	if _trans_dur <= 0.0:
		_trans_active = false
		_snap = {}
