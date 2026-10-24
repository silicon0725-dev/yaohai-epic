## 物品图标生成（表现层）。方块物品直接从图集裁剪其 side 贴图
##（与材质包同源，材质包替换时图标自动跟随，§2.3）；
## 材料与工具用确定性像素画（与程序化占位贴图同一套思路）。
## 图标按物品数值 ID 缓存；纹理资源仅供 UI 显示，不是物品身份。
class_name ItemIcons
extends RefCounted

const ICON_SIZE := 32

static var _cache := {}  # item_id -> ImageTexture
## 世界掉落实体贴图缓存（与背包图标同源，仅像素画额外去底）
static var _world_cache := {}  # item_id -> ImageTexture
static var _atlas_image: Image


## 供所有图标共用的图集图像（由主场景在图集生成后注入一次）。
static func set_atlas(atlas: Image) -> void:
	_atlas_image = atlas
	_cache.clear()
	_world_cache.clear()


static func icon_for(item_id: int, item_registry: ItemRegistry) -> ImageTexture:
	if _cache.has(item_id):
		return _cache[item_id]
	var definition := item_registry.definition_for_id(item_id)
	var image := _render(definition)
	var texture := ImageTexture.create_from_image(image)
	_cache[item_id] = texture
	return texture


## 世界掉落实体贴图：与背包图标同源；像素画物品（煤/木棍/镐）的
## 纯色背景转透明，落地实体不显示"图标底板"。方块物品（图集裁剪）
## 保持满幅——MC 式平面方块观感。缓存独立于背包图标。
static func world_sprite_for(
		item_id: int, item_registry: ItemRegistry) -> ImageTexture:
	if _world_cache.has(item_id):
		return _world_cache[item_id]
	var image := sprite_image_for(item_id, item_registry)
	var texture := ImageTexture.create_from_image(image)
	_world_cache[item_id] = texture
	return texture


## 掉落实体的源图像（像素画已去底）。供平面贴图与挤出网格共用。
static func sprite_image_for(
		item_id: int, item_registry: ItemRegistry) -> Image:
	var definition := item_registry.definition_for_id(item_id)
	var image := _render(definition)
	if definition.get("icon", {}).has("pixel_art"):
		image.convert(Image.FORMAT_RGBA8)
		_apply_background_alpha(image)
	return image


## 以左上角像素为背景色，等色像素（容差 5/255/通道）置为全透明。
## 像素画背景为固定纯色填充（_fill），容差足以区分邻近的内部笔触。
static func _apply_background_alpha(image: Image) -> void:
	var bg := image.get_pixel(0, 0)
	var tolerance := 5.0 / 255.0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if absf(pixel.r - bg.r) <= tolerance \
					and absf(pixel.g - bg.g) <= tolerance \
					and absf(pixel.b - bg.b) <= tolerance:
				image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))


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


## 煤块：中心近圆噪声团块 + 高光点。背景必须用纯黑（与镐一致）——
## 旧版把整面填成煤色，世界贴图去底时整块被当背景键控成碎点。
static func _art_coal(image: Image) -> void:
	_fill(image, Color.BLACK)
	var lump := Color("26262c")
	var dark := Color("18181c")
	var mid := Color("2e2e34")
	var shine := Color("4a4a52")
	var rng := RandomNumberGenerator.new()
	rng.seed = "coal_icon".hash()
	for gy in 16:
		for gx in 16:
			var dx := gx - 7.5
			var dy := gy - 8.5
			if dx * dx + dy * dy <= 27.0 + rng.randf_range(-4.0, 4.0):
				var shade := dark if rng.randf() < 0.4 else lump
				if rng.randf() < 0.15:
					shade = mid
				_plot(image, gx, gy, shade)
	_plot(image, 6, 6, shine)
	_plot(image, 7, 6, shine)


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
