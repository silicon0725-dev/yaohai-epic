## 天气系统单元测试：状态机转移合法性、参数向目标平滑收敛、
## 雨声流合成（格式/非静音/循环长度）、暗度合成。
extends VoxelTestCase

const WeatherScript := preload("res://systems/weather/weather_system.gd")


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	_test_state_transitions()
	_test_smooth_convergence()
	_test_weather01_composition()
	_test_rain_stream()
	_test_debug_cycle()
	_test_rain_particles_visual()
	_test_lightning_sequence()
	_test_bolt_lifecycle()
	_test_debug_strike_player()
	_test_rain_occlusion()


## 转移表合法性：概率和 ≤1（余概率保持）、目标都是合法状态
func _test_state_transitions() -> void:
	for state_v in WeatherScript.TRANSITIONS.keys():
		var total := 0.0
		for entry in WeatherScript.TRANSITIONS[state_v]:
			check(WeatherScript.STATE_TARGETS.has(entry[0]),
					"转移目标合法（%s）" % [entry[0]])
			check(float(entry[1]) >= 0.0, "转移概率非负")
			total += float(entry[1])
		check(total <= 1.0001, "转移概率和 ≤1（状态 %d 和 %.2f）"
				% [int(state_v), total])


## 参数平滑：强制状态后向目标单调收敛（指数平滑 60 秒后 >63% 路程）
func _test_smooth_convergence() -> void:
	var w: Node = WeatherScript.new()
	# 直接驱动内部（跳过 _process 的随机步进干扰）：手调 _smooth_params
	w.state = WeatherScript.State.RAIN
	var target: Vector3 = WeatherScript.STATE_TARGETS[w.state]
	# 从晴的参数出发
	w.cloudiness = 0.05
	w.rain_intensity = 0.0
	for i in 120:  # 120 秒（dt=1；tau=45 → 路程 93%）
		w._smooth_params(1.0)
	check(w.cloudiness > target.x * 0.90,
			"云量收敛到雨目标（%.3f → 目标 %.2f）" % [w.cloudiness, target.x])
	check(w.rain_intensity > target.y * 0.90,
			"雨强收敛（%.3f → 目标 %.2f）" % [w.rain_intensity, target.y])
	check(w.weather01 > 0.5, "综合暗度随雨升起（%.3f）" % w.weather01)
	# 单调性：从晴到雨全程云量不下降
	var w2: Node = WeatherScript.new()
	w2.state = WeatherScript.State.RAIN
	w2.cloudiness = 0.05
	var prev: float = w2.cloudiness
	var monotonic := true
	for i in 60:
		w2._smooth_params(1.0)
		if w2.cloudiness < prev - 0.0001:
			monotonic = false
		prev = w2.cloudiness
	check(monotonic, "过渡单调无跳变（写实平滑红线）")
	w.free()
	w2.free()


## 暗度合成：weather01 = 0.7*云 + 0.3*雨，暴雨最暗
func _test_weather01_composition() -> void:
	var w: Node = WeatherScript.new()
	w.cloudiness = 1.0
	w.rain_intensity = 1.0
	w._smooth_params(0.0)  # dt=0 不动参数，仅重算暗度
	check(absf(w.weather01 - 1.0) < 0.001, "雷暴满暗度")
	w.cloudiness = 0.0
	w.rain_intensity = 0.0
	w._smooth_params(0.0)
	check(absf(w.weather01) < 0.001, "晴空零暗度")
	w.free()


