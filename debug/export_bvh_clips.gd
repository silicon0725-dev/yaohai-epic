## CMU BVH 动作分析 + 切片导出（离线工具，产出入库 JSON）。
## 用法：
##   分析（找动作窗口）：-s res://debug/export_bvh_clips.gd -- <bvh路径>
##   导出（切片→assets/anims/cmu/<名>.txt）：-- <bvh路径> <t0> <t1> <名>
extends SceneTree

const BvhLoader := preload("res://characters/bvh_loader.gd")
const YsmModel := preload("res://characters/ysm_model.gd")
const CharacterRig := preload("res://characters/character_rig.gd")


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_print_usage()
		quit(1)
		return
	var bvh_path: String = args[0]
	var parsed: Dictionary = BvhLoader.parse(
			FileAccess.get_file_as_string(bvh_path))
	if (parsed["bones"] as Array).is_empty():
		print("解析失败: %s" % bvh_path)
		quit(1)
		return
	if args.size() >= 4:
		_export(parsed, bvh_path, float(args[1]), float(args[2]), args[3])
	else:
		_analyze(parsed, bvh_path)
	quit()


func _print_usage() -> void:
	print("分析: -- <bvh>            （双臂/根速度窗口排行）")
	print("导出: -- <bvh> <t0> <t1> <名> （切片 30fps → assets/anims/cmu/）")


## 双腕+根世界速度滑窗排行（找打击/动作密集段）。
func _analyze(parsed: Dictionary, bvh_path: String) -> void:
	var bones: Array = parsed["bones"]
	var channels: Array = parsed["channels"]
	var hand_l := _bone_idx(bones, "LeftHand")
	var hand_r := _bone_idx(bones, "RightHand")
	var n: int = parsed["n_frames"]
	var frame_time: float = parsed["frame_time"]
	# 世界位置逐帧（间隔 5 帧采样省时）
	var step := 5
	var wrist_l := {}
	var wrist_r := {}
	var root_pos := {}
	for f in range(0, n, step):
		var w: Array = BvhLoader.world_chain(parsed, f, bones, channels)
		wrist_l[f] = (w[hand_l] as Transform3D).origin
		wrist_r[f] = (w[hand_r] as Transform3D).origin
		root_pos[f] = (w[0] as Transform3D).origin
	print("%s：%d 帧 %.1fs" % [bvh_path.get_file(), n, n * frame_time])
	print("窗口(1s) 按双腕速度和排行（出拳=峰值）:")
	var windows := []
	var keys := wrist_l.keys()
	keys.sort()
	for wi in range(1, keys.size() - 12):  # 1s 窗 = 12 个采样步（5帧×12=60帧）
		var speed := 0.0
		var root_speed := 0.0
		for k in range(wi, wi + 12):
			var dt: float = (keys[k] - keys[k - 1]) * frame_time
			speed += (wrist_l[keys[k]] as Vector3).distance_to(
					wrist_l[keys[k - 1]] as Vector3) / maxf(dt, 1e-3)
			speed += (wrist_r[keys[k]] as Vector3).distance_to(
					wrist_r[keys[k - 1]] as Vector3) / maxf(dt, 1e-3)
			root_speed += (root_pos[keys[k]] as Vector3).distance_to(
					root_pos[keys[k - 1]] as Vector3) / maxf(dt, 1e-3)
		windows.append({"t": keys[wi] * frame_time, "hand": speed / 12.0,
				"root": root_speed / 12.0})
	windows.sort_custom(func(a, b): return a["hand"] > b["hand"])
	for w in windows.slice(0, 10):
		print("  t=%6.2fs  腕速=%.2f u/s  根速=%.2f u/s" % [
				w["t"], w["hand"], w["root"]])


func _export(parsed: Dictionary, bvh_path: String, t0: float, t1: float,
		clip_name: String) -> void:
	var pack := YsmModel.load_pack("res://assets/characters/ysm_default")
	var rig: Dictionary = CharacterRig.build(pack)
	var clip: Dictionary = BvhLoader.retarget(parsed, rig, clip_name)
	if clip.is_empty():
		print("重定向失败")
		return
	var part: Dictionary = BvhLoader.slice(clip, t0, t1, 30.0, false, "")
	part["name"] = clip_name
	var out_path := "res://assets/anims/cmu/%s.txt" % clip_name
	DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path("res://assets/anims/cmu"))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(var_to_str(part))
	f.close()
	print("导出 %s：%.2f-%.2fs → %.2fs %d 键 %d 轨" % [
			out_path, t0, t1, part["length"],
			((part["tracks"] as Dictionary).values()[0] as Dictionary)["quats"].size(),
			(part["tracks"] as Dictionary).size()])


func _bone_idx(bones: Array, bname: String) -> int:
	for bi in bones.size():
		if bones[bi]["name"] == bname:
			return bi
	return -1
