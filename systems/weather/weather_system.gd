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
## 群系雨量缩放（main 按 0.5s 轮询注入：荒漠≈0/寒原 0.55/常 1.0）
## ——状态机照常运转（阴天云保留），只压降水视觉/听觉/涟漪
var rain_scale := 1.0


## 有效雨强（粒子/音频/涟漪统一消费口——乘群系缩放）
func rain01() -> float:
	return rain_intensity * rain_scale


func set_rain_scale(scale: float) -> void:
	rain_scale = clampf(scale, 0.0, 1.0)

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
var _rain_streak_mat: ShaderMaterial  # 雨丝着色器（u_tilt/u_wind_dir 下发）
## 雨遮蔽（用户需求：方块/树叶下无雨）：玩家周围 OCCL_N×OCCL_N 列
## 表面高度图（R8 编码），雨丝 shader 采样裁剪。逐行轮转重建
##（每帧 1 行 ≈ 21 列查询——整图一次性重建 9k+ get_block 会卡帧）
const OCCL_N := 21  # 奇数（中心格对玩家）；±20m 覆盖发射盒
const OCCL_STEP := 2.0  # 格距（米）——树叶边缘线性插值过渡
const OCCL_RANGE := 80.0  # R8 编码高度范围
var _occl_img: Image
var _occl_tex: ImageTexture
var _occl_row := 0  # 下一个待重建行（轮转游标）
var _occl_center := Vector2.ZERO  # 高度图世界中心（行重建基准）
var _occl_base := 0.0  # R8 编码基准 Y（重建周期内锁定）
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
var _bolt_root: Node3D  # 十字双面片父节点（抬头/任意水平角可见）
var _bolt_mat: ShaderMaterial
var _bolt_life := 0.0
var _strike_light: OmniLight3D  # 触地光爆（击中点 0.3s 亮闪）
var _strike_light_life := 0.0
## 地形查询（main 注入）：(x, z, hint_y) -> 列表面高度——雷击点
## 贴地形（劈在方块上）+焦痕贴地。无注入时回落玩家高度
var _terrain_query: Callable
## 焦痕（用户需求：雷击方块留烧焦痕迹，~1 分钟后淡出消失）
const BOLT_LIFE := 0.5  # 0.3 太短（实机"没看到闪电"）——放慢一档
const SCORCH_LIFETIME := 60.0
const SCORCH_FADE := 2.0
const SCORCH_POOL := 8
var _scorch_tex: ImageTexture
var _scorches: Array = []  # [{mesh, mat, age}]


func setup_player(p_player: Node3D) -> void:
	_player = p_player


## 地形列表面查询注入（main 提供：从上向下找第一个实心方块顶面）
func setup_terrain_query(p_query: Callable) -> void:
	_terrain_query = p_query


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
	_update_rain_occlusion()
	_update_lightning(delta)
	_update_scorches(delta)


## 雨粒子（批 2）：盒发射器跟随玩家上方（40×26×40 覆盖视野近场），
## 世界竖直细条面片（自写 shader billboard：绕 Y 朝相机+风偏倾斜
## +随机角）；密度随雨强（amount_ratio）、风偏随风力（发射方向
## 向量倾斜 + u_tilt 下发）。参数参考 TCA_Weather_System（MIT）
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
	# 随机倾斜角：写入 CUSTOM.x 由 rain_streak.gdshader 应用——
	# StandardMaterial 的 BILLBOARD_FIXED_Y 强制 Y 对齐会忽略粒子
	# angle（第四轮实机反馈"雨还是竖直的"根因）
	_rain_process.angle_min = -6.0
	_rain_process.angle_max = 18.0
	_rain_particles.process_material = _rain_process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.085, 1.25)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://presentation/rain_streak.gdshader")
	# 条纹纹理（实机反馈：纯色矩形硬边不自然）：中心亮线横向高斯
	# 柔边 + 纵向两端渐隐（社区标准做法，端部 fade 在贴图不在引擎）
	mat.set_shader_parameter("u_tex", _make_rain_streak_texture())
	mat.set_shader_parameter("u_tint", Color(0.78, 0.84, 0.94, 1.0))
	# 遮蔽高度图（先建 1×1 占位——无地形查询时全 0=不遮蔽）
	_occl_img = Image.create(1, 1, false, Image.FORMAT_R8)
	_occl_img.set_pixel(0, 0, Color(0.0, 0.0, 0.0))
	_occl_tex = ImageTexture.create_from_image(_occl_img)
	mat.set_shader_parameter("u_hm_tex", _occl_tex)
	mat.set_shader_parameter("u_hm_base", -4000.0)  # 占位不遮蔽
	_rain_streak_mat = mat
	quad.material = mat
	_rain_particles.draw_pass_1 = quad
	add_child(_rain_particles)


