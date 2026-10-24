## 水流动模拟（v2：扩散/下落/断供回退）。
## MC 式元胞自动机，水位存方块状态 "level"（§4.3，随存档持久化）：
## - 无状态 = 0 = 源（海洋填充、永久不退）
## - 1..7   = 流动水，离源越远级别越大、渲染高度越低（7 格扩散半径）
## - 8      = 下落水柱（头顶有水的竖直段，满格渲染，落地后按 1 级扩散）
## 规则（每格每 tick）：
## 1. 下方是空气 -> 优先向下灌（成 level 8），本 tick 不再横向扩散
## 2. 自我校验：流动水必须被供给（上方水 -> 8；否则水平邻居最小级别 +1，
##    无供给或超过 7 -> 退化为空气）。源（0）永久
## 3. 水平扩散：寻坡简化版——4 向扫描 4 格内最近落差，只朝落差方向流；
##    平地才四向铺开。子级 = 自身级别 +1（8 按 1 计），超过 7 不再扩
## 扰动来源：VoxelWorld.block_changed 信号（挖掘/放置/水自身写入）。
## 写入走 VoxelWorld.set_block / set_block_state，自动标记网格与存档过期。
class_name WaterFlow
extends Node

const TICK_INTERVAL := 0.25
## 单 tick 最多评估格数（防大范围溃坝卡帧；剩余顺延下一 tick）。
const MAX_CELLS_PER_TICK := 512
## 寻坡扫描半径（格）：范围内的最近落差决定流向。
const SLOPE_SEEK_RANGE := 4

const UP := Vector3i(0, 1, 0)
const DOWN := Vector3i(0, -1, 0)
const HORIZONTAL_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var world: VoxelWorld

## 待评估位置（Vector3i -> true，Dictionary 保插入序作 FIFO 集合）。
var _pending := {}
var _accumulator := 0.0


func setup(voxel_world: VoxelWorld) -> void:
	world = voxel_world
	world.block_changed.connect(_on_block_changed)


func _process(delta: float) -> void:
	_accumulator += delta
	while _accumulator >= TICK_INTERVAL:
		_accumulator -= TICK_INTERVAL
		tick()


## 方块变更 -> 扰动入队：变更位置的 6 邻居（自身若是水也入队）。
## 评估非水格是廉价 no-op，宁可多入队也不漏扰动。
func _on_block_changed(pos: Vector3i, _old_id: int, _new_id: int) -> void:
	_enqueue(pos)
	for d in HORIZONTAL_DIRS:
		_enqueue(pos + d)
	_enqueue(pos + UP)
	_enqueue(pos + DOWN)


func _enqueue(pos: Vector3i) -> void:
	_pending[pos] = true


## 跑一批模拟步（测试可直接调用，不依赖 _process 节拍）。
## 返回本 tick 实际发生变更的格数。
func tick() -> int:
	var positions: Array = _pending.keys()
	_pending = {}
	var changes := 0
	var evaluated := 0
	for pos in positions:
		if evaluated >= MAX_CELLS_PER_TICK:
			_pending[pos] = true  # 顺延下一 tick
			continue
		evaluated += 1
		if _evaluate(pos):
			changes += 1
	return changes


## ---- 规则实现 ----

func _evaluate(pos: Vector3i) -> bool:
	if world.get_block(pos) != VoxelTypes.WATER_ID:
		return false
	var lvl := _level(pos)
	var above_water := world.get_block(pos + UP) == VoxelTypes.WATER_ID

	# 1) 向下流：任何级别的水都优先灌满下方空气
	if world.get_block(pos + DOWN) == VoxelTypes.AIR_ID:
		_set_water(pos + DOWN, 8)
		return true

	# 2) 自我校验：源（0）永久；其余必须有上游供给
	if lvl != 0:
		var target := 8 if above_water else _supply_target(pos, lvl)
		if target != lvl:
			if target < 0:
				world.set_block(pos, VoxelTypes.AIR_ID, false)
			else:
				world.set_block(pos, VoxelTypes.WATER_ID, false)
				world.set_block_state(pos, "level", target, true)
			return true

	# 3) 水平扩散（仅当下方已非空气）。先短路：4 邻全非空气时
	# 连寻坡扫描都不必做（稳定水体内部的大量格子走这条快路径）
	var spread := 1 if lvl == 8 else lvl + 1
	if spread > 7:
		return false
	var has_air_neighbor := false
	for d in HORIZONTAL_DIRS:
		if world.get_block(pos + d) == VoxelTypes.AIR_ID:
			has_air_neighbor = true
			break
	if not has_air_neighbor:
		return false
	var changed := false
	for d in _spread_dirs(pos):
		var q := pos + d
		if world.get_block(q) == VoxelTypes.AIR_ID:
			_set_water(q, spread)
			changed = true
	return changed


