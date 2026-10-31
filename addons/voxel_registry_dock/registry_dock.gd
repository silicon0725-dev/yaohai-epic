@tool
## 编辑器侧栏 Dock：方块注册表全貌 + 实时校验（存档兼容红线）。
## 数据每次从磁盘 load() 重读——保存 voxel_types.gd /
## texture_atlas_loader.gd 或重导贴图后自动刷新（文件系统信号去抖 0.4 秒）。
## 校验逻辑在 registry_validator.gd（纯数据，headless 测试同步守护：
## tests/test_registry_dock.gd）。
## 新方块工作台用法：在 voxel_types.gd 末尾追加注册 + 三张对齐表补行，
## 面板即时标出新增行并逐项检查对齐，点「固化基线」归档进 git。
extends Control

const ValidatorScript := preload("res://addons/voxel_registry_dock/registry_validator.gd")
const VOXEL_TYPES_PATH := "res://core/voxel_types.gd"
const ATLAS_LOADER_PATH := "res://presentation/texture_atlas_loader.gd"
const BASELINE_PATH := "res://addons/voxel_registry_dock/id_baseline.json"

const HEX_ERROR := "ff6a61"
const HEX_WARN := "ffcc59"
const HEX_OK := "94e58c"
const HEX_INFO := "8cbaff"
const HEX_MUTED := "9aa0a6"
const HEX_TEXT := "e8eaf0"
const HEX_NEW := "6fb3ff"

var _status: RichTextLabel
var _baseline_label: Label
var _freeze_button: Button
var _tree: Tree
var _faces_box: HBoxContainer
var _detail_info: RichTextLabel
var _refresh_timer: Timer
var _atlas_texture: ImageTexture
var _row_items: Array = []
var _last_snap: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(560, 0)
	_build_ui()
	_connect_filesystem()
	_refresh()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "方块注册表"
	title.add_theme_font_size_override("font_size", 15)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var refresh_button := Button.new()
	refresh_button.text = "刷新"
	refresh_button.tooltip_text = "重新从磁盘读取 voxel_types.gd / texture_atlas_loader.gd"
	refresh_button.pressed.connect(_refresh)
	header.add_child(refresh_button)
	root.add_child(header)

	_status = RichTextLabel.new()
	_status.bbcode_enabled = true
	_status.fit_content = true
	_status.selection_enabled = true
	root.add_child(_status)

	var baseline_row := HBoxContainer.new()
	_baseline_label = Label.new()
	_baseline_label.add_theme_font_size_override("font_size", 12)
	baseline_row.add_child(_baseline_label)
	var baseline_spacer := Control.new()
	baseline_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	baseline_row.add_child(baseline_spacer)
	_freeze_button = Button.new()
	_freeze_button.text = "固化基线"
	_freeze_button.tooltip_text = "把当前注册顺序追加进 id_baseline.json（存档兼容红线归档，随 git 提交）"
	_freeze_button.pressed.connect(_on_freeze_pressed)
	_freeze_button.visible = false
	baseline_row.add_child(_freeze_button)
	root.add_child(baseline_row)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_item_selected)
	var columns := ["ID", "方块", "渲染", "阻光", "发光", "硬度", "贴图 tile"]
	for i in columns.size():
		_tree.set_column_title(i, columns[i])
		_tree.set_column_expand(i, i == 1 or i == 6)
	_tree.set_column_custom_minimum_width(0, 34)
	_tree.set_column_custom_minimum_width(2, 58)
	_tree.set_column_custom_minimum_width(3, 44)
	_tree.set_column_custom_minimum_width(4, 44)
	_tree.set_column_custom_minimum_width(5, 44)
	root.add_child(_tree)

	var detail := VBoxContainer.new()
	detail.custom_minimum_size = Vector2(0, 210)
	detail.size_flags_vertical = Control.SIZE_SHRINK_END
	root.add_child(detail)
	_faces_box = HBoxContainer.new()
	_faces_box.add_theme_constant_override("separation", 12)
	detail.add_child(_faces_box)
	_detail_info = RichTextLabel.new()
	_detail_info.bbcode_enabled = true
	_detail_info.selection_enabled = true
	_detail_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(_detail_info)


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
	# 去抖：连续变更（批量保存/重导）只刷最后一次
	_refresh_timer.start()


