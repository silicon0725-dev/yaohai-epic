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
