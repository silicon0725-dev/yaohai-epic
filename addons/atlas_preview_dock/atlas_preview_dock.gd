@tool
## 图集布局预览 Dock：TextureAtlasLoader 程序化图集的可视化。
## 16×N 真实布局 + 每格 tile 名/坐标/引用数 + 空闲落点高亮（防错位）
## + 容量/未引用/未登记引用告警（复用注册表校验器 TILE_* 报告）。
## 数据每次从磁盘 load() 重读；保存 atlas/voxel_types 或重导贴图后
## 自动刷新（文件系统信号去抖 0.4 秒）。
extends Control

const ATLAS_PATH := "res://presentation/texture_atlas_loader.gd"
const VOXEL_TYPES_PATH := "res://core/voxel_types.gd"
const ValidatorScript := preload("res://addons/voxel_registry_dock/registry_validator.gd")
const Model := preload("res://addons/atlas_preview_dock/atlas_preview_model.gd")
const GridViewScript := preload("res://addons/atlas_preview_dock/atlas_grid_view.gd")

const HEX_MUTED := "9aa0a6"
const HEX_WARN := "ffcc59"
const HEX_OK := "94e58c"
const HEX_ERR := "ff6a61"
const HEX_INFO := "8cbaff"

var _info: Label
var _warnings: RichTextLabel
var _grid: Control
var _detail: RichTextLabel
var _refresh_timer: Timer

var _last_tiles: Array = []
var _last_usage: Dictionary = {}
var _last_packed: Dictionary = {}
var _last_cols := 16
var _selected := -1


func _ready() -> void:
	custom_minimum_size = Vector2(520, 0)
	_build_ui()
	_connect_filesystem()
	_refresh()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "图集布局"
	title.add_theme_font_size_override("font_size", 15)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_info = Label.new()
	_info.add_theme_color_override("font_color", Color(HEX_MUTED))
	header.add_child(_info)
	var refresh_button := Button.new()
	refresh_button.text = "刷新"
	refresh_button.pressed.connect(_refresh)
	header.add_child(refresh_button)
	root.add_child(header)

	_warnings = RichTextLabel.new()
	_warnings.bbcode_enabled = true
	_warnings.fit_content = true
	_warnings.selection_enabled = true
	root.add_child(_warnings)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_grid = GridViewScript.new()
	_grid.cell_selected.connect(_on_cell_selected)
	scroll.add_child(_grid)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	_detail.selection_enabled = true
	_detail.custom_minimum_size = Vector2(0, 96)
	root.add_child(_detail)


func _connect_filesystem() -> void:
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = 0.4
	_refresh_timer.timeout.connect(_refresh)
	add_child(_refresh_timer)
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.filesystem_changed.connect(_on_filesystem_changed)


func _on_filesystem_changed() -> void:
	_refresh_timer.start()


func _refresh() -> void:
	var atlas_script: Script = load(ATLAS_PATH)
	var types_script: Script = load(VOXEL_TYPES_PATH)
	if atlas_script == null or types_script == null \
			or not atlas_script.can_instantiate() or not types_script.can_instantiate():
		_show_fatal("无法加载 texture_atlas_loader.gd / voxel_types.gd——脚本存在编译错误或缺 @tool？")
		return
	var atlas_inst = atlas_script.new()
	var types_inst = types_script.new()
	if not atlas_inst.has_method("generate_atlas_image") \
			or not types_inst.has_method("build_default_registry"):
		_show_fatal("脚本缺少 generate_atlas_image() / build_default_registry()——接口被改动？")
		return
	var image: Image = atlas_inst.generate_atlas_image()
	if image == null:
		_show_fatal("generate_atlas_image() 返回空——检查 atlas 加载器。")
		return
	var atlas_tex := ImageTexture.create_from_image(image)
	var consts: Dictionary = atlas_script.get_script_constant_map()
	var tiles: Array = consts.get("TILES", [])
	var cols := int(consts.get("COLS", 16))
	var rows := int(consts.get("ROWS", 1))
	var tile_size := int(consts.get("TILE_SIZE", 32))
	var pack_dir := String(consts.get("TEXTURE_PACK_DIR", "res://assets/textures"))
	var registry = types_inst.build_default_registry()
	var usage: Dictionary = Model.build_tile_usage(registry)
	var packed: Dictionary = Model.packed_status(tiles, pack_dir)

	_last_tiles = tiles
	_last_usage = usage
	_last_packed = packed
	_last_cols = cols
	_selected = -1
	_info.text = "%d/%d tiles · %d 列 × %d 行 · %dpx" % [
		tiles.size(), cols * rows, cols, rows, tile_size]
	_grid.setup(atlas_tex, tiles, usage, cols, rows, tile_size, packed)
	_update_warnings(atlas_script, types_script, registry, tiles, packed)
	_detail.text = "[color=#%s]点击格子查看被哪些方块引用[/color]" % HEX_MUTED


