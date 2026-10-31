## 图集预览插件数据层测试：tile 引用图、PNG 来源探测、
## 空闲落点计算、校验报告过滤。
extends VoxelTestCase

const Model := preload("res://addons/atlas_preview_dock/atlas_preview_model.gd")
const VoxelTypesScript := preload("res://core/voxel_types.gd")
const AtlasScript := preload("res://presentation/texture_atlas_loader.gd")


func run() -> void:
	_test_tile_usage_real_registry()
	_test_next_free()
	_test_packed_status()
	_test_atlas_reports()


func _test_tile_usage_real_registry() -> void:
	var registry = VoxelTypesScript.build_default_registry()
	var usage: Dictionary = Model.build_tile_usage(registry)
	check(usage.has("grass_top"), "grass_top 有引用记录")
	var grass_top: Array = usage["grass_top"]
	check_eq(grass_top.size(), 1, "grass_top 仅被 core:grass 顶面引用")
	if grass_top.size() == 1:
		check_eq(String(grass_top[0]["block"]), "core:grass", "grass_top 引用方块名")
		check_eq(String(grass_top[0]["face"]), "top", "grass_top 引用面")
	# dirt：core:dirt 三面 + core:grass 底面 = 4
	check_eq((usage["dirt"] as Array).size(), 4, "dirt 被 4 个面引用")
	# torch：core:torch 三面
	var torch: Array = usage["torch"]
	check_eq(torch.size(), 3, "torch 被 3 个面引用")
	var blocks: PackedStringArray = []
	for u in torch:
		blocks.append(String(u["block"]))
	check_eq(blocks, PackedStringArray(["core:torch", "core:torch", "core:torch"]),
			"torch 引用都来自 core:torch")
	# 所有 TILES 至少被引用（当前注册表无冗余 tile）
	for tile in AtlasScript.TILES:
		check(usage.has(String(tile)), "tile %s 被引用" % tile)


func _test_next_free() -> void:
	var tiles: Array = []
	for i in 17:
		tiles.append("t%d" % i)
	check_eq(Model.next_free_index(tiles, 16, 2), 17, "17 个 tile 时下个落点是 17")
	tiles.resize(32)
	check_eq(Model.next_free_index(tiles, 16, 2), -1, "图集满员无落点（-1）")


func _test_packed_status() -> void:
	# 造一张真实 PNG 探测存在性（user:// 下确定性）
	var img := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	check(img.save_png("user://li_atlas_probe.png") == Error.OK, "测试 PNG 写入")
	var status: Dictionary = Model.packed_status(["li_atlas_probe", "no_such_tile"], "user://")
	check_eq(bool(status["li_atlas_probe"]), true, "存在的 PNG 探测为真实")
	check_eq(bool(status["no_such_tile"]), false, "缺失 PNG 探测为占位")
	DirAccess.remove_absolute("user://li_atlas_probe.png")


func _test_atlas_reports() -> void:
	# 未登记 tile 引用被过滤出来
	var snap := {
		"names": ["b1"],
		"definitions": [{"id": "b1", "render_type": "opaque",
				"textures": {"side": "nope"}}],
		"tiles": ["stone", "dust"],
		"atlas_cols": 16, "atlas_rows": 2, "tile_size": 32,
		"light_opacity": [0], "light_emission": [0], "id_consts": {},
	}
	var codes: PackedStringArray = []
	for r in Model.atlas_reports(snap):
		codes.append(String(r["code"]))
	check(codes.has("TILE_UNKNOWN"), "过滤出未登记 tile 引用")
	check(codes.has("TILE_UNUSED"), "过滤出闲置 tile")
	check(codes.has("TILE_SPACE"), "过滤出容量报告")
	check(not codes.has("OPACITY_LEN"), "不夹带光照报告")
