## 塔科夫式多格网格背包（数据核心，替代旧槽位 Inventory）。
## 条目占格模型：物品按注册表 grid_w×grid_h 占多格（如镐 1×2），拖拽可
## 旋转（footprint 宽高互换）。分区：MAIN 主网格 / HOTBAR 快捷栏 /
## GEAR 穿戴预留容器。自动入包（拾取/合成产出/起始装备）只寻位
## HOTBAR→MAIN（先快捷栏），绝不进 GEAR（穿戴区只能手动拖放）。
## 条目字段：{ uid, item_id, count, zone, x, y, rotated }；uid 为自增标识
## （Dictionary == 是深比较，同内容条目无法区分，删除/查找一律按 uid）。
## 聚合 API（add/can_fit/count_of/remove_item…）与旧 Inventory 同名同
## 语义，DropManager/CraftingRecipes 零改动。序列化 v2 用物品稳定名称
## （§2.2）；旧槽位存档（Array）读入时自动 first-fit 迁移。
class_name GridInventory
extends RefCounted

signal changed

## 批量事务（审查二轮 D7）：begin/end 之间的 changed 合并为末尾一次
## ——合成（消耗 N 种材料+产出）曾发 3-5 次，消费者 _refresh_hud
## 每次 8 轮 hotbar 全扫+背包面板全量重建
var _batch_depth := 0


func begin_batch() -> void:
	_batch_depth += 1


func end_batch() -> void:
	_batch_depth = maxi(_batch_depth - 1, 0)
	if _batch_depth == 0:
		_emit_changed()


func _emit_changed() -> void:
	if _batch_depth == 0:
		changed.emit()

enum Zone { MAIN, HOTBAR, GEAR }

## 自动入包（add/can_fit）的寻位顺序：快捷栏 → 主网格（沿用旧槽位
## 背包"前 N 格即快捷栏"的先填快捷栏语义，保证拾取物/起始装备
## 优先出现在玩家可选的列上）。
const AUTO_ZONES := [Zone.HOTBAR, Zone.MAIN]

## 放下拖拽条目的结果（try_drop 返回值）。
enum DropResult { PLACED, MERGED, PARTIAL, BLOCKED }

var entries: Array = []
var hotbar_columns := 8

var _registry: ItemRegistry
var _zone_sizes := {}
var _next_uid := 1


func _init(registry: ItemRegistry,
		main_size := Vector2i(8, 9),
		hotbar_size := Vector2i(8, 2),
		gear_size := Vector2i(4, 4)) -> void:
	_registry = registry
	hotbar_columns = hotbar_size.x
	_zone_sizes = {
		Zone.MAIN: main_size,
		Zone.HOTBAR: hotbar_size,
		Zone.GEAR: gear_size,
	}


# ---- 只读查询 ----

func item_registry() -> ItemRegistry:
	return _registry


func zone_size(zone: int) -> Vector2i:
	return _zone_sizes.get(zone, Vector2i.ZERO)


## 条目实际占格（rotated 时宽高互换）。
func footprint(item_id: int, rotated: bool) -> Vector2i:
	var size := _registry.grid_size(item_id)
	return Vector2i(size.y, size.x) if rotated else size


## 覆盖格 (zone,x,y) 的条目；空格返回 {}。条目量级 <百，线性扫即可。
func entry_at_cell(zone: int, x: int, y: int) -> Dictionary:
	for e in entries:
		if int(e["zone"]) != zone:
			continue
		var fp := footprint(int(e["item_id"]), bool(e["rotated"]))
		var ex := int(e["x"])
		var ey := int(e["y"])
		if x >= ex and x < ex + fp.x and y >= ey and y < ey + fp.y:
			return e
	return {}


func is_empty_cell(zone: int, x: int, y: int) -> bool:
	return entry_at_cell(zone, x, y).is_empty()


## 指定分区的条目列表（渲染层按 uid 建节点用）。
func entries_in(zone: int) -> Array:
	var result: Array = []
	for e in entries:
		if int(e["zone"]) == zone:
			result.append(e)
	return result


