## 声音管理器：AudioServer 总线布局 + 播放器池 + 方块交互音。
## 总线结构（运行时代码创建，无 default_bus_layout 资源依赖）：
##   Master ─ Footsteps（脚步）
##          ─ SFX（放置/破坏等交互）
##          ─ Ambient（环境音景）
## 方块交互音挂 world.block_changed（与 tree_manager/voxel_light
## 同模式）；放置=短闷击、破坏=碎裂（按材质族程序化合成，与脚步
## 共用合成管线）。headless（AudioServer dummy）下全链路不报错。
class_name SoundManager
extends Node

const FootstepSystemScript := preload("res://systems/sound/footstep_system.gd")
const AmbientSystemScript := preload("res://systems/sound/ambient_system.gd")

## 各总线默认音量（dB）
const BUS_VOLUME := {
	"Footsteps": -6.0,
	"SFX": -4.0,
	"Ambient": -6.0,
}
## 播放器池大小（2D 一次性音效并发上限）
const POOL_SIZE := 8

var footstep: Node  # FootstepSystem
var ambient: Node  # AmbientSystem
var _world: VoxelWorld
var _registry: VoxelRegistry
var _pool: Array[AudioStreamPlayer] = []
var _pool_idx := 0
## 方块放置/破坏合成音缓存：family -> {place: stream, break: stream}
var _block_sounds := {}


func setup(p_world: VoxelWorld, p_registry: VoxelRegistry) -> void:
	_world = p_world
	_registry = p_registry
	_setup_buses()
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)
	footstep = FootstepSystemScript.new()
	add_child(footstep)
	footstep.setup(self, p_world)
	ambient = AmbientSystemScript.new()
	add_child(ambient)
	ambient.setup(p_world)
	# 方块交互音：block_changed 信号驱动（old/new 语义见
	# tree_manager 同模式）
	if _world != null:
		_world.block_changed.connect(_on_block_changed)


## 玩家在 main 加载流程后段才创建（脚步/音景都要跟随它）
func attach_player(p_player: Node) -> void:
	footstep.set_player(p_player)
	ambient.set_player(p_player)


func set_day01(v: float) -> void:
	if ambient != null:
		ambient.set_day01(v)


## 运行时建总线（幂等——重进游戏不重复加）
func _setup_buses() -> void:
	for bus_name in BUS_VOLUME:
		if AudioServer.get_bus_index(bus_name) == -1:
			var idx := AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
			AudioServer.set_bus_volume_db(idx, BUS_VOLUME[bus_name])


## 2D 一次性音效（脚步/UI）：从池取用（轮转，挤掉最旧）
func play_2d(stream: AudioStream, volume: float, pitch: float,
		bus: String) -> void:
	if stream == null:
		return
	var p := _pool[_pool_idx]
	_pool_idx = (_pool_idx + 1) % POOL_SIZE
	p.bus = bus
	p.stream = stream
	p.volume_db = linear_to_db(clampf(volume, 0.0, 1.0))
	p.pitch_scale = pitch
	p.play()


## 3D 定位一次性音效（方块交互）：播放器播放完自动释放
func play_3d(stream: AudioStream, pos: Vector3, volume: float,
		pitch: float) -> void:
	if stream == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.bus = "SFX"
	p.stream = stream
	p.volume_db = linear_to_db(clampf(volume, 0.0, 1.0))
	p.pitch_scale = pitch
	p.max_distance = 24.0
	add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


# ---- 方块交互音（MAtmos sfx_database 的 onplace/onbreak 语义） ----

func _on_block_changed(pos: Vector3i, old_id: int, new_id: int) -> void:
	# 水位等引擎侧写入（set_block_state/水位降级 set_block(false)）
	# 不发声——只响应玩家可见的增删（.air↔实体）
	if (old_id == 0) == (new_id == 0):
		return
	var center := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	if new_id == 0:
		play_3d(_family_stream(old_id, "break"), center, 0.9,
				randf_range(0.92, 1.08))
	else:
		play_3d(_family_stream(new_id, "place"), center, 0.8,
				randf_range(0.92, 1.08))


## 家族放置/破坏音（懒合成缓存）：place=短闷击（family 特征低频体）、
## break=碎裂（噪声簇更长）
func _family_stream(block_id: int, kind: String) -> AudioStream:
	var family: String = FootstepSystemScript.block_family(block_id)
	if family == "":
		return null
	if not _block_sounds.has(family):
		_block_sounds[family] = {}
	var cache: Dictionary = _block_sounds[family]
	if cache.has(kind):
		return cache[kind]
	var stream := _synth_block_sound(family, kind)
	cache[kind] = stream
	return stream


## 方块交互合成：短促版脚步（闷击 90ms / 碎裂 200ms）
static func _synth_block_sound(family: String, kind: String) -> AudioStreamWAV:
	var dur := 0.09 if kind == "place" else 0.2
	var sample_rate := 22050
	var n := int(dur * sample_rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng_state := hash(family + kind)
	var lp := 0.0
	for i in n:
		var t := float(i) / sample_rate
		rng_state = (rng_state * 1103515245 + 12345) & 0x7FFFFFFF
		var white := float(rng_state % 65536) / 32768.0 - 1.0
		lp += (white - lp) * 0.3
		var env := exp(-t * (60.0 if kind == "place" else 18.0))
		var body := sin(t * TAU * (170.0 if kind == "place" else 90.0)) \
				* exp(-t * 50.0) * 0.4
		var s := clampf((lp * env * 0.9 + body), -1.0, 1.0)
		var tail := dur - t
		if tail < 0.003:
			s *= tail / 0.003
		data.encode_s16(i * 2, int(s * 30000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
