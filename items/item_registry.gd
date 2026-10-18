## 物品注册表：稳定语义名称 <-> 运行时数值 ID（与 VoxelRegistry 同构，§2.2）。
## 物品存档（背包序列化）必须使用稳定名称，防止注册顺序变化破坏旧存档。
## 物品定义字段：
##   id            稳定语义名称，例如 "core:stone"、"core:wooden_pickaxe"
##   display_name  HUD 显示名（默认字体无 CJK 字形，用英文）
##   max_stack     单格最大堆叠（方块/材料 64，工具 1）
##   place_block   可选：放置类物品对应的方块稳定名称（如 "core:dirt"）
##   tool          可选：{"class": "pickaxe", "tier": 2, "speed": 4.0}
##                 class 匹配方块 requires_tool.class 时按 speed 加速，
##                 tier >= 方块 min_tier 才会掉落物品
##   icon          表现层引用（不参与逻辑）：{"tile": 图集 tile 名} 或
##                 {"pixel_art": 程序化图案名}，见 presentation/item_icons.gd
class_name ItemRegistry
extends RefCounted

var _items: Array[Dictionary] = []
var _id_by_name := {}
var _voxel_registry: VoxelRegistry
## 物品名 -> 方块数值 ID 的解析缓存（place_block 物品）。
var _place_block_ids := {}


func _init(voxel_registry: VoxelRegistry = null) -> void:
	_voxel_registry = voxel_registry


## 注册一个物品定义，返回分配的数值 ID。注册顺序发布后不可重排。
func register_item(definition: Dictionary) -> int:
	var item_name: String = definition.get("id", "")
	assert(item_name != "", "物品定义缺少 id")
	assert(not _id_by_name.has(item_name), "重复注册物品: " + item_name)
	var numeric_id := _items.size()
	_items.append(definition)
	_id_by_name[item_name] = numeric_id
	return numeric_id


func item_count() -> int:
	return _items.size()


## 未知名称返回 -1。
func id_for_name(item_name: String) -> int:
	return _id_by_name.get(item_name, -1)


## 未知 ID 返回空字符串。
func name_for_id(id: int) -> String:
	if id < 0 or id >= _items.size():
		return ""
	return _items[id].get("id", "")


## 未知 ID 返回空字典。
func definition_for_id(id: int) -> Dictionary:
	if id < 0 or id >= _items.size():
		return {}
	return _items[id]


func display_name(id: int) -> String:
	return String(definition_for_id(id).get("display_name", name_for_id(id)))


func max_stack(id: int) -> int:
	return int(definition_for_id(id).get("max_stack", 64))


## 该物品放置时的方块数值 ID；非放置类或未注册方块返回 -1。
func place_block_id(id: int) -> int:
	if _place_block_ids.has(id):
		return _place_block_ids[id]
	var block_name := String(definition_for_id(id).get("place_block", ""))
	if block_name == "" or _voxel_registry == null:
		_place_block_ids[id] = -1
		return -1
	var block_id := _voxel_registry.id_for_name(block_name)
	_place_block_ids[id] = block_id
	return block_id


## 工具定义（无 tool 字段返回空字典）。
func tool_for(id: int) -> Dictionary:
	var tool: Dictionary = definition_for_id(id).get("tool", {})
	return tool
