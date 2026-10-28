## 注册表与图集单元测试：稳定 ID 映射、图集布局、图集生成确定性。
extends VoxelTestCase


func run() -> void:
	var registry := VoxelTypes.build_default_registry()
	check_eq(registry.id_for_name("core:air"), VoxelTypes.AIR_ID, "air 数值 ID")
	check_eq(registry.id_for_name("core:grass"), VoxelTypes.GRASS_ID, "grass 数值 ID")
	check_eq(registry.id_for_name("core:dirt"), VoxelTypes.DIRT_ID, "dirt 数值 ID")
	check_eq(registry.id_for_name("core:stone"), VoxelTypes.STONE_ID, "stone 数值 ID")
	check_eq(registry.id_for_name("core:bedrock"), VoxelTypes.BEDROCK_ID, "bedrock 数值 ID")
	check_eq(
		registry.name_for_id(VoxelTypes.STONE_ID), "core:stone", "数值 ID 反查稳定名称")
	check_eq(registry.id_for_name("core:missing"), -1, "未知名称返回 -1")
	check(not registry.occludes(VoxelTypes.AIR_ID), "空气不遮挡相邻面")
	check(registry.occludes(VoxelTypes.STONE_ID), "石头遮挡相邻面")
	check(not registry.is_solid(VoxelTypes.AIR_ID), "空气不产生几何")
	check(registry.is_solid(VoxelTypes.GRASS_ID), "草产生几何")

	# 阶段 E 扩充方块 + v4 水：注册顺序与数值 ID 常量一致
	check(registry.block_count() >= 17, "方块总数 >= 17（空气+水+枝/叶+追加；曾硬编码 17，加方块即挂）")
	check_eq(registry.id_for_name("core:water"), VoxelTypes.WATER_ID,
			"water 数值 ID（追加在末尾，§2.2）")
	check(not registry.occludes(VoxelTypes.WATER_ID), "水不遮挡邻面")
	check(not registry.is_targetable(VoxelTypes.WATER_ID), "射线穿过水")
	check(registry.is_solid(VoxelTypes.WATER_ID), "水产生几何（独立水面）")
	check_eq(registry.id_for_name("core:log"), VoxelTypes.LOG_ID, "log 数值 ID")
	check_eq(registry.id_for_name("core:planks"), VoxelTypes.PLANKS_ID, "planks 数值 ID")
	check_eq(registry.id_for_name("core:cobblestone"), VoxelTypes.COBBLESTONE_ID, "cobblestone 数值 ID")
	check_eq(registry.id_for_name("core:bricks"), VoxelTypes.BRICKS_ID, "bricks 数值 ID")
	check_eq(registry.id_for_name("core:sand"), VoxelTypes.SAND_ID, "sand 数值 ID")
	check_eq(registry.id_for_name("core:sandstone"), VoxelTypes.SANDSTONE_ID, "sandstone 数值 ID")
	check_eq(registry.id_for_name("core:gravel"), VoxelTypes.GRAVEL_ID, "gravel 数值 ID")
	check_eq(registry.id_for_name("core:coal_ore"), VoxelTypes.COAL_ORE_ID, "coal_ore 数值 ID")
	check_eq(registry.id_for_name("core:iron_ore"), VoxelTypes.IRON_ORE_ID, "iron_ore 数值 ID")
	check(registry.occludes(VoxelTypes.SAND_ID), "沙子遮挡相邻面")
	check(registry.is_solid(VoxelTypes.BRICKS_ID), "砖块产生几何")
	var log_def := registry.definition_for_id(VoxelTypes.LOG_ID)
	check_eq(log_def["textures"]["top"], "log_top", "原木顶面年轮贴图")
	check_eq(log_def["textures"]["side"], "log_side", "原木侧面树皮贴图")
	check_eq(log_def["textures"]["bottom"], "log_top", "原木底面年轮贴图")

	var grass_def := registry.definition_for_id(VoxelTypes.GRASS_ID)
	check_eq(grass_def["textures"]["top"], "grass_top", "草方块顶面贴图")
	check_eq(grass_def["textures"]["side"], "grass_side", "草方块侧面贴图")
	check_eq(grass_def["textures"]["bottom"], "dirt", "草方块底面贴图")

	# 图集布局与 UV 计算
	var rect := AtlasUV.tile_rect(Vector2i(1, 0), 8, 1)
	check(rect.position.is_equal_approx(Vector2(0.125, 0.0)), "tile(1,0) UV 起点")
	check(rect.size.is_equal_approx(Vector2(0.125, 1.0)), "tile UV 尺寸")
	check_eq(
		TextureAtlasLoader.tile_grid("grass_side"), Vector2i(1, 0),
		"grass_side 网格位置")
	check_eq(
		TextureAtlasLoader.tile_grid("bedrock"), Vector2i(4, 0),
		"bedrock 网格位置")
	var corner := AtlasUV.corner_uv(rect, Vector2(1, 1))
	check(corner.is_equal_approx(Vector2(0.25, 1.0)), "角点 UV 映射")

	# 图集生成：尺寸与确定性
	var image := TextureAtlasLoader.generate_atlas_image()
	check_eq(
		image.get_width(), TextureAtlasLoader.COLS * TextureAtlasLoader.TILE_SIZE,
		"图集宽度")
	check_eq(
		image.get_height(), TextureAtlasLoader.ROWS * TextureAtlasLoader.TILE_SIZE,
		"图集高度")
	var image2 := TextureAtlasLoader.generate_atlas_image()
	check(
		image.get_data() == image2.get_data(), "图集逐像素生成确定性")
	# 占位贴图不应出现未登记 tile 的洋红色
	var has_magenta := false
	for px in image.get_width():
		for py in image.get_height():
			if image.get_pixel(px, py).is_equal_approx(Color.MAGENTA):
				has_magenta = true
				break
		if has_magenta:
			break
	check(not has_magenta, "图集无未登记 tile（无洋红像素）")
