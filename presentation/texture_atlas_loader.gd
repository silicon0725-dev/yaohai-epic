## 纹理图集加载（开发文档 §7.1、§7.3）。
## 优先使用 assets/textures/ 下的真实材质包文件（按 tile 名称），
## 缺失的 tile 回退到程序化占位图——保证任何情况下图集完整可用。
## 真实贴图的来源与许可证记录见 assets/textures/CREDITS.md。
class_name TextureAtlasLoader
extends RefCounted

## tile 像素尺寸。跟随当前材质包（Conquest 为 32px）；图集与图标
## 的全部几何都从本常量推导，切换材质包只改这一处。
const TILE_SIZE := 32
const COLS := 16
const ROWS := 1

## 真实材质包目录（tile 名.png）；置空则完全使用程序化占位图。
const TEXTURE_PACK_DIR := "res://assets/textures"

## tile 名称 -> 网格位置（index = col + row * COLS）。
## 新增方块面贴图时在此登记，方块定义通过名称引用。
const TILES := [
	"grass_top",
	"grass_side",
	"dirt",
	"stone",
	"bedrock",
	"log_top",
	"log_side",
	"planks",
	"cobblestone",
	"bricks",
	"sand",
	"sandstone",
	"gravel",
	"coal_ore",
	"iron_ore",
]

## 矿石斑点中心（程序化占位图用，确定性团簇）。
const COAL_SPOTS := [Vector2i(3, 4), Vector2i(10, 3), Vector2i(6, 11), Vector2i(12, 12)]
const IRON_SPOTS := [Vector2i(4, 3), Vector2i(11, 5), Vector2i(7, 10), Vector2i(13, 12), Vector2i(2, 12)]


static func tile_grid(tile_name: String) -> Vector2i:
	var index := TILES.find(tile_name)
	assert(index >= 0, "未知图集 tile: %s" % tile_name)
	@warning_ignore("integer_division")
	return Vector2i(index % COLS, index / COLS)


## 真实材质包覆盖的 tile 数量（诊断/测试用）。
static func packed_tile_count() -> int:
	var count := 0
	for tile in TILES:
		if _packed_image(tile) != null:
			count += 1
	return count