func _refresh() -> void:
	var types_script: Script = load(VOXEL_TYPES_PATH)
	var atlas_script: Script = load(ATLAS_LOADER_PATH)
	if types_script == null or atlas_script == null:
		_show_fatal("无法加载 voxel_types.gd / texture_atlas_loader.gd——脚本存在编译错误？修复后点「刷新」。")
		return
	if not types_script.can_instantiate() or not atlas_script.can_instantiate():
		# 编辑器上下文只允许实例化 @tool 脚本（整条引用链都得有）
		_show_fatal("voxel_types / voxel_registry / texture_atlas_loader 缺少 @tool 注解——编辑器内无法实例化。")
		return
	var types_inst = types_script.new()
	var atlas_inst = atlas_script.new()
	if not types_inst.has_method("build_default_registry") \
			or not atlas_inst.has_method("generate_atlas_image"):
		_show_fatal("脚本缺少 build_default_registry() / generate_atlas_image()——接口被改动？")
		return
	var registry = types_inst.build_default_registry()
	if registry == null:
		_show_fatal("build_default_registry() 返回空——检查 voxel_types.gd。")
		return
	_last_snap = ValidatorScript.snapshot_from(types_script, atlas_script, registry)
	_atlas_texture = null
	var image: Image = atlas_inst.generate_atlas_image()
	if image != null:
		_atlas_texture = ImageTexture.create_from_image(image)

	var baseline: Array = ValidatorScript.load_baseline(BASELINE_PATH)
	if baseline.is_empty():
		# 仓库里已随 git 提交基线，正常不会走到；首次生成兜底
		ValidatorScript.save_baseline(BASELINE_PATH, _last_snap.get("names", []))
		print("[voxel_registry_dock] 已固化初始基线：%s" % BASELINE_PATH)
		baseline = (_last_snap.get("names", []) as Array).duplicate()
	var result: Dictionary = ValidatorScript.validate(_last_snap, baseline)
	_update_status(result)
	_rebuild_tree(baseline)
	_update_baseline_row(baseline, result)


func _update_status(result: Dictionary) -> void:
	var names: Array = _last_snap.get("names", [])
	var tiles: Array = _last_snap.get("tiles", [])
	var capacity := int(_last_snap.get("atlas_cols", 16)) * int(_last_snap.get("atlas_rows", 1))
	var errors := int(result.get("errors", 0))
	var warnings := int(result.get("warnings", 0))
	var appended: Array = result.get("appended", [])
	var lines := ""
	if errors > 0:
		lines += "[color=#%s]✗ 校验未通过：%d 个错误，%d 个警告[/color]\n" % [HEX_ERROR, errors, warnings]
	elif warnings > 0:
		lines += "[color=#%s]▲ 警告 %d 个（无错误）[/color]\n" % [HEX_WARN, warnings]
	else:
		lines += "[color=#%s]✓ 全部校验通过[/color]\n" % [HEX_OK]
	lines += "[color=#%s]共 %d 个方块 · 图集 %d/%d tiles · 待固化新增 %d[/color]\n" % [
		HEX_MUTED, names.size(), tiles.size(), capacity, appended.size()]
	for r in result.get("reports", []):
		var hex := HEX_MUTED
		var mark := "·"
		var level := String(r.get("level", ""))
		if level == ValidatorScript.LEVEL_ERROR:
			hex = HEX_ERROR
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
	_status.text = lines


