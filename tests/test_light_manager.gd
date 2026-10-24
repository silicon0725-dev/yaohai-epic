## 光源管理器单元测试（headless 纯逻辑组）：注册制、三态转换、
## 确定性排序、滞回、预算释放。
## 渲染行为（灯真实照亮/投影）归桌面图形集成测试，这里不覆盖。
extends VoxelTestCase

const LightManagerScript := preload("res://systems/lighting/light_manager.gd")


func run() -> void:
	_test_registration_basics()
	_test_node_creation()
	_test_remove_releases_budget()
	_test_enabled_state()
	_test_distance_culling_hysteresis()
	_test_shadow_ordering_deterministic()
	_test_priority_beats_distance()
	_test_hysteresis_displacement()
	_test_no_request_no_shadow()


func _lm(budget: int, max_dist := 64.0):
	var lm = LightManagerScript.new()
	lm.configure({
		"shadow_budget": budget,
		"max_distance": max_dist,
		"hyst_margin": 4.0,
	})
	return lm


## id 单调递增不复用；非法 type 拒绝；registered 计数正确。
func _test_registration_basics() -> void:
	var lm = _lm(0)
	var a := lm.add_light({"type": "omni", "position": Vector3.ZERO})
	var b := lm.add_light({"type": "omni", "position": Vector3.ZERO})
	check(a > 0 and b == a + 1, "id 单调递增")
	lm.remove_light(a)
	var c := lm.add_light({"type": "omni", "position": Vector3.ZERO})
	check(c > b, "id 不复用（注销后仍递增）")
	check(lm.add_light({"type": "candle"}) == -1, "非法 type 返回 -1")
	check(lm.add_light({}) == -1, "缺 type 返回 -1")
	check_eq(lm.get_stats().registered, 2, "registered 计数")
	lm.free()


## omni/spot 节点真实创建，属性与配置一致；spot 方向沿 -Z。
func _test_node_creation() -> void:
	var lm = _lm(0)
	var id := lm.add_light({
		"type": "omni",
		"position": Vector3(3, 4, 5),
		"color": Color(1.0, 0.6, 0.2),
		"energy": 2.5,
		"range": 12.0,
	})
	var rec: Dictionary = lm._records[id]
	check(rec.node is OmniLight3D, "omni 建 OmniLight3D")
	check_eq(rec.node.omni_range, 12.0, "omni_range 写入")
	check_eq(rec.node.light_energy, 2.5, "energy 写入")
	check(rec.node.light_color.is_equal_approx(Color(1.0, 0.6, 0.2)), "颜色写入")
	check(rec.node.position.is_equal_approx(Vector3(3, 4, 5)),
			"世界坐标写入（树外=本地坐标，LightRoot 恒等）")
	check(rec.node.visible, "范围内灯可见（7.07m < 64m）")
	var sid := lm.add_light({
		"type": "spot",
		"position": Vector3.ZERO,
		"direction": Vector3(1, 0, 0),
		"angle": 0.6,
	})
	var srec: Dictionary = lm._records[sid]
	check(srec.node is SpotLight3D, "spot 建 SpotLight3D")
	check(is_equal_approx(srec.node.spot_angle, rad_to_deg(0.6)),
			"spot_angle 写入（API 弧度转属性度）")
	var fwd: Vector3 = -srec.node.basis.z
	check(fwd.normalized().dot(Vector3.RIGHT) > 0.99, "spot 朝向配置方向")
	# 竖直方向不崩（look_at 上向轴退化路径）
	var vid := lm.add_light({
		"type": "spot",
		"position": Vector3(1, 2, 3),
		"direction": Vector3.UP,
	})
	check(lm._records.has(vid), "竖直方向 spot 注册成功")
	lm.free()


## 预算 1：A 持有阴影，remove A 后 B 即时获得资格。
func _test_remove_releases_budget() -> void:
	var lm = _lm(1)
	lm.probe_position = Vector3.ZERO
	var a := lm.add_light({"type": "omni", "position": Vector3(5, 0, 0),
			"shadow_requested": true})
	var b := lm.add_light({"type": "omni", "position": Vector3(15, 0, 0),
			"shadow_requested": true})
	var ra: Dictionary = lm._records[a]
	var rb: Dictionary = lm._records[b]
	check(ra.shadow_granted, "更近者 A 获得资格")
	check(not rb.shadow_granted, "B 排队等待")
	var node_b: OmniLight3D = rb.node
	lm.remove_light(a)
	check(rb.shadow_granted, "移除 A 后 B 即时获得预算")
	check(node_b.shadow_enabled, "B 节点 shadow_enabled 打开")
	lm.free()


## 禁用灯：不可见、释放阴影、active 计数下降；重开恢复。
func _test_enabled_state() -> void:
	var lm = _lm(2)
	lm.probe_position = Vector3.ZERO
	var a := lm.add_light({"type": "omni", "position": Vector3(4, 0, 0),
			"shadow_requested": true})
	var ra: Dictionary = lm._records[a]
	check(ra.node.visible, "初始在范围内可见")
	check(ra.shadow_granted, "初始获得阴影")
	lm.set_light_enabled(a, false)
	check(not ra.enabled, "enabled 翻转")
	check(not ra.node.visible, "禁用后不可见")
	check(not ra.shadow_granted, "禁用释放阴影")
	check(not ra.node.shadow_enabled, "节点 shadow_enabled 关闭")
	check_eq(lm.get_stats().active, 0, "active 计数清零")
	lm.set_light_enabled(a, true)
	check(ra.node.visible and ra.shadow_granted, "重开恢复可见与阴影")
	lm.free()


