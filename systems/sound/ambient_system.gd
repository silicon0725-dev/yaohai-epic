## 环境音景系统：体素扫描条件 → 音景机选择 → 循环流交叉淡入。
## 架构学习自 MAtmos（条件 sheet 体素统计 → set 组合 → machine 的
## outdoor/indoor stream_pair + fadein/fadeout）；音频素材为 MAtmos
## 2020 Zen 声音包（CC0，见 assets/sounds/ambient/SOUND_LICENSES.md）。
## 露天度用头顶直射扫描（raycast spaciousness 的简化），近域统计
## 水/沙/叶（scan_small 的简化）。评估每秒一次 + 条件稳定 2 拍才
## 切换（洞口抖动防闪烁）；夜蟋蟀为独立第二层。
## 纯数据部分（选择器）静态可测。
class_name AmbientSystem
extends Node

const AMBIENT_DIR := "res://assets/sounds/ambient/loop/"
## 条件扫描半径（近域统计单层 25×25）
const SCAN_RADIUS := 12
## 露天判定：头顶到障碍的空格数下限
const OUTDOOR_AIR_MIN := 5
## 洞穴判定：头顶覆盖深度
const CAVE_DEPTH_MIN := 7
## 评估周期（秒）与切换稳定拍数
const EVAL_PERIOD := 1.0
const STABLE_TICKS := 2
## 交叉淡入时长（秒）
const FADE_TIME := 3.0
## 流响度补偿（dB）：原始素材流间响度差 24dB（cave_a -12dB、
## sand/waves -35dB）——cave_a 的 vorbis 重编码会崩（libsndfile
## native），离线归一不可行改播放端补偿；目标把极值拉回 -20/-28
const STREAM_GAIN_DB := {
	"cave_a": -8.0,
	"sand": 8.0,
	"waves_medium": 7.0,
}

## 音景机表（优先级从高到低，首个满足者生效；night/indoor 为可选
## 变体流名——MAtmos stream_pair 语义）。cond 字段：
## deep_water / roof_depth_min / water_nearby_min / sand_nearby_min /
## leaves_nearby_min（缺省条件恒真——兜底 plains）
const MACHINES := [
	{"name": "underwater", "cond": {"deep_water": true},
		"stream": "underwater_direct", "fade": 1.5},
	# 涉水（脚部浸水未没顶）也有水声——曾只有浸没/大水域两台，
	# 小溪浅滩涉水静默（实机报告）。快淡入淡出贴合进出水
	{"name": "wading", "cond": {"wading": true},
		"stream": "water_medium", "fade": 1.5},
	{"name": "cave", "cond": {"roof_depth_min": CAVE_DEPTH_MIN},
		"stream": "cave_a", "fade": 3.0},
	{"name": "lakeside", "cond": {"water_nearby_min": 120},
		"stream": "waves_medium", "fade": 3.0},
	{"name": "desert", "cond": {"sand_nearby_min": 150},
		"stream": "sand", "fade": 3.0},
	{"name": "forest", "cond": {"leaves_nearby_min": 90},
		"stream": "wind_forest", "night": "wind_forest_night",
		"indoor": "wind_forest_indoors", "fade": 3.0},
	{"name": "plains", "cond": {},
		"stream": "wind_novege", "night": "wind_novege_night",
		"indoor": "wind_novege_indoors", "fade": 3.0},
]

var _player: Node
var _world: VoxelWorld
## 昼夜系数（main 注入：0 夜 1 昼）——夜晚变体流 + 蟋蟀层
var _day01 := 1.0
var _eval_acc := 0.0
var _candidate := ""
var _last_ctx := {}  # 1Hz 扫描缓存（蟋蟀层等低频判断复用）
var _candidate_ticks := 0
var _current_machine := ""
## 交叉淡入双播放器（A/B 互为进出）
var _players: Array[AudioStreamPlayer] = []
var _active := 0
var _fade := -1.0  # <0 无过渡；>=0 过渡进行中
## 蟋蟀层（夜晚露天专属）
var _crickets: AudioStreamPlayer
var _cricket_got := false
## 音频流缓存（ogg 运行时字节加载，无 .import 依赖）
var _streams := {}


func setup(p_world: VoxelWorld) -> void:
	_world = p_world


