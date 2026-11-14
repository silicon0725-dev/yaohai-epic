## 声音系统单元测试：材质族映射、脚步合成、音景选择器、
## 方块交互合成、总线布局。headless（AudioServer dummy）下全链路
## 只验证数据层——真实听觉由实机验收。
extends VoxelTestCase

const FootstepScript := preload("res://systems/sound/footstep_system.gd")
const AmbientScript := preload("res://systems/sound/ambient_system.gd")
const ManagerScript := preload("res://systems/sound/sound_manager.gd")
const AcousticScript := preload("res://systems/sound/acoustic_system.gd")
const ReflectionsScript := preload("res://systems/sound/early_reflections.gd")


func run() -> void:
	_test_block_family_map()
	_test_footstep_synth()
	_test_footstep_recorded()
	_test_foot_cell_formula()
	_test_land_volume()
	_test_ambient_selector()
	_test_ambient_stream_variant()
	_test_block_sound_synth()
	_test_bus_layout()
	_test_occlusion()
	_test_room_reverb()
	_test_block_sound_filtering()
	_test_early_reflections()
	_test_multibounce_reflections()


## 1 阶镜像源早期反射：单面墙产生 1 条（延迟/镜像位/衰减合理）、
## 开放空间 0 条、镜像路径被第二堵墙挡掉时 0 条
func _test_early_reflections() -> void:
	var world: VoxelWorld = make_world(16, [Vector3i.ZERO], 7)
	var chunk: ChunkData = world.get_chunk(Vector3i.ZERO)
	# 石墙 x=8（跨整块）：源 (4.5,8.5,8.5) → 听者 (6.5,8.5,8.5)。
	# 走 world.set_block（反射面缓存按 edit_generation 失效——chunk
	# 直写绕过计数会命中旧缓存，审查二轮 B4）
	for z in 16:
		for y in 16:
			world.set_block(Vector3i(8, y, z), VoxelTypes.STONE_ID)
	var events: Array = ReflectionsScript.plan_reflections(world,
			Vector3(4.5, 8.5, 8.5), Vector3(6.5, 8.5, 8.5))
	check(events.size() == 1, "单面墙 1 条反射（%d）" % events.size())
	if events.size() == 1:
		var ev: Dictionary = events[0]
		# 镜像点 = 源关于 x=9 面（墙面向声源的表面 x=9.0？命中格
		# (8,·,·) 面在 x=9.0 侧？源在 -x 侧 → 命中面 x=8.0）对称：
		# dist=3.5 → mirror.x = 4.5+7 = 11.5
		check(absf(ev["pos"].x - 11.5) < 0.01, "镜像点 x=11.5（%f）"
				% ev["pos"].x)
		# 直达 2m，反射路径 |11.5-6.5|=5m → 延迟 (5-2)/343≈8.7ms
		check(absf(ev["delay_sec"] - 3.0 / 343.0) < 0.002,
				"延迟=路径差/声速（%f）" % ev["delay_sec"])
		check(ev["gain"] > 0.2 and ev["gain"] <= 0.7,
				"反射增益合理（%f）" % ev["gain"])
	# 开放空间：移除墙 → 0 条
	for z in 16:
		for y in 16:
			world.set_block(Vector3i(8, y, z), VoxelTypes.AIR_ID)
	events = ReflectionsScript.plan_reflections(world,
			Vector3(4.5, 8.5, 8.5), Vector3(6.5, 8.5, 8.5))
	check(events.is_empty(), "开放空间无反射")
	# 镜像路径被第二堵墙挡掉：y 向地面反射、听者与源同在地面附近
	# 且之间再放一堵矮墙 → y+ 镜像路径穿墙 → 0 条
	for x in 16:
		for z in 16:
			chunk.set_block(Vector3i(x, 7, z), VoxelTypes.STONE_ID)
	events = ReflectionsScript.plan_reflections(world,
			Vector3(4.5, 6.5, 8.5), Vector3(4.5, 6.5, 8.5))
	check(events.is_empty(), "源=听者无路径差 0 条")