## 距离裁剪滞回带：出界阈值 max_distance*(1+10%)，进界 max_distance。
func _test_distance_culling_hysteresis() -> void:
	var lm = _lm(0, 64.0)
	lm.probe_position = Vector3.ZERO
	var a := lm.add_light({"type": "omni", "position": Vector3(60, 0, 0)})
	var ra: Dictionary = lm._records[a]
	check(ra.in_range, "60m < 64m 在界内")
	lm.set_light_position(a, Vector3(66, 0, 0))
	lm._evaluate()
	check(ra.in_range, "66m 在滞回带内保持界内（出界需 >70.4m）")
	lm.set_light_position(a, Vector3(71, 0, 0))
	lm._evaluate()
	check(not ra.in_range, "71m 越出滞回带")
	check(not ra.node.visible, "越界灯不可见")
	lm.set_light_position(a, Vector3(63, 0, 0))
	lm._evaluate()
	check(ra.in_range, "63m 重新入界")
	lm.free()


## 预算 2、三候选：最近两盏获资格；同距离同优先级时 id 小者赢。
func _test_shadow_ordering_deterministic() -> void:
	var lm = _lm(2)
	lm.probe_position = Vector3.ZERO
	var near1 := lm.add_light({"type": "omni", "position": Vector3(5, 0, 0),
			"shadow_requested": true})
	var near2 := lm.add_light({"type": "omni", "position": Vector3(6, 0, 0),
			"shadow_requested": true})
	var far := lm.add_light({"type": "omni", "position": Vector3(40, 0, 0),
			"shadow_requested": true})
	check(lm._records[near1].shadow_granted, "最近获资格")
	check(lm._records[near2].shadow_granted, "次近获资格")
	check(not lm._records[far].shadow_granted, "远者排队")
	# 移走近两盏后 far 递补（预算释放）
	lm.set_light_position(near1, Vector3(200, 0, 0))
	lm.set_light_position(near2, Vector3(200, 0, 0))
	lm._evaluate()
	check(lm._records[far].shadow_granted, "近者出界后 far 递补")
	# 同优先级同距离：id 小者赢（确定性）
	var lm2 = _lm(1)
	lm2.probe_position = Vector3.ZERO
	var first := lm2.add_light({"type": "omni", "position": Vector3(7, 0, 0),
			"shadow_requested": true})
	var second := lm2.add_light({"type": "omni", "position": Vector3(7, 0, 0),
			"shadow_requested": true})
	check(lm2._records[first].shadow_granted, "同距同优先 id 小者获资格")
	check(not lm2._records[second].shadow_granted, "同距同优先 id 大者排队")
	lm.free()
	lm2.free()


## 高优先级远灯胜过低优先级近灯。
func _test_priority_beats_distance() -> void:
	var lm = _lm(1)
	lm.probe_position = Vector3.ZERO
	var near := lm.add_light({"type": "omni", "position": Vector3(5, 0, 0),
			"shadow_requested": true, "priority": 0})
	var far := lm.add_light({"type": "omni", "position": Vector3(30, 0, 0),
			"shadow_requested": true, "priority": 10})
	check(not lm._records[near].shadow_granted, "近灯低优先排队")
	check(lm._records[far].shadow_granted, "远灯高优先获资格")
	lm.free()


## 阴影滞回：持有者 A d=10，挑战者 B 需 d < 10-4=6 才夺走资格。
func _test_hysteresis_displacement() -> void:
	var lm = _lm(1)
	lm.probe_position = Vector3.ZERO
	var a := lm.add_light({"type": "omni", "position": Vector3(10, 0, 0),
			"shadow_requested": true})
	var b := lm.add_light({"type": "omni", "position": Vector3(8, 0, 0),
			"shadow_requested": true})
	check(lm._records[a].shadow_granted, "A 持有")
	check(not lm._records[b].shadow_granted, "B 近 2m 但在滞回带内不夺")
	lm.set_light_position(b, Vector3(5, 0, 0))
	lm._evaluate()
	check(lm._records[b].shadow_granted, "B 近 5m（<6m）夺走资格")
	check(not lm._records[a].shadow_granted, "A 被替换释放")
	lm.free()


## 未请求阴影的灯永不占用预算；stats 计数正确。
func _test_no_request_no_shadow() -> void:
	var lm = _lm(2)
	lm.probe_position = Vector3.ZERO
	var a := lm.add_light({"type": "omni", "position": Vector3(3, 0, 0)})
	check(not lm._records[a].shadow_granted, "未请求者无资格")
	var st: Dictionary = lm.get_stats()
	check_eq(st.registered, 1, "registered=1")
	check_eq(st.active, 1, "active=1")
	check_eq(st.shadowed, 0, "shadowed=0")
	# 撤回请求即时释放
	var b := lm.add_light({"type": "omni", "position": Vector3(4, 0, 0),
			"shadow_requested": true})
	check(lm._records[b].shadow_granted, "请求者获资格")
	check_eq(lm.get_stats().shadowed, 1, "shadowed=1")
	lm.set_light_shadow_requested(b, false)
	check(not lm._records[b].shadow_granted, "撤回请求即时释放")
	check_eq(lm.get_stats().shadowed, 0, "shadowed 归零")
	lm.free()
