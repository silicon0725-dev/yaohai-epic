## 动作编辑器测试：时间轴数据层（队列/seek/循环/跨段）+ dock 集成
##（avatar 装载全动画清单、播放驱动采样姿态变化）。
extends VoxelTestCase

const ModelScript := preload("res://addons/anim_editor/anim_editor_model.gd")
const DockScript := preload("res://addons/anim_editor/anim_editor_dock.gd")
const PlayerAvatar := preload("res://characters/player_avatar.gd")


func run() -> void:
	_test_timeline_model()
	_test_timeline_trim_events()
	# ⚠ 含 await 的子测试必须 await——曾裸调用：协程在 wait 循环首个
	# await 挂起即被弃，其后全部断言（装载/seek 姿态/武器全套）从未
	# 执行过（31 项假象=前 30+avatar 1 项），改动全靠全量套件外验证。
	await _test_dock_integration()


func _test_timeline_model() -> void:
	var m = ModelScript.new()
	check_eq(m.total_length(), 0.0, "空队列总长 0")
	check_eq(m.locate(0.0), {}, "空队列 locate 空")
	m.append("a", 1.0)
	m.append("b", 0.5)
	check(absf(m.total_length() - 1.5) < 1e-4, "两段总长 1.5s")
	var l0: Dictionary = m.locate(0.2)
	check_eq(l0["index"], 0, "0.2s 在段 0")
	check(absf(float(l0["local_t"]) - 0.2) < 1e-4, "段内 0.2s")
	var l1: Dictionary = m.locate(1.2)
	check_eq(l1["index"], 1, "1.2s 在段 1")
	check(absf(float(l1["local_t"]) - 0.2) < 1e-4, "段 1 内 0.2s")
	var l2: Dictionary = m.locate(9.0)
	check_eq(l2["index"], 1, "越界钳到末段")
	check(absf(float(l2["local_t"]) - 0.5) < 1e-4, "末段钳尾 0.5s")
	# 推进跨段
	var sw: Dictionary = m.advance(1.2)
	check_eq(sw.get("switch_to"), 1, "1.2s 跨到段 1")
	# 循环回卷
	m.looping = true
	m.playhead = 1.4
	var loop_sw: Dictionary = m.advance(0.2)
	check_eq(loop_sw.get("switch_to"), 0, "循环回卷到段 0")
	check(absf(m.playhead - 0.1) < 1e-4, "回卷后 0.1s")
	# seek + 删除
	var si: int = m.seek(0.8)
	check_eq(si, 0, "seek 0.8 落段 0")
	m.remove_at(0)
	check(absf(m.total_length() - 0.5) < 1e-4, "删段 0 剩 0.5s")


## 段级修剪/倍速/事件扫掠（CwcMontage 借鉴概念）。
func _test_timeline_trim_events() -> void:
	var m = ModelScript.new()
	m.append("long", 10.0)          # 源 10s
	var item: Dictionary = m.queue[0]
	item["t0"] = 2.0                 # 修剪 2-6s
	item["t1"] = 6.0
	item["speed"] = 2.0              # 2× → 表观 2s
	check(absf(m.item_length(item) - 2.0) < 1e-4,
			"修剪 4s@2× 表观 2s（实际 %.2f）" % m.item_length(item))
	check(absf(m.total_length() - 2.0) < 1e-4, "总长 2s")
	# 表观时间 → 源时间映射
	check(absf(m.source_time(item, 0.0) - 2.0) < 1e-4, "表观 0 → 源 2s")
	check(absf(m.source_time(item, 1.0) - 4.0) < 1e-4, "表观 1s → 源 4s")
	check(absf(m.source_time(item, 2.0) - 6.0) < 1e-4,
			"表观末 → 源出点 6s（钳制）")
	# 事件扫掠：源 3-5s（表观 0.5-1.5s）——半开区间成对触发
	item["events"] = [{"t0": 3.0, "t1": 5.0, "name": "hit"}]
	var s1: Array = m.sweep_events(item, 0.0, 0.4)
	check(s1.is_empty(), "0→0.4s 未入事件区")
	var s2: Array = m.sweep_events(item, 0.4, 0.6)
	check_eq(s2.size(), 1, "0.6s 跨入 OnEnter")
	check_eq(String(s2[0]["phase"]), "enter", "phase=enter")
	var s3: Array = m.sweep_events(item, 0.6, 1.4)
	check(s3.is_empty(), "区内推进无触发")
	var s4: Array = m.sweep_events(item, 1.4, 1.6)
	check_eq(s4.size(), 1, "1.6s 跨出 OnExit")
	check_eq(String(s4[0]["phase"]), "exit", "phase=exit")
	# 大步跳（低帧率）：一步跨进又跨出=成对（不漏 exit）
	var s5: Array = m.sweep_events(item, 0.2, 1.8)
	check_eq(s5.size(), 2, "大步跨全区间 enter+exit 成对")
	# 导出/导入往返
	var data: Dictionary = m.export_montage("combo")
	m.clear()
	check(m.import_montage(data), "导入成功")
	check_eq(m.queue.size(), 1, "往返段数 1")
	var rt: Dictionary = m.queue[0]
	check(absf(float(rt["t0"]) - 2.0) < 1e-4 and absf(float(rt["t1"]) - 6.0) < 1e-4
			and absf(float(rt["speed"]) - 2.0) < 1e-4,
			"往返保留修剪/倍速")
	check_eq((rt["events"] as Array).size(), 1, "往返保留事件")