## 雨声合成：16bit 单声道、4 秒循环、内容非静音且不削顶
func _test_rain_stream() -> void:
	var stream: AudioStreamWAV = WeatherScript._make_rain_stream()
	check(stream != null, "雨声流生成")
	check_eq(stream.format, AudioStreamWAV.FORMAT_16_BITS, "16bit 格式")
	check_eq(stream.stereo, false, "单声道")
	check_eq(stream.data.size(), 22050 * 4 * 2, "4 秒循环长度（16bit 字节）")
	# 循环模式（实机"没有雨声"真凶回归守卫）：默认播完即停——
	# 4s 流在加载期播完，切到雨态时 player 早已停止
	check_eq(stream.loop_mode, AudioStreamWAV.LOOP_FORWARD,
			"雨声循环播放")
	check_eq(stream.loop_end, 22050 * 4, "循环区间覆盖全长")
	var peak := 0
	var rms := 0.0
	var count := stream.data.size() / 2
	# 逐样本读 int16（小端）
	var bytes: PackedByteArray = stream.data
	var nonzero := 0
	for i in count:
		var v := int(bytes[i * 2]) | (int(bytes[i * 2 + 1]) << 8)
		if v >= 32768:
			v -= 65536
		var av := absi(v)
		if av > peak:
			peak = av
		rms += float(av)
		if av > 100:
			nonzero += 1
	rms /= count
	check(peak > 4000, "雨声非静音（峰值 %d）" % peak)
	check(peak < 32767, "不削顶（峰值 %d）" % peak)
	check(rms > 2000.0, "能量可观（RMS %.0f）" % rms)
	check(nonzero > count * 90 / 100, "绝大多数样本有声（%d/%d）"
			% [nonzero, count])


## F8 调试循环：四态循环顺序、参数瞬时对齐、雷暴快速闪电、
## 转移计时重置（不被立刻转走）
func _test_debug_cycle() -> void:
	var w: Node = WeatherScript.new()
	# 从晴出发连按四次 → 回到晴（循环闭合）
	var seen_states := []
	for i in 4:
		w.debug_cycle_state()
		seen_states.append(w.state)
	check_eq(seen_states, [
		WeatherScript.State.CLOUDY, WeatherScript.State.RAIN,
		WeatherScript.State.THUNDER, WeatherScript.State.CLEAR],
		"四态循环顺序 晴→多云→雨→雷暴→晴")
	# 瞬时对齐：切完参数即等于状态目标（无平滑残留）
	w.debug_cycle_state()  # 晴 → 多云
	var target: Vector3 = WeatherScript.STATE_TARGETS[w.state]
	check(absf(w.cloudiness - target.x) < 0.001
			and absf(w.rain_intensity - target.y) < 0.001
			and absf(w.wind_strength - target.z) < 0.001,
			"参数瞬时对齐状态目标")
	check(absf(w.weather01 - (target.x * 0.7 + target.y * 0.3)) < 0.001,
			"暗度同步重算")
	# 雷暴快速闪电：切到雷暴后 _thunder_timer 压到 2s（不等 7-22s）
	w.debug_cycle_state()  # 多云 → 雨
	w._thunder_timer = 20.0
	w.debug_cycle_state()  # 雨 → 雷暴
	check(absf(w._thunder_timer - 2.0) < 0.001, "雷暴切入闪电窗压到 2s")
	# 转移计时重置：切完 _next_step 回到步进窗内
	check(w._next_step >= WeatherScript.STEP_WINDOW.x
			and w._next_step <= WeatherScript.STEP_WINDOW.y,
			"转移计时重置回窗内")
	w.free()