func _update_warnings(atlas_script: Script, types_script: Script,
		registry, tiles: Array, packed: Dictionary) -> void:
	var lines := ""
	var snapshot: Dictionary = ValidatorScript.snapshot_from(
			types_script, atlas_script, registry)
	for r in Model.atlas_reports(snapshot):
		var hex := HEX_MUTED
		var mark := "·"
		var level := String(r.get("level", ""))
		if level == ValidatorScript.LEVEL_ERROR:
			hex = HEX_ERR
			mark = "✗"
		elif level == ValidatorScript.LEVEL_WARN:
			hex = HEX_WARN
			mark = "▲"
		elif level == ValidatorScript.LEVEL_OK:
			hex = HEX_OK
			mark = "✓"
		else:
			hex = HEX_INFO
		lines += "[color=#%s]%s [/color]%s\n" % [hex, mark, String(r.get("text", ""))]
	var placeholders: PackedStringArray = []
	for tile in tiles:
		if not bool(packed.get(String(tile), true)):
			placeholders.append(String(tile))
	if placeholders.size() > 0:
		lines += "[color=#%s]· 程序化占位（assets/textures 缺 PNG）：%s[/color]" % [
			HEX_INFO, ", ".join(placeholders)]
	_warnings.text = lines


func _on_cell_selected(index: int) -> void:
	_selected = index
	if index < 0 or index >= _last_tiles.size():
		_detail.text = "[color=#%s]点击格子查看被哪些方块引用[/color]" % HEX_MUTED
		return
	_update_detail(index)


func _update_detail(index: int) -> void:
	var tile := String(_last_tiles[index])
	@warning_ignore("integer_division")
	var gp := Vector2i(index % _last_cols, index / _last_cols)
	var source_text := "真实 PNG" if bool(_last_packed.get(tile, true)) \
			else "[color=#%s]程序化占位（assets/textures/%s.png 缺失）[/color]" % [HEX_WARN, tile]
	var lines := "[b]%s[/b]   下标 %d · 格 (%d, %d)   来源：%s\n" % [
		tile, index, gp.x, gp.y, source_text]
	# 聚合：方块 -> 面列表
	var by_block := {}
	for u in _last_usage.get(tile, []):
		var block := String(u["block"])
		if not by_block.has(block):
			by_block[block] = []
		by_block[block].append(String(u["face"]))
	var used_blocks: Array = by_block.keys()
	if used_blocks.is_empty():
		lines += "[color=#%s]▲ 未被任何方块引用（tile 冗余或待接入）[/color]" % HEX_WARN
	else:
		lines += "被 %d 个方块引用：" % used_blocks.size()
		var first := true
		for block in used_blocks:
			if not first:
				lines += "、"
			first = false
			lines += "%s（%s）" % [block, " / ".join(PackedStringArray(by_block[block]))]
	_detail.text = lines


func _show_fatal(message: String) -> void:
	_warnings.text = "[color=#%s]✗ %s[/color]" % [HEX_ERR, message]
	_grid.setup(null, [], {}, 16, 2, 32, {})
	_detail.text = ""
	_info.text = "—"
