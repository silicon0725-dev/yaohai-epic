## 方块类型的稳定语义名称与运行时数值 ID（开发文档 §2.2、§5.2）。
## 数值 ID 顺序必须与 build_default_registry() 的注册顺序一致（由单元测试保证）。
## 阶段 E 前扩充：建造类（原木/木板/圆石/砖）仅可放置；
## 沙地与矿物（沙/砂岩/沙砾/煤矿/铁矿）参与地形生成（生成算法 v2）。
## 物品层新增字段（挖掘规则，interaction/block_mining.gd 消费）：
##   hardness      徒手基准挖掘秒数；-1 = 不可破坏（基岩）；0 = 即时
##   requires_tool 可选 {"class": "pickaxe", "min_tier": 2}：
##                 工具 class 匹配时按工具 speed 加速；
##                 tier 不足则 4 倍减速且不掉落物品（可挖开但白挖）
class_name VoxelTypes
extends RefCounted

const AIR_ID := 0
const GRASS_ID := 1
const DIRT_ID := 2
const STONE_ID := 3
const BEDROCK_ID := 4
const LOG_ID := 5
const PLANKS_ID := 6
const COBBLESTONE_ID := 7
const BRICKS_ID := 8
const SAND_ID := 9
const SANDSTONE_ID := 10
const GRAVEL_ID := 11
const COAL_ORE_ID := 12
const IRON_ORE_ID := 13
const WATER_ID := 14
const BRANCH_ID := 15
const LEAVES_ID := 16


## 构建默认注册表。textures 引用的是图集 tile 名称，
## 由 presentation/texture_atlas_loader.gd 解析到图集网格位置，
## 材质资源因此可以整体替换而不影响方块身份（§2.3）。
## 动态树（v6，参考 Dynamic Trees）：枝干按 radius 状态渲染
##（1-2 十字面片 / 3+ 方形柱，无碰撞不遮挡）；树叶不遮挡邻居
##（叶团内部面保留，避免整团被剔除成空壳）。
static func build_default_registry() -> VoxelRegistry:
	var registry := VoxelRegistry.new()
	registry.register_block({
		"id": "core:air",
		"render_type": "none",
		"textures": {},
		"collision": false,
		"occludes_neighbors": false,
		"hardness": 0.0,
	})
	registry.register_block({
		"id": "core:grass",
		"render_type": "opaque",
		"textures": {"top": "grass_top", "side": "grass_side", "bottom": "dirt"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 0.9,
	})
	registry.register_block({
		"id": "core:dirt",
		"render_type": "opaque",
		"textures": {"top": "dirt", "side": "dirt", "bottom": "dirt"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 0.75,
	})
	registry.register_block({
		"id": "core:stone",
		"render_type": "opaque",
		"textures": {"top": "stone", "side": "stone", "bottom": "stone"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 5.5,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	registry.register_block({
		"id": "core:bedrock",
		"render_type": "opaque",
		"textures": {"top": "bedrock", "side": "bedrock", "bottom": "bedrock"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": -1.0,
	})
	registry.register_block({
		"id": "core:log",
		"render_type": "opaque",
		"textures": {"top": "log_top", "side": "log_side", "bottom": "log_top"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 2.2,
	})
	registry.register_block({
		"id": "core:planks",
		"render_type": "opaque",
		"textures": {"top": "planks", "side": "planks", "bottom": "planks"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 2.0,
	})
	registry.register_block({
		"id": "core:cobblestone",
		"render_type": "opaque",
		"textures": {"top": "cobblestone", "side": "cobblestone", "bottom": "cobblestone"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 6.0,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	registry.register_block({
		"id": "core:bricks",
		"render_type": "opaque",
		"textures": {"top": "bricks", "side": "bricks", "bottom": "bricks"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 6.5,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	registry.register_block({
		"id": "core:sand",
		"render_type": "opaque",
		"textures": {"top": "sand", "side": "sand", "bottom": "sand"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 0.7,
	})
	registry.register_block({
		"id": "core:sandstone",
		"render_type": "opaque",
		"textures": {"top": "sandstone", "side": "sandstone", "bottom": "sandstone"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 4.0,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	registry.register_block({
		"id": "core:gravel",
		"render_type": "opaque",
		"textures": {"top": "gravel", "side": "gravel", "bottom": "gravel"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 0.85,
	})
	registry.register_block({
		"id": "core:coal_ore",
		"render_type": "opaque",
		"textures": {"top": "coal_ore", "side": "coal_ore", "bottom": "coal_ore"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 7.0,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	registry.register_block({
		"id": "core:iron_ore",
		"render_type": "opaque",
		"textures": {"top": "iron_ore", "side": "iron_ore", "bottom": "iron_ore"},
		"collision": true,
		"occludes_neighbors": true,
		"hardness": 9.0,
		"requires_tool": {"class": "pickaxe", "min_tier": 2},
	})
	# 水（v4 地形）：不可破坏（v1 无桶，无法收集/放置）、不遮挡、
	# 不参与碰撞；render_type 专用类别 "water"——网格器把它发到
	# 独立的半透明表面（§6.5：透明材质与不透明网格不混在第一版）
	registry.register_block({
		"id": "core:water",
		"render_type": "water",
		"textures": {},
		"collision": false,
		"occludes_neighbors": false,
		"hardness": -1.0,
	})
	registry.register_block({
		"id": "core:branch",
		"render_type": "branch",
		"textures": {"side": "log_side", "top": "log_top", "bottom": "log_top"},
		"collision": false,
		"occludes_neighbors": false,
		"hardness": 1.0,
	})
	registry.register_block({
		"id": "core:leaves",
		"render_type": "cutout",
		"textures": {"top": "leaves", "side": "leaves", "bottom": "leaves"},
		"collision": true,
		"occludes_neighbors": false,
		"hardness": 0.3,
	})
	return registry
