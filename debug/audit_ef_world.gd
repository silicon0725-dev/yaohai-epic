## EF attributes 语义直查（SceneTree）：不经过 retarget/animator/rig，
## 按 EF 源码公式 world = PARENT·L_bind·T(loc)·R(conj) 直接构建 MC 空间
## 世界链，审计解剖（脊柱+Y/大腿−Y/手臂±X/跑步腿摆 sagittal ±Z）。
## 运行：godot --headless --path . -s res://debug/audit_ef_world.gd
extends SceneTree

const EfRef := preload("res://characters/ef_reference_rig.gd")

const KEYS := [
	"biped/yamato/living/yamato_idle",
	"biped/yamato/living/yamato_walk",
	"biped/yamato/living/yamato_run",
	"biped/yamato/attack/yamato_combo_a_1",
	"biped/stun/hit_knockback",
]


func _init() -> void:
	var abs_path := ProjectSettings.globalize_path("user://anim_ef")
	if DirAccess.open(abs_path) == null:
		print("!! no anim_ef")
		quit(1)
		return
	for key in KEYS:
		var raw: Dictionary = EfRef._load_file("%s/%s.json" % [abs_path, key])
		if raw.is_empty():
			print("%-42s MISSING" % key)
			continue
		var attr := bool(raw.get("attr_space", false))
		var length: float = raw["length"]
		print("=== %s  attr=%s len=%.2f" % [key, attr, length])
		var n := 5
		for k in n:
			var t: float = length * float(k) / float(n)
			var w := _world_at(raw, t)
			_report(key, w)
	quit(0)


## 源码公式世界链（与 ef_reference_rig.retarget 第 1 步同构，独立实现互查）。
func _world_at(raw: Dictionary, t: float) -> Array:
	var tracks: Dictionary = raw["tracks"]
	var out := []
	out.resize(EfRef.JOINTS.size())
	for i in EfRef.JOINTS.size():
		var q_anim := Quaternion()
		var p_anim := Vector3.ZERO
		if tracks.has(EfRef.JOINTS[i]):
			var tr: Dictionary = tracks[EfRef.JOINTS[i]]
			var k := _locate(tr["times"], t)
			q_anim = tr["quats"][k]
			p_anim = tr["poss"][k]
		var q_local: Quaternion = EfRef.BIND_QUAT[i] * q_anim
		var p_local: Vector3 = EfRef.BIND_POS[i] + Basis(EfRef.BIND_QUAT[i]) * p_anim
		var parent: int = EfRef.PARENTS[i]
		if parent < 0:
			out[i] = Transform3D(Basis(q_local), p_local)
		else:
			out[i] = (out[parent] as Transform3D) * Transform3D(Basis(q_local), p_local)
	return out


static func _locate(times: Array, t: float) -> int:
	for i in times.size():
		if float(times[i]) >= t:
			return i
	return times.size() - 1


func _report(_key: String, w: Array) -> void:
	var head: Vector3 = _p(w, "Head") - _p(w, "Chest")
	var chest: Vector3 = _p(w, "Chest") - _p(w, "Root")
	var thigh_r: Vector3 = _p(w, "Knee_R") - _p(w, "Thigh_R")
	var thigh_l: Vector3 = _p(w, "Knee_L") - _p(w, "Thigh_L")
	var arm_r: Vector3 = _p(w, "Hand_R") - _p(w, "Shoulder_R")
	var arm_l: Vector3 = _p(w, "Hand_L") - _p(w, "Shoulder_L")
	print("  spine Head-Chest   ", _v3(head.normalized()), "  (want +Y)")
	print("  chest Chest-Root   ", _v3(chest.normalized()), "  (want +Y)")
	print("  thighR Knee-Thigh  ", _v3(thigh_r.normalized()), "  (want -Y)")
	print("  thighL Knee-Thigh  ", _v3(thigh_l.normalized()), "  (want -Y)")
	print("  armR Hand-Shldr    ", _v3(arm_r.normalized()), "  (want ±X)")
	print("  armL Hand-Shldr    ", _v3(arm_l.normalized()), "  (want ∓X)")
	print("  Root pos           ", _v3(_p(w, "Root")))


static func _p(w: Array, jname: String) -> Vector3:
	return (w[EfRef.JOINTS.find(jname)] as Transform3D).origin


static func _v3(v: Vector3) -> String:
	return "(%+.2f %+.2f %+.2f)" % [v.x, v.y, v.z]
