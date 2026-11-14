## 体素光照系统（光照阶段 2）：每区块 0-15 级天光/方块光传播与局部失效。
## 无 class_name（全局类缓存坑）——main preload 接线。
##
## 三条路径：
## - init_chunk_light(chunk, neighbors)：生成 worker 线程内做本块全量计算
##   （列直射天光 + 方块光源 + BFS 泛洪 + 邻块边界播入）。只写 chunk
##   自身；邻块引用由主线程入队时快照传入（避开 Dictionary 并发遍历）。
## - on_chunk_ready(chunk)：主线程（DATA_READY 提交后）把本块边界光向
##   已加载邻块播出（我亮邻暗方向；邻亮我暗已由 init 的种子播入覆盖），
##   邻块受影响则标 mesh_dirty 走现有重网格管线。
## - block_changed 增量（主线程同步）：透明度/发光变化 → 减光 BFS
##   （置 0 回收 + 边界亮格转增光种子重扩散）+ 增光 BFS → 变化格按块
##   分组标 mesh_dirty（set_block 已标本块，幂等）。
##
## 传播规则（MC 式）：步进衰减 max(1, opacity)；天光特例——向下传播且
## 当前 15 级且目标完全透光时保持 15（垂直直射）。光照数组为 transient
## 派生数据：不入库，重算即恢复（WaterFlow _pending 同模式）。
@tool
extends Node

const MAX_LEVEL := 15
const DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const DOWN := Vector3i(0, -1, 0)
const NativeMeshBridge := preload("res://meshing/native_mesh_bridge.gd")

var world: VoxelWorld
var _chunk_size := 16
## 光照变化块的插队重网格回调（main 接 chunk_manager._on_light_mesh_dirty；
## ef-000001 验收修复——挖掘后明暗 70-130ms 滞后的主因是重网格排
## 普通脏块通道）
var mesh_dirty_cb: Callable
## 当前 BFS 事务中光照变化的区块（coord -> true），flush 时标 mesh_dirty
var _dirty_chunks := {}


func setup(p_world: VoxelWorld) -> void:
	world = p_world
	_chunk_size = world.config.chunk_size
	world.block_changed.connect(_on_block_changed)
	world.blocks_changed_batch.connect(_on_blocks_changed_batch)


## 批量变更（树占位清理）：cells 实际所在块去重标脏，重算由帧预算
## drain 摊（曾同步对 cells 涉及的全部块立即重算——砍树一次 13.5ms，
## 审查二轮 B5）。邻块影响由 _recalc_one 的变化传播闭环，不必预扩散
func _on_blocks_changed_batch(cells: Array) -> void:
	for pos_v in cells:
		var pos: Vector3i = pos_v
		_light_dirty[VoxelCoords.world_to_chunk(pos, _chunk_size)] = true
	if not _light_dirty.is_empty():
		_drain_light(LIGHT_DRAIN_BUDGET_USEC)


# ============================================================
# 全量初始化（worker 线程；只写 chunk 自身）
# ============================================================

## neighbors：主线程快照的 6 面邻块引用，顺序同 DIRS
##（+x,-x,+y,-y,+z,-z），缺失为 null。可重复调用 = 重置重算。
## C# 优先（真实地形 GD p50 23ms / C# ~1ms 级），GD 为回退与等价真值。
## 列直射天光仅当上方邻块缺失（世界顶/垂直加载带顶——头上确为
## 天空）时从 15 起算；上方存在时从 0 起算、由其边界播入补齐
##（曾无条件 15 起算：深埋于区块顶层的洞穴格被灌满天光，合成
## 探针实锤上方全实心仍 sky=15）。chunk_manager 保证列内自上而下
## 入队，故"上方缺失"在游戏路径中恒等于"带顶"。
func init_chunk_light(chunk: ChunkData, neighbors: Array) -> void:
	var sky_above: bool = neighbors[2] == null
	if _init_chunk_light_native(chunk, neighbors, sky_above):
		return
	_init_chunk_light_gd(chunk, neighbors, sky_above)


