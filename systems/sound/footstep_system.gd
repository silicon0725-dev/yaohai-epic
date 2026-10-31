## 脚步声系统：方块材质族 → 程序化合成音变体随机播放。
## 架构学习自 Presence Footsteps（blockmap→材质族→acoustics 规则→
## 随机变体+音量/音高抖动）；其 ogg 素材为 PolyForm Shield 许可
## （Noncompete 条款）不可随游戏分发——第一版改为程序化合成
## （噪声脉冲+包络+滤波特征，每族 4 变体），后续可换 CC0 录音。
## 步态：水平步距累计触发（楼梯/冲刺自然变频），落地按坠落速度
## 加响。纯数据部分（族映射/步距判定）静态可测。
class_name FootstepSystem
extends Node

## 声音管理器（setup 注入，避免 preload 环）
var _manager: Node

## 步距（米）：走/冲刺；水体步距更长（涉水拖沓）
const STRIDE_WALK := 1.9
const STRIDE_SPRINT := 2.4
const STRIDE_WADE := 2.6
## 落地最小坠落速度（m/s）——低于此不发声（小台阶/贴地抖动）
const LAND_MIN_FALL := 3.0

## 方块 ID → 材质族（Presence Footsteps blockmap 的缩略版——
## 我们方块集小，直接表驱动；新方块注册时同步此表）
const BLOCK_FAMILY := {
	0: "",  # air
	1: "grass", 2: "dirt", 3: "stone", 4: "stone",
	5: "wood", 6: "wood", 7: "stone", 8: "stone",
	9: "sand", 10: "stone", 11: "gravel",
	12: "stone", 13: "stone",
	14: "water", 15: "leaves", 16: "leaves",
	17: "wood", 18: "wood",
}

## 录音素材（CC0，见 assets/sounds/footsteps/ATTRIBUTION.md）：
## 族 → 文件名表。步态播放优先录音，缺失族回退程序化合成。
## water 族录音（splash）只做入水/出水溅泼——涉水脚步短促，用合成。
const RECORDED_DIR := "res://assets/sounds/footsteps/"
const RECORDED_FILES := {
	"grass": ["grass_01.ogg", "grass_02.ogg", "grass_03.ogg",
			"grass_04.ogg"],
	"dirt": ["dirt_01.ogg"],
	"stone": ["stone_01.ogg", "stone_f01.ogg", "stone_f02.ogg",
			"stone_f03.ogg", "stone_f04.ogg", "stone_f05.ogg",
			"stone_f06.ogg"],
	"wood": ["wood_01.ogg", "wood_02.ogg", "wood_03.ogg"],
	"sand": ["sand_01.ogg", "sand_02.ogg", "sand_03.ogg", "sand_04.ogg",
			"sand_05.ogg", "sand_06.ogg"],
	"gravel": ["gravel_01.ogg"],
	"leaves": ["leaves_01.ogg", "leaves_02.ogg"],
	"water": ["splash_01.wav", "splash_02.wav"],
}

## 步态变体（录音优先，合成兜底；water 恒用合成）
var _variants := {}
## 溅泼变体（water 族录音，入水/出水事件用）
var _splash_variants: Array = []
var _player: Node  # PlayerController
var _world: VoxelWorld
var _stride_acc := 0.0
var _was_on_floor := true
var _prev_fall_speed := 0.0
var _wading := false
var _was_wading := false
## 音量倍率（main 注入：潜行/静音等）
var volume_scale := 1.0


func setup(p_manager: Node, p_world: VoxelWorld) -> void:
	_manager = p_manager
	_world = p_world
	for family in ["grass", "dirt", "stone", "wood", "sand",
			"gravel", "leaves", "water"]:
		# 录音优先（CC0）；合成兜底。water 的录音（splash）留给
		# 溅泼事件，涉水脚步用合成（录音 2s+ 太长）
		var recorded := load_family_streams(family)
		if family == "water":
			_splash_variants = recorded
			_variants[family] = _synth_family(family)
		elif recorded.is_empty():
			_variants[family] = _synth_family(family)
		else:
			_variants[family] = recorded


## 玩家在 main 加载流程后段才创建，单独挂接
func set_player(p_player: Node) -> void:
	_player = p_player