## 雨粒子可见性与观感（实机多轮回归守卫）：自写 shader billboard
##（FIXED_Y 材质会忽略粒子 angle——雨丝永远竖直的根因）+条纹
## 纹理（防矩形硬边）+随机倾斜角
func _test_rain_particles_visual() -> void:
	var w: Node = WeatherScript.new()
	w._setup_rain_particles()
	var quad: QuadMesh = w._rain_particles.draw_pass_1
	var mat: ShaderMaterial = quad.material
	check(mat.shader != null
			and w._rain_streak_mat == mat,
			"自写 shader billboard（绕 Y 朝相机+风偏倾斜）")
	check(quad.size.y >= 0.6 and quad.size.x >= 0.03,
			"雨丝尺寸（宽度下限防 <1px 不可见，%.3f×%.2f）"
					% [quad.size.x, quad.size.y])
	var tex: Texture2D = mat.get_shader_parameter("u_tex")
	check(tex != null, "条纹纹理（端部渐隐防矩形硬边）")
	# 纹理端部 alpha 渐隐：顶/底行平均 alpha 应显著低于中心行
	var img: Image = tex.get_image()
	var a_sum_mid := 0.0
	var a_sum_top := 0.0
	var a_sum_bot := 0.0
	for x in img.get_width():
		a_sum_mid += img.get_pixel(x, img.get_height() / 2).a
		a_sum_top += img.get_pixel(x, 2).a
		a_sum_bot += img.get_pixel(x, img.get_height() - 3).a
	var n := float(img.get_width())
	check(a_sum_mid / n > a_sum_top / n * 1.5
			and a_sum_mid / n > a_sum_bot / n * 1.5,
			"端部渐隐（中 %.2f vs 顶 %.2f/底 %.2f）"
					% [a_sum_mid / n, a_sum_top / n, a_sum_bot / n])
	check(w._rain_process.angle_max - w._rain_process.angle_min >= 15.0,
			"随机倾斜角范围（防整齐平行）")
	check(w._rain_process.initial_velocity_min >= 14.0,
			"雨速写实（≥14 m/s）")
	w.free()


## 闪电回击频闪：主闪全亮 + 1-2 次回击排程 + 回击抬升亮度
func _test_lightning_sequence() -> void:
	var w: Node = WeatherScript.new()
	tree_root.add_child(w)  # _trigger_strike 走雷声调度（需在树）
	w._trigger_strike()
	check(absf(w.flash01 - 1.0) < 0.001, "主闪全亮")
	check(w._flash_pending >= 1 and w._flash_pending <= 2,
			"排程 1-2 次回击（%d）" % w._flash_pending)
	# 人为推进到回击窗内：计数递减且亮度被回击抬回
	w._flash_gap = 0.01
	var pending_before: int = w._flash_pending
	w._update_lightning(0.05)
	check_eq(w._flash_pending, pending_before - 1, "回击计数递减")
	check(w.flash01 > 0.4, "回击窗内亮度可观（%.2f）" % w.flash01)
	# 衰减到黑：无回击后 1 秒彻底归零
	w._flash_pending = 0
	w._update_lightning(1.0)
	check(absf(w.flash01) < 0.001, "闪后归零")
	w.free()


## 雷击 bolt：贴地（地形查询）+ 焦痕生成/淡出/池上限 + 隐去
func _test_bolt_lifecycle() -> void:
	var w: Node = WeatherScript.new()
	tree_root.add_child(w)
	var dummy := Node3D.new()
	tree_root.add_child(dummy)
	dummy.global_position = Vector3(10.0, 60.0, -5.0)
	w.setup_player(dummy)
	# 地形查询 mock：任何列表面=77（bolt 底端应贴 77、焦痕在 77+0.03）
	w.setup_terrain_query(
			func(_x: float, _z: float, _h: float) -> float: return 77.0)
	w._trigger_strike()
	check(w._bolt_root.visible, "雷击 bolt 出现")
	check(w._bolt_life > 0.0, "bolt 生命周期启动")
	var bp: Vector3 = w._bolt_root.global_position
	var pp: Vector3 = dummy.global_position
	var d: float = Vector2(bp.x - pp.x, bp.z - pp.z).length()
	check(d >= 19.0 and d <= 46.0, "雷击点水平 20-45m 环带（%.0fm）" % d)
	check(absf(bp.y - (77.0 + 27.5)) < 0.01,
			"bolt 底端贴地形表面（中心 %.1f = 77+27.5）" % bp.y)
	# 焦痕：贴地生成 + 淡出消失 + 池上限
	check_eq(w._scorches.size(), 1, "焦痕生成")
	var sc: Dictionary = w._scorches[0]
	check(absf(float(sc.mesh.position.y) - 77.03) < 0.01,
			"焦痕贴地（表面+3cm）")
	check(absf(sc.mat.albedo_color.a - 0.85) < 0.01, "焦痕初始不透明")
	w._update_scorches(30.0)
	check(absf(w._scorches[0].mat.albedo_color.a - 0.85) < 0.01,
			"寿命内不淡出")
	w._update_scorches(31.0)  # 61s：淡出过半
	var mid_a: float = w._scorches[0].mat.albedo_color.a
	check(mid_a < 0.85 and mid_a > 0.0, "淡出中（%.2f）" % mid_a)
	w._update_scorches(2.0)  # 63s > 60+2：移除
	check_eq(w._scorches.size(), 0, "焦痕到期移除")
	# 池上限：连击 10 道只剩 8
	for i in 10:
		w._spawn_scorch(float(i), 77.0, float(i))
	check_eq(w._scorches.size(), 8, "焦痕池上限 8")
	w._update_lightning(0.6)
	check(not w._bolt_root.visible, "bolt 0.5s 后隐去")
	dummy.free()
	w.free()