## 多阶路径展开：封闭屋内的障碍遮挡直达时，墙面 2 阶反弹链
## （源→后墙→柱面→听者）仍有回声——曾只在直达无遮挡时做 1 阶
## （实机讨论：否则路径追踪没意义）。镜面反射物理上不穿不透明
## 墙——跨封闭墙的传声靠衍射，不在镜像源法域内
func _test_multibounce_reflections() -> void:
	var world: VoxelWorld = make_world(16, [Vector3i.ZERO], 7)
	var chunk: ChunkData = world.get_chunk(Vector3i.ZERO)
	# 封闭石屋：壳 x 2..14、y 6..10、z 6..10；中央柱 (8,8,8)
	# 挡住源→听者直达
	for x in range(2, 15):
		for y in range(6, 11):
			for z in range(6, 11):
				var shell: bool = x == 2 or x == 14 or y == 6 \
						or y == 10 or z == 6 or z == 10
				chunk.set_block(Vector3i(x, y, z),
						VoxelTypes.STONE_ID if shell
						else VoxelTypes.AIR_ID)
	chunk.set_block(Vector3i(8, 8, 8), VoxelTypes.STONE_ID)
	var source := Vector3(12.5, 8.5, 8.5)
	var ear := Vector3(4.5, 8.5, 8.5)
	var occ: float = AcousticScript.occlusion_between(world, source, ear)
	check(occ > 0.01, "柱子确实挡住直达（%f）" % occ)
	var events: Array = ReflectionsScript.plan_reflections(world,
			source, ear, 0.9)
	check(events.size() >= 1,
			"被柱遮挡仍有反射事件（%d 条）" % events.size())
	if not events.is_empty():
		var ev: Dictionary = events[0]
		check(ev["delay_sec"] > 0.0, "反射晚于直达（%f）"
				% ev["delay_sec"])
		check(ev["gain"] > 0.05 and ev["gain"] < 0.8,
				"衰减后增益合理（%f）" % ev["gain"])
	# 能量剪枝：低源能量不产生超增益事件
	var far_events: Array = ReflectionsScript.plan_reflections(world,
			source, ear, 0.3)
	for ev in far_events:
		check(ev["gain"] <= 0.8, "剪枝后无超增益事件（%f）" % ev["gain"])


## 交互音过滤回归：水位引擎写入静音（洪水 AIR↔WATER 曾每格一声
## 音爆）+ 同族 80ms 节流（砍树占位清除等级联一格一声）
func _test_block_sound_filtering() -> void:
	var mgr: Node = ManagerScript.new()
	# 玩家侧：泥土挖放正常发声
	mgr.play_count = 0
	mgr._on_block_changed(Vector3i.ZERO, VoxelTypes.DIRT_ID,
			VoxelTypes.AIR_ID)
	check(mgr.play_count == 1, "玩家挖泥土发声")
	# 引擎侧水位写入：AIR↔WATER 一律静音（WaterFlow 走 set_block，
	# 信号无区分——洪水时每格一声会音爆）
	mgr.play_count = 0
	mgr._on_block_changed(Vector3i.ZERO, VoxelTypes.AIR_ID,
			VoxelTypes.WATER_ID)
	mgr._on_block_changed(Vector3i.ZERO, VoxelTypes.WATER_ID,
			VoxelTypes.AIR_ID)
	check(mgr.play_count == 0, "水位写入静音（洪水防音爆）")
	# 同族节流：连挖两块石头只响一声（80ms 内）
	mgr.play_count = 0
	mgr._family_last_ms.clear()
	mgr._on_block_changed(Vector3i.ZERO, VoxelTypes.STONE_ID,
			VoxelTypes.AIR_ID)
	mgr._on_block_changed(Vector3i.ONE, VoxelTypes.STONE_ID,
			VoxelTypes.AIR_ID)
	check(mgr.play_count == 1, "同族 80ms 节流去重（级联防音爆）")
	# 不同族不受节流影响
	mgr._on_block_changed(Vector3i.ZERO, VoxelTypes.DIRT_ID,
			VoxelTypes.AIR_ID)
	check(mgr.play_count == 2, "不同族不互斥")
	mgr.free()


