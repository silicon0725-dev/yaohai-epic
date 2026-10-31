## 方块注册表校验器：编辑器 Dock 与 headless 测试共用。
## 纯数据进、报告出——不加载项目脚本，测试可注入合成数据
##（tests/test_registry_dock.gd）。
## 三条红线：
##   1) 语义名按注册顺序只增不改（存档按名解析 + 数值 ID 布局冻结；
##      基线清单 id_baseline.json 随 git 提交，是兼容契约本身）
##   2) 图集 COLS 列满员必须扩 ROWS（tile 网格位置派生自 TILES 顺序）
##   3) LIGHT_OPACITY / LIGHT_EMISSION 长度 = 注册数——越界 ID 会静默
##      兜底（阻光按 15 全挡、发光按 0），错表不会报错只会"黑得不对"
extends RefCounted

const LEVEL_ERROR := "error"
const LEVEL_WARN := "warn"
const LEVEL_INFO := "info"
const LEVEL_OK := "ok"


## 校验入口。snapshot 字段（见 snapshot_from）：
##   names           注册顺序的稳定语义名
##   id_consts       voxel_types.gd 脚本常量表（get_script_constant_map）
##   light_opacity   LIGHT_OPACITY 数组（索引 = 数值 ID）
##   light_emission  LIGHT_EMISSION 数组
##   definitions     每个方块的注册定义字典
##   tiles / atlas_cols / atlas_rows / tile_size  图集布局
## baseline_names：已固化基线（空数组 = 尚无基线）。
## 返回 { reports, appended, errors, warnings }；report = {level, code, text}。
static func validate(snapshot: Dictionary, baseline_names: Array) -> Dictionary:
	var reports: Array = []
	var appended: Array = []
	_check_id_order(snapshot, baseline_names, reports, appended)
	_check_id_consts(snapshot, reports)
	_check_atlas(snapshot, reports)
	_check_light(snapshot, reports)
	var errors := 0
	var warnings := 0
	for r in reports:
		if r.level == LEVEL_ERROR:
			errors += 1
		elif r.level == LEVEL_WARN:
			warnings += 1
	return {
		"reports": reports,
		"appended": appended,
		"errors": errors,
		"warnings": warnings,
	}


## 从脚本资源 + 注册表实例拼装校验快照（Dock 与测试共用）。
## types_script / atlas_script 为 load() 出的 GDScript 资源；
## registry 为 build_default_registry() 的返回实例。
static func snapshot_from(
		types_script: Script, atlas_script: Script, registry: RefCounted) -> Dictionary:
	var consts: Dictionary = types_script.get_script_constant_map()
	var atlas_consts: Dictionary = atlas_script.get_script_constant_map()
	var count: int = registry.block_count()
	var names: Array = []
	var definitions: Array = []
	for i in count:
		names.append(registry.name_for_id(i))
		definitions.append(registry.definition_for_id(i))
	return {
		"names": names,
		"definitions": definitions,
		"id_consts": consts,
		"light_opacity": consts.get("LIGHT_OPACITY", []),
		"light_emission": consts.get("LIGHT_EMISSION", []),
		"tiles": atlas_consts.get("TILES", []),
		"atlas_cols": int(atlas_consts.get("COLS", 16)),
		"atlas_rows": int(atlas_consts.get("ROWS", 1)),
		"tile_size": int(atlas_consts.get("TILE_SIZE", 32)),
	}