## C# InitChunkLight：返回 true 表示已写入 chunk.light。
func _init_chunk_light_native(chunk: ChunkData, neighbors: Array,
		sky_above := true) -> bool:
	if not NativeMeshBridge.available():
		return false
	var s := chunk.dimensions.x
	var nlights := []
	var nexists := PackedByteArray()
	nexists.resize(6)
	for k in DIRS.size():
		var nb: ChunkData = neighbors[k]
		if nb == null:
			nlights.append(PackedByteArray())
		else:
			nlights.append(nb.light)
			nexists[k] = 1
	var result: Variant = NativeMeshBridge.native().InitChunkLight(
			s, chunk.block_ids,
			PackedByteArray(VoxelTypes.LIGHT_OPACITY),
			PackedByteArray(VoxelTypes.LIGHT_EMISSION),
			nlights, nexists, sky_above)
	if result == null:
		return false
	chunk.light = result
	return true


func _init_chunk_light_gd(chunk: ChunkData, neighbors: Array,
		sky_above := true) -> void:
	var dims := chunk.dimensions
	chunk.light.fill(0)
	# 1) 列直射天光：每列自顶向下；opacity 0 保持（15 不衰减直落），
	#    0<op<15 逐层衰减，实心（op>=15）后下方全 0（break）。
	#    仅 sky_above（上方确为天空）；否则由上方邻块面播入延续
	for z in (dims.z if sky_above else 0):
		for x in dims.x:
			var level := MAX_LEVEL
			for y in range(dims.y - 1, -1, -1):
				var local := Vector3i(x, y, z)
				var op := VoxelTypes.light_opacity(chunk.get_block(local))
				if op >= MAX_LEVEL:
					break
				if op > 0:
					level = maxi(0, level - maxi(1, op))
				if level <= 1:
					break  # 1 级无法再向外扩散，更深处保持 0
				chunk.set_sky_light(local, level)
	# 2) 方块光光源（本轮无光源方块，表全 0；框架就位）
	for i in chunk.volume():
		var em := VoxelTypes.light_emission(chunk.block_ids[i])
		if em > 0:
			chunk.light[i] = (chunk.light[i] & 0xF0) | em
	# 3) BFS 种子筛选：只收"光照不连续边界"格（4 水平邻或下方存在
	#    值差 >= 2 / 半透明衰减差）——均匀露天直射区（全 15）无种子，
	#    全量种子 BFS 曾是初始化的主要成本（真实地形 p50 51ms）。
	#    边界格扩散后新写入的格由 BFS 链式入队，覆盖完整
	var sky_pos: Array[Vector3i] = []
	var sky_val: Array[int] = []
	var ids := chunk.block_ids
	var lg := chunk.light
	for z in dims.z:
		for y in dims.y:
			var row_base := dims.x * (y + dims.y * z)
			for x in dims.x:
				var i := row_base + x
				var v := lg[i] >> 4
				if v <= 1:
					continue
				if _is_sky_border(ids, lg, dims, x, y, z, i, v):
					sky_pos.append(Vector3i(x, y, z))
					sky_val.append(v)
	if not sky_pos.is_empty():
		_bfs_single(chunk, sky_pos, sky_val, true)
	var blk_pos: Array[Vector3i] = []
	var blk_val: Array[int] = []
	for i in chunk.volume():
		if chunk.light[i] & 0x0F > 1:
			blk_pos.append(_local_of_index(chunk, i))
			blk_val.append(chunk.light[i] & 0x0F)
	if not blk_pos.is_empty():
		_bfs_single(chunk, blk_pos, blk_val, false)
	# 4) 已加载邻块边界光播入（邻亮我暗方向的输入；跨块泛洪后仍限本块）
	_seed_in_from_neighbors(chunk, neighbors)


## 天光种子判定：任一水平邻/下方格满足"我能把它提升"（值差 >= 2，
## 或其为半透明且 v - max(1,op) > 其现值）。实心邻格无法被提升。
static func _is_sky_border(
		ids: PackedInt32Array, lg: PackedByteArray, dims: Vector3i,
		x: int, y: int, z: int, i: int, v: int
) -> bool:
	var stride_y := dims.x
	var stride_z := dims.x * dims.y
	if x > 0 and _seed_pair(ids, lg, i - 1, v):
		return true
	if x < dims.x - 1 and _seed_pair(ids, lg, i + 1, v):
		return true
	if y > 0 and _seed_pair(ids, lg, i - stride_y, v):
		return true
	# +y：列直射断链（厚水/深叶 level<=1 break）处，水平光可向上渗透
	if y < dims.y - 1 and _seed_pair(ids, lg, i + stride_y, v):
		return true
	if z > 0 and _seed_pair(ids, lg, i - stride_z, v):
		return true
	if z < dims.z - 1 and _seed_pair(ids, lg, i + stride_z, v):
		return true
	return false


