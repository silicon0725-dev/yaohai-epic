## 方块注册表：稳定语义名称 <-> 运行时数值 ID 的唯一映射（开发文档 §2.2）。
## 数值 ID 只用于运行时紧凑存储；存档层（阶段 D）必须保存稳定名称
## 或带版本映射的数值 ID，防止重排注册表破坏旧存档。
class_name VoxelRegistry
extends RefCounted

## 注册顺序即数值 ID。注册表一旦发布，顺序不可重排。
var _blocks: Array[Dictionary] = []
var _id_by_name := {}


## 注册一个方块定义（结构见 §7.2），返回分配的数值 ID。
## 定义字段：
##   id                 稳定语义名称，例如 "core:stone"
##   render_type        "none"（不渲染，如空气）或 "opaque"
##   textures           { top / side / bottom -> 图集 tile 名称 }
##   collision          是否参与碰撞
##   occludes_neighbors 是否完全遮挡相邻面（透明方块应为 false）
func register_block(definition: Dictionary) -> int:
	var block_name: String = definition.get("id", "")
	assert(block_name != "", "方块定义缺少 id")
	assert(not _id_by_name.has(block_name), "重复注册方块: " + block_name)
	var numeric_id := _blocks.size()
	_blocks.append(definition)
	_id_by_name[block_name] = numeric_id
	return numeric_id


func block_count() -> int:
	return _blocks.size()


## 未知名称返回 -1。
func id_for_name(block_name: String) -> int:
	return _id_by_name.get(block_name, -1)


## 未知 ID 返回空字符串。
func name_for_id(id: int) -> String:
	if id < 0 or id >= _blocks.size():
		return ""
	return _blocks[id].get("id", "")


## 未知 ID 返回空字典。
func definition_for_id(id: int) -> Dictionary:
	if id < 0 or id >= _blocks.size():
		return {}
	return _blocks[id]


## 该方块是否完全遮挡相邻面（用于可见面剔除，§6.1）。
func occludes(id: int) -> bool:
	return definition_for_id(id).get("occludes_neighbors", false)


## 该方块是否产生可见几何（空气为 false；水为 true，走独立水面）。
func is_solid(id: int) -> bool:
	return definition_for_id(id).get("render_type", "none") != "none"


## 射线/出生点扫描的"可命中实体"判定：可见几何且非水——
## 挖掘射线穿过水（MC 同款），出生点搜索也跳过水柱。
func is_targetable(id: int) -> bool:
	var render_type := String(definition_for_id(id).get("render_type", "none"))
	return render_type != "none" and render_type != "water"
