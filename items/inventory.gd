## 槽位背包（物品层数据核心）。
## 槽位为 { item_id: int, count: int } 或空字典；前 hotbar_size 格即快捷栏。
## 所有堆叠操作遵守 ItemRegistry.max_stack；改动后发 changed 信号（UI 刷新）。
## 序列化使用物品稳定名称（§2.2 原则同样适用于物品注册表）。
class_name Inventory
extends RefCounted

signal changed

var slots: Array = []
var hotbar_size := 0
var _registry: ItemRegistry


## 只读访问关联的物品注册表（合成规则/UI 解析名称用）。
func item_registry() -> ItemRegistry:
	return _registry


func _init(registry: ItemRegistry, size: int, hotbar: int) -> void:
	_registry = registry
	slots.resize(size)
	for i in size:
		slots[i] = {}
	hotbar_size = mini(hotbar, size)


func size() -> int:
	return slots.size()


func slot(index: int) -> Dictionary:
	return slots[index]


func is_empty(index: int) -> bool:
	return slots[index].is_empty()


func item_id_at(index: int) -> int:
	return int(slots[index].get("item_id", -1))


func count_at(index: int) -> int:
	return int(slots[index].get("count", 0))


## 添加物品：先并入已有同类堆，再开新堆。返回放不下的剩余数量
##（背包满时调用方决定丢弃或拒绝动作）。
func add(item_id: int, count: int) -> int:
	if item_id < 0 or count <= 0:
		return count
	var remaining := count
	var max_stack := _registry.max_stack(item_id)
	# 第一遍：并入已有堆
	for i in slots.size():
		if remaining <= 0:
			break
		if item_id_at(i) == item_id and count_at(i) < max_stack:
			var space := max_stack - count_at(i)
			var moved := mini(space, remaining)
			slots[i]["count"] = count_at(i) + moved
			remaining -= moved
	# 第二遍：空格开新堆
	for i in slots.size():
		if remaining <= 0:
			break
		if is_empty(i):
			var moved := mini(max_stack, remaining)
			slots[i] = {"item_id": item_id, "count": moved}
			remaining -= moved
	if remaining < count:
		changed.emit()
	return remaining


## 从指定槽移除 count 个（不跨槽）。返回实际移除数量。
func remove_at(index: int, count: int) -> int:
	if is_empty(index) or count <= 0:
		return 0
	var took := mini(count_at(index), count)
	var left := count_at(index) - took
	if left <= 0:
		slots[index] = {}
	else:
		slots[index]["count"] = left
	changed.emit()
	return took


## 跨堆移除同类物品共 count 个（从末尾堆往前扣，合成消耗用）。
## 返回实际移除数量（不足时移除现有全部——调用方 craft 前已校验）。
func remove_item(item_id: int, count: int) -> int:
	if item_id < 0 or count <= 0:
		return 0
	var remaining := count
	for i in range(slots.size() - 1, -1, -1):
		if remaining <= 0:
			break
		if item_id_at(i) == item_id:
			remaining -= remove_at(i, remaining)
	return count - remaining


## 全背包同类物品总数。
func count_of(item_id: int) -> int:
	var total := 0
	for i in slots.size():
		if item_id_at(i) == item_id:
			total += count_at(i)
	return total


func has_item(item_id: int, count: int = 1) -> bool:
	return count_of(item_id) >= count


## 同类合并；不同类交换；空格之一则移动。不完整的同类堆部分合并。
func move_or_swap(from: int, to: int) -> void:
	if from == to or from < 0 or to < 0 \
			or from >= slots.size() or to >= slots.size():
		return
	if is_empty(from):
		return
	if is_empty(to):
		slots[to] = slots[from]
		slots[from] = {}
	elif item_id_at(from) == item_id_at(to):
		var max_stack := _registry.max_stack(item_id_at(to))
		var space := max_stack - count_at(to)
		var moved := mini(space, count_at(from))
		if moved <= 0:
			return  # 目标堆已满：交换无意义，保持原状
		slots[to]["count"] = count_at(to) + moved
		var left := count_at(from) - moved
		if left <= 0:
			slots[from] = {}
		else:
			slots[from]["count"] = left
	else:
		var tmp: Dictionary = slots[to]
		slots[to] = slots[from]
		slots[from] = tmp
	changed.emit()


## 起始装备（新世界/旧档迁移）。放不下的部分直接忽略。
func apply_starting_kit(kit: Array) -> void:
	for entry in kit:
		var item_name: String = entry[0]
		var count: int = entry[1]
		var item_id := _registry.id_for_name(item_name)
		if item_id >= 0:
			add(item_id, count)


func clear() -> void:
	for i in slots.size():
		slots[i] = {}
	changed.emit()


# ---- 序列化（稳定名称，未知名称跳过）----

func serialize() -> Array:
	var data := []
	for i in slots.size():
		if is_empty(i):
			data.append({})
		else:
			data.append({
				"item": _registry.name_for_id(item_id_at(i)),
				"count": count_at(i),
			})
	return data


func deserialize(data: Array) -> void:
	clear()
	for i in mini(data.size(), slots.size()):
		var entry: Dictionary = data[i]
		var item_id := _registry.id_for_name(String(entry.get("item", "")))
		var count := int(entry.get("count", 0))
		if item_id >= 0 and count > 0:
			slots[i] = {"item_id": item_id, "count": mini(
					count, _registry.max_stack(item_id))}
	changed.emit()
