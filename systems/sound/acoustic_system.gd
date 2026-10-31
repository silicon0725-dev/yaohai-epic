## 声学系统：遮挡 / 房间混响 / 水下闷化。混合方案（各取所长）：
## - 遮挡 = Sound Physics 射线法（声源→玩家递进 trace 累计遮挡，
##   半透明方块 0.15 系数，cutoff=exp(-occ×吸收)）
## - 房间混响 = Sound Filters 腔体 flood fill（玩家眼格 BFS 空气腔
##   上限 512 格）→ roomFactor/skyFactor → Reverb 参数；skyFactor
##   直接读体素天光（腔体格 skylight==15 占比）——零射线成本
## - 水下 = 玩家眼在水中 → 全局 LowPass 拉低（Sound Filters
##   LiquidLowPass 语义）
## 纯函数（遮挡计数/混响映射）静态可测；flood fill 与射线只走
## 体素数据（无引擎查询），headless 安全。
class_name AcousticSystem
extends RefCounted

## 遮挡：非满格方块（树叶/细枝）的穿透系数（Sound Physics 0.15）
const TRANSPARENT_OCCLUSION := 0.15
## 遮挡吸收系数（Sound Physics globalBlockAbsorption×3）
const ABSORPTION_COEFF := 1.35
## 遮挡射线最大递进次数（Sound Physics 10）
const OCCLUSION_TRACES := 10
## 混响腔体 flood fill 上限（Sound Filters 1024，我们取一半省时）
const CAVE_FILL_MAX := 512
## 腔体评估周期（秒；Sound Filters 13 tick ≈0.65）
const EVAL_PERIOD := 0.5
## 水下低通截止（Hz）
const UNDERWATER_CUTOFF := 3200.0
## 干线低通默认截止（透明——预挂 LowPass 靠参数切换免增删）
const OPEN_CUTOFF := 20000.0

## 满格不透明（LIGHT_OPACITY 15）；水 2/枝叶 1 视为半透明
static func is_opaque_block(block_id: int) -> bool:
	return VoxelTypes.light_opacity(block_id) >= 15


static func is_transparent_block(block_id: int) -> bool:
	var op := VoxelTypes.light_opacity(block_id)
	return op > 0 and op < 15


## 方块声学反射率（Sound Physics getBlockReflectivity 的简化表）：
## 石硬面高反射、木中、草土吸声；水强吸声
static func reflectivity(block_id: int) -> float:
	match block_id:
		3, 4, 7, 8, 12, 13:  # stone/bedrock/cobble/bricks/矿物
			return 0.9
		5, 6, 17, 18:  # log/planks/torch/lantern
			return 0.7
		9, 10:  # sand/sandstone
			return 0.5
		1, 2, 11:  # grass/dirt/gravel
			return 0.4
		14:  # water
			return 0.2
		_:
			return 0.5


## ---- 遮挡（Sound Physics evaluateEnvironment 直接声路径） ----

## 声源→听者的遮挡累计：DDA 体素步进，满格 +1.0 / 半透明 +0.15。
## 返回 [0,∞)，0=直通。max_dist 限程（超出按无遮挡计）。
static func occlusion_between(world: VoxelWorld, from: Vector3,
		to: Vector3, max_dist := 32.0) -> float:
	var delta := to - from
	var dist := delta.length()
	if dist < 0.5 or dist > max_dist:
		return 0.0
	var dir := delta / dist
	var pos := Vector3i(floori(from.x), floori(from.y), floori(from.z))
	var end_cell := Vector3i(floori(to.x), floori(to.y), floori(to.z))
	var step := Vector3i(
			1 if dir.x > 0.0 else -1,
			1 if dir.y > 0.0 else -1,
			1 if dir.z > 0.0 else -1)
	# Amanatides-Woo：各轴到下一格边界的 t 与步进 tDelta
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for axis in 3:
		var d: float = dir[axis]
		if absf(d) < 1.0e-6:
			t_delta[axis] = INF
			t_max[axis] = INF
		else:
			var boundary := float(pos[axis] + 1) if d > 0.0 \
					else float(pos[axis])
			t_max[axis] = (boundary - from[axis]) / d
			t_delta[axis] = 1.0 / absf(d)
	var occ := 0.0
	var t := 0.0
	var first := true
	while t < dist:
		# 起点格跳过（放置音的源格即新方块本身，不能自遮挡）
		if not first and pos != end_cell:
			var b := world.get_block(pos)
			if is_opaque_block(b):
				occ += 1.0
			elif is_transparent_block(b):
				occ += TRANSPARENT_OCCLUSION
		first = false
		# 步进到最近边界
		if t_max.x < t_max.y and t_max.x < t_max.z:
			t = t_max.x
			t_max.x += t_delta.x
			pos.x += step.x
		elif t_max.y < t_max.z:
			t = t_max.y
			t_max.y += t_delta.y
			pos.y += step.y
		else:
			t = t_max.z
			t_max.z += t_delta.z
			pos.z += step.z
		if occ >= OCCLUSION_TRACES:
			break
	return occ