## 读基线清单（缺失/损坏返回空数组）。
static func load_baseline(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and (parsed as Dictionary).has("names"):
		return (parsed as Dictionary)["names"]
	return []


## 固化基线清单（覆盖写入；JSON 缩进制表符与项目风格一致）。
static func save_baseline(path: String, names: Array) -> bool:
	var data := {
		"version": 1,
		"frozen_at": Time.get_date_string_from_system(),
		"note": "存档兼容红线：稳定名按注册顺序只增不改。由编辑器 Dock 固化，tests/test_registry_dock.gd 同步守护。",
		"names": names,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t") + "\n")
	return true


static func _check_id_order(
		snap: Dictionary, baseline: Array, reports: Array, appended: Array) -> void:
	var names: Array = snap.get("names", [])
	var seen := {}
	for block_name in names:
		if seen.has(block_name):
			_error(reports, "ID_DUPLICATE",
					"重复注册 %s（register_block 会 assert，加载即崩）" % block_name)
		seen[block_name] = true
	if baseline.is_empty():
		_info(reports, "BASELINE_MISSING",
				"尚无基线清单——本次将把全部 %d 个 ID 固化为基线" % names.size())
		appended.append_array(names)
		return
	var before := reports.size()
	var common := mini(names.size(), baseline.size())
	for i in common:
		if names[i] != baseline[i]:
			_error(reports, "ID_REORDERED",
					"槽位 %d：基线 '%s' → 现在 '%s'（存档兼容红线：ID 只能追加，不可重排/改名）"
					% [i, baseline[i], names[i]])
	if baseline.size() > names.size():
		var removed: PackedStringArray = []
		for i in range(names.size(), baseline.size()):
			removed.append(baseline[i])
		_error(reports, "ID_REMOVED",
				"注册数 %d < 基线 %d，疑似删除：%s"
				% [names.size(), baseline.size(), ", ".join(removed)])
	if names.size() > baseline.size():
		for i in range(baseline.size(), names.size()):
			appended.append(names[i])
		_warn(reports, "ID_APPENDED",
				"新增 %d 个 ID（追加合法，点「固化基线」归档）：%s"
				% [appended.size(), ", ".join(PackedStringArray(appended))])
	if reports.size() == before:
		_ok(reports, "ID_BASELINE_OK",
				"ID 顺序与基线一致（%d 个已固化）" % mini(names.size(), baseline.size()))


static func _check_id_consts(snap: Dictionary, reports: Array) -> void:
	var names: Array = snap.get("names", [])
	var id_consts: Dictionary = snap.get("id_consts", {})
	var before := reports.size()
	for i in names.size():
		var block_name := String(names[i])
		# "core:coal_ore" -> "COAL_ORE_ID"（取最后一个 ':' 之后的部分）
		var tail := block_name.get_slice(":", block_name.get_slice_count(":") - 1)
		var const_key := tail.to_upper() + "_ID"
		if not id_consts.has(const_key):
			_error(reports, "ID_CONST_MISSING",
					"常量 %s 缺失（voxel_types.gd 顶部 ID 常量表须与注册顺序一一对应）" % const_key)
		elif int(id_consts[const_key]) != i:
			_error(reports, "ID_CONST_MISMATCH",
					"常量 %s = %d，但 '%s' 的注册序号是 %d"
					% [const_key, int(id_consts[const_key]), block_name, i])
	if reports.size() == before and not names.is_empty():
		_ok(reports, "ID_CONSTS_OK", "ID 常量表与注册顺序一致（%d 个）" % names.size())


static func _check_atlas(snap: Dictionary, reports: Array) -> void:
	var names: Array = snap.get("names", [])
	var definitions: Array = snap.get("definitions", [])
	var tiles: Array = snap.get("tiles", [])
	var cols := int(snap.get("atlas_cols", 16))
	var rows := int(snap.get("atlas_rows", 1))
	var capacity := cols * rows
	var referenced := {}
	for i in mini(definitions.size(), names.size()):
		var textures: Dictionary = definitions[i].get("textures", {})
		for face in textures:
			var tile_name := String(textures[face])
			if not tiles.has(tile_name):
				_error(reports, "TILE_UNKNOWN",
						"%s 的 %s 面引用未登记 tile '%s'（tile_grid 会 assert，进游戏即崩）"
						% [names[i], face, tile_name])
			referenced[tile_name] = true
	for tile_name in tiles:
		if not referenced.has(tile_name):
			_info(reports, "TILE_UNUSED", "tile '%s' 已登记但没有任何方块引用" % tile_name)
	if tiles.size() > capacity:
		_error(reports, "TILE_OVERFLOW",
				"图集 %d 个 tile 超过容量 %d 列 × %d 行 = %d——先扩 ROWS 再加贴图"
				% [tiles.size(), cols, rows, capacity])
	elif tiles.size() == capacity:
		_warn(reports, "TILE_FULL",
				"图集已满（%d 列 × %d 行 = %d tiles）——新增贴图前先扩 ROWS" % [cols, rows, capacity])
	elif capacity - tiles.size() <= 2:
		_info(reports, "TILE_SPACE_LOW",
				"图集余量仅 %d 格（%d/%d，%d 列 × %d 行）——下次贴图前先扩 ROWS"
				% [capacity - tiles.size(), tiles.size(), capacity, cols, rows])
	else:
		_ok(reports, "TILE_SPACE",
				"图集 %d/%d tiles（%d 列 × %d 行，余 %d）"
				% [tiles.size(), capacity, cols, rows, capacity - tiles.size()])


static func _check_light(snap: Dictionary, reports: Array) -> void:
	var names: Array = snap.get("names", [])
	var definitions: Array = snap.get("definitions", [])
	var opacity = snap.get("light_opacity", [])
	var emission = snap.get("light_emission", [])
	var count: int = names.size()
	if opacity.size() != count:
		_error(reports, "OPACITY_LEN",
				"LIGHT_OPACITY 长度 %d ≠ 注册数 %d——越界 ID 静默按 15（全挡）兜底"
				% [opacity.size(), count])
	if emission.size() != count:
		_error(reports, "EMISSION_LEN",
				"LIGHT_EMISSION 长度 %d ≠ 注册数 %d——越界 ID 静默按 0（不发光）兜底"
				% [emission.size(), count])
	var emitters: PackedStringArray = []
	var light_clean := true
	for i in mini(opacity.size(), count):
		var value := int(opacity[i])
		if value < 0 or value > 15:
			_error(reports, "OPACITY_RANGE",
					"LIGHT_OPACITY[%d] = %d 超出 0-15" % [i, value])
			light_clean = false
		var def: Dictionary = definitions[i] if i < definitions.size() else {}
		if value != 0 and String(def.get("render_type", "")) == "none":
			_warn(reports, "OPACITY_GHOST",
					"%s（ID %d）不可见却阻光 %d——空气墙会投下鬼影阴影" % [names[i], i, value])
	for i in mini(emission.size(), count):
		var value := int(emission[i])
		if value < 0 or value > 15:
			_error(reports, "EMISSION_RANGE",
					"LIGHT_EMISSION[%d] = %d 超出 0-15" % [i, value])
			light_clean = false
			continue
		if value > 0:
			emitters.append("%s = %d" % [names[i], value])
			var def: Dictionary = definitions[i] if i < definitions.size() else {}
			if String(def.get("render_type", "")) == "none":
				_warn(reports, "EMISSION_INVISIBLE",
						"%s（ID %d）发光 %d 但 render_type = none——有光无体" % [names[i], i, value])
	if emitters.size() > 0:
		_info(reports, "EMISSION_LIST", "光源方块：%s" % ", ".join(emitters))
	if light_clean and opacity.size() == count and emission.size() == count:
		_ok(reports, "LIGHT_TABLES_OK",
				"LIGHT_OPACITY / LIGHT_EMISSION 长度 = 注册数 %d，数值均在 0-15" % count)


static func _error(reports: Array, code: String, text: String) -> void:
	reports.append({"level": LEVEL_ERROR, "code": code, "text": text})


static func _warn(reports: Array, code: String, text: String) -> void:
	reports.append({"level": LEVEL_WARN, "code": code, "text": text})


static func _info(reports: Array, code: String, text: String) -> void:
	reports.append({"level": LEVEL_INFO, "code": code, "text": text})


static func _ok(reports: Array, code: String, text: String) -> void:
	reports.append({"level": LEVEL_OK, "code": code, "text": text})