func _update_rain_particles() -> void:
	if _rain_particles == null:
		return
	# 密度：有效雨强（群系缩放后）0.02 以下全隐（无雨不跑粒子）
	var effective := rain01()
	var density := 0.0 if effective < 0.02 else effective
	if not _hide_rain:
		_rain_particles.amount_ratio = density
	else:
		_rain_particles.amount_ratio = 0.0
	if _player != null and is_instance_valid(_player):
		_rain_particles.global_position = _player.global_position \
				+ Vector3(0.0, 14.0, 0.0)
	# 风偏融进发射方向（ParticleProcessMaterial 无常量风加速度属性
	# ——风分量加进 direction 向量，重力叠加后雨幕整体倾斜）
	var wind := Vector3(
			6.0 * wind_strength, -26.0, 3.0 * wind_strength)
	_rain_process.direction = wind.normalized()
	# 雨丝视觉倾斜同步下发（shader 侧运动模糊拖影角）：风向水平
	# 分量/落速的 atan（风强 1≈14°、微风≈4°），方向与世界风向一致
	if _rain_streak_mat != null:
		var horiz := Vector2(wind.x, wind.z)
		_rain_streak_mat.set_shader_parameter("u_tilt",
				atan2(horiz.length(), 26.0))
		if horiz.length() > 0.001:
			_rain_streak_mat.set_shader_parameter("u_wind_dir",
					horiz.normalized())


## 雨遮蔽重建：每帧 1 行轮转（21 帧一圈 ≈0.35s@60fps）。玩家跨
## 8m 重锁中心与编码基准（之后轮转自然覆盖全图）。无地形查询
## 时保持占位（base -4000 = 全不遮蔽）
func _update_rain_occlusion() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var pp: Vector3 = _player.global_position
	# 首建（尺寸 1×1 占位）或玩家跨 8m：重锁中心/基准。首建判断
	# 不能只看跨距——玩家在原点 ±8m 内时初始 center=ZERO 距离不足
	#（单测抓出：图永不升级、遮蔽失灵）
	if _occl_img.get_width() != OCCL_N \
			or _occl_center.distance_to(Vector2(pp.x, pp.z)) > 8.0:
		_occl_center = Vector2(pp.x, pp.z)
		_occl_base = pp.y - OCCL_RANGE * 0.5
		if _occl_img.get_width() != OCCL_N:
			_occl_img = Image.create(
					OCCL_N, OCCL_N, false, Image.FORMAT_R8)
			_occl_tex = ImageTexture.create_from_image(_occl_img)
			_rain_streak_mat.set_shader_parameter("u_hm_tex", _occl_tex)
	if not _terrain_query.is_valid():
		return
	_rain_streak_mat.set_shader_parameter("u_hm_center", _occl_center)
	_rain_streak_mat.set_shader_parameter("u_hm_base", _occl_base)
	var half := (OCCL_N - 1) * 0.5
	for ix in OCCL_N:
		var wx := _occl_center.x + (float(ix) - half) * OCCL_STEP
		var wz := _occl_center.y \
				+ (float(_occl_row) - half) * OCCL_STEP
		var h: float = _terrain_query.call(wx, wz, pp.y)
		var v := clampf((h - _occl_base) / OCCL_RANGE, 0.0, 1.0)
		_occl_img.set_pixel(ix, _occl_row, Color(v, 0.0, 0.0))
	_occl_row = (_occl_row + 1) % OCCL_N
	_occl_tex.update(_occl_img)


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
			_bolt_mat.set_shader_parameter("u_fade",
					_bolt_life / BOLT_LIFE)
		if _bolt_life <= 0.0 and _bolt_root != null:
			_bolt_root.visible = false
	if _strike_light_life > 0.0:
		_strike_light_life = maxf(_strike_light_life - delta, 0.0)
		_strike_light.light_energy = 26.0 * _strike_light_life / 0.35
		if _strike_light_life <= 0.0:
			_strike_light.visible = false


