## 合成规则（物品层规则层）。v1 为无序配方（inputs 计数匹配即可，
## 无网格摆放）；原子性由 craft() 保证：先全量校验、再统一消耗、
## 最后产出（产出放不下时按挖掘掉落同语义告警丢弃）。
## 配方链构成工具升级闭环（开发文档玩法扩展第一步）：
##   原木 -> 木板 -> 木棍 -> 木镐 -> 挖石头得圆石 -> 石镐
class_name CraftingRecipes
extends RefCounted

## 配方定义：inputs [[稳定名称, 数量], ...]、output [稳定名称, 数量]。
## 名称在 craft/can_craft 时经 ItemRegistry 解析（§2.2 稳定身份）。
const RECIPES := [
	{
		"id": "core:planks_from_log",
		"inputs": [["core:log", 1]],
		"output": ["core:planks", 4],
	},
	{
		"id": "core:stick_from_planks",
		"inputs": [["core:planks", 2]],
		"output": ["core:stick", 4],
	},
	{
		"id": "core:wooden_pickaxe",
		"inputs": [["core:planks", 3], ["core:stick", 2]],
		"output": ["core:wooden_pickaxe", 1],
	},
	{
		"id": "core:stone_pickaxe",
		"inputs": [["core:cobblestone", 3], ["core:stick", 2]],
		"output": ["core:stone_pickaxe", 1],
	},
]


## 全部配方（UI 渲染用；字典为 const 引用，调用方不得改写）。
static func all() -> Array:
	return RECIPES


## 按稳定名称查配方；不存在返回空字典。
static func by_id(recipe_id: String) -> Dictionary:
	for recipe in RECIPES:
		if String(recipe["id"]) == recipe_id:
			return recipe
	return {}


## 背包是否集齐该配方全部材料（跨堆计数）。
static func can_craft(recipe: Dictionary, inventory: Inventory) -> bool:
	var items := inventory.item_registry()
	for entry: Array in recipe.get("inputs", []):
		var item_id := items.id_for_name(String(entry[0]))
		if item_id < 0 or inventory.count_of(item_id) < int(entry[1]):
			return false
	return true


## 原子合成：校验 -> 消耗 -> 产出。任何一步不满足返回 false 且
## 背包不变；产出放不下时消耗照常、多余产出告警丢弃（与挖掘掉落
## 背包满同语义）。
static func craft(recipe: Dictionary, inventory: Inventory) -> bool:
	if recipe.is_empty() or not can_craft(recipe, inventory):
		return false
	var items := inventory.item_registry()
	for entry: Array in recipe["inputs"]:
		inventory.remove_item(items.id_for_name(String(entry[0])), int(entry[1]))
	var output: Array = recipe["output"]
	var output_id := items.id_for_name(String(output[0]))
	var leftover := inventory.add(output_id, int(output[1]))
	if leftover > 0:
		push_warning("背包已满，%d 个合成产物丢失" % leftover)
	return true