## 玩家在 main 加载流程后段才创建，单独挂接
func set_player(p_player: Node) -> void:
	_player = p_player
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = "Ambient"
		add_child(p)
		_players.append(p)
	_crickets = AudioStreamPlayer.new()
	_crickets.bus = "Ambient"
	add_child(_crickets)


## main._update_day_night 每帧下发
func set_day01(v: float) -> void:
	_day01 = v


func _process(delta: float) -> void:
	_eval_acc += delta
	if _eval_acc >= EVAL_PERIOD:
		_eval_acc = 0.0
		_evaluate()
	_tick_fade(delta)
	_tick_crickets(delta)


## 条件评估 + 稳定拍去抖（洞口/屋檐下移动防闪烁）
func _evaluate() -> void:
	if _player == null or _world == null:
		return
	var ctx := _scan()
	_last_ctx = ctx
	var machine := select_machine(ctx)
	if machine == _current_machine:
		_candidate_ticks = 0
		return
	if machine == _candidate:
		_candidate_ticks += 1
	else:
		_candidate = machine
		_candidate_ticks = 1
	if _candidate_ticks >= STABLE_TICKS:
		_current_machine = machine
		_candidate_ticks = 0
		_start_crossfade(machine, ctx)


## 交叉淡入：非活跃播放器起新流，双端对拉音量（目标电平带流响度
## 补偿——原始素材流间差 24dB）
func _start_crossfade(machine_name: String, ctx: Dictionary) -> void:
	var machine := _machine_by_name(machine_name)
	if machine.is_empty():
		return
	var stream_name := _machine_stream(machine, ctx)
	var stream := _load_stream(stream_name)
	if stream == null:
		return
	var nxt := _players[1 - _active]
	var cur := _players[_active]
	nxt.stream = stream
	nxt.volume_db = -60.0
	nxt.play()
	_active = 1 - _active
	_fade = 0.0
	# 淡入时长取音景机配置；目标电平 = 基准 + 流补偿
	set_meta("fade_time", float(machine.get("fade", 3.0)))
	set_meta("gain_db", float(STREAM_GAIN_DB.get(stream_name, 0.0)))


func _tick_fade(delta: float) -> void:
	if _fade < 0.0:
		return
	_fade += delta
	var total: float = get_meta("fade_time", 3.0)
	var target_db: float = -9.0 + float(get_meta("gain_db", 0.0))
	var k := clampf(_fade / total, 0.0, 1.0)
	var nxt := _players[_active]
	var cur := _players[1 - _active]
	nxt.volume_db = lerpf(-60.0, target_db, k)
	cur.volume_db = lerpf(target_db, -60.0, k)
	if k >= 1.0:
		cur.stop()
		_fade = -1.0


## 夜蟋蟀层：夜晚（day01<0.3）+ 露天 + 非洞穴/水下音景时淡入。
## 用 1Hz 缓存上下文（逐帧 _scan 625 次查询不可接受）
func _tick_crickets(delta: float) -> void:
	if _last_ctx.is_empty():
		return
	var ctx: Dictionary = _last_ctx
	var want: bool = _day01 < 0.3 \
			and ctx["overhead_air"] >= OUTDOOR_AIR_MIN \
			and not ctx["deep_water"] \
			and ctx["roof_depth"] < CAVE_DEPTH_MIN \
			and _current_machine != "cave" \
			and _current_machine != "underwater"
	if want and not _cricket_got:
		var stream := _load_stream("cricketz_night")
		if stream != null:
			_crickets.stream = stream
			_crickets.volume_db = -60.0  # 淡入起点（默认 0dB 会爆）
			_crickets.play()
			_cricket_got = true
	if _cricket_got:
		# 音量跟随条件平滑（避免硬切）
		var target := -14.0 if want else -60.0
		_crickets.volume_db = move_toward(_crickets.volume_db, target,
				delta * 12.0)
		if not want and _crickets.volume_db <= -59.0:
			_crickets.stop()
			_cricket_got = false


# ---- 扫描（数据层，可测） ----