func _rebuild_tree(baseline: Array) -> void:
	_tree.clear()
	_row_items.clear()
	var root_item := _tree.create_item()
	var names: Array = _last_snap.get("names", [])
	var definitions: Array = _last_snap.get("definitions", [])
	var baseline_count := baseline.size()
	var select_index := -1
	for i in names.size():
		var def: Dictionary = definitions[i] if i < definitions.size() else {}
		var item := _tree.create_item(root_item)
		_row_items.append(item)
		item.set_text(0, str(i))
		item.set_text_alignment(0, HORIZONTAL_ALIGNMENT_RIGHT)
		var display_name := String(names[i])
		if i >= baseline_count:
			display_name += "（未固化）"
			item.set_custom_color(1, Color(HEX_NEW))
			if select_index < 0:
				select_index = i  # 刚加的方块自动选中——工作台直接看新块
		item.set_text(1, display_name)
		item.set_text(2, String(def.get("render_type", "?")))
		item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_CENTER)
		var opacity := _table_value("light_opacity", i, 15)
		var emission := _table_value("light_emission", i, 0)
		item.set_text(3, str(opacity))
		item.set_text_alignment(3, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(4, str(emission))
		item.set_text_alignment(4, HORIZONTAL_ALIGNMENT_CENTER)
		if emission > 0:
			item.set_custom_color(4, Color("ffb347"))
		var hardness: float = float(def.get("hardness", 0.0))
		item.set_text(5, "∞" if hardness < 0.0 else str(hardness))
		item.set_text_alignment(5, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(6, _tiles_text(def))
		item.set_metadata(0, {"index": i})
	if select_index < 0 and names.size() > 1:
		select_index = 1
	_select_index(select_index)


func _select_index(index: int) -> void:
	if index < 0 or index >= _row_items.size():
		_clear_detail()
		return
	var item: TreeItem = _row_items[index]
	_tree.set_selected(item, 1)
	_show_detail(item)


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item != null:
		_show_detail(item)


## 读光照表第 index 项；越界回退与运行时兜底一致（阻光 15 / 发光 0）。
func _table_value(key: String, index: int, fallback: int) -> int:
	var table = _last_snap.get(key, [])
	if index < table.size():
		return int(table[index])
	return fallback


func _tiles_text(def: Dictionary) -> String:
	var textures: Dictionary = def.get("textures", {})
	if textures.is_empty():
		return "—"
	var seen := {}
	var parts: PackedStringArray = []
	for face in textures:
		var tile := String(textures[face])
		if tile != "" and not seen.has(tile):
			seen[tile] = true
			parts.append(tile)
	return " ".join(parts)


func _show_detail(item: TreeItem) -> void:
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty():
		return
	var index := int(meta.get("index", -1))
	var names: Array = _last_snap.get("names", [])
	var definitions: Array = _last_snap.get("definitions", [])
	if index < 0 or index >= names.size():
		return
	var def: Dictionary = definitions[index]
	for child in _faces_box.get_children():
		child.queue_free()
	var textures: Dictionary = def.get("textures", {})
	if textures.is_empty():
		var none_label := Label.new()
		none_label.text = "（无贴图——不渲染面）"
		none_label.add_theme_color_override("font_color", Color(HEX_MUTED))
		_faces_box.add_child(none_label)
	else:
		for face in textures:
			_faces_box.add_child(_make_face_view(face, String(textures[face])))
	_detail_info.text = _detail_bbcode(index, String(names[index]), def)


func _make_face_view(face: String, tile_name: String) -> Control:
	var box := VBoxContainer.new()
	var rect := TextureRect.new()
	rect.texture = _face_texture(tile_name)
	rect.custom_minimum_size = Vector2(64, 64)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.add_child(rect)
	var tiles: Array = _last_snap.get("tiles", [])
	var cols := int(_last_snap.get("atlas_cols", 16))
	var idx: int = tiles.find(tile_name)
	var label := Label.new()
	if idx >= 0:
		@warning_ignore("integer_division")
		label.text = "%s · %s\n(%d, %d)" % [face, tile_name, idx % cols, idx / cols]
	else:
		label.text = "%s · %s\n(未登记!)" % [face, tile_name]
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(HEX_MUTED))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	return box


func _face_texture(tile_name: String) -> AtlasTexture:
	var at := AtlasTexture.new()
	if _atlas_texture == null:
		return at
	var tiles: Array = _last_snap.get("tiles", [])
	var idx: int = tiles.find(tile_name)
	if idx < 0:
		return at
	var cols := int(_last_snap.get("atlas_cols", 16))
	var tile_size := int(_last_snap.get("tile_size", 32))
	@warning_ignore("integer_division")
	var grid := Vector2i(idx % cols, idx / cols)
	at.atlas = _atlas_texture
	at.region = Rect2(grid.x * tile_size, grid.y * tile_size, tile_size, tile_size)
	return at


func _detail_bbcode(index: int, block_name: String, def: Dictionary) -> String:
	var opacity := _table_value("light_opacity", index, 15)
	var emission := _table_value("light_emission", index, 0)
	var lines := ""
	lines += "[b][color=#%s][font_size=14]%s[/font_size][/color][/b]   [color=#%s]ID = %d[/color]\n" % [
		HEX_TEXT, block_name, HEX_MUTED, index]
	lines += "渲染类别: [color=#%s]%s[/color]   碰撞: %s   遮挡邻面: %s\n" % [
		HEX_TEXT,
		String(def.get("render_type", "?")),
		"是" if bool(def.get("collision", false)) else "否",
		"是" if bool(def.get("occludes_neighbors", false)) else "否",
	]
	var hardness: float = float(def.get("hardness", 0.0))
	var hardness_text := "不可破坏" if hardness < 0.0 else "%.2f 秒（徒手基准）" % hardness
	var tool_text := "无"
	var requires_tool: Dictionary = def.get("requires_tool", {})
	if not requires_tool.is_empty():
		tool_text = "%s ≥ T%d（tier 不足 4× 减速且不掉落）" % [
			String(requires_tool.get("class", "?")), int(requires_tool.get("min_tier", 1))]
	lines += "硬度: %s   工具要求: %s\n" % [hardness_text, tool_text]
	var emission_text := "[color=#%s]%d[/color]" % [HEX_TEXT, emission]
	if emission > 0:
		emission_text = "[color=#ffb347][b]%d（光源方块）[/b][/color]" % emission
	lines += "阻光: [color=#%s]%d[/color]   发光: %s\n" % [HEX_TEXT, opacity, emission_text]
	var baseline: Array = ValidatorScript.load_baseline(BASELINE_PATH)
	if index < baseline.size():
		lines += "[color=#%s]基线已固化（存档兼容）[/color]" % HEX_OK
	else:
		lines += "[color=#%s]新增 ID，尚未固化基线[/color]" % HEX_NEW
	return lines


func _update_baseline_row(baseline: Array, result: Dictionary) -> void:
	var appended: Array = result.get("appended", [])
	_freeze_button.visible = appended.size() > 0
	if appended.size() > 0:
		_baseline_label.text = "基线 %d 个 ID · 新增 %d 个待固化" % [baseline.size(), appended.size()]
		_baseline_label.add_theme_color_override("font_color", Color(HEX_NEW))
	else:
		_baseline_label.text = "基线 %d 个 ID · 已固化" % baseline.size()
		_baseline_label.add_theme_color_override("font_color", Color(HEX_OK))


func _on_freeze_pressed() -> void:
	if _last_snap.is_empty():
		return
	var names: Array = _last_snap.get("names", [])
	if ValidatorScript.save_baseline(BASELINE_PATH, names):
		print("[voxel_registry_dock] 基线已固化（%d 个 ID）：%s" % [names.size(), BASELINE_PATH])
	else:
		push_error("[voxel_registry_dock] 基线写入失败：" + BASELINE_PATH)
	_refresh()


func _show_fatal(message: String) -> void:
	_status.text = "[color=#%s]✗ %s[/color]" % [HEX_ERROR, message]
	_tree.clear()
	_row_items.clear()
	_clear_detail()
	_freeze_button.visible = false
	_baseline_label.text = "—"


func _clear_detail() -> void:
	for child in _faces_box.get_children():
		child.queue_free()
	_detail_info.text = ""