func _test_dock_integration() -> void:
	if tree_root == null:
		check(false, "需要 tree_root")
		return
	var t0 := Time.get_ticks_msec()
	var dock = DockScript.new()
	tree_root.add_child(dock)
	check(dock.avatar != null and dock.avatar.animator != null,
			"dock avatar 同步装载（内置动作即时可用）")
	# EF/CMU 分帧重定向就位等待（曾同步 97 个卡主线程十几秒）。
	# ⚠ 只等数量会竞速：CMU 装载排在 EF 全部重定向之后（clips≥100
	# 提前退出时 cmu/ 还没进清单——"清单含 CMU"断言曾因此假失败）
	var has_cmu_key := func() -> bool:
		for k in dock.avatar.clips:
			if String(k).begins_with("cmu/"):
				return true
		return false
	var waited := 0
	while (dock.avatar.clips.size() < 100 or not has_cmu_key.call()) \
			and waited < 12000:
		await tree_root.get_tree().process_frame
		waited += 1
	var load_ms := Time.get_ticks_msec() - t0
	check(dock.avatar.clips.size() >= 100,
			"异步重定向就位 ≥100 个（实际 %d，%d ms）" % [
					dock.avatar.clips.size(), load_ms])
	check(load_ms < 20000, "装载 <20s（实际 %d ms）" % load_ms)
	var clip_count: int = dock.avatar.clips.size()
	check(clip_count >= 8, "动作清单 ≥8（实际 %d：内置+CMU+EF 全量）" % clip_count)
	# 清单含全源
	var has_ef := false
	var has_cmu := false
	for k in dock.avatar.clips:
		if String(k).begins_with("ef/"):
			has_ef = true
		if String(k).begins_with("cmu/"):
			has_cmu = true
	check(has_cmu, "清单含 CMU mocap")
	# EF：用户目录 user://anim_ef 存在才有（97 个 DMC 提取件）
	var ef_dir := DirAccess.open(ProjectSettings.globalize_path("user://anim_ef"))
	if ef_dir != null and not ef_dir.get_current_dir().is_empty():
		check(has_ef, "清单含 EF yamato（anim_ef 已提取）")
	# 队列播放驱动：姿态随播放头推进变化
	dock.model.clear()
	dock.model.append("idle", 3.0)
	dock.model.append("walk", 1.0)
	dock._on_seek(0.0)
	var thigh_a: Quaternion = dock.avatar.animator.update(0.0)["Thigh_L"]["q"]
	dock._on_seek(3.25)  # walk 段 0.25s=sin(π/2) 大摆相位（0.5s 是过中零位）
	for i in 12:         # 推进 0.2s 让快照过渡（0.15s）完成
		dock._process(1.0 / 60.0)
	var thigh_b: Quaternion = dock.avatar.animator.update(0.0)["Thigh_L"]["q"]
	check(thigh_a.angle_to(thigh_b) > 0.05,
			"seek 跨段姿态变化（Δ=%.1f°）" % rad_to_deg(thigh_a.angle_to(thigh_b)))
	check_eq(dock.avatar.animator.base_name(), "walk", "seek 后 base=walk")
	# 播放推进
	dock.playing = true
	var head0: float = dock.model.playhead
	dock._process(1.0 / 60.0)
	check(dock.model.playhead > head0, "播放推进播放头")
	# 武器开关（可见性由 _apply_pose 每帧刷新——先推进一帧再断言；
	# 下拉三态：0 无 / 1 收刀 / 2 拔刀）。战斗系统下线（COMBAT_ENABLED
	# =false，用户"先把动作系统藏起来"）时刀鞘不构建、入口全 guard——
	# 断言跳过（翻回 true 自动恢复验证）。
	if not PlayerAvatar.COMBAT_ENABLED:
		check(dock.avatar._weapon == null and dock.avatar._sheath == null,
				"战斗下线：刀/鞘模型不构建")
		check(not dock.avatar.is_armed(), "战斗下线：armed 恒 false")
		tree_root.remove_child(dock)
		dock.queue_free()
		return
	dock._on_weapon_selected(2)
	check(dock.avatar.is_armed(), "选太刀（拔刀）=armed")
	dock._process(1.0 / 60.0)
	check(dock.avatar._weapon != null and dock.avatar._weapon.visible,
			"太刀可见")
	# 挂接断言按武器来源分流：DMC 官方模型（user://anim_ef/weapon 自放）
	# = Tool_R 局部原样（EF 渲染同构，持刀几何数据自带）；回退自建 =
	# 刀尖垂直前臂（用户实机反馈）。animator pose 复算世界链，不依赖
	# Skeleton3D 延迟更新。
	var rig_d: Dictionary = dock.avatar.rig
	var joints_d: Array = rig_d["joints"]
	var pose_d: Dictionary = dock.avatar.animator.update(0.0)
	var globals_d := []
	globals_d.resize(joints_d.size())
	for i in joints_d.size():
		var e: Dictionary = pose_d[joints_d[i]]
		var local := Transform3D(Basis(e["q"]), e["p"])
		globals_d[i] = local if int(rig_d["parents"][i]) < 0 \
				else (globals_d[rig_d["parents"][i]] as Transform3D) * local
	if dock.avatar._weapon_dmc:
		var tool_g: Transform3D = globals_d[joints_d.find("Tool_R")]
		# 旋转=Tool_R 局部原样（官方持刀几何）；origin=拳心偏移
		#（_grip_off 实测 Tool_R 权重顶点均值，握点校准）
		check(dock.avatar._weapon.transform.basis.get_rotation_quaternion(
				).angle_to(tool_g.basis.get_rotation_quaternion()) < 1e-3,
				"DMC 刀旋转=Tool_R 局部原样（官方持刀几何）")
		check(dock.avatar._weapon.transform.origin.distance_to(tool_g.origin)
				< 0.3, "DMC 刀挂点=拳心（距腕 <0.3）")
		check(dock.avatar._sheath.visible,
				"拔刀后空鞘恒挂腰（DMC on_torso 建模挂姿不配小躯干已撤）")
	else:
		var forearm: Vector3 = ((globals_d[joints_d.find("Tool_R")] as Transform3D).origin
				- (globals_d[joints_d.find("Hand_R")] as Transform3D).origin).normalized()
		var tip: Vector3 = dock.avatar._weapon.global_transform.basis.y
		check(absf(tip.dot(forearm)) < 0.35,
				"刀尖垂直前臂（|dot|=%.2f）" % absf(tip.dot(forearm)))
		check(dock.avatar._sheath != null and dock.avatar._sheath.visible,
				"刀鞘挂腰可见")
	dock._on_weapon_selected(0)
	check(not dock.avatar.is_armed(), "选无=收刀")
	dock._process(1.0 / 60.0)
	if dock.avatar._weapon_dmc:
		check(not dock.avatar._weapon.visible, "DMC 收刀：刀隐藏（空鞘挂腰）")
		check(dock.avatar._sheath.visible, "DMC 收刀：鞘可见")
	else:
		var wpos: Vector3 = dock.avatar._weapon.global_transform.origin
		var spos: Vector3 = dock.avatar._sheath.global_transform.origin
		check(wpos.distance_to(spos) < 0.4,
				"收刀后刀插鞘（刀-鞘距 %.2fm；握点悬鞘口上 ~0.25）" % [
						wpos.distance_to(spos)])
	tree_root.remove_child(dock)
	dock.queue_free()
