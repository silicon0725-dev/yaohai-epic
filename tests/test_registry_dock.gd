## 注册表 Dock 校验器测试：合成数据覆盖各红线分支，
## 另加一条真实注册表 vs 已固化基线的红线集成检查（CI 同样拦截重排）。
extends VoxelTestCase

const ValidatorScript := preload("res://addons/voxel_registry_dock/registry_validator.gd")
const VoxelTypesScript := preload("res://core/voxel_types.gd")
const AtlasScript := preload("res://presentation/texture_atlas_loader.gd")
const BASELINE_PATH := "res://addons/voxel_registry_dock/id_baseline.json"


func run() -> void:
	_test_real_registry_baseline()
	_test_append_only()
	_test_id_consts()
	_test_atlas()
	_test_light_tables()


## 合成快照工厂：默认每名一块 opaque 定义 + 自洽的常量表/光照表
##（否则被测分支之外的检查也报错，无法隔离断言）。
## overrides 深合并覆盖字段。
func _snap(names: Array, overrides: Dictionary = {}) -> Dictionary:
	var snap := {
		"names": names,
		"id_consts": {},
		"light_opacity": [],
		"light_emission": [],
		"definitions": [],
		"tiles": [],
		"atlas_cols": 16,
		"atlas_rows": 2,
		"tile_size": 32,
	}
	for i in names.size():
		var block_name := String(names[i])
		var tail := block_name.get_slice(":", block_name.get_slice_count(":") - 1)
		snap["id_consts"][tail.to_upper() + "_ID"] = i
		snap["light_opacity"].append(0)
		snap["light_emission"].append(0)
		snap["definitions"].append({"id": names[i], "render_type": "opaque", "textures": {}})
	snap.merge(overrides, true)
	return snap


func _codes(result: Dictionary) -> PackedStringArray:
	var codes: PackedStringArray = []
	for r in result.get("reports", []):
		codes.append(String(r.get("code", "")))
	return codes


func _has_code(result: Dictionary, code: String) -> bool:
	return _codes(result).has(code)


func _test_real_registry_baseline() -> void:
	var registry = VoxelTypesScript.build_default_registry()
	var snap: Dictionary = ValidatorScript.snapshot_from(
			VoxelTypesScript, AtlasScript, registry)
	check_eq(snap["names"][0], "core:air", "真实注册表：air 恒为 ID 0")
	var baseline: Array = ValidatorScript.load_baseline(BASELINE_PATH)
	check(baseline.size() > 0, "基线清单存在且非空")
	var result: Dictionary = ValidatorScript.validate(snap, baseline)
	check_eq(result["errors"], 0,
			"真实注册表过全部校验 errors=0 — %s" % " ".join(_codes(result)))
	check_eq(result["warnings"], 0, "真实注册表无警告（无待固化新增）")
	check((result["appended"] as Array).is_empty(), "无未固化新增 ID")
	check_eq(
			(snap["names"] as Array).slice(0, baseline.size()), baseline,
			"基线与注册表前缀逐项一致")


func _test_append_only() -> void:
	var baseline := ["a", "b"]

	# 合法追加：只警告 + 待固化清单
	var result := ValidatorScript.validate(_snap(["a", "b", "c"]), baseline)
	check_eq(result["errors"], 0, "合法追加无错误")
	check_eq(result["warnings"], 1, "合法追加产生一条待固化警告")
	check_eq(result["appended"], ["c"], "待固化清单识别新 ID")

	# 中段改名/重排：红线报错
	result = ValidatorScript.validate(_snap(["a", "c", "b"]), baseline)
	check(_has_code(result, "ID_REORDERED"), "中段重排被拦截")

	# 删除方块：红线报错
	result = ValidatorScript.validate(_snap(["a"]), baseline)
	check(_has_code(result, "ID_REMOVED"), "删除已有方块被拦截")

	# 重复注册
	result = ValidatorScript.validate(_snap(["a", "b", "a"]), baseline)
	check(_has_code(result, "ID_DUPLICATE"), "重复注册被拦截")

	# 无基线：全部视为待固化
	result = ValidatorScript.validate(_snap(["a", "b"]), [])
	check(_has_code(result, "BASELINE_MISSING"), "无基线给出提示")
	check_eq(result["appended"], ["a", "b"], "无基线时全部 ID 待固化")

	# 完全一致：ok 报告
	result = ValidatorScript.validate(_snap(["a", "b"]), baseline)
	check(_has_code(result, "ID_BASELINE_OK"), "顺序一致给出 ok 报告")
	check_eq(result["errors"], 0, "顺序一致无错误")