## 一次雷击：主闪 + 频闪排程 + 雷声 + bolt 雷击点
func _trigger_strike() -> void:
	flash01 = 1.0
	_flash_pending = _rng.randi_range(1, 2)
	_flash_gap = _rng.randf_range(0.06, 0.16)
	_play_thunder_after(_rng.randf_range(0.4, 2.4))
	_spawn_bolt()


## bolt：玩家 20-45m 外随机方位、底端贴地形表面（劈在方块上，
## main 注入列高查询）到云底的竖直锯齿十字亮带。距离收窄——
## 默认深度雾 10-100m 在 70m 处透射仅 33%，远处被洗淡。
## 触地瞬间击中点光爆（"劈到地上"的感知载体——照亮焦痕出现）
func _spawn_bolt() -> void:
	if _bolt_root == null or _player == null or not is_instance_valid(_player):
		return
	var ang := _rng.randf() * TAU
	var dist := _rng.randf_range(20.0, 45.0)
	_strike_at(_player.global_position + Vector3(
			cos(ang) * dist, 0.0, sin(ang) * dist))


## 落点执行：bolt 十字定位（中心=表面+27.5，底端贴方块）+ 光爆
## + 焦痕。bx/bz 为落点水平坐标，表面高度走地形查询（hint=玩家）
func _strike_at(landing: Vector3) -> void:
	var pp: Vector3 = _player.global_position
	var surface_y := pp.y
	if _terrain_query.is_valid():
		surface_y = _terrain_query.call(landing.x, landing.z, pp.y)
	_bolt_root.global_position = Vector3(
			landing.x, surface_y + 27.5, landing.z)
	_bolt_mat.set_shader_parameter("u_seed", _rng.randf() * 100.0)
	_bolt_mat.set_shader_parameter("u_fade", 1.0)
	_bolt_root.visible = true
	_bolt_life = BOLT_LIFE
	_strike_light.global_position = Vector3(
			landing.x, surface_y + 1.5, landing.z)
	_strike_light.light_energy = 26.0
	_strike_light.visible = true
	_strike_light_life = 0.35
	_spawn_scorch(landing.x, surface_y, landing.z)


func _setup_bolt() -> void:
	_bolt_mat = ShaderMaterial.new()
	_bolt_mat.shader = preload("res://presentation/lightning_bolt.gdshader")
	var quad := QuadMesh.new()
	quad.size = Vector2(12.0, 55.0)
	quad.material = _bolt_mat
	# 十字双面片（抬头变横根治）：单面片 look_at 玩家是静态朝向，
	# 玩家抬头后面片侧对投影成横线；两片正交竖直面（MC 同款），
	# 任意水平视角至少一片正对，且不再需要 look_at
	_bolt_root = Node3D.new()
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.rotation.y = PI * 0.5 * float(i)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bolt_root.add_child(mi)
	_bolt_root.visible = false
	add_child(_bolt_root)
	_strike_light = OmniLight3D.new()
	_strike_light.light_color = Color(0.85, 0.9, 1.0)
	_strike_light.omni_range = 26.0
	_strike_light.light_energy = 0.0
	_strike_light.visible = false
	add_child(_strike_light)
	_scorch_tex = _make_scorch_texture()


## 焦痕（用户需求）：雷击点贴地焦黑面片（受光材质——阴影里自然
## 变暗），60s 后 2s 淡出；池上限 8 最老先回收。抬 3cm 防 z-fight
func _spawn_scorch(bx: float, surface_y: float, bz: float) -> void:
	if _scorch_tex == null:
		return
	while _scorches.size() >= SCORCH_POOL:
		var oldest: Dictionary = _scorches.pop_front()
		oldest.mesh.queue_free()
	var quad := PlaneMesh.new()  # 平躺朝上
	quad.size = Vector2(2.4, 2.4)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _scorch_tex
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.85)
	quad.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.position = Vector3(bx, surface_y + 0.03, bz)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_scorches.append({"mesh": mi, "mat": mat, "age": 0.0})


func _update_scorches(delta: float) -> void:
	var i := 0
	while i < _scorches.size():
		var s: Dictionary = _scorches[i]
		s.age += delta
		if s.age >= SCORCH_LIFETIME + SCORCH_FADE:
			s.mesh.queue_free()
			_scorches.remove_at(i)
			continue
		var fade01: float = clampf(
				(SCORCH_LIFETIME + SCORCH_FADE - s.age) / SCORCH_FADE,
				0.0, 1.0)
		s.mat.albedo_color = Color(1.0, 1.0, 1.0, 0.85 * fade01)
		i += 1


