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
## 批 2：雨粒子 / 闪电 / 雷声
var _rain_particles: GPUParticles3D
var _rain_process: ParticleProcessMaterial
var _player: Node3D
var _hide_rain := false  # 探针/测试用强制隐藏
## 闪电亮度（0-1 指数衰减；main 乘入太阳能量/环境光/天空能量
## ——每帧计算平滑无跳变）。雷暴态随机触发，~0.4s 衰减 + 1-2 次
## 回击频闪（真实闪电是多回击过程，BSL 同款观感）
var flash01 := 0.0
var _thunder_timer := 6.0
var _flash_pending := 0  # 剩余回击次数
var _flash_gap := 0.0  # 距下次回击
var _thunder_clap_player: AudioStreamPlayer
var _thunder_streams: Array[AudioStreamWAV] = []
## 雷击 bolt（批 2 修复）：程序锯齿亮带（lightning_bolt.gdshader，
## gameidea.org 思路）——只调太阳能量观感≈没有（天空自发光不跟），
## 必须有可见雷击点 + main 侧天空爆白
var _bolt_mesh: MeshInstance3D
var _bolt_mat: ShaderMaterial
var _bolt_life := 0.0


func setup_player(p_player: Node3D) -> void:
	_player = p_player


func _ready() -> void:
	_rng.randomize()
	_next_step = _rng.randf_range(STEP_WINDOW.x, STEP_WINDOW.y)
	_setup_rain_audio()
	_setup_rain_particles()
	_setup_thunder()
	_setup_bolt()


func _process(delta: float) -> void:
	_next_step -= delta
	if _next_step <= 0.0:
		_next_step = _rng.randf_range(STEP_WINDOW.x, STEP_WINDOW.y)
		_step_state()
	_smooth_params(delta)
	_update_rain_audio(delta)
	_update_rain_particles()
	_update_lightning(delta)


## 雨粒子（批 2）：盒发射器跟随玩家上方（40×26×40 覆盖视野近场），
## 世界竖直细条面片（BILLBOARD_FIXED_Y：侧视可见+抬头仍竖直）；
## 密度随雨强（amount_ratio）、风偏随风力（发射方向向量倾斜）。
## 参数参考 TCA_Weather_System（MIT）：速度 15、量级 3000
func _setup_rain_particles() -> void:
	_rain_particles = GPUParticles3D.new()
	_rain_particles.amount = 4000
	_rain_particles.lifetime = 1.1
	_rain_particles.preprocess = 1.0  # 预填满（进场即有完整雨幕）
	_rain_particles.visibility_aabb = AABB(
			Vector3(-26.0, -22.0, -26.0), Vector3(52.0, 44.0, 52.0))
	_rain_process = ParticleProcessMaterial.new()
	_rain_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# 盒收窄到 ±20m：同量级粒子密度翻倍——雨幕感来自近场密度，
	# 远场雨靠雾/雨声补（远处细雨本来就看不清）
	_rain_process.emission_box_extents = Vector3(20.0, 13.0, 20.0)
	_rain_process.direction = Vector3(0.0, -1.0, 0.0)
	_rain_process.spread = 3.0
	_rain_process.gravity = Vector3(0.0, -26.0, 0.0)
	_rain_process.initial_velocity_min = 15.0
	_rain_process.initial_velocity_max = 19.0
	_rain_particles.process_material = _rain_process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.045, 1.1)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# BILLBOARD_FIXED_Y（实机观感反馈第三轮）：面片绕世界 Y 朝玩家
	#（侧视仍可见）但竖边沿世界竖直——抬头看雨丝依然竖直（物理
	# 正确）。BILLBOARD_PARTICLES 贴屏幕对齐，抬头时屏幕竖直≠世界
	# 竖直，雨丝全变横且朝向乱
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.albedo_color = Color(0.78, 0.84, 0.94, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	quad.material = mat
	_rain_particles.draw_pass_1 = quad
	add_child(_rain_particles)


func _update_rain_particles() -> void:
	if _rain_particles == null:
		return
	# 密度：雨强 0.02 以下全隐（无雨不跑粒子）
	var density := 0.0 if rain_intensity < 0.02 else rain_intensity
	if not _hide_rain:
		_rain_particles.amount_ratio = density
	else:
		_rain_particles.amount_ratio = 0.0
	if _player != null and is_instance_valid(_player):
		_rain_particles.global_position = _player.global_position \
				+ Vector3(0.0, 14.0, 0.0)
	# 风偏融进发射方向（ParticleProcessMaterial 无常量风加速度属性
	# ——风分量加进 direction 向量，重力叠加后雨幕整体倾斜）
	_rain_process.direction = Vector3(
			6.0 * wind_strength, -26.0, 3.0 * wind_strength).normalized()


## 闪电（批 2）：雷暴态随机触发主闪（flash01=1）→ ~0.4s 衰减，
## 主闪后 60-160ms 接 1-2 次较弱回击（max 不覆盖更强残光）；
## 雷声延迟播放（0.4-2.4s——距离感），程序合成三变体；bolt
## 亮带随主闪出现，0.3s 淡出
func _update_lightning(delta: float) -> void:
	if state == State.THUNDER:
		_thunder_timer -= delta
		if _thunder_timer <= 0.0:
			_thunder_timer = _rng.randf_range(7.0, 22.0)
			_trigger_strike()
	if _flash_pending > 0:
		_flash_gap -= delta
		if _flash_gap <= 0.0:
			_flash_pending -= 1
			flash01 = maxf(flash01, _rng.randf_range(0.45, 0.8))
			_flash_gap = _rng.randf_range(0.08, 0.22)
	flash01 = maxf(flash01 - delta * 2.6, 0.0)
	if _bolt_life > 0.0:
		_bolt_life = maxf(_bolt_life - delta, 0.0)
		if _bolt_mat != null:
			_bolt_mat.set_shader_parameter("u_fade", _bolt_life / 0.3)
		if _bolt_life <= 0.0 and _bolt_mesh != null:
			_bolt_mesh.visible = false


## 一次雷击：主闪 + 频闪排程 + 雷声 + bolt 雷击点
func _trigger_strike() -> void:
	flash01 = 1.0
	_flash_pending = _rng.randi_range(1, 2)
	_flash_gap = _rng.randf_range(0.06, 0.16)
	_play_thunder_after(_rng.randf_range(0.4, 2.4))
	_spawn_bolt()


## bolt：玩家 20-45m 外随机方位、云底（+55m）到地面的竖直锯齿
## 亮带，look_at 玩家（0.3s 生命周期内静态朝向够用）。距离收窄
## ——默认深度雾 10-100m 在 70m 处透射仅 33%，远处 bolt 被洗淡
func _spawn_bolt() -> void:
	if _bolt_mesh == null or _player == null or not is_instance_valid(_player):
		return
	var ang := _rng.randf() * TAU
	var dist := _rng.randf_range(20.0, 45.0)
	var pp: Vector3 = _player.global_position
	_bolt_mesh.global_position = Vector3(
			pp.x + cos(ang) * dist, pp.y + 27.0, pp.z + sin(ang) * dist)
	_bolt_mesh.look_at(pp, Vector3.UP)
	_bolt_mat.set_shader_parameter("u_seed", _rng.randf() * 100.0)
	_bolt_mat.set_shader_parameter("u_fade", 1.0)
	_bolt_mesh.visible = true
	_bolt_life = 0.3


func _setup_bolt() -> void:
	_bolt_mat = ShaderMaterial.new()
	_bolt_mat.shader = preload("res://presentation/lightning_bolt.gdshader")
	var quad := QuadMesh.new()
	quad.size = Vector2(9.0, 55.0)
	quad.material = _bolt_mat
	_bolt_mesh = MeshInstance3D.new()
	_bolt_mesh.mesh = quad
	_bolt_mesh.visible = false
	_bolt_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bolt_mesh)