static func _seed_pair(
		ids: PackedInt32Array, lg: PackedByteArray, i_nb: int, v: int
) -> bool:
	var nb_v: int = lg[i_nb] >> 4
	if v - nb_v >= 2:
		return true
	var op := VoxelTypes.light_opacity(ids[i_nb])
	return op < MAX_LEVEL and v - maxi(1, op) > nb_v


func _seed_in_from_neighbors(chunk: ChunkData, neighbors: Array) -> void:
	var dims := chunk.dimensions
	for k in DIRS.size():
		var nb: ChunkData = neighbors[k]
		if nb == null:
			continue
		var axis: Vector3i = DIRS[k]
		# 邻块流进本块的传播方向 = -axis；天光直射特例仅当 -axis 向下
		var feed_down := axis == Vector3i(0, 1, 0)
		var in_sky_pos: Array[Vector3i] = []
		var in_sky_val: Array[int] = []
		var in_blk_pos: Array[Vector3i] = []
		var in_blk_val: Array[int] = []
		var ranges := _face_ranges(dims, axis)
		for a in ranges[0]:
			for b in ranges[1]:
				var my_local := _face_local(dims, axis, a, b)
				var nb_local := _map_into_neighbor(dims, axis, my_local)
				var byte_val: int = nb.light[nb.local_index(nb_local)]
				var op := VoxelTypes.light_opacity(chunk.get_block(my_local))
				if op >= MAX_LEVEL:
					continue
				var cur_sky := chunk.get_sky_light(my_local)
				var nl_sky := _step_level(byte_val >> 4, op, feed_down, true)
				if nl_sky > cur_sky:
					chunk.set_sky_light(my_local, nl_sky)
					in_sky_pos.append(my_local)
					in_sky_val.append(nl_sky)
				var cur_blk := chunk.get_block_light(my_local)
				var nl_blk := _step_level(byte_val & 0x0F, op, feed_down, false)
				if nl_blk > cur_blk:
					chunk.set_block_light(my_local, nl_blk)
					in_blk_pos.append(my_local)
					in_blk_val.append(nl_blk)
		if not in_sky_pos.is_empty():
			_bfs_single(chunk, in_sky_pos, in_sky_val, true)
		if not in_blk_pos.is_empty():
			_bfs_single(chunk, in_blk_pos, in_blk_val, false)


# ============================================================
# 邻块到达：边界光播出（主线程）
# ============================================================

func on_chunk_ready(chunk: ChunkData) -> void:
	_dirty_chunks.clear()
	var dims := chunk.dimensions
	for axis_i in DIRS:
		var axis: Vector3i = axis_i
		var nb: ChunkData = _chunk_at(chunk.chunk_coord + axis)
		if nb == null:
			continue
		# 本块流向邻块 = +axis；天光直射特例仅当 axis 向下
		var push_down := axis == DOWN
		var ranges := _face_ranges(dims, axis)
		for a in ranges[0]:
			for b in ranges[1]:
				var my_local := _face_local(dims, axis, a, b)
				var nb_local := _map_into_neighbor(dims, axis, my_local)
				if not nb.is_valid_local(nb_local):
					continue
				var byte_val: int = chunk.light[chunk.local_index(my_local)]
				var nb_i := nb.local_index(nb_local)
				var op := VoxelTypes.light_opacity(nb.get_block(nb_local))
				if op >= MAX_LEVEL:
					continue
				var nl_sky := _step_level(byte_val >> 4, op, push_down, true)
				if nl_sky > 1 and nl_sky > (nb.light[nb_i] >> 4):
					nb.set_sky_light(nb_local, nl_sky)
					_dirty_chunks[nb.chunk_coord] = true
					# 限界邻块内扩散（_bfs_single 不出块、内联位运算；
					# 曾用跨块 _bfs_world——world 字典查询让主线程
					# 播出成为加载期最大卡点。跨块链式传播由后到块的
					# init 种子播入最终收敛）
					var s_pos: Array[Vector3i] = [nb_local]
					var s_val: Array[int] = [nl_sky]
					_bfs_single(nb, s_pos, s_val, true)
				var nl_blk := _step_level(byte_val & 0x0F, op, push_down, false)
				if nl_blk > 1 and nl_blk > (nb.light[nb_i] & 0x0F):
					nb.set_block_light(nb_local, nl_blk)
					_dirty_chunks[nb.chunk_coord] = true
					var b_pos: Array[Vector3i] = [nb_local]
					var b_val: Array[int] = [nl_blk]
					_bfs_single(nb, b_pos, b_val, false)
	_flush_dirty()