func _test_id_consts() -> void:
	var snap := _snap(["core:air", "core:grass"])
	snap["id_consts"] = {"AIR_ID": 0, "GRASS_ID": 1}
	var result := ValidatorScript.validate(snap, [])
	check(_has_code(result, "ID_CONSTS_OK"), "常量表一致给出 ok 报告")

	snap["id_consts"] = {"GRASS_ID": 0}
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "ID_CONST_MISSING"), "缺失常量被拦截")
	check(_has_code(result, "ID_CONST_MISMATCH"), "常量值与注册序号不符被拦截")

	# 多词名派生：core:coal_ore -> COAL_ORE_ID
	snap = _snap(["core:air", "core:coal_ore"])
	snap["id_consts"] = {"AIR_ID": 0, "COAL_ORE_ID": 1}
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "ID_CONSTS_OK"), "下划线多词名派生常量键")


func _test_atlas() -> void:
	# 未登记 tile 引用（运行时 assert 的前置拦截）
	var snap := _snap(["b1"], {
		"definitions": [{"id": "b1", "render_type": "opaque",
				"textures": {"side": "nope"}}],
		"tiles": ["stone"],
	})
	var result := ValidatorScript.validate(snap, [])
	check(_has_code(result, "TILE_UNKNOWN"), "未登记 tile 引用被拦截")

	# 已登记但闲置
	snap = _snap(["b1"], {"tiles": ["stone", "dust"]})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "TILE_UNUSED"), "闲置 tile 提示")

	# 满员：提醒扩 ROWS
	var tiles_32: Array = []
	for i in 32:
		tiles_32.append("t%d" % i)
	snap = _snap(["b1"], {"tiles": tiles_32})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "TILE_FULL"), "图集 16 列满员提醒扩 ROWS")
	check_eq(result["errors"], 0, "满员只是提醒不是错误")

	# 超员：报错
	tiles_32.append("t32")
	result = ValidatorScript.validate(_snap(["b1"], {"tiles": tiles_32}), [])
	check(_has_code(result, "TILE_OVERFLOW"), "图集超员报错")

	# 余量告急
	var tiles_30: Array = tiles_32.slice(0, 30)
	result = ValidatorScript.validate(_snap(["b1"], {"tiles": tiles_30}), [])
	check(_has_code(result, "TILE_SPACE_LOW"), "图集余量 ≤2 提前提醒")

	# 正常余量
	result = ValidatorScript.validate(_snap(["b1"], {"tiles": ["stone"]}), [])
	check(_has_code(result, "TILE_SPACE"), "图集余量正常给出 ok 报告")


func _test_light_tables() -> void:
	# 对齐 + 范围正常，且列出光源
	var snap := _snap(["a", "b", "c"], {
		"light_opacity": [0, 15, 15],
		"light_emission": [0, 0, 14],
	})
	var result := ValidatorScript.validate(snap, [])
	check(_has_code(result, "LIGHT_TABLES_OK"), "光照表对齐给出 ok 报告")
	check(_has_code(result, "EMISSION_LIST"), "光源方块列出（c = 14）")

	# 长度不齐：报错并说明静默兜底方向
	snap = _snap(["a", "b", "c"], {"light_opacity": [0, 15]})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "OPACITY_LEN"), "LIGHT_OPACITY 长度不齐被拦截")
	snap = _snap(["a", "b", "c"], {"light_emission": [0, 0]})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "EMISSION_LEN"), "LIGHT_EMISSION 长度不齐被拦截")

	# 越界值
	snap = _snap(["a", "b"], {"light_opacity": [0, 16], "light_emission": [0, -1]})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "OPACITY_RANGE"), "阻光超 15 被拦截")
	check(_has_code(result, "EMISSION_RANGE"), "发光负值被拦截")

	# 不可见却阻光 / 发光但无几何
	snap = _snap(["ghost", "laser"], {
		"definitions": [
			{"id": "ghost", "render_type": "none", "textures": {}},
			{"id": "laser", "render_type": "none", "textures": {}},
		],
		"light_opacity": [15, 0],
		"light_emission": [0, 14],
	})
	result = ValidatorScript.validate(snap, [])
	check(_has_code(result, "OPACITY_GHOST"), "不可见方块阻光被警告")
	check(_has_code(result, "EMISSION_INVISIBLE"), "无几何方块发光被警告")