## 遮挡→总线档位：0=干；≤0.6=轻挡（LowPass 5kHz）；>0.6=重挡
## （LowPass 1.2kHz）。directGain = cutoff^0.1（Sound Physics）
static func occlusion_bus(occ: float) -> String:
	if occ <= 0.01:
		return "SFX"
	return "SFXOcc1" if occ <= 0.6 else "SFXOcc2"


static func occlusion_gain(occ: float) -> float:
	var cutoff := exp(-occ * ABSORPTION_COEFF)
	return pow(cutoff, 0.1)


## ---- 房间混响（Sound Filters ReverbHandler 腔体 profile） ----

## 玩家眼格 BFS 空气腔体：返回 {room, sky_frac, reflectivity}。
## room=腔体格数；sky_frac=腔体内天光满值格占比（露天直通度）；
## reflectivity=腔体边界面反射率均值。非空气格（水/实体）不入腔。
## 天光检查在入队时做（visited 含未 pop 的排队格——曾只在出队时
## 计数导致分子分母错位，sky_frac 被稀释）
static func evaluate_room(world: VoxelWorld, eye: Vector3) -> Dictionary:
	var start := Vector3i(floori(eye.x), floori(eye.y), floori(eye.z))
	if is_opaque_block(world.get_block(start)):
		return {"room": 0, "sky_frac": 0.0, "reflectivity": 0.5}
	# 水下不评腔体：水格会整个入腔+水底高反射面 → 假"封闭腔"回声
	# （实机报告：水里能听到回声）。水下声学由低通闷化承担
	if world.get_block(start) == VoxelTypes.WATER_ID:
		return {"room": 0, "sky_frac": 0.0, "reflectivity": 0.2}
	var visited := {}
	var queue: Array[Vector3i] = [start]
	visited[start] = true
	var sky_hits := _count_sky(world, start)
	var refl_sum := 0.0
	var refl_faces := 0
	while not queue.is_empty() and visited.size() < CAVE_FILL_MAX:
		# BFS（pop_front）：cap 截断时保留离眼近的格子
		var c: Vector3i = queue.pop_front()
		# 6 邻域：可入腔（非满格不透明）则入队；不透明则计边界面反射。
		# 未加载区块不计入腔体（get_block 对未加载返回空气——曾让
		# flood fill 冲出加载区把 512 格全填进虚空）
		for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var n: Vector3i = c + d
			if visited.has(n):
				continue
			if not world.has_chunk(VoxelCoords.world_to_chunk(n,
					world.config.chunk_size)):
				continue
			var nb := world.get_block(n)
			if is_opaque_block(nb):
				refl_sum += reflectivity(nb)
				refl_faces += 1
			else:
				visited[n] = true
				sky_hits += _count_sky(world, n)
				if visited.size() < CAVE_FILL_MAX:
					queue.append(n)
	var room := visited.size()
	var sky_frac := float(sky_hits) / float(maxi(room, 1))
	var refl := refl_sum / float(maxi(refl_faces, 1))
	return {"room": room, "sky_frac": sky_frac, "reflectivity": refl}


## 腔体格天光判定（sky==15 = 露天直通；未加载不计）
static func _count_sky(world: VoxelWorld, cell: Vector3i) -> int:
	var chunk: ChunkData = world.chunks.get(
			VoxelCoords.world_to_chunk(cell, world.config.chunk_size))
	if chunk == null:
		return 0
	var llocal := VoxelCoords.world_to_local(cell, world.config.chunk_size)
	return 1 if chunk.get_sky_light(llocal) >= 15 else 0


## 腔体 → Godot Reverb 参数（AudioEffectReverb 域）：
## room_size 0.25..0.8（小屋→大厅洞穴）；wet 封闭度驱动（露天≈0）；
## damping 吸声材质驱动（草屋闷、石洞亮）
static func reverb_params(profile: Dictionary) -> Dictionary:
	var room: int = profile["room"]
	var sky_frac: float = profile["sky_frac"]
	var refl: float = profile["reflectivity"]
	var room_factor := clampf(float(room) / float(CAVE_FILL_MAX), 0.0, 1.0)
	# 露天腔体（天光直通占比高）混响趋零；小封闭腔（玩家自建盒、
	# 小石屋）恰恰是回声最强场景——room_factor×6 让 ~85 格以上
	# 的封闭腔即达满湿（×2 时 18 格小盒 wet≈0.08 几乎不可闻，实机
	# 报告"封闭盒子没回声"的第二个根因）
	var enclosure := (1.0 - clampf(sky_frac * 1.4, 0.0, 1.0)) \
			* clampf(room_factor * 6.0, 0.0, 1.0)
	return {
		"room_size": clampf(0.25 + room_factor * 0.55, 0.25, 0.8),
		"wet": clampf(0.03 + enclosure * 0.6 * refl, 0.03, 0.5),
		"damping": clampf(0.85 - refl * 0.6, 0.2, 0.85),
		"hipass": 0.1,
	}
