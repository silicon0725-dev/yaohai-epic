## 物品图标生成（表现层）。方块物品直接从图集裁剪其 side 贴图
##（与材质包同源，材质包替换时图标自动跟随，§2.3）；
## 材料与工具用确定性像素画（与程序化占位贴图同一套思路）。
## 图标按物品数值 ID 缓存；纹理资源仅供 UI 显示，不是物品身份。
class_name ItemIcons
extends RefCounted

const ICON_SIZE := 32

static var _cache := {}  # item_id -> ImageTexture
static var _atlas_image: Image


## 供所有图标共用的图集图像（由主场景在图集生成后注入一次）。
static func set_atlas(atlas: Image) -> void:
	_atlas_image = atlas
	_cache.clear()


static func icon_for(item_id: int, item_registry: ItemRegistry) -> ImageTexture:
	if _cache.has(item_id):
		return _cache[item_id]
	var definition := item_registry.definition_for_id(item_id)
	var image := _render(definition)
	var texture := ImageTexture.create_from_image(image)
	_cache[item_id] = texture
	return texture


static func _render(definition: Dictionary) -> Image:
	var icon: Dictionary = definition.get("icon", {})
	var image := Image.create_empty(
			ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGB8)
	if icon.has("tile") and _atlas_image != null:
		var grid := TextureAtlasLoader.tile_grid(String(icon["tile"]))
		var source := _atlas_image.get_region(Rect2i(
				Vector2i(grid.x * TextureAtlasLoader.TILE_SIZE,
						grid.y * TextureAtlasLoader.TILE_SIZE),
				Vector2i(TextureAtlasLoader.TILE_SIZE, TextureAtlasLoader.TILE_SIZE)))
		source.resize(ICON_SIZE, ICON_SIZE, Image.INTERPOLATE_NEAREST)
		image.blit_rect(source, Rect2i(Vector2i.ZERO, source.get_size()), Vector2i.ZERO)
	elif icon.has("pixel_art"):
		_draw_pixel_art(image, String(icon["pixel_art"]))
	else:
		# 未登记图标：品红暴露问题（与图集缺失回退策略一致，§11.2）
		_fill(image, Color.MAGENTA)
	return image


static func _draw_pixel_art(image: Image, art: String) -> void:
	match art:
		"coal":
			_art_coal(image)
		"stick":
			_art_stick(image)
		"pickaxe_wood":
			_art_pickaxe(image, Color("b08a54"), Color("8d6b3e"))
		"pickaxe_stone":
			_art_pickaxe(image, Color("9a9aa2"), Color("6f6f78"))
		_:
			_fill(image, Color.MAGENTA)


static func _fill(image: Image, color: Color) -> void:
	for y in image.get_height():
		for x in image.get_width():
			image.set_pixel(x, y, color)


## 16x16 逻辑网格放大到 ICON_SIZE（2 像素/格），描点即方块。
static func _plot(image: Image, gx: int, gy: int, color: Color) -> void:
	for oy in 2:
		for ox in 2:
			image.set_pixel(gx * 2 + ox, gy * 2 + oy, color)


## 煤块：不规则黑色团块 + 高光点。
static func _art_coal(image: Image) -> void:
	_fill(image, Color("26262c"))
	var dark := Color("18181c")
	var shine := Color("4a4a52")
	var rng := RandomNumberGenerator.new()
	rng.seed = "coal_icon".hash()
	for i in 26:
		var gx := 3 + rng.randi_range(0, 9)
		var gy := 3 + rng.randi_range(0, 9)
		_plot(image, gx, gy, dark if rng.randf() < 0.5 else Color("2e2e34"))
	_plot(image, 5, 5, shine)
	_plot(image, 6, 5, shine)


## 木棍：45° 斜杆，亮面 + 暗面双色。
static func _art_stick(image: Image) -> void:
	_fill(image, Color("1c1a16"))
	for i in 10:
		_plot(image, 3 + i, 12 - i, Color("a8834f"))
		_plot(image, 4 + i, 12 - i, Color("8a6a3d"))


## 镐：斜柄 + 弧形镐头。head_color 区分木/石等级。
static func _art_pickaxe(image: Image, head_color: Color, head_shadow: Color) -> void:
	var handle := Color("9c7a4a")
	var handle_shadow := Color("7d5f38")
	# 斜柄：左下到右上
	for i in 9:
		_plot(image, 3 + i, 12 - i, handle)
		_plot(image, 4 + i, 12 - i, handle_shadow)
	# 镐头：顶部弧线（两端下垂）
	for t in 9:
		var hx := 2 + t
		var hy := 3 + int(round(0.35 * absf(t - 4.0)))
		_plot(image, hx, hy, head_color)
		_plot(image, hx, hy + 1, head_shadow)