# ============================================================
# block_changed → 块级脏集合（审查二轮 B1/B2/B7 重构）
# ============================================================

## 编辑只标块脏（O(1)，含 6 邻扩散）；_process 按预算逐块封盖重算。
## 演进史：①同步增量 BFS（单格 2-70ms 无界）→ ②格级队列"名义分帧
## 实际同步"（水流逐格 ×7 块重算 = 溃坝 tick 实测 950ms、96% 在光照，
## 审查二轮 B1）→ ③本版块级去重：512 格水流合并成 ≤27 块，tick 内
## 光照开销 O(1)/格，重算摊帧（每帧 2ms 预算）。单次编辑保留同帧
## 首拍（编辑块即时正确，跨块收敛随后帧）。重算 diff 有变化 →
## 6 邻重新标脏（传播波迭代至不动点，顺序无关——B7 跨块光缝根除：
## 先算块用过期邻值后会被邻块的变化再触发，值域 16 级有限必收敛）。
const LIGHT_DRAIN_BUDGET_USEC := 2000
var _light_dirty := {}  # chunk coord -> true

func _on_block_changed(pos: Vector3i, old_id: int, new_id: int) -> void:
	if VoxelTypes.light_opacity(old_id) == VoxelTypes.light_opacity(new_id) \
			and VoxelTypes.light_emission(old_id) \
					== VoxelTypes.light_emission(new_id):
		return  # 光照无关替换（草→土等）——入口快判免标脏
	var coord := VoxelCoords.world_to_chunk(pos, _chunk_size)
	if _chunk_at(coord) == null:
		return
	var was_empty := _light_dirty.is_empty()
	_light_dirty[coord] = true
	for d in DIRS:
		_light_dirty[coord + d] = true
	if was_empty:
		# 首拍同步（集合此前空=单次编辑/批量首格）：编辑块最先入
		# 集合最先重算，视觉即时；后续条目纯标脏由 _process 摊
		_drain_light(LIGHT_DRAIN_BUDGET_USEC)


func _process(_delta: float) -> void:
	if not _light_dirty.is_empty():
		_drain_light(LIGHT_DRAIN_BUDGET_USEC)


## 测试辅助：无预算清空脏集合并完成全部重算（断言前调用——
## 跨块收敛本是多帧异步语义，测试需确定性同步终态）
func flush() -> void:
	_drain_light(-1)


func _drain_light(budget_usec: int) -> void:
	var t0 := Time.get_ticks_usec()
	while not _light_dirty.is_empty():
		# 集合会在循环内被重插（收敛传播）——逐个取键而非快照遍历
		var coord: Vector3i = _light_dirty.keys()[0]
		_light_dirty.erase(coord)
		_recalc_one(coord)
		if budget_usec > 0 \
				and Time.get_ticks_usec() - t0 > budget_usec:
			return  # 剩余留在集合，下帧续


## 单块封盖重算（C# ~0.13ms p50；GD 回退全量 init 较慢但正确）。
## diff 无变化不标脏；有变化标 mesh_dirty 并把 6 邻重新入集合
##（其播种输入含本块新光——迭代至不动点）。
## diff 比较缓冲（单槽复用——重算串行，比较完成后才轮到下一块；
## 曾每块 duplicate 4KB×2，审查二轮 B3）
var _before_buf := PackedByteArray()


func _recalc_one(coord: Vector3i) -> void:
	var chunk := _chunk_at(coord)
	if chunk == null:
		return
	var six: Array = []
	for d in DIRS:
		six.append(_chunk_at(coord + d))
	_before_buf.resize(0)
	_before_buf.append_array(chunk.light)
	if _init_chunk_light_native(chunk, six, six[2] == null):
		pass  # C# 已覆盖 chunk.light（新数组实例，与缓冲比较安全）
	else:
		init_chunk_light(chunk, six)  # GD 回退（无 C# 降级形态）
	if chunk.light != _before_buf:
		chunk.mesh_dirty = true
		# 光照变化的块走插队重网格（ef-000001 验收：光照计算当帧
		# 0.13ms 完成，但重网格排普通脏块通道（4 帧分频 + 2/帧限流
		# + 流式在途竞争）→ 挖掘后明暗滞后 70-130ms 被用户实机感知。
		# 回调由 main 接到 chunk_manager 的光照豁免通道）
		if mesh_dirty_cb.is_valid():
			mesh_dirty_cb.call(coord)
		for d in DIRS:
			_light_dirty[coord + d] = true


