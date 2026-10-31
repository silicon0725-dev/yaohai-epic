@tool
## 图集网格视图：真实 16 列布局逐格绘制。
## 占用格 = 棋盘格底（镂空贴图 alpha 可见）+ tile 真实像素（最近邻）
## + 名称/下标/坐标/引用数；空闲格 = 暗底 + 下标，首个空闲格绿框标
## 「下一个」——新 tile 的落点一目了然（防中段插入错位）。
extends Control

signal cell_selected(index: int)

const CELL_W := 62.0
const CELL_H := 80.0
const IMG := 48.0
const PAD := 7.0

const COLOR_EMPTY_BG := Color(0.10, 0.10, 0.12)
const COLOR_BORDER := Color(0.35, 0.35, 0.38)
const COLOR_TEXT := Color(0.85, 0.87, 0.92)
const COLOR_MUTED := Color(0.55, 0.58, 0.63)
const COLOR_WARN := Color(1.0, 0.8, 0.35)
const COLOR_NEXT := Color(0.45, 0.85, 0.5)
const COLOR_SELECT := Color(1, 1, 1)

var _atlas_tex: ImageTexture = null
var _tiles: Array = []
var _usage: Dictionary = {}
var _packed: Dictionary = {}
var _cols := 16
var _rows := 2
var _tile_size := 32
var _selected := -1


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_STOP
	_update_min_size()


func setup(atlas_tex: ImageTexture, tiles: Array, usage: Dictionary,
		cols: int, rows: int, tile_size: int, packed: Dictionary) -> void:
	_atlas_tex = atlas_tex
	_tiles = tiles
	_usage = usage
	_cols = cols
	_rows = rows
	_tile_size = tile_size
	_packed = packed
	if _selected >= _tiles.size():
		_selected = -1
	_update_min_size()
	queue_redraw()


func _update_min_size() -> void:
	custom_minimum_size = Vector2(
			_cols * CELL_W + PAD * 2, _rows * CELL_H + PAD * 2)


func _grid_pos(index: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(index % _cols, index / _cols)


func _cell_rect(index: int) -> Rect2:
	var gp := _grid_pos(index)
	return Rect2(PAD + gp.x * CELL_W, PAD + gp.y * CELL_H, CELL_W - 2, CELL_H - 2)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	for i in _cols * _rows:
		var rect := _cell_rect(i)
		if i < _tiles.size():
			_draw_occupied(font, i, rect)
		else:
			draw_rect(rect, COLOR_EMPTY_BG)
			var is_next := i == _tiles.size()
			draw_rect(rect, COLOR_NEXT if is_next else COLOR_BORDER,
					false, 1.5 if is_next else 1.0)
			draw_string(font, rect.position + Vector2(6, 20),
					"下一个" if is_next else "空闲",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
					COLOR_NEXT if is_next else COLOR_MUTED)
			draw_string(font, rect.position + Vector2(6, 36), str(i),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_MUTED)
	if _selected >= 0 and _selected < _tiles.size():
		draw_rect(_cell_rect(_selected), COLOR_SELECT, false, 2.0)


func _draw_occupied(font: Font, index: int, rect: Rect2) -> void:
	var tile := String(_tiles[index])
	var img_pos := rect.position + Vector2((CELL_W - 2.0 - IMG) * 0.5, 2.0)
	# 棋盘格底：镂空贴图（火把等）的 alpha 轮廓可见
	var sq := 8.0
	var k := 0
	while sq * k < IMG:
		var kk := 0
		while sq * kk < IMG:
			var c := 0.20 if (k + kk) % 2 == 0 else 0.30
			draw_rect(Rect2(img_pos + Vector2(sq * k, sq * kk),
					Vector2(minf(sq, IMG - sq * k), minf(sq, IMG - sq * kk))),
					Color(c, c, c))
			kk += 1
		k += 1
	if _atlas_tex != null:
		var gp := _grid_pos(index)
		var src := Rect2(gp.x * _tile_size, gp.y * _tile_size, _tile_size, _tile_size)
		draw_texture_rect_region(_atlas_tex, Rect2(img_pos, Vector2(IMG, IMG)), src)
	var sel := index == _selected
	draw_rect(rect, COLOR_SELECT if sel else COLOR_BORDER, false, 2.0 if sel else 1.0)
	# 文本：名称 / 下标+坐标+引用数 / 占位标记
	var text_w := CELL_W - 14.0
	var gp := _grid_pos(index)
	var uses: Array = _usage.get(tile, [])
	var use_text := ("%d 面引用" % uses.size()) if uses.size() > 0 else "未引用"
	var use_color := COLOR_TEXT if uses.size() > 0 else COLOR_WARN
	draw_string(font, rect.position + Vector2(6, IMG + 16.0),
			_truncate(font, tile, text_w), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_TEXT)
	draw_string(font, rect.position + Vector2(6, IMG + 30.0),
			"%d (%d,%d) %s" % [index, gp.x, gp.y, use_text],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, use_color)
	if not bool(_packed.get(tile, true)):
		draw_string(font, rect.position + Vector2(6, IMG + 44.0), "占位（无 PNG）",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_WARN)


func _truncate(font: Font, text: String, max_w: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x <= max_w:
		return text
	var t := text
	while t.length() > 1 and font.get_string_size(
			t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t + "…"


func _index_at(pos: Vector2) -> int:
	var fx := pos.x - PAD
	var fy := pos.y - PAD
	if fx < 0 or fy < 0:
		return -1
	@warning_ignore("integer_division")
	var col := int(fx / CELL_W)
	@warning_ignore("integer_division")
	var row := int(fy / CELL_H)
	if col >= _cols or row >= _rows:
		return -1
	var idx := row * _cols + col
	return idx if idx < _tiles.size() else -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_selected = _index_at(mb.position)
			queue_redraw()
			cell_selected.emit(_selected)
			accept_event()
	elif event is InputEventMouseMotion:
		var idx := _index_at((event as InputEventMouseMotion).position)
		if idx >= 0:
			var tile := String(_tiles[idx])
			var gp := _grid_pos(idx)
			var names: PackedStringArray = []
			for u in _usage.get(tile, []):
				names.append("%s[%s]" % [u["block"], u["face"]])
			tooltip_text = "%s · %d (%d,%d)%s%s" % [
				tile, idx, gp.x, gp.y,
				"\n" if names.size() > 0 else "",
				"\n".join(names),
			]
		else:
			tooltip_text = ""