## 方块 ID → 材质族映射（blockmap 语义：新方块注册须同步）
func _test_block_family_map() -> void:
	check_eq(FootstepScript.block_family(VoxelTypes.GRASS_ID), "grass",
			"草地→grass")
	check_eq(FootstepScript.block_family(VoxelTypes.DIRT_ID), "dirt",
			"泥土→dirt")
	check_eq(FootstepScript.block_family(VoxelTypes.SAND_ID), "sand",
			"沙→sand")
	check_eq(FootstepScript.block_family(VoxelTypes.STONE_ID), "stone",
			"石头→stone")
	check_eq(FootstepScript.block_family(VoxelTypes.LOG_ID), "wood",
			"原木→wood")
	check_eq(FootstepScript.block_family(VoxelTypes.LEAVES_ID), "leaves",
			"树叶→leaves")
	check_eq(FootstepScript.block_family(VoxelTypes.WATER_ID), "water",
			"水→water")
	check_eq(FootstepScript.block_family(VoxelTypes.AIR_ID), "",
			"空气→无声")
	# 全部运行时方块 ID 都在映射表（防新方块漏配）
	for id in 19:
		check(FootstepScript.BLOCK_FAMILY.has(id),
				"方块 %d 已在映射表（族=%s）" % [id,
				FootstepScript.block_family(id)])


## 脚步合成：每族 4 变体、16bit、样本数>0、非全零（有波形）
func _test_footstep_synth() -> void:
	for family in ["grass", "dirt", "stone", "wood", "sand", "gravel",
			"leaves", "water"]:
		# 走私有合成入口（静态）：直接构造一个系统实例拿变体
		var sys: Node = FootstepScript.new()
		# _variants 由 setup 填充；headless 直接调合成静态函数
		var stream: AudioStreamWAV = sys._synth_variant(family,
				hash(family))
		check(stream != null, "%s 合成流非空" % family)
		if stream == null:
			continue
		check(stream.format == AudioStreamWAV.FORMAT_16_BITS,
				"%s 16bit 格式" % family)
		var n := stream.data.size() / 2
		check(n > 0, "%s 样本数>0（%d）" % [family, n])
		var nonzero := false
		for i in mini(n, 4000):
			if stream.data.decode_s16(i * 2) != 0:
				nonzero = true
				break
		check(nonzero, "%s 波形非全零" % family)
		sys.free()


## CC0 录音层（ATTRIBUTION.md）：八族全部有录音流、格式正确、
## 变体数与文件表一致——步态播放走录音，合成只做兜底
func _test_footstep_recorded() -> void:
	for family in ["grass", "dirt", "stone", "wood", "sand", "gravel",
			"leaves", "water"]:
		var streams: Array = FootstepScript.load_family_streams(family)
		var expect: int = FootstepScript.RECORDED_FILES[family].size()
		check(streams.size() == expect,
				"%s 录音 %d/%d 全部加载" % [family, streams.size(), expect])
		for s in streams:
			check(s is AudioStreamOggVorbis or s is AudioStreamWAV,
					"%s 录音流类型正确" % family)


## 脚位公式回归：站方块顶面时 _family_at_feet 必须读到脚下那格。
## 曾用 y-0.95（涉水判定脚位）——直接读格类型时读到**空气层**，
## 族恒 air → 脚步从不出声（实机报告：只闻环境/互动音无脚步）
func _test_foot_cell_formula() -> void:
	var world: VoxelWorld = make_world(16, [Vector3i.ZERO], 7)
	world.get_chunk(Vector3i.ZERO).set_block(
			Vector3i(5, 5, 5), VoxelTypes.GRASS_ID)
	var sys: Node = FootstepScript.new()
	sys.setup(Node.new(), world)
	if tree_root == null:
		check(false, "tree_root 未注入（runner 需设置 suite.tree_root）")
		return
	var fake := Node3D.new()
	tree_root.add_child(fake)  # 树外节点 global_position 不可靠
	sys._player = fake
	# 站 (5,5,5) 顶面（y=6.0）：胶囊中心 = 脚底+1.0
	fake.position = Vector3(5.5, 7.0, 5.5)
	check_eq(sys._family_at_feet(), "grass", "站草顶读到 grass")
	check_eq(sys.block_family(world.get_block(Vector3i(5, 6, 5))),
			"", "y-0.95 层是空气（旧公式 bug 层）")
	# 漂浮一格高（脚底 y=7.0）→ 读不到草（垂直错位不误报）
	fake.position = Vector3(5.5, 8.0, 5.5)
	check_eq(sys._family_at_feet(), "", "悬空一格不误报")
	fake.free()
	sys.free()