# ============================================================
# BFS 核心
# ============================================================

## 步进衰减：常规 max(1,op)；天光垂直直射特例（向下 + 15 级 + 完全透光）。
func _step_level(lv: int, op: int, down: bool, sky: bool) -> int:
	if sky and down and lv == MAX_LEVEL and op == 0:
		return MAX_LEVEL
	return lv - maxi(1, op)


## 单块泛洪（初始化路径，worker 线程）：种子为 (local, 已写入值)。
func _bfs_single(
		chunk: ChunkData, q_pos: Array[Vector3i], q_val: Array[int], sky: bool
) -> void:
	var dims := chunk.dimensions
	# 内联位运算（get_block/get_sky_light/set_sky_light 函数调用在
	# 泛洪热循环里是主要开销——直查数组 + 掩码写）
	var ids := chunk.block_ids
	var lg := chunk.light
	var dx := dims.x
	var dy := dims.y
	var sky_mask_shift := 4 if sky else 0
	var keep_mask := 0x0F if sky else 0xF0
	var i := 0
	while i < q_pos.size():
		var p: Vector3i = q_pos[i]
		var lv: int = q_val[i]
		i += 1
		if lv <= 1:
			continue
		for d in DIRS:
			var n: Vector3i = p + d
			if n.x < 0 or n.x >= dx or n.y < 0 or n.y >= dy \
					or n.z < 0 or n.z >= dims.z:
				continue  # 不出块（跨块交给边界种子/播出）
			var ni := n.x + dx * (n.y + dy * n.z)
			var op := VoxelTypes.light_opacity(ids[ni])
			if op >= MAX_LEVEL:
				continue
			var nl := lv - maxi(1, op)
			if nl <= 1:
				continue
			if sky and lv == MAX_LEVEL and d == DOWN and op == 0:
				nl = MAX_LEVEL  # 天光垂直直射
			var cur: int = (lg[ni] >> sky_mask_shift) & 0x0F
			if cur >= nl:
				continue
			lg[ni] = (lg[ni] & keep_mask) | (nl << sky_mask_shift)
			q_pos.append(n)
			q_val.append(nl)


## 跨块泛洪（主线程）：种子为 (world_pos, 已写入值)，记账变化块。
func _bfs_world(
		q_pos: Array[Vector3i], q_val: Array[int], sky: bool
) -> void:
	var i := 0
	while i < q_pos.size():
		var p: Vector3i = q_pos[i]
		var lv: int = q_val[i]
		i += 1
		if lv <= 1:
			continue
		for d in DIRS:
			var n: Vector3i = p + d
			var op := _opacity_at(n)
			if op >= MAX_LEVEL:
				continue
			var nl := _step_level(lv, op, d == DOWN, sky)
			if nl <= 1:
				continue
			var cur := _light_at(n, sky)
			if cur < 0 or cur >= nl:
				continue
			if _set_light(n, nl, sky):
				_mark_dirty(n)
			q_pos.append(n)
			q_val.append(nl)