## 玩家周围体素统计：露天度/顶盖深度/深水/近域水沙叶计数
func _scan() -> Dictionary:
	var pc: Vector3i = Vector3i(floori(_player.global_position.x),
			floori(_player.global_position.y),
			floori(_player.global_position.z))
	# 头顶扫描：到障碍空格数 + 覆盖深度（到世界顶或 32 格封顶）
	var overhead := 0
	var y := pc.y + 1
	while y < pc.y + 32:
		if _is_solid(pc.x, y, pc.z):
			break
		overhead += 1
		y += 1
	var roof_depth := y - pc.y - overhead - 1
	var deep_water := _is_water(pc + Vector3i(0, 1, 0)) \
			and _is_water(pc + Vector3i(0, 2, 0))
	# 涉水：脚部浸深 > 0.1（与 footstep_system 同式——脚位 y-0.95
	# 配 water_surface_at 向上扫）
	var feet_y: float = _player.global_position.y - 1.0
	var feet_cell := Vector3i(floori(_player.global_position.x),
			floori(feet_y + 0.05), floori(_player.global_position.z))
	var wading: bool = WaterFlow.water_surface_at(_world, feet_cell) \
			- feet_y > 0.1
	var water := 0
	var sand := 0
	var leaves := 0
	for dz in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
		for dx in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
			var b := _world.get_block(Vector3i(pc.x + dx, pc.y, pc.z + dz))
			if b == 14:
				water += 1
			elif b == 9:
				sand += 1
			elif b == 16:
				leaves += 1
	return {
		"overhead_air": overhead,
		"roof_depth": roof_depth,
		"deep_water": deep_water,
		"wading": wading,
		"water_nearby": water,
		"sand_nearby": sand,
		"leaves_nearby": leaves,
		"night01": 1.0 - _day01,
	}


func _is_solid(x: int, y: int, z: int) -> bool:
	var b := _world.get_block(Vector3i(x, y, z))
	# 空气/水/细枝/树叶不挡音景天空（树叶下算林间不算洞）
	return b != 0 and b != 14 and b != 15 and b != 16


func _is_water(cell: Vector3i) -> bool:
	return _world.get_block(cell) == 14


# ---- 选择器（纯函数，静态可测） ----

static func select_machine(ctx: Dictionary) -> String:
	for m in MACHINES:
		if _cond_met(m["cond"], ctx):
			return m["name"]
	return "plains"


## 条件键 → 上下文键（显式映射——replace 拼 key 曾得出
## "water_nearby_nearby" 双后缀键）
const COND_TO_CTX := {
	"roof_depth_min": "roof_depth",
	"water_nearby_min": "water_nearby",
	"sand_nearby_min": "sand_nearby",
	"leaves_nearby_min": "leaves_nearby",
}


static func _cond_met(cond: Dictionary, ctx: Dictionary) -> bool:
	if cond.is_empty():
		return true
	if cond.get("deep_water", false) and not ctx["deep_water"]:
		return false
	if cond.get("wading", false) and not ctx.get("wading", false):
		return false
	for key in COND_TO_CTX:
		if cond.has(key) and int(ctx[COND_TO_CTX[key]]) < int(cond[key]):
			return false
	return true


## 流变体选择：室内（露天不足）优先于昼夜变体——MAtmos
## outdoor/indoor stream_pair 语义
static func _machine_stream(machine: Dictionary, ctx: Dictionary) -> String:
	if ctx["overhead_air"] < OUTDOOR_AIR_MIN and machine.has("indoor"):
		return machine["indoor"]
	if float(ctx.get("night01", 0.0)) > 0.5 and machine.has("night"):
		return machine["night"]
	return machine["stream"]


static func _machine_by_name(machine_name: String) -> Dictionary:
	for m in MACHINES:
		if m["name"] == machine_name:
			return m
	return {}


## ogg 运行时字节加载（AudioStreamOggVorbis.load_from_buffer）——
## 绕开 .import 依赖（本机禁 --import 纪律），结果缓存
func _load_stream(stream_name: String) -> AudioStreamOggVorbis:
	if _streams.has(stream_name):
		return _streams[stream_name]
	var path := AMBIENT_DIR + stream_name + ".ogg"
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_warning("环境音缺失: " + path)
		_streams[stream_name] = null
		return null
	var stream := AudioStreamOggVorbis.load_from_buffer(bytes)
	if stream != null:
		stream.loop = true
	_streams[stream_name] = stream
	return stream
