## 声音系统单元测试：材质族映射、脚步合成、音景选择器、
## 方块交互合成、总线布局。headless（AudioServer dummy）下全链路
## 只验证数据层——真实听觉由实机验收。
extends VoxelTestCase

const FootstepScript := preload("res://systems/sound/footstep_system.gd")
const AmbientScript := preload("res://systems/sound/ambient_system.gd")
const ManagerScript := preload("res://systems/sound/sound_manager.gd")


func run() -> void:
	_test_block_family_map()
	_test_footstep_synth()
	_test_land_volume()
	_test_ambient_selector()
	_test_ambient_stream_variant()
	_test_block_sound_synth()
	_test_bus_layout()


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
	for bus_name in ["Footsteps", "SFX", "Ambient"]:
		var idx := AudioServer.get_bus_index(bus_name)
		check(idx != -1, "总线 %s 已创建" % bus_name)
		if idx != -1:
			check_eq(AudioServer.get_bus_send(idx), "Master",
					"%s 发送到 Master" % bus_name)
	mgr.free()
