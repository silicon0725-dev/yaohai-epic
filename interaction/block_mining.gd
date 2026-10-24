## 方块挖掘规则（开发文档 §8.2 + 物品层）。
## 挖掘时长由方块 hardness 与手持工具共同决定（break_info）；
## 玩家控制器负责按住累积进度，进度满后调用 mine() 破坏并结算掉落。
## 基岩 hardness=-1 不可挖掘，防止破坏世界底层与边界策略。
class_name BlockMining
extends RefCounted

## 树系统回调（main 注入：BRANCH 占位被挖时通知 TreeManager）。
## 静态变量由 main.gd 赋值（RefCounted 无 export）。
static var tree_callback: Callable

## 工具等级不满足 requires_tool.min_tier 时的减速倍率与掉落禁止。
const WRONG_TOOL_PENALTY := 4.0


## 挖掘信息：{ seconds: float, drops: bool, breakable: bool }。
##   seconds    挖穿所需秒数（工具 class 匹配按 speed 加速；
##              requires_tool 未满足时 4 倍减速）
##   drops      破坏时是否掉落物品（requires_tool 未满足则 false）
##   breakable  是否可破坏（基岩/空气 false）
## tool_def 为手持物品的 tool 定义（空字典 = 徒手）。
static func break_info(
		block_id: int,
		registry: VoxelRegistry,
		tool_def: Dictionary) -> Dictionary:
	if block_id == VoxelTypes.AIR_ID:
		return {"seconds": 0.0, "drops": false, "breakable": false}
	var definition := registry.definition_for_id(block_id)
	var hardness := float(definition.get("hardness", 1.0))
	if hardness < 0.0:
		return {"seconds": 0.0, "drops": false, "breakable": false}
	var requires: Dictionary = definition.get("requires_tool", {})
	if requires.is_empty():
		# 无工具要求（泥土/原木等）：v1 尚无铲/斧类工具，一律基准速度
		return {"seconds": hardness, "drops": true, "breakable": true}
	# 有工具要求：class 匹配且 tier 足够才享受加速与掉落
	var tool_class := String(requires.get("class", ""))
	var min_tier := int(requires.get("min_tier", 1))
	var matches := String(tool_def.get("class", "")) == tool_class
	var tier_ok := int(tool_def.get("tier", 1)) >= min_tier
	if matches and tier_ok:
		return {
			"seconds": hardness / maxf(float(tool_def.get("speed", 1.0)), 1.0),
			"drops": true,
			"breakable": true,
		}
	if matches:
		# class 对但等级不够：正常速度链但 4 倍减速、不掉落
		return {
			"seconds": hardness * WRONG_TOOL_PENALTY / maxf(float(tool_def.get("speed", 1.0)), 1.0),
			"drops": false,
			"breakable": true,
		}
	# 徒手挖工具方块：基准硬度 4 倍减速、不掉落
	return {
		"seconds": hardness * WRONG_TOOL_PENALTY,
		"drops": false,
		"breakable": true,
	}


static func can_mine(block_id: int, registry: VoxelRegistry) -> bool:
	return break_info(block_id, registry, {}).get("breakable", false)


## 破坏方块。返回掉落列表（[{item_id, count}]，可直接喂给 Inventory.add）。
## allow_drops 由调用方按 break_info().drops 传入（工具等级不足 = 白挖）；
## 未破坏（空气/基岩）返回空数组。
## 内部经 VoxelWorld.set_block，自动标记网格/碰撞/存档过期并传播到邻区块。
static func mine(
		world: VoxelWorld,
		block_pos: Vector3i,
		item_registry: ItemRegistry,
		allow_drops := true) -> Array:
	var block_id := world.get_block(block_pos)
	if not can_mine(block_id, world.registry):
		return []
	# 结构化树：BRANCH 的 set_block AIR 会经 block_changed 信号
	# 驱动 TreeManager 砍伐管线（不再用 static var 回调——失效过）
	if not world.set_block(block_pos, VoxelTypes.AIR_ID):
		return []
	if not allow_drops:
		return []
	return DropTable.drops_for(block_id, world.registry, item_registry)