static func generate_atlas_image() -> Image:
	var image := Image.create_empty(
			COLS * TILE_SIZE, ROWS * TILE_SIZE, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	for i in TILES.size():
		var grid := tile_grid(TILES[i])
		var origin := Vector2i(grid.x * TILE_SIZE, grid.y * TILE_SIZE)
		var packed := _packed_image(TILES[i])
		if packed != null:
			# 统一尺寸与格式；丢弃 alpha（不透明方块按 RGB 处理）
			if packed.get_size() != Vector2i(TILE_SIZE, TILE_SIZE):
				packed.resize(TILE_SIZE, TILE_SIZE, Image.INTERPOLATE_NEAREST)
			packed.convert(Image.FORMAT_RGB8)
			image.blit_rect(packed, Rect2i(Vector2i.ZERO,
					Vector2i(TILE_SIZE, TILE_SIZE)), origin)
		else:
			rng.seed = TILES[i].hash()
			for py in TILE_SIZE:
				for px in TILE_SIZE:
					image.set_pixel(
							origin.x + px, origin.y + py,
							_pixel_color(TILES[i], px, py, rng))
	return image


static func generate_atlas_texture() -> ImageTexture:
	return ImageTexture.create_from_image(generate_atlas_image())


static func _packed_image(tile_name: String) -> Image:
	var path := TEXTURE_PACK_DIR + "/" + tile_name + ".png"
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(path)


static func _pixel_color(
		tile: String, px: int, py: int, rng: RandomNumberGenerator) -> Color:
	match tile:
		"grass_top":
			return _vary(Color("4c8c3b"), rng)
		"grass_side":
			# 顶部草皮条带（4 像素 + 1 像素锯齿过渡），其余为泥土。
			if py <= 3:
				return _vary(Color("4c8c3b"), rng)
			if py == 4 and rng.randf() < 0.5:
				return _vary(Color("4c8c3b"), rng)
			return _vary(Color("8a5a33"), rng)
		"dirt":
			return _vary(Color("8a5a33"), rng)
		"stone":
			return _vary(Color("8b8b90"), rng)
		"bedrock":
			var base := Color("3a3a40")
			if rng.randf() < 0.2:
				base = Color("26262b")
			return _vary(base, rng)
		"log_top":
			# 年轮：以中心作方形环带，深浅交替
			var ring := maxi(absi(px - 7), absi(py - 7))
			var wood := Color("9c7a4a") if ring % 2 == 0 else Color("7d5f38")
			if ring >= 7:
				wood = Color("6e5433")  # 外圈树皮
			return _vary(wood, rng)
		"log_side":
			# 竖向树皮条纹
			var bark := Color("6e5433")
			if px % 3 == 0:
				bark = Color("5a4428")
			if px % 7 == 4:
				bark = Color("7d6136")
			return _vary(bark, rng)
		"planks":
			# 横向木板 + 板缝，每板错位的竖向接缝
			var board := Color("b08a54")
			if py % 4 == 3:
				board = Color("7d5f38")
			elif (px + (2 if (py / 4) % 2 == 1 else 0)) % 8 == 0:
				board = Color("8d6b3e")
			return _vary(board, rng)
		"cobblestone":
			# 圆石：不规则深色缝格
			var stone := Color("8a8a8f")
			if px % 5 == 0 or py % 5 == 0 or (px + py) % 7 == 0:
				stone = Color("5f5f64")
			if rng.randf() < 0.1:
				stone = Color("76767c")
			return _vary(stone, rng)
		"bricks":
			# 砖块：砖红 + 灰浆横缝与错位竖缝
			var brick := Color("9e4a3a")
			if py % 4 == 3:
				brick = Color("9a9a92")
			elif (px + (4 if (py / 4) % 2 == 1 else 0)) % 8 == 7:
				brick = Color("9a9a92")
			return _vary(brick, rng)
		"sand":
			# 沙子：亮黄褐 + 明显颗粒感
			var grain := Color("d9c98e")
			if rng.randf() < 0.18:
				grain = Color("c7b47a")
			return _vary(grain, rng)
		"sandstone":
			# 砂岩：层积岩水平纹理
			var layer := Color("d3c284")
			if py % 4 == 0:
				layer = Color("c1b074")
			if py % 4 == 2 and rng.randf() < 0.3:
				layer = Color("caba7c")
			return _vary(layer, rng)
		"gravel":
			# 沙砾：三种灰度碎块随机混合
			var pick := rng.randi() % 3
			var clump := Color("8f8a84") if pick == 0 \
					else Color("7a756f") if pick == 1 else Color("a09a93")
			return _vary(clump, rng)
		"coal_ore":
			# 石底 + 黑色煤斑（固定团簇中心）
			if _near_spot(px, py, COAL_SPOTS, 1.6):
				return _vary(Color("26262a"), rng)
			return _vary(Color("8b8b90"), rng)
		"iron_ore":
			# 石底 + 铁锈斑
			if _near_spot(px, py, IRON_SPOTS, 1.5):
				return _vary(Color("c49a6a"), rng)
			return _vary(Color("8b8b90"), rng)
		_:
			# 未登记的 tile 用洋红色暴露问题（材质缺失回退策略 §11.2）
			return Color.MAGENTA


static func _near_spot(px: int, py: int, spots: Array, radius: float) -> bool:
	for spot in spots:
		var d := Vector2(px - spot.x, py - spot.y)
		if d.length() <= radius:
			return true
	return false


static func _vary(base: Color, rng: RandomNumberGenerator) -> Color:
	var amount := rng.randf_range(-0.07, 0.07)
	return Color(
		clampf(base.r + amount, 0.0, 1.0),
		clampf(base.g + amount, 0.0, 1.0),
		clampf(base.b + amount, 0.0, 1.0)
	)