## 快捷栏第 col 列的选中条目：覆盖该列的条目中起始行最小者优先；
## 空列返回 {}（上下两格各一个 1×1 条目时选上格）。
func hotbar_pick(col: int) -> Dictionary:
	var best := {}
	for e in entries:
		if int(e["zone"]) != Zone.HOTBAR:
			continue
		var fp := footprint(int(e["item_id"]), bool(e["rotated"]))
		var ex := int(e["x"])
		if col >= ex and col < ex + fp.x:
			if best.is_empty() or int(e["y"]) < int(best["y"]):
				best = e
	return best


# ---- 占位与寻位 ----

## 条目能否放在 (zone,x,y)（左上角锚点）。ignore_uid 忽略自身（旋转原位）。
func can_place(item_id: int, zone: int, x: int, y: int, rotated: bool,
		ignore_uid := -1) -> bool:
	var fp := footprint(item_id, rotated)
	var size := zone_size(zone)
	if x < 0 or y < 0 or x + fp.x > size.x or y + fp.y > size.y:
		return false
	for e in entries:
		if int(e["uid"]) == ignore_uid or int(e["zone"]) != zone:
			continue
		var efp := footprint(int(e["item_id"]), bool(e["rotated"]))
		# 矩形相交判定
		if x < int(e["x"]) + efp.x and int(e["x"]) < x + fp.x \
				and y < int(e["y"]) + efp.y and int(e["y"]) < y + fp.y:
			return false
	return true


## 为一个新堆找落点（行序扫描，多格物品先自然朝向再旋转）。
## 返回 {zone,x,y,rotated} 或空字典。
func first_fit(item_id: int, zones: Array = AUTO_ZONES) -> Dictionary:
	var rotatable := _registry.grid_size(item_id) != Vector2i.ONE
	for zone in zones:
		var size := zone_size(int(zone))
		for y in size.y:
			for x in size.x:
				if can_place(item_id, int(zone), x, y, false):
					return {"zone": int(zone), "x": x, "y": y, "rotated": false}
				if rotatable and can_place(item_id, int(zone), x, y, true):
					return {"zone": int(zone), "x": x, "y": y, "rotated": true}
	return {}


## 堆叠上限：多格物品不可堆叠（两堆同物品占位语义矛盾），强制 1。
func _stack_limit(item_id: int) -> int:
	if _registry.grid_size(item_id) == Vector2i.ONE:
		return _registry.max_stack(item_id)
	return 1


func _is_auto_zone(zone: int) -> bool:
	return zone == Zone.MAIN or zone == Zone.HOTBAR


# ---- 聚合 API（与旧 Inventory 同名同语义）----

## 自动入包：先并入已有同类非满堆（仅 AUTO 区），再 first_fit 开新堆。
## 返回放不下的剩余数量（调用方决定丢弃或拒绝）。
func add(item_id: int, count: int) -> int:
	if item_id < 0 or count <= 0:
		return count
	var limit := _stack_limit(item_id)
	var remaining := count
	# 第一遍：并入已有堆（仅可堆叠物品）
	if limit > 1:
		for e in entries:
			if remaining <= 0:
				break
			if not _is_auto_zone(int(e["zone"])):
				continue
			if int(e["item_id"]) == item_id and int(e["count"]) < limit:
				var moved := mini(limit - int(e["count"]), remaining)
				e["count"] = int(e["count"]) + moved
				remaining -= moved
	# 第二遍：开新堆
	while remaining > 0:
		var spot := first_fit(item_id)
		if spot.is_empty():
			break
		var put := mini(limit, remaining)
		_spawn_entry(item_id, put, int(spot["zone"]),
				int(spot["x"]), int(spot["y"]), bool(spot["rotated"]))
		remaining -= put
	if remaining < count:
		_emit_changed()
	return remaining


