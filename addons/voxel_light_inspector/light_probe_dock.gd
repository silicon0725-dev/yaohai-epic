@tool
## 光照探查 Dock：世界重建参数 + 通道/过滤显示 + 探针信息面板。
## 编辑器插件 UI（由 plugin.gd 实例化并注入 plugin 引用）。
extends Control

const RebuilderRef := preload("res://addons/voxel_light_inspector/world_rebuilder.gd")
const ChunkStateScript := preload("res://world/chunk_state.gd")

const HEX_MUTED := "9aa0a6"
const HEX_SKY := "8cbaff"
const HEX_BLK := "ffa866"
const HEX_ERR := "ff6a61"

## 由 plugin.gd 注入（request_rebuild / refresh_display / set_probe_mode）
var plugin: EditorPlugin = null

var _status: Label
var _busy: Label
var _radius: SpinBox
var _center_x: SpinBox
var _center_z: SpinBox
var _use_save: CheckButton
var _save_root: LineEdit
var _rebuild_btn: Button
var _sky_toggle: CheckButton
var _blk_toggle: CheckButton
var _borders: CheckButton
var _min_level: SpinBox
var _max_level: SpinBox
var _probe_toggle: CheckButton
var _probe_info: RichTextLabel
var _stats: Label


func _ready() -> void:
	custom_minimum_size = Vector2(420, 0)
	_build_ui()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "光照探查"
	title.add_theme_font_size_override("font_size", 15)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(HEX_ERR))
	header.add_child(_status)
	root.add_child(header)

	# ---- 世界重建 ----
	var world_box := _section(root, "世界重建（存档 meta 恢复种子，生成器/存档/光照与游戏同源）")
	var row1 := HBoxContainer.new()
	world_box.add_child(row1)
	row1.add_child(_label("半径"))
	_radius = _spin(1, 12, 4, "重建范围（区块半径，方形）")
	row1.add_child(_radius)
	row1.add_child(_label("中心X"))
	_center_x = _spin(-128, 128, 2, "中心区块 X（默认出生点所在区块）")
	row1.add_child(_center_x)
	row1.add_child(_label("Z"))
	_center_z = _spin(-128, 128, 2, "中心区块 Z")
	row1.add_child(_center_z)
	var row2 := HBoxContainer.new()
	world_box.add_child(row2)
	_use_save = CheckButton.new()
	_use_save.text = "用存档改动"
	_use_save.button_pressed = true
	_use_save.tooltip_text = "已保存的挖掘/放置覆盖确定性生成（与游戏重建一致）"
	row2.add_child(_use_save)
	_save_root = LineEdit.new()
	_save_root.text = RebuilderRef.DEFAULT_SAVE_ROOT
	_save_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_root.tooltip_text = "游戏存档目录（main.gd DEFAULT_SAVE_ROOT 同源）"
	row2.add_child(_save_root)
	var row3 := HBoxContainer.new()
	world_box.add_child(row3)
	_rebuild_btn = Button.new()
	_rebuild_btn.text = "重建世界"
	_rebuild_btn.pressed.connect(_on_rebuild_pressed)
	row3.add_child(_rebuild_btn)
	_busy = _label("")
	_busy.add_theme_color_override("font_color", Color(HEX_MUTED))
	row3.add_child(_busy)

	# ---- 显示 ----
	var disp_box := _section(root, "显示")
	var row4 := HBoxContainer.new()
	disp_box.add_child(row4)
	_sky_toggle = _toggle(row4, "天光", true, _on_display_changed)
	_blk_toggle = _toggle(row4, "方块光", true, _on_display_changed)
	_borders = _toggle(row4, "区块边框", true, _on_display_changed)
	var row5 := HBoxContainer.new()
	disp_box.add_child(row5)
	row5.add_child(_label("亮度下限"))
	_min_level = _spin(1, 15, 1, "只显示光照值 >= 下限的格（残留光排查：看 1-3）")
	_min_level.value_changed.connect(_on_display_changed)
	row5.add_child(_min_level)
	row5.add_child(_label("上限"))
	_max_level = _spin(1, 15, 14, "只显示光照值 <= 上限的格（天光 14 排除满日照噪声）")
	_max_level.value_changed.connect(_on_display_changed)
	row5.add_child(_max_level)
	var hint := Label.new()
	hint.text = "天光上限默认 14：排除满日照 15 的大片噪声，专看洞口梯度/树荫/残留光。卡就调小半径。"
	hint.add_theme_color_override("font_color", Color(HEX_MUTED))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(0, 34)
	disp_box.add_child(hint)

	# ---- 探针 ----
	var probe_row := HBoxContainer.new()
	root.add_child(probe_row)
	_probe_toggle = _toggle(probe_row, "探针模式（悬停查值，点击锁定）", true, _on_probe_mode)
	_probe_info = RichTextLabel.new()
	_probe_info.bbcode_enabled = true
	_probe_info.fit_content = true
	_probe_info.selection_enabled = true
	_probe_info.text = "[color=#%s]重建世界后在 3D 视口里悬停/点击任意格查值[/color]" % HEX_MUTED
	root.add_child(_probe_info)
	_stats = _label("")
	_stats.add_theme_color_override("font_color", Color(HEX_MUTED))
	root.add_child(_stats)


