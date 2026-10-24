## 挖掘掉落规则（世界规则层）：方块数值 ID -> 掉落物品列表。
## 默认规则：掉方块自身对应的物品（core:stone -> core:stone）。
## 例外表按稳定名称声明，与数值 ID 解耦（§2.2）：
##   core:grass      -> core:dirt        （草方块掉泥土，草皮不转移）
##   core:stone      -> core:cobblestone （经典：挖石得圆石）
##   core:coal_ore   -> core:coal        （煤矿掉煤，不掉矿石方块）
##   core:bedrock    -> 无               （不可破坏，正常到不了这里）
## 工具等级不满足时是否掉落由 BlockMining.break_info 决定，本表只管
## "满足条件时掉什么"。
class_name DropTable
extends RefCounted

## 方块稳定名称 -> [物品稳定名称, 数量]。
const EXCEPTIONS := {
	"core:grass": [["core:dirt", 1]],
	"core:stone": [["core:cobblestone", 1]],
	"core:coal_ore": [["core:coal", 1]],
	"core:bedrock": [],
	"core:branch": [["core:stick", 1]],   # 细枝掉木棍（动态树）
	"core:leaves": [],                    # 树叶无掉落（v1 无树苗物品）
}


## 返回 [{item_id: int, count: int}, ...]；未知方块默认掉自身物品。
static func drops_for(
		block_id: int,
		voxel_registry: VoxelRegistry,
		item_registry: ItemRegistry) -> Array:
	var block_name := voxel_registry.name_for_id(block_id)
	if block_name == "":
		return []
	if EXCEPTIONS.has(block_name):
		var result := []
		for entry: Array in EXCEPTIONS[block_name]:
			var item_id := item_registry.id_for_name(entry[0])
			if item_id >= 0:
				result.append({"item_id": item_id, "count": entry[1]})
		return result
	# 默认：方块自身的同名物品
	var self_item := item_registry.id_for_name(block_name)
	if self_item >= 0:
		return [{"item_id": self_item, "count": 1}]
	return []