## AUTO 区是否还装得下 count 个（已有非满同类堆空隙 + 影子模拟空位容量）。
func can_fit(item_id: int, count := 1) -> bool:
	if item_id < 0 or count <= 0:
		return false
	var limit := _stack_limit(item_id)
	var space := 0
	for e in entries:
		if _is_auto_zone(int(e["zone"])) and int(e["item_id"]) == item_id:
			space += limit - int(e["count"])
			if space >= count:
				return true
	# 空位容量：影子占用网格上贪心开堆（多格物品相邻锚点会重复计数，
	# 必须逐堆铺入影子后重扫）
	var occupied := {}
	for e in entries:
		_mark_footprint(occupied, e)
	var capacity := 0
	while capacity < count:
		var spot := _first_fit_shadow(occupied, item_id, limit)
		if spot.is_empty():
			break
		var fp := footprint(item_id, bool(spot["rotated"]))
		for dy in fp.y:
			for dx in fp.x:
				occupied[[int(spot["zone"]), int(spot["x"]) + dx,
						int(spot["y"]) + dy]] = true
		capacity += limit
	return space + capacity >= count


func count_of(item_id: int) -> int:
	var total := 0
	for e in entries:
		if int(e["item_id"]) == item_id:
			total += int(e["count"])
	return total


func has_item(item_id: int, count: int = 1) -> bool:
	return count_of(item_id) >= count