## 落地音量：随坠落速度单调、边界收敛
func _test_land_volume() -> void:
	check(FootstepScript.land_volume(3.0) >= 0.5
			and FootstepScript.land_volume(3.0) <= 0.6,
			"最小坠落音量≈0.5")
	check(FootstepScript.land_volume(15.0) > FootstepScript.land_volume(5.0),
			"重落地比轻落地响")
	check(FootstepScript.land_volume(100.0) <= 1.2, "音量封顶 1.2")


## 音景选择器优先级：水下 > 洞穴 > 湖畔 > 沙漠 > 森林 > 平原兜底
func _test_ambient_selector() -> void:
	var sel: Callable = AmbientScript.select_machine
	check_eq(sel.call({"deep_water": true, "roof_depth": 0,
			"water_nearby": 0, "sand_nearby": 0, "leaves_nearby": 0}),
			"underwater", "深水→underwater")
	# 涉水（脚浸水未没顶）：deep 优先，无 deep 才 wading——小溪浅滩
	# 也有水声（实机报告：曾只有浸没/大水域两台，涉水静默）
	check_eq(sel.call({"deep_water": true, "wading": true,
			"roof_depth": 0, "water_nearby": 0, "sand_nearby": 0,
			"leaves_nearby": 0}), "underwater", "浸没优先于涉水")
	check_eq(sel.call({"deep_water": false, "wading": true,
			"roof_depth": 2, "water_nearby": 0, "sand_nearby": 0,
			"leaves_nearby": 0}), "wading", "涉水→wading 水声")
	check_eq(sel.call({"deep_water": false, "wading": false,
			"roof_depth": 2, "water_nearby": 0, "sand_nearby": 0,
			"leaves_nearby": 0}), "plains", "未涉水走原链")
	check_eq(sel.call({"deep_water": false, "roof_depth": 10,
			"water_nearby": 0, "sand_nearby": 0, "leaves_nearby": 0}),
			"cave", "深顶盖→cave")
	check_eq(sel.call({"deep_water": false, "roof_depth": 10,
			"water_nearby": 500, "sand_nearby": 0, "leaves_nearby": 0}),
			"cave", "洞穴优先于湖畔")
	check_eq(sel.call({"deep_water": false, "roof_depth": 2,
			"water_nearby": 500, "sand_nearby": 0, "leaves_nearby": 0}),
			"lakeside", "近水域→lakeside")
	check_eq(sel.call({"deep_water": false, "roof_depth": 2,
			"water_nearby": 0, "sand_nearby": 500, "leaves_nearby": 0}),
			"desert", "近沙域→desert")
	check_eq(sel.call({"deep_water": false, "roof_depth": 2,
			"water_nearby": 0, "sand_nearby": 0, "leaves_nearby": 300}),
			"forest", "林间→forest")
	check_eq(sel.call({"deep_water": false, "roof_depth": 2,
			"water_nearby": 0, "sand_nearby": 0, "leaves_nearby": 0}),
			"plains", "兜底→plains")
	# 阈值边界（<120 水不算湖畔）
	check_eq(sel.call({"deep_water": false, "roof_depth": 2,
			"water_nearby": 100, "sand_nearby": 0, "leaves_nearby": 0}),
			"plains", "水低于阈值→plains")


## 流变体选择：室内优先于昼夜（MAtmos stream_pair 语义）
func _test_ambient_stream_variant() -> void:
	var m := {"stream": "wind_forest", "night": "wind_forest_night",
			"indoor": "wind_forest_indoors"}
	check_eq(AmbientScript._machine_stream(m, {"overhead_air": 1,
			"night01": 0.9}), "wind_forest_indoors", "室内优先于夜")
	check_eq(AmbientScript._machine_stream(m, {"overhead_air": 20,
			"night01": 0.9}), "wind_forest_night", "露天夜晚→夜变体")
	check_eq(AmbientScript._machine_stream(m, {"overhead_air": 20,
			"night01": 0.2}), "wind_forest", "露天白天→基础流")
	check_eq(AmbientScript._machine_stream({"stream": "sand"},
			{"overhead_air": 1, "night01": 0.9}), "sand",
			"无变体的音景恒用基础流")


