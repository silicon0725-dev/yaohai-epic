## 图集预览纯数据层：tile 引用图 / PNG 来源状态 / 校验报告过滤。
## 与 UI 解离，headless 测试直调（tests/test_atlas_preview.gd）。
extends RefCounted

const ValidatorScript := preload("res://addons/voxel_registry_dock/registry_validator.gd")


## tile 名 -> [{block, face}]：被哪些方块的哪些面引用。
static func build_tile_usage(registry) -> Dictionary:
	var usage := {}
	var count: int = registry.block_count()
	for i in count:
		var def: Dictionary = registry.definition_for_id(i)
		var textures: Dictionary = def.get("textures", {})
		var block_name: String = registry.name_for_id(i)
		for face in textures:
			var tile := String(textures[face])
			if not usage.has(tile):
				usage[tile] = []
			usage[tile].append({"block": block_name, "face": String(face)})
	return usage


## tile 名 -> 是否有真实材质包 PNG（false = 程序化占位）。
static func packed_status(tiles: Array, pack_dir: String) -> Dictionary:
	var out := {}
	for tile in tiles:
		var path := pack_dir + "/" + String(tile) + ".png"
		out[String(tile)] = FileAccess.file_exists(path) or ResourceLoader.exists(path)
	return out


## 下一个新 tile 的落点下标；图集已满返回 -1。
static func next_free_index(tiles: Array, cols: int, rows: int) -> int:
	if tiles.size() >= cols * rows:
		return -1
	return tiles.size()


## 复用注册表校验器，只取图集相关报告（TILE_* 代码）。
static func atlas_reports(snapshot: Dictionary) -> Array:
	var result: Dictionary = ValidatorScript.validate(snapshot, [])
	var out: Array = []
	for r in result.get("reports", []):
		if String(r.get("code", "")).begins_with("TILE_"):
			out.append(r)
	return out
