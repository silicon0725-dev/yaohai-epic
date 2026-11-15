## 群系批 1 测试：判定纯函数全分支、column_profile 集成、
## TreeScatter 温度噪声同源同步（红线守卫）、天气雨量缩放。
extends VoxelTestCase

const WeatherScript := preload("res://systems/weather/weather_system.gd")
const TreeScatterScript := preload("res://systems/trees/tree_scatter.gd")


func run() -> void:
	if tree_root == null:
		check(false, "tree_root 未注入")
		return
	_test_biome_for_table()
	_test_profile_biome_field()
	_test_tree_scatter_temp_sync()
	_test_rain_scale()


## 判定优先级：裸岩峰 > 寒原 > 荒漠 > 密林 > 平原
func _test_biome_for_table() -> void:
	var B = TerrainGenerator.Biome
	check_eq(TerrainGenerator.biome_for(
			-0.9, 0.8, true, false), B.ALPINE, "裸岩峰优先于一切")
	check_eq(TerrainGenerator.biome_for(
			-0.9, 0.8, false, false), B.SNOWY, "寒极=寒原（湿度无关）")
	check_eq(TerrainGenerator.biome_for(
			0.5, -0.5, false, true), B.DESERT, "荒漠判定传入")
	check_eq(TerrainGenerator.biome_for(
			-0.34, 0.8, false, false), B.FOREST, "冷边缘+湿=密林")
	check_eq(TerrainGenerator.biome_for(
			0.1, 0.2, false, false), B.PLAINS, "温带常态=平原")
	# 寒极优先于荒漠（复合条件的荒漠在冷区不成立，但直传时守序）
	check_eq(TerrainGenerator.biome_for(
			-0.5, -0.5, false, true), B.SNOWY, "寒原优先于荒漠")


## column_profile 集成：biome 字段在枚举值域内、大范围采样五档
## 都能出现（阈值合理性——覆盖率探针的轻量版）
func _test_profile_biome_field() -> void:
	var cfg := WorldConfig.new()
	cfg.world_seed = 42
	var gen := TerrainGenerator.new(cfg)
	var counts := {}
	var valid := true
	for wz in range(-512, 512, 32):
		for wx in range(-512, 512, 32):
			var b: int = gen.column_profile(wx, wz)["biome"]
			if b < 0 or b > TerrainGenerator.Biome.ALPINE:
				valid = false
			counts[b] = counts.get(b, 0) + 1
	check(valid, "biome 字段全部在枚举域内")
	check_eq(counts.size(), 5, "1024 列采样五档群系齐现（%d）"
			% counts.size())
	check(gen.biome_at(0, 0) == gen.column_profile(0, 0)["biome"],
			"biome_at 与 profile 一致")


## 同源红线：TreeScatter._temp 与 generator._temp_noise 同 seed
## 构造必须逐位同值（两侧参数改动必须同步——对拍先例）
func _test_tree_scatter_temp_sync() -> void:
	var cfg := WorldConfig.new()
	cfg.world_seed = 7
	var gen := TerrainGenerator.new(cfg)
	TreeScatterScript.configure(7)
	check(TreeScatterScript._temp_ready, "温度噪声已配置")
	var all_eq := true
	for i in 64:
		var x := (i * 137) % 997 - 498
		var z := (i * 311) % 997 - 498
		if absf(TreeScatterScript._temp.get_noise_2d(x, z)
				- gen._temp_noise.get_noise_2d(x, z)) > 0.000001:
			all_eq = false
			break
	check(all_eq, "温度噪声 64 点逐位同值（同源红线）")


## 天气雨量缩放：rain01 = rain_intensity × scale；音频/粒子目标压低
func _test_rain_scale() -> void:
	var w: Node = WeatherScript.new()
	tree_root.add_child(w)
	w.rain_intensity = 0.8
	w.set_rain_scale(0.05)
	check(absf(w.rain01() - 0.04) < 0.001, "rain01 乘群系缩放")
	w.set_rain_scale(1.0)
	check(absf(w.rain01() - 0.8) < 0.001, "常群系不衰减")
	# 音频目标随有效雨强压低（荒漠静音）
	w._rain_player.volume_db = -60.0
	w.set_rain_scale(0.0)
	w._update_rain_audio(1.0)
	check(w._rain_player.volume_db < -50.0,
			"荒漠雨声归静（%.1f dB）" % w._rain_player.volume_db)
	w.free()