func _physics_process(_delta: float) -> void:
	if _player == null or _world == null or not is_instance_valid(_player):
		return
	var on_floor: bool = _player.is_on_floor()
	var vel: Vector3 = _player.velocity
	# 落地检测（坠落速度取离地前的最大值）
	if on_floor and not _was_on_floor:
		var impact := -_prev_fall_speed
		if impact >= LAND_MIN_FALL:
			_play_step(land_volume(impact))
		_stride_acc = 0.0
	if on_floor:
		_prev_fall_speed = 0.0
	else:
		_prev_fall_speed = minf(_prev_fall_speed, vel.y)
	_was_on_floor = on_floor
	if not on_floor:
		return
	# 涉水判定（与 player_controller 同式：浸深 > 0.1）
	var feet_cell := Vector3i(floori(_player.global_position.x),
			floori(_player.global_position.y - 0.95),
			floori(_player.global_position.z))
	_wading = WaterFlow.water_surface_at(_world, feet_cell) \
			- (_player.global_position.y - 1.0) > 0.1
	# 入水/出水溅泼（边沿触发；SFX 总线比脚步响一档）——CC0 录音
	# splash，缺失回退合成 water 变体
	if _wading != _was_wading:
		var splashes: Array = _splash_variants if not _splash_variants.is_empty() \
				else _variants["water"]
		_manager.play_2d(splashes.pick_random(), 1.3 * volume_scale,
				randf_range(0.9, 1.1), "SFX")
	_was_wading = _wading
	# 步距累计（水平速度）
	var horizontal := Vector2(vel.x, vel.z).length()
	if horizontal < 0.5:
		_stride_acc = 0.0
		return
	var sprint: bool = horizontal > 5.5
	var stride := STRIDE_WADE if _wading else (
			STRIDE_SPRINT if sprint else STRIDE_WALK)
	_stride_acc += horizontal * _delta
	if _stride_acc >= stride:
		_stride_acc = 0.0
		_play_step(1.0)


func _play_step(volume: float) -> void:
	var family := _family_at_feet()
	if family == "" or volume <= 0.0:
		return
	var streams: Array = _variants.get(family, [])
	if streams.is_empty():
		return
	# 稀缺族（录音变体 ≤2）加大音高抖动弥补变化感
	var pitch_span := 0.06 if streams.size() > 2 else 0.12
	_manager.play_2d(streams.pick_random(), volume * volume_scale,
			randf_range(1.0 - pitch_span, 1.0 + pitch_span), "Footsteps")


## 脚下方块材质族；涉水时水声优先（splash 掩盖底部材质）
func _family_at_feet() -> String:
	if _wading:
		return "water"
	var cell := Vector3i(floori(_player.global_position.x),
			floori(_player.global_position.y - 0.95),
			floori(_player.global_position.z))
	return block_family(_world.get_block(cell))


static func block_family(block_id: int) -> String:
	return BLOCK_FAMILY.get(block_id, "")


## 落地音量：坠落速度 3→15 m/s 映射 0.5→1.2
static func land_volume(fall_speed: float) -> float:
	return clampf(0.5 + (fall_speed - LAND_MIN_FALL) / 12.0 * 0.7,
			0.5, 1.2)


## 族录音流加载（CC0 文件，见 assets/sounds/footsteps/
## ATTRIBUTION.md）：ogg 字节加载绕 .import、wav 同理；缺失/损坏
## 返回空数组（调用方回退合成）。静态可测。
static func load_family_streams(family: String) -> Array:
	var out := []
	for file_name: String in RECORDED_FILES.get(family, []):
		var path := RECORDED_DIR + family + "/" + file_name
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			push_warning("脚步录音缺失: " + path)
			continue
		if file_name.ends_with(".ogg"):
			var ogg := AudioStreamOggVorbis.load_from_buffer(bytes)
			if ogg != null:
				out.append(ogg)
		elif file_name.ends_with(".wav"):
			var wav := AudioStreamWAV.load_from_file(path)
			if wav != null:
				out.append(wav)
	return out


# ---- 程序化合成（22050Hz 16bit 单声道短样本，启动时一次） ----