## 程序化焦痕纹理（64×64）：径向炭黑渐变 + 随机破碎边缘（噪声
## 半径）。素材零依赖（雨丝纹理同款先例）
static func _make_scorch_texture() -> ImageTexture:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7715  # 固定：所有焦痕同款（统一感）
	for y in s:
		for x in s:
			var vx := (float(x) + 0.5) / float(s) - 0.5
			var vy := (float(y) + 0.5) / float(s) - 0.5
			var r := Vector2(vx, vy).length()
			var edge := 0.34 + (rng.randf() - 0.5) * 0.22  # 破碎边缘
			var a: float = clampf((edge - r) / 0.14, 0.0, 1.0)
			var dark := 1.0 - smoothstep(0.0, edge, r)  # 中心最深
			img.set_pixel(x, y, Color(0.05, 0.04, 0.035,
					a * (0.5 + 0.5 * dark)))
	return ImageTexture.create_from_image(img)


func _setup_thunder() -> void:
	for i in 3:
		_thunder_streams.append(_make_thunder_stream(9300 + i * 17))
	_thunder_clap_player = AudioStreamPlayer.new()
	_thunder_clap_player.bus = "SFX"
	_thunder_clap_player.volume_db = -3.0
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
		lp1 += 0.06 * (white - lp1)   # ~400Hz（中低通上移：80Hz 轰鸣
		                              # 在笔记本扬声器不可闻——实机
		                              # "没有打雷声"反馈）
		lp2 += 0.012 * (lp1 - lp2)     # ~80Hz
		lp3 += 0.0009 * (lp2 - lp3)    # ~6Hz 慢波动
		# 起始瞬态（宽带 crack 放长放响——可听性主载体）+ 轰鸣主体
		#（中频贡献）+ 隆隆调制
		var crack := exp(-t * 32.0) * white * 0.65
		var boom := exp(-t * 1.15) * lp2 * 3.2 \
				+ exp(-t * 2.2) * lp1 * 1.4
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


## 雨声音量跟随有效雨强（群系缩放；60dB 动态范围，平滑防跳变）
func _update_rain_audio(delta: float) -> void:
	if _rain_player == null:
		return
	var effective := rain01()
	var target_db := linear_to_db(clampf(
			0.14 + effective * 0.5, 0.0, 1.0)) if effective > 0.02 \
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
	# 循环（实机"没有雨声"真凶）：默认播完即停——4s 流在加载期
	# 就播完，切到雨态时 player 早已停止（探针实测 playing=false）
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
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


## 程序化雨丝条纹纹理（8×64）：中心竖亮线横向高斯柔边 + 纵向
## 两端渐隐（上端快入 12%、下端长尾 38%——下落运动模糊感）。
## 素材零依赖（雨声合成同款先例）；纯色 QuadMesh 是硬边矩形
##（实机反馈"矩形不自然"），社区标准做法=条纹贴图自带端部 fade
static func _make_rain_streak_texture() -> ImageTexture:
	var w := 8
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var vy := float(y) / float(h - 1)
		var fade: float = smoothstep(0.0, 0.12, vy) \
				* (1.0 - smoothstep(0.62, 1.0, vy))
		for x in w:
			var vx := (float(x) + 0.5) / float(w) - 0.5
			var gauss := exp(-vx * vx / 0.015)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0,
					clampf(gauss * fade, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## 调试（main F9）：闪电劈玩家前方 8m（近到爆闪感、又不贴脸
## ——正脚下抬头时十字面片透视极端拉伸）。全套：flash/回击/
## 近雷/bolt/光爆/焦痕
func debug_strike_player() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	flash01 = 1.0
	_flash_pending = _rng.randi_range(1, 2)
	_flash_gap = _rng.randf_range(0.06, 0.16)
	_play_thunder_after(0.15)  # 近雷几乎瞬时
	if _bolt_root == null:
		return
	var pp: Vector3 = _player.global_position
	# 玩家朝向前方 8m（yaw 旋转的 -Z 前向）
	var yaw: float = _player.rotation.y
	_strike_at(pp + Vector3(-sin(yaw) * 8.0, 0.0, -cos(yaw) * 8.0))


## HUD/调试：当前状态名
func state_name() -> String:
	return STATE_NAMES[state]