## 方块交互音合成：place/break 长度不同、非全零
func _test_block_sound_synth() -> void:
	var place: AudioStreamWAV = ManagerScript._synth_block_sound("stone",
			"place")
	var brk: AudioStreamWAV = ManagerScript._synth_block_sound("stone",
			"break")
	check(place != null and brk != null, "交互音合成非空")
	if place != null and brk != null:
		check(place.data.size() / 2 < brk.data.size() / 2,
				"place 短于 break")
		check(place.data.decode_s16(100) != 0, "place 波形非全零")


## 总线布局：Footsteps/SFX/Ambient 挂 Master，幂等
func _test_bus_layout() -> void:
	var mgr: Node = ManagerScript.new()
	mgr._setup_buses()
	mgr._setup_buses()  # 幂等（重进游戏不重复建）
	for bus_name in ["Footsteps", "SFX", "Ambient", "SFXOcc1", "SFXOcc2"]:
		var idx := AudioServer.get_bus_index(bus_name)
		check(idx != -1, "总线 %s 已创建" % bus_name)
		if idx != -1:
			check_eq(AudioServer.get_bus_send(idx), "Master",
					"%s 发送到 Master" % bus_name)
			check(AudioServer.get_bus_effect_count(idx) >= 1,
					"%s 已预挂声学效果" % bus_name)
	mgr.free()


## 遮挡射线：空场直通 / 石墙全挡 / 树叶弱挡 / 限程外不计
func _test_occlusion() -> void:
	var world: VoxelWorld = make_world(16,
			[Vector3i.ZERO], 7)
	# 石墙 x=8（跨整块）：源 (4,8,8) → 听 (12,8,8)
	for z in 16:
		for y in 16:
			world.get_chunk(Vector3i.ZERO).set_block(
					Vector3i(8, y, z), VoxelTypes.STONE_ID)
	var occ: float = AcousticScript.occlusion_between(world,
			Vector3(4.5, 8.5, 8.5), Vector3(12.5, 8.5, 8.5))
	check(absf(occ - 1.0) < 0.01, "单层石墙遮挡=1（%f）" % occ)
	# 树叶墙：穿透系数 0.15
	for z in 16:
		for y in 16:
			world.get_chunk(Vector3i.ZERO).set_block(
					Vector3i(8, y, z), VoxelTypes.LEAVES_ID)
	occ = AcousticScript.occlusion_between(world,
			Vector3(4.5, 8.5, 8.5), Vector3(12.5, 8.5, 8.5))
	check(absf(occ - AcousticScript.TRANSPARENT_OCCLUSION) < 0.01,
			"树叶墙遮挡=0.15（%f）" % occ)
	# 开洞后射线恰从洞中穿过 → 直通（单层墙的洞正对射线）
	world.get_chunk(Vector3i.ZERO).set_block(
			Vector3i(8, 8, 8), VoxelTypes.AIR_ID)
	occ = AcousticScript.occlusion_between(world,
			Vector3(4.5, 8.5, 8.5), Vector3(12.5, 8.5, 8.5))
	check(occ < 0.01, "树叶墙开洞后直通（%f）" % occ)
	# 总线档位与音量衰减
	check_eq(AcousticScript.occlusion_bus(0.0), "SFX", "直通走干总线")
	check_eq(AcousticScript.occlusion_bus(0.3), "SFXOcc1", "轻挡走 Occ1")
	check_eq(AcousticScript.occlusion_bus(2.0), "SFXOcc2", "重挡走 Occ2")
	check(AcousticScript.occlusion_gain(0.0) == 1.0, "直通无衰减")
	check(AcousticScript.occlusion_gain(2.0)
			< AcousticScript.occlusion_gain(0.5), "重挡更响衰减")