## 减光：old 为该格旧值（该格已置 0）。受光格回收置 0，
## 不受影响的亮邻格（>= old）转为增光种子重扩散。
func _decrease(pos: Vector3i, old: int, sky: bool) -> void:
	var q_pos: Array[Vector3i] = [pos]
	var q_val: Array[int] = [old]
	var re_pos: Array[Vector3i] = []
	var re_val: Array[int] = []
	var i := 0
	while i < q_pos.size():
		var p: Vector3i = q_pos[i]
		var lv: int = q_val[i]
		i += 1
		for d in DIRS:
			var n: Vector3i = p + d
			var nl := _light_at(n, sky)
			if nl <= 0:
				continue
			# 回收判定：值更低 = 由我供光；天光垂直 15/15 直射链；
			# <15 的等值链仅限完全透光格（op==0，露天梯度网封盖场景）——
			# 半透明区（水/叶）层内天然大片等值，无界等值链会横扫整片
			# 海域（水下放/破方块卡 90ms 的根因，实测插桩）；15 等值不
			# 回收（露天 15 来自天空直射，横向回收会横扫整片天空）
			var fed_by_me: bool = nl < lv \
					or (sky and lv == MAX_LEVEL and d == DOWN and nl == MAX_LEVEL) \
					or (nl == lv and lv < MAX_LEVEL and _opacity_at(n) == 0)
			if fed_by_me:
				if _set_light(n, 0, sky):
					_mark_dirty(n)
				q_pos.append(n)
				q_val.append(nl)
			else:
				re_pos.append(n)
				re_val.append(nl)
	if not re_pos.is_empty():
		_bfs_world(re_pos, re_val, sky)


# ============================================================
# 通道读写与记账（跨块路径）
# ============================================================

func _light_at(pos: Vector3i, sky: bool) -> int:
	var chunk := _chunk_at(VoxelCoords.world_to_chunk(pos, _chunk_size))
	if chunk == null:
		return -1
	var local := _to_local(pos)
	if sky:
		return chunk.get_sky_light(local)
	return chunk.get_block_light(local)


func _set_light(pos: Vector3i, value: int, sky: bool) -> bool:
	var chunk := _chunk_at(VoxelCoords.world_to_chunk(pos, _chunk_size))
	if chunk == null:
		return false
	var local := _to_local(pos)
	if sky:
		chunk.set_sky_light(local, value)
	else:
		chunk.set_block_light(local, value)
	return true


func _opacity_at(pos: Vector3i) -> int:
	var chunk := _chunk_at(VoxelCoords.world_to_chunk(pos, _chunk_size))
	if chunk == null:
		return MAX_LEVEL  # 未加载当实心（不向未加载区扩散）
	return VoxelTypes.light_opacity(chunk.get_block(_to_local(pos)))


func _mark_dirty(pos: Vector3i) -> void:
	_dirty_chunks[VoxelCoords.world_to_chunk(pos, _chunk_size)] = true


func _flush_dirty() -> void:
	for coord in _dirty_chunks:
		var chunk: ChunkData = world.chunks.get(coord)
		if chunk != null:
			chunk.mesh_dirty = true
	_dirty_chunks.clear()


func _chunk_at(coord: Vector3i) -> ChunkData:
	return world.chunks.get(coord)


func _to_local(pos: Vector3i) -> Vector3i:
	return VoxelCoords.world_to_local(pos, _chunk_size)


func _local_of_index(chunk: ChunkData, index: int) -> Vector3i:
	var dims := chunk.dimensions
	var z := index / (dims.x * dims.y)
	var rem := index - z * dims.x * dims.y
	var y := rem / dims.x
	return Vector3i(rem - y * dims.x, y, z)


# ============================================================
# 面几何辅助（axis 含方向：面在 axis 正向端）
# ============================================================

func _face_ranges(dims: Vector3i, axis: Vector3i) -> Array:
	if axis.x != 0:
		return [range(dims.y), range(dims.z)]
	if axis.y != 0:
		return [range(dims.x), range(dims.z)]
	return [range(dims.x), range(dims.y)]


## axis 正向端面上的格（切向分量 a/b）。
func _face_local(dims: Vector3i, axis: Vector3i, a: int, b: int) -> Vector3i:
	if axis.x != 0:
		return Vector3i(dims.x - 1 if axis.x > 0 else 0, a, b)
	if axis.y != 0:
		return Vector3i(a, dims.y - 1 if axis.y > 0 else 0, b)
	return Vector3i(a, b, dims.z - 1 if axis.z > 0 else 0)


## 我方面格对应邻块内一格（切向相同、axis 分量翻转到对面）。
func _map_into_neighbor(
		dims: Vector3i, axis: Vector3i, face_local: Vector3i
) -> Vector3i:
	if axis.x != 0:
		return Vector3i(0 if axis.x > 0 else dims.x - 1, face_local.y, face_local.z)
	if axis.y != 0:
		return Vector3i(face_local.x, 0 if axis.y > 0 else dims.y - 1, face_local.z)
	return Vector3i(face_local.x, face_local.y, 0 if axis.z > 0 else dims.z - 1)
