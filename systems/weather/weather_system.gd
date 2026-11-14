## 天气系统（阶段 1：状态机 + 光照/天空联动 + 程序化雨声）。
##
## 状态机：晴 CLEAR / 多云 CLOUDY / 雨 RAIN / 雷暴 THUNDER，分钟级
## 马尔可夫转移；三个连续参数（云量/雨强/风力 0..1）向状态目标
## 指数平滑——一切视觉/audio 联动只读连续参数，状态本身只是驱动
## 源（过渡期天空渐暗渐亮，无跳变——写实画风红线）。
##
## 联动全部在 main 侧参数层（零 shader 改动）：
##   - 太阳能量/环境光/雾色按 weather01 压暗（与日夜循环同源写入）
##   - 天空色向阴天灰插值（C5 脏检查块内同一次写）
##   - 雨声程序合成（白噪声两级滤波，素材零依赖）
##   - 音景机雨量接口（压虫鸣，ambient_system.set_weather）
##
## 阶段 2（后续批）：GPU 雨粒子 + 雨滴打水面涟漪（WaterRipples
## 冲量复用）+ 闪电/雷声 + 植被风力联动；群系联动（荒漠少雨，
## 寒带雨→雪）待气候查询接口暴露。
##
## 无 class_name（全局类缓存坑）——main preload 接线。
extends Node

enum State { CLEAR, CLOUDY, RAIN, THUNDER }

## 状态显示名（HUD）
const STATE_NAMES := {
	State.CLEAR: "晴",
	State.CLOUDY: "多云",
	State.RAIN: "雨",
	State.THUNDER: "雷暴",
}

## 各状态的目标参数（云量, 雨强, 风力）
const STATE_TARGETS := {
	State.CLEAR: Vector3(0.05, 0.0, 0.25),
	State.CLOUDY: Vector3(0.55, 0.0, 0.45),
	State.RAIN: Vector3(0.85, 0.7, 0.65),
	State.THUNDER: Vector3(1.0, 1.0, 1.0),
}

## 转移表：当前状态 -> [(目标状态, 概率), ...]（余下概率保持）
const TRANSITIONS := {
	State.CLEAR: [[State.CLOUDY, 0.35]],
	State.CLOUDY: [[State.CLEAR, 0.40], [State.RAIN, 0.30]],
	State.RAIN: [[State.CLOUDY, 0.45], [State.THUNDER, 0.20]],
	State.THUNDER: [[State.RAIN, 0.55]],
}

## 转移评估间隔（秒，随机取窗）与参数平滑时间常数
const STEP_WINDOW := Vector2(150.0, 360.0)  # 2.5-6 分钟
const SMOOTH_TAU := 45.0  # 过渡 ~45s 到 63%（整体 2-3 分钟完成）

## 连续天气参数（0..1）：读方只消费这三个
var cloudiness := 0.05
var rain_intensity := 0.0
var wind_strength := 0.25

var state: int = State.CLEAR
## 综合暗度（云量驱动，main 用它压太阳/环境/天空）
var weather01 := 0.0

var _rng := RandomNumberGenerator.new()
var _next_step := 0.0
var _rain_player: AudioStreamPlayer
var _rain_volume_base := 0.0


func _ready() -> void:
	_rng.randomize()
	_next_step = _rng.randf_range(STEP_WINDOW.x, STEP_WINDOW.y)
	_setup_rain_audio()


func _process(delta: float) -> void:
	_next_step -= delta
	if _next_step <= 0.0:
		_next_step = _rng.randf_range(STEP_WINDOW.x, STEP_WINDOW.y)
		_step_state()
	_smooth_params(delta)
	_update_rain_audio(delta)


## 状态转移（马尔可夫一步）
func _step_state() -> void:
	var roll := _rng.randf()
	for entry in TRANSITIONS[state]:
		var target: int = entry[0]
		var prob: float = entry[1]
		if roll < prob:
			state = target
			return
		roll -= prob
	# 余概率保持


## 参数向状态目标指数平滑
func _smooth_params(delta: float) -> void:
	var target: Vector3 = STATE_TARGETS[state]
	var k := 1.0 - exp(-delta / SMOOTH_TAU)
	cloudiness += (target.x - cloudiness) * k
	rain_intensity += (target.y - rain_intensity) * k
	wind_strength += (target.z - wind_strength) * k
	# 综合暗度：云量主导（暴雨天最暗）
	weather01 = cloudiness * 0.7 + rain_intensity * 0.3


func _setup_rain_audio() -> void:
	_rain_player = AudioStreamPlayer.new()
	_rain_player.stream = _make_rain_stream()
	# Ambient 总线由 SoundManager 运行时创建；未就绪时退 Master
	#（创建顺序差异防一次性警告）
	var bus := "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 \
			else "Master"
	_rain_player.bus = bus
	_rain_player.volume_db = -60.0  # 从无声渐入
	add_child(_rain_player)
	_rain_player.play()


## 雨声音量跟随雨强（60dB 动态范围，平滑防跳变）
func _update_rain_audio(delta: float) -> void:
	if _rain_player == null:
		return
	var target_db := linear_to_db(clampf(
			0.14 + rain_intensity * 0.5, 0.0, 1.0)) if rain_intensity > 0.02 \
			else -60.0
	var cur := db_to_linear(_rain_player.volume_db)
	var want := db_to_linear(target_db)
	cur += (want - cur) * (1.0 - exp(-delta * 1.5))
	_rain_player.volume_db = linear_to_db(maxf(cur, 0.0001))


## 程序化雨声：白噪声两级滤波的循环 AudioStreamWAV。
## 雨声本体=宽带噪声偏高频嘶声（一阶高通保 1kHz 以上）+ 低频
## 隆隆衬底（重低通，模拟远处雨幕/雷雨底噪）两层混合。素材零
## 依赖（freesound 许可清单有候选但未入库——程序合成同脚步先例，
## 且音量可随强度连续调制）。循环长度 4s：白噪声自相关短，
## 4s 无明显周期感。
static func _make_rain_stream() -> AudioStreamWAV:
	var sample_rate := 22050
	var seconds := 4
	var n := sample_rate * seconds
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261114  # 固定种子：每次运行同一雨声（内容一致）
	var samples := PackedByteArray()
	samples.resize(n * 2)  # 16bit 小端：每样本 2 字节
	# 一阶滤波状态：lp 为低通（~800Hz 截止），hp = 白噪 - lp 即高通
	var hp := 0.0
	var lp := 0.0
	for i in n:
		var white := rng.randf_range(-1.0, 1.0)
		lp += 0.12 * (white - lp)
		hp = white - lp
		# 嘶声层（高通）+ 隆隆衬底（低通残余）混合
		var v := int(clampf(hp * 0.85 + lp * 0.35, -1.0, 1.0) * 32000.0)
		samples[i * 2] = v & 0xFF
		samples[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = samples
	return wav


## HUD/调试：当前状态名
func state_name() -> String:
	return STATE_NAMES[state]