## 跨堆移除同类物品共 count 个（条目序从后往前扣，合成消耗沿用旧语义）。
func remove_item(item_id: int, count: int) -> int:
	if item_id < 0 or count <= 0:
		return 0
	var remaining := count
	for i in range(entries.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var e: Dictionary = entries[i]
		if int(e["item_id"]) == item_id:
			remaining -= remove_at_entry(e, remaining)
	return count - remaining


## 从指定条目移除 count 个（不跨堆）。返回实际移除数量。
func remove_at_entry(entry: Dictionary, count: int) -> int:
	if entry.is_empty() or count <= 0 or int(entry.get("count", 0)) <= 0:
		return 0
	var took := mini(int(entry["count"]), count)
	var left := int(entry["count"]) - took
	if left <= 0:
		_remove_entry(entry)
	else:
		entry["count"] = left
	_emit_changed()
	return took


## 起始装备（新世界/旧档迁移）。放不下的部分直接忽略。
func apply_starting_kit(kit: Array) -> void:
	for entry in kit:
		var item_name: String = entry[0]
		var count: int = entry[1]
		var item_id := _registry.id_for_name(item_name)
		if item_id >= 0:
			add(item_id, count)


func clear() -> void:
	entries.clear()
	_emit_changed()


# ---- 拖拽原语（背包 UI 用；zone 不限，GEAR 可手动放）----

## 拿起：从网格移除并返回该条目；空格返回 {}。
func pickup(zone: int, x: int, y: int) -> Dictionary:
	var e := entry_at_cell(zone, x, y)
	if e.is_empty():
		return {}
	_remove_entry(e)
	_emit_changed()
	return e


## 落点检查："place" 直接落格 / "merge" 并入落点同类 1×1 非满堆 /
## "blocked" 放不下。
func drop_check(entry: Dictionary, zone: int, x: int, y: int,
		rotated: bool) -> String:
	# 同类 1×1 并堆：双方都必须是 1×1（可堆叠物品必然 1×1）
	if footprint(int(entry["item_id"]), rotated) == Vector2i.ONE:
		var target := entry_at_cell(zone, x, y)
		if not target.is_empty() \
				and int(target["item_id"]) == int(entry["item_id"]) \
				and footprint(int(target["item_id"]),
						bool(target["rotated"])) == Vector2i.ONE \
				and int(target["count"]) < _stack_limit(int(target["item_id"])):
			return "merge"
	if can_place(int(entry["item_id"]), zone, x, y, rotated):
		return "place"
	return "blocked"


## 放下拖拽条目。返回 DropResult：
## PLACED 已落格 / MERGED 整堆并入（条目消失）/ PARTIAL 部分
## 并入（entry["count"] 为余量，调用方继续手持）/ BLOCKED 放不下（未变）。
func try_drop(entry: Dictionary, zone: int, x: int, y: int,
		rotated: bool) -> int:
	var what := drop_check(entry, zone, x, y, rotated)
	if what == "place":
		entry["zone"] = zone
		entry["x"] = x
		entry["y"] = y
		entry["rotated"] = rotated
		entries.append(entry)
		_emit_changed()
		return DropResult.PLACED
	if what == "merge":
		var target := entry_at_cell(zone, x, y)
		var limit := _stack_limit(int(entry["item_id"]))
		var moved := mini(limit - int(target["count"]), int(entry["count"]))
		target["count"] = int(target["count"]) + moved
		entry["count"] = int(entry["count"]) - moved
		_emit_changed()
		return DropResult.MERGED if int(entry["count"]) <= 0 else DropResult.PARTIAL
	return DropResult.BLOCKED


# ---- 序列化（稳定名称；v2 = 条目网格，旧 Array 槽位档自动迁移）----

func serialize() -> Dictionary:
	var data := []
	for e in entries:
		data.append({
			"item": _registry.name_for_id(int(e["item_id"])),
			"count": int(e["count"]),
			"zone": int(e["zone"]),
			"x": int(e["x"]),
			"y": int(e["y"]),
			"rotated": bool(e["rotated"]),
		})
	return {"v": 2, "entries": data}


func deserialize(data) -> void:
	clear()
	if data is Array:
		# 旧槽位存档：逐堆 first-fit 迁移
		for entry: Dictionary in data:
			var item_id := _registry.id_for_name(
					String(entry.get("item", "")))
			var count := int(entry.get("count", 0))
			if item_id >= 0 and count > 0:
				add(item_id, count)
		return
	if data is Dictionary and int(data.get("v", 0)) == 2:
		for entry: Dictionary in data.get("entries", []):
			var item_id := _registry.id_for_name(
					String(entry.get("item", "")))
			var count := mini(int(entry.get("count", 0)),
					_stack_limit(item_id)) if item_id >= 0 else 0
			if item_id < 0 or count <= 0:
				continue
			var zone := int(entry.get("zone", Zone.MAIN))
			var x := int(entry.get("x", 0))
			var y := int(entry.get("y", 0))
			var rotated := bool(entry.get("rotated", false))
			# 位置合法则原位恢复；越界/重叠降级 first-fit，物品不丢
			if can_place(item_id, zone, x, y, rotated):
				_spawn_entry(item_id, count, zone, x, y, rotated)
			else:
				add(item_id, count)


# ---- 内部 ----

func _spawn_entry(item_id: int, count: int, zone: int, x: int, y: int,
		rotated: bool) -> void:
	entries.append({
		"uid": _next_uid,
		"item_id": item_id,
		"count": count,
		"zone": zone,
		"x": x,
		"y": y,
		"rotated": rotated,
	})
	_next_uid += 1


## 按 uid 删除（Dictionary == 深比较，同内容条目会误删，禁用 erase）。
func _remove_entry(entry: Dictionary) -> void:
	var uid := int(entry.get("uid", -1))
	for i in entries.size():
		if int(entries[i].get("uid", -1)) == uid:
			entries.remove_at(i)
			return


func _mark_footprint(occupied: Dictionary, e: Dictionary) -> void:
	var fp := footprint(int(e["item_id"]), bool(e["rotated"]))
	for dy in fp.y:
		for dx in fp.x:
			occupied[[int(e["zone"]), int(e["x"]) + dx,
					int(e["y"]) + dy]] = true


## 影子占用网格上的 first_fit（can_fit 空位容量模拟用）。
func _first_fit_shadow(occupied: Dictionary, item_id: int,
		_limit: int) -> Dictionary:
	var rotatable := _registry.grid_size(item_id) != Vector2i.ONE
	var variants: Array = [false] if not rotatable else [false, true]
	for zone in AUTO_ZONES:
		var size := zone_size(int(zone))
		for y in size.y:
			for x in size.x:
				for rotated: bool in variants:
					var fp := footprint(item_id, rotated)
					if x + fp.x > size.x or y + fp.y > size.y:
						continue
					var free := true
					for dy in fp.y:
						for dx in fp.x:
							if occupied.has([int(zone), x + dx, y + dy]):
								free = false
								break
						if not free:
							break
					if free:
						return {"zone": int(zone), "x": x, "y": y,
								"rotated": rotated}
	return {}