## F9 调试直劈：bolt 在玩家所在列、底端贴地形、焦痕在脚下
func _test_debug_strike_player() -> void:
	var w: Node = WeatherScript.new()
	tree_root.add_child(w)
	var dummy := Node3D.new()
	tree_root.add_child(dummy)
	dummy.global_position = Vector3(10.0, 60.0, -5.0)
	w.setup_player(dummy)
	w.setup_terrain_query(
			func(_x: float, _z: float, _h: float) -> float: return 77.0)
	w.debug_strike_player()
	check(w._bolt_root.visible, "直劈 bolt 出现")
	var bp: Vector3 = w._bolt_root.global_position
	var pp: Vector3 = dummy.global_position
	var dh: float = Vector2(bp.x - pp.x, bp.z - pp.z).length()
	check(dh >= 6.0 and dh <= 10.0, "bolt 在玩家前方 8m（%.1fm）" % dh)
	check(absf(bp.y - (77.0 + 27.5)) < 0.01, "底端贴地形（77+27.5）")
	check_eq(w._scorches.size(), 1, "焦痕生成")
	check(w._strike_light.visible and w._strike_light.light_energy > 0.0,
			"触地光爆启动")
	dummy.free()
	w.free()


## 雨遮蔽高度图：分帧行重建转满一圈后，左半高表面/右半低表面
## 编码正确（用户需求：方块/树叶下无雨——shader 按此图裁剪）
func _test_rain_occlusion() -> void:
	var w: Node = WeatherScript.new()
	tree_root.add_child(w)
	var dummy := Node3D.new()
	tree_root.add_child(dummy)
	dummy.global_position = Vector3(0.0, 50.0, 0.0)
	w.setup_player(dummy)
	w.setup_terrain_query(func(x: float, _z: float, _h: float) -> float:
			return 60.0 if x < 0.0 else 40.0)
	for i in WeatherScript.OCCL_N:  # 轮转满一圈（每帧 1 行）
		w._update_rain_occlusion()
	check_eq(w._occl_img.get_width(), WeatherScript.OCCL_N,
			"高度图尺寸（21×21）")
	var base: float = w._occl_base
	check(absf(w._occl_img.get_pixel(0, 0).r
			- (60.0 - base) / 80.0) < 0.01, "左半=高表面编码")
	check(absf(w._occl_img.get_pixel(20, 20).r
			- (40.0 - base) / 80.0) < 0.01, "右半=低表面编码")
	# 露天列（低表面 40 < 玩家 50）：材质基准已下发
	check(absf(float(w._rain_streak_mat.get_shader_parameter(
			"u_hm_base")) - base) < 0.01, "编码基准下发材质")
	dummy.free()
	w.free()