func _setup_thunder() -> void:
	for i in 3:
		_thunder_streams.append(_make_thunder_stream(9300 + i * 17))
	_thunder_clap_player = AudioStreamPlayer.new()
	_thunder_clap_player.bus = "SFX"
	_thunder_clap_player.volume_db = -6.0
	add_child(_thunder_clap_player)


func _play_thunder_after(delay: float) -> void:
	var tree := get_tree()
	if tree == null:
		return  # 未进树（单元测试直调）
	await tree.create_timer(delay).timeout
	if not is_instance_valid(_thunder_clap_player):
		return  # 等待期间系统已释放
	_thunder_clap_player.stream = _thunder_streams[
			_rng.randi_range(0, _thunder_streams.size() - 1)]
	_thunder_clap_player.pitch_scale = _rng.randf_range(0.88, 1.12)
	_thunder_clap_player.volume_db = linear_to_db(
			_rng.randf_range(0.5, 0.85))
	_thunder_clap_player.play()


## 程序化雷声：起始瞬态（50ms 宽带 crack）+ 主体低频轰鸣（强低通
## 噪声，指数衰减包络 3.5s）+ 尾部隆隆（更低频慢波动）。4s 单次
static func _make_thunder_stream(seed_value: int) -> AudioStreamWAV:
	var sample_rate := 22050
	var n := sample_rate * 4
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var samples := PackedByteArray()
	samples.resize(n * 2)
	var lp1 := 0.0  # 中低通（crack 尾与轰鸣主体）
	var lp2 := 0.0  # 深低通（隆隆）
	var lp3 := 0.0  # 慢波动包络
	for i in n:
		var t := float(i) / float(sample_rate)
		var white := rng.randf_range(-1.0, 1.0)
		lp1 += 0.045 * (white - lp1)   # ~300Hz
		lp2 += 0.012 * (lp1 - lp2)     # ~80Hz
		lp3 += 0.0009 * (lp2 - lp3)    # ~6Hz 慢波动
		# 起始瞬态（前 50ms 宽带）+ 轰鸣主体（指数衰减）+ 隆隆调制
		var crack := exp(-t * 55.0) * white * 0.5
		var boom := exp(-t * 1.15) * lp2 * 3.2
		var rumble := (0.6 + 0.4 * sin(t * 9.0 + lp3 * 40.0)) \
				* exp(-t * 0.55) * lp3 * 22.0
		var v := int(clampf(crack + boom + rumble, -1.0, 1.0) * 31000.0)
		samples[i * 2] = v & 0xFF
		samples[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = samples
	return wav


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


## 调试（main F8 触发）：循环切下一状态并把参数瞬时对齐目标
##（跳过 45s 平滑——调试专用快进；正常玩法仍走马尔可夫转移 +
## 指数平滑，写实过渡红线不破坏）。切到雷暴 2s 后出首道闪电
##（不等 7-22s 随机窗）；转移计时重置（切完不被立刻转走）
func debug_cycle_state() -> void:
	state = (state + 1) % State.size()
	var target: Vector3 = STATE_TARGETS[state]
	cloudiness = target.x
	rain_intensity = target.y
	wind_strength = target.z
	weather01 = cloudiness * 0.7 + rain_intensity * 0.3
	if state == State.THUNDER:
		_thunder_timer = 2.0
	_next_step = _rng.randf_range(STEP_WINDOW.x, STEP_WINDOW.y)


## HUD/调试：当前状态名
func state_name() -> String:
	return STATE_NAMES[state]