func _section(parent: Control, title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(HEX_MUTED))
	box.add_child(l)
	parent.add_child(box)
	return box


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _spin(min_v: int, max_v: int, value: int, tip: String = "") -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.value = value
	s.step = 1
	s.custom_minimum_size = Vector2(64, 0)
	s.tooltip_text = tip
	return s


func _toggle(parent: Control, text: String, pressed: bool, cb: Callable) -> CheckButton:
	var t := CheckButton.new()
	t.text = text
	t.button_pressed = pressed
	t.toggled.connect(cb)
	parent.add_child(t)
	return t


# ---- 信号转发 ----

func _on_rebuild_pressed() -> void:
	if plugin != null:
		plugin.request_rebuild()


func _on_display_changed(_v = null) -> void:
	if plugin != null:
		plugin.refresh_display()


func _on_probe_mode(pressed: bool) -> void:
	if plugin != null:
		plugin.set_probe_mode(pressed)


# ---- 选项读取（plugin 调用） ----

func radius() -> int:
	return int(_radius.value)


func center_xz() -> Vector2i:
	return Vector2i(int(_center_x.value), int(_center_z.value))


func use_save() -> bool:
	return _use_save.button_pressed


func save_root_text() -> String:
	return _save_root.text.strip_edges()


func sky_on() -> bool:
	return _sky_toggle.button_pressed


func block_on() -> bool:
	return _blk_toggle.button_pressed


func borders_on() -> bool:
	return _borders.button_pressed


func min_level() -> int:
	return int(_min_level.value)


func max_level() -> int:
	return int(_max_level.value)


# ---- 状态回写（plugin 调用） ----

func set_busy(text: String) -> void:
	_busy.text = text


func set_status(text: String) -> void:
	_status.text = text


func clear_status() -> void:
	_status.text = ""


func set_stats(text: String) -> void:
	_stats.text = text


func set_rebuilding(on: bool) -> void:
	_rebuild_btn.disabled = on


## 探针结果面板（hit 为 world_rebuilder.probe 的返回）。
func show_probe(hit: Dictionary, world, sources: Dictionary) -> void:
	if world == null:
		return
	if hit.is_empty():
		_probe_info.text = "[color=#%s]未命中（指向天空 / 未加载区）[/color]" % HEX_MUTED
		return
	var pos: Vector3i = hit["block_pos"]
	var face: Vector3i = hit["face_pos"]
	var block_name: String = world.registry.name_for_id(int(hit.get("block_id", 0)))
	var lines := ""
	lines += "[b]%s[/b]  (%d, %d, %d)\n" % [block_name, pos.x, pos.y, pos.z]
	lines += "该格  天光 [color=#%s]%d[/color] · 方块光 [color=#%s]%d[/color]\n" % [
		HEX_SKY, int(hit.get("cell_sky", -1)), HEX_BLK, int(hit.get("cell_block", -1))]
	lines += "命中面外格 (%d, %d, %d)  天光 %d · 方块光 %d\n" % [
		face.x, face.y, face.z, int(hit.get("face_sky", -1)), int(hit.get("face_block", -1))]
	var chunk = hit.get("chunk")
	if chunk != null:
		var src: String = String(sources.get(chunk.chunk_coord, "?"))
		var state_names: Array = ChunkStateScript.State.keys()
		var state_idx := int(chunk.state)
		var state_name: String = String(state_names[state_idx]) \
				if state_idx >= 0 and state_idx < state_names.size() else "?"
		lines += "区块 %s · 来源=%s · 状态=%s · edit_serial=%d · 存档待写=%s" % [
			chunk.chunk_coord,
			"存档" if src == "save" else "生成",
			state_name,
			chunk.edit_serial,
			"是" if chunk.save_needed else "否",
		]
	_probe_info.text = lines