const SAMPLE_RATE := 22050
const VARIANTS_PER_FAMILY := 4

## 每族 4 变体：族特征（一阶低通状态 + 包络 + 音体）× 确定性种子
static func _synth_family(family: String) -> Array:
	var out := []
	for v in VARIANTS_PER_FAMILY:
		out.append(_synth_variant(family, hash(family) + v * 7919))
	return out


static func _synth_variant(family: String, seed_v: int) -> AudioStreamWAV:
	var dur := _family_duration(family)
	var n := int(dur * SAMPLE_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng_state := seed_v
	var lp := 0.0
	for i in n:
		var t := float(i) / SAMPLE_RATE
		rng_state = _next_rand(rng_state)
		var white := _rand01(rng_state) * 2.0 - 1.0
		lp += (white - lp) * _family_lp(family)
		var s := _family_shape(family, t, dur, white, lp, rng_state)
		s = clampf(s, -1.0, 1.0)
		# 尾部 3ms 淡出防爆音
		var tail := dur - t
		if tail < 0.003:
			s *= tail / 0.003
		data.encode_s16(i * 2, int(s * 30000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	return stream


static func _family_duration(family: String) -> float:
	match family:
		"stone":
			return 0.11
		"wood":
			return 0.16
		"water":
			return 0.22
		"sand":
			return 0.19
		"gravel":
			return 0.18
		_:
			return 0.15


## 一阶低通系数（越小越暗）
static func _family_lp(family: String) -> float:
	match family:
		"dirt":
			return 0.16
		"sand":
			return 0.30
		"grass":
			return 0.45
		"water":
			return 0.40
		"leaves":
			return 0.9
		_:
			return 0.5


## 族特征波形（lp=滤波后噪声，white=原始噪声，rng_state=确定性随流）
static func _family_shape(family: String, t: float, dur: float,
		white: float, lp: float, rng_state: int) -> float:
	match family:
		"grass":
			# 宽带软沙沙 + 叶片回弹脉冲（55ms 处二次沙沙）
			var env := exp(-t * 46.0)
			var rustle := 0.0
			if t > 0.055:
				rustle = exp(-(t - 0.055) * 30.0) * lp * 0.5
			return (lp * env * 0.85 + rustle) * 1.1
		"dirt":
			# 中频闷响
			return (lp * exp(-t * 40.0) * 0.8
					+ sin(t * TAU * 130.0) * exp(-t * 60.0) * 0.25)
		"stone":
			# 硬 click + 低频体
			return (white * exp(-t * 220.0) * 0.9
					+ sin(t * TAU * 165.0) * exp(-t * 70.0) * 0.5)
		"wood":
			# 250Hz 共振 + 击打瞬态
			return (sin(t * TAU * 250.0) * exp(-t * 34.0) * 0.85
					+ white * exp(-t * 260.0) * 0.4)
		"sand":
			# 长颗粒沙沙：60Hz 幅度调制
			var grain := 0.6 + 0.4 * sin(t * TAU * 60.0 + lp * 6.28)
			return lp * exp(-t * 22.0) * grain * 1.0
		"gravel":
			# 随机石子碰撞群：5 个短 click
			var s := 0.0
			for k in 5:
				var t0 := _rand01(rng_state + k * 131) * dur * 0.5
				if t >= t0 and t < t0 + 0.03:
					s += white * exp(-(t - t0) * 160.0)
			return s * 0.7
		"leaves":
			# 高频脆沙沙（几乎不滤）
			return white * exp(-t * 50.0) * 0.7
		"water":
			# 溅泼：滤波噪声 + 下滑音体
			var env := exp(-t * 26.0)
			var pitch := 900.0 - 500.0 * t / dur
			return (lp * env * 0.9
					+ sin(t * TAU * pitch) * env * 0.15)
	return 0.0


## xorshift 确定性随机（变体可复现——测试锁定样本长度非零即可）
static func _next_rand(s: int) -> int:
	s = (s ^ (s << 13)) & 0x7FFFFFFF
	s = (s ^ (s >> 17)) & 0x7FFFFFFF
	return (s ^ (s << 5)) & 0x7FFFFFFF


static func _rand01(s: int) -> float:
	return float(s % 100000) / 100000.0
