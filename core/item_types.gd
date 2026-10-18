## 物品类型的默认定义（与 VoxelTypes 同模式）。
## 放置类物品的 id 与方块稳定名称一致（core:grass 既指方块也指其物品），
## 保证"挖什么得什么、放什么消耗什么"的映射直观。
## 材料与工具类物品（core:coal、core:wooden_pickaxe）为纯物品，无方块。
class_name ItemTypes
extends RefCounted


## 新世界起始装备（也用于缺失 inventory 键的旧档迁移）：
## [物品稳定名称, 数量]。木镐保证石头系可掉落开采。
const STARTING_KIT := [
	["core:wooden_pickaxe", 1],
	["core:dirt", 16],
	["core:planks", 16],
]


## 构建默认物品注册表。block_registry 用于解析 place_block -> 方块数值 ID。
## 注册顺序发布后不可重排（测试断言数值 ID）；新物品一律追加到末尾。
static func build_default_item_registry(
		block_registry: VoxelRegistry) -> ItemRegistry:
	var registry := ItemRegistry.new(block_registry)

	# ---- 放置类：方块物品（图标用其 side 贴图，grass 用 grass_side）----
	_block_item(registry, "core:grass", "Grass", "grass_side")
	_block_item(registry, "core:dirt", "Dirt", "dirt")
	_block_item(registry, "core:stone", "Stone", "stone")
	_block_item(registry, "core:log", "Log", "log_side")
	_block_item(registry, "core:planks", "Planks", "planks")
	_block_item(registry, "core:cobblestone", "Cobblestone", "cobblestone")
	_block_item(registry, "core:bricks", "Bricks", "bricks")
	_block_item(registry, "core:sand", "Sand", "sand")
	_block_item(registry, "core:sandstone", "Sandstone", "sandstone")
	_block_item(registry, "core:gravel", "Gravel", "gravel")
	_block_item(registry, "core:iron_ore", "Iron Ore", "iron_ore")

	# ---- 材料类 ----
	registry.register_item({
		"id": "core:coal",
		"display_name": "Coal",
		"max_stack": 64,
		"icon": {"pixel_art": "coal"},
	})

	# ---- 工具类 ----
	registry.register_item({
		"id": "core:wooden_pickaxe",
		"display_name": "Wooden Pickaxe",
		"max_stack": 1,
		"tool": {"class": "pickaxe", "tier": 2, "speed": 4.0},
		"icon": {"pixel_art": "pickaxe_wood"},
	})
	registry.register_item({
		"id": "core:stone_pickaxe",
		"display_name": "Stone Pickaxe",
		"max_stack": 1,
		"tool": {"class": "pickaxe", "tier": 3, "speed": 8.0},
		"icon": {"pixel_art": "pickaxe_stone"},
	})
	# 新物品一律追加到末尾（数值 ID 发布后不可重排，§2.2）
	registry.register_item({
		"id": "core:stick",
		"display_name": "Stick",
		"max_stack": 64,
		"icon": {"pixel_art": "stick"},
	})
	return registry


static func _block_item(
		registry: ItemRegistry,
		block_name: String,
		display_name: String,
		icon_tile: String) -> void:
	registry.register_item({
		"id": block_name,
		"display_name": display_name,
		"max_stack": 64,
		"place_block": block_name,
		"icon": {"tile": icon_tile},
	})