## 水平供给计算：4 邻居中"级别严格小于自身"的水的最小级别 +1；
## 无更小级别邻居返回 -1（退化为空气）。下落柱（8）横向等效源级
## （0）供给——落地水柱周围维持 level 1。只降不升防止水池互相
## 供给不消退（MC 同款语义）；拆源后从边缘逐层剥落。
func _supply_target(pos: Vector3i, lvl: int) -> int:
	var min_lvl := lvl
	for d in HORIZONTAL_DIRS:
		if world.get_block(pos + d) != VoxelTypes.WATER_ID:
			continue
		var nl := _level(pos + d)
		if nl > 7:
			nl = 0
		if nl < min_lvl:
			min_lvl = nl
	if min_lvl >= lvl:
		return -1
	return min_lvl + 1


## 寻坡：4 向扫描 SLOPE_SEEK_RANGE 格内"空气且其下方也是空气"的落差，
## 只朝最近落差方向的相邻格流；范围内无落差则四向铺开（平地成池）。
func _spread_dirs(pos: Vector3i) -> Array[Vector3i]:
	var best := SLOPE_SEEK_RANGE + 1
	var result: Array[Vector3i] = []
	for d in HORIZONTAL_DIRS:
		for step in range(1, SLOPE_SEEK_RANGE + 1):
			var q := pos + d * step
			var qid := world.get_block(q)
			if qid != VoxelTypes.AIR_ID and qid != VoxelTypes.WATER_ID:
				break  # 实心挡路，此向不通
			if qid == VoxelTypes.AIR_ID \
					and world.get_block(q + DOWN) == VoxelTypes.AIR_ID:
				if step < best:
					best = step
					result = [d]
				elif step == best:
					result.append(d)
				break  # 该方向最近落差已找到
	if result.is_empty():
		return HORIZONTAL_DIRS
	return result


func _set_water(pos: Vector3i, lvl: int) -> void:
	# set_block 清空状态，随后写入级别（级别 0 = 源，无状态即默认）。
	# 水无碰撞体：affects_collision=false 跳过碰撞形状重建（§性能）
	world.set_block(pos, VoxelTypes.WATER_ID, false)
	if lvl > 0:
		world.set_block_state(pos, "level", lvl, true)


func _level(pos: Vector3i) -> int:
	return int(world.get_block_state(pos).get("level", 0))


## ---- 供表现/测试查询 ----

## 调试用：待评估格数。
func pending_count() -> int:
	return _pending.size()


## ---- 供物理查询（玩家/掉落物水流推力）----

## 格所在水体的实际水位（世界 y）：向上扫到表面格（被覆盖的中层
## 格不算表面）+ 级别水面高度；非水格返回 -INF。
## 玩家涉水判定与掉落物浮力目标共用。
static func water_surface_at(world: VoxelWorld, pos: Vector3i) -> float:
	if world.get_block(pos) != VoxelTypes.WATER_ID:
		return -INF
	var surface_cell := pos
	while world.get_block(surface_cell + Vector3i(0, 1, 0)) 			== VoxelTypes.WATER_ID:
		surface_cell += Vector3i(0, 1, 0)
	return float(surface_cell.y) + ChunkMesher.water_surface_height(
			int(world.get_block_state(surface_cell).get("level", 0)))


## 某水格的流向（单位向量，无流向返回零向量）：
## - 下方空气 -> 竖直向下（下落段/瀑布顶）；
## - 否则水平朝"级别更大"的水邻格——级别随离源距离递增，
##   更大级别 = 地势更低的下游（下落柱 8 是水流汇入点，按最大级
##   参与，物品会漂向柱并随之坠下）；
## - 无更大级别邻时查落差边：邻格空气且其下方也空气 -> 朝该方向
##   （物品被冲到台阶边后落下）。**仅对流动水（level >= 1）**：
##   源是静水（MC 同款语义——源不推人，一格宽的源水柱边缘不该
##   产生假流向把物品推离；真实水道的边缘是流动水，会被推走）；
## - 都没有 -> 零向量（静止水不推）。
static func flow_direction_at(world: VoxelWorld, pos: Vector3i) -> Vector3:
	if world.get_block(pos) != VoxelTypes.WATER_ID:
		return Vector3.ZERO
	if world.get_block(pos + DOWN) == VoxelTypes.AIR_ID:
		return Vector3(0.0, -1.0, 0.0)
	var self_lvl := int(world.get_block_state(pos).get("level", 0))
	var best_lvl := self_lvl
	var best_dir := Vector3.ZERO
	for d in HORIZONTAL_DIRS:
		var q := pos + d
		if world.get_block(q) != VoxelTypes.WATER_ID:
			continue
		var nl := int(world.get_block_state(q).get("level", 0))
		if nl > best_lvl:
			best_lvl = nl
			best_dir = Vector3(d.x, 0.0, d.z)
	if best_dir != Vector3.ZERO:
		return best_dir
	if self_lvl == 0:
		return Vector3.ZERO  # 源是静水：无下游也无落差推力
	for d in HORIZONTAL_DIRS:
		var q := pos + d
		if world.get_block(q) == VoxelTypes.AIR_ID 				and world.get_block(q + DOWN) == VoxelTypes.AIR_ID:
			return Vector3(d.x, 0.0, d.z)
	return Vector3.ZERO