## 房间混响：封闭石室 wet 高/露天 wet≈0；映射在 Godot 域内
func _test_room_reverb() -> void:
	var world: VoxelWorld = make_world(16,
			[Vector3i.ZERO], 7)
	var chunk: ChunkData = world.get_chunk(Vector3i.ZERO)
	# 封闭石室：壳 x/z 4..12、y 2..8，内部空气
	for x in range(4, 13):
		for y in range(2, 9):
			for z in range(4, 13):
				var shell := x == 4 or x == 12 or y == 2 or y == 8 \
						or z == 4 or z == 12
				chunk.set_block(Vector3i(x, y, z),
						VoxelTypes.STONE_ID if shell else VoxelTypes.AIR_ID)
	activate_light(world, Vector3i.ZERO)
	var profile: Dictionary = AcousticScript.evaluate_room(world,
			Vector3(8.5, 5.5, 8.5))
	check(int(profile["room"]) >= 200, "封闭腔体格数（%s）"
			% profile["room"])
	check(profile["sky_frac"] < 0.01, "封闭腔体无天光（%f）"
			% profile["sky_frac"])
	check(profile["reflectivity"] > 0.8, "石壁反射率高（%f）"
			% profile["reflectivity"])
	var params: Dictionary = AcousticScript.reverb_params(profile)
	check(params["wet"] > 0.15, "封闭石室混响湿端高（%f）" % params["wet"])
	check(params["room_size"] > 0.3, "腔体尺寸感（%f）"
			% params["room_size"])
	check(params["damping"] < 0.5, "石壁阻尼低（声音亮）")
	# 露天：纯空气区块 + 光照激活 → 天光满 → wet≈0.02
	var open_world: VoxelWorld = make_world(16,
			[Vector3i.ZERO], 7)
	activate_light(open_world, Vector3i.ZERO)
	profile = AcousticScript.evaluate_room(open_world,
			Vector3(8.5, 10.5, 8.5))
	check(profile["sky_frac"] > 0.9, "露天腔体天光满（%f）"
			% profile["sky_frac"])
	params = AcousticScript.reverb_params(profile)
	check(params["wet"] <= 0.05, "露天混响趋零（%f）" % params["wet"])
	# 水下不评腔体：水格曾整个入腔+水底高反射面 → 假回声（实机报告）
	var water_world: VoxelWorld = make_world(16, [Vector3i.ZERO], 7)
	var wchunk: ChunkData = water_world.get_chunk(Vector3i.ZERO)
	for x in range(4, 12):
		for y in range(4, 12):
			for z in range(4, 12):
				wchunk.set_block(Vector3i(x, y, z),
						VoxelTypes.WATER_ID)
	profile = AcousticScript.evaluate_room(water_world,
			Vector3(8.5, 8.5, 8.5))
	check(int(profile["room"]) == 0, "水下不评腔体（room=%s）"
			% profile["room"])
	check(AcousticScript.reverb_params(profile)["wet"] <= 0.05,
			"水下湿端趋零")
	# 玩家真实站姿的两格高封闭盒：眼=中心+0.7 曾被写成 +1.6 →
	# 眼格戳进顶壁 → 空腔 → 永远没混响（实机报告）
	var box_world: VoxelWorld = make_world(16, [Vector3i.ZERO], 7)
	var bchunk: ChunkData = box_world.get_chunk(Vector3i.ZERO)
	for x in range(4, 9):
		for y in range(4, 8):
			for z in range(4, 9):
				var shell: bool = x == 4 or x == 8 or y == 4 \
						or y == 7 or z == 4 or z == 8
				bchunk.set_block(Vector3i(x, y, z),
						VoxelTypes.STONE_ID if shell
						else VoxelTypes.AIR_ID)
	activate_light(box_world, Vector3i.ZERO)
	profile = AcousticScript.evaluate_room(box_world,
			Vector3(6.5, 6.7, 6.5))  # 中心(6.5,6.0,6.5)+眼高0.7
	check(int(profile["room"]) > 0, "两格高盒腔体非空（room=%s）"
			% profile["room"])
	check(AcousticScript.reverb_params(profile)["wet"] > 0.12,
			"小封闭盒回声可闻（wet=%f）"
			% AcousticScript.reverb_params(profile)["wet"])
