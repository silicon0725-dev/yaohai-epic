## 早期反射（1 阶镜像源法，体素版）：声源 6 方向 DDA 找最近实体面
## → 镜像点 → 镜像→听者遮挡检查 → 可闻则生成"延迟反射声像"事件。
## 架构学习自 Resonance Audio 的 6 面早期反射模型（每面 delay+gain，
## Unity 端 unity_reverb_computer 由房间几何计算）与 Steam Audio 的
## real-time pathing 概念——体素世界的优势：DDA 射线极廉价，每声源
## 一次 ~200 步。混合方案分工：早期反射=几何镜像源（方向感/延迟）
## ，晚尾=腔体统计混响（acoustic_system 的 Reverb 总线）。
## 纯函数（plan_reflections）静态可测。
class_name EarlyReflections
extends RefCounted

const Acoustic := preload("res://systems/sound/acoustic_system.gd")

## 声速（m/s）——延迟 = 路径差/声速
const SPEED_OF_SOUND := 343.0
## 反射面搜索半径（格）；镜像→听者路径限程
const MAX_WALL_DIST := 16.0
const MAX_PATH_DIST := 24.0
## 路径差下限（米）：<1m 的反射与直达几乎重叠，不值得播
const MIN_PATH_DELTA := 1.0
## 最多同时生成的反射声像数（每声源）
const MAX_REFLECTIONS := 2
## 总增益折减（反射天然弱于直达——散射/吸收残余）
const GLOBAL_GAIN := 0.7


## 声源→听者的早期反射事件：[{delay_sec, pos: Vector3, gain: float}]
## （pos=镜像源位置，3D 声像从反射方向传来）。纯函数。
static func plan_reflections(world: VoxelWorld, source: Vector3,
		ear: Vector3) -> Array:
	var direct := source.distance_to(ear)
	if direct < 1.0 or direct > MAX_PATH_DIST:
		return []
	var events := []
	for dir in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var wall := _first_wall(world, source, Vector3(dir))
		if wall.is_empty():
			continue
		# 镜像源：关于命中面平面对称。面平面 = hit 格面向声源的那面
		# （法线 = -dir 分量）；镜像距离 = 2×(源到面距离)
		var face: Vector3 = wall["face"]
		var dist_to_wall: float = wall["dist"]
		var mirror := source + Vector3(dir) * (dist_to_wall * 2.0)
		var path := mirror.distance_to(ear)
		if path - direct < MIN_PATH_DELTA or path > MAX_PATH_DIST:
			continue
		# 镜像→听者路径无遮挡才算可闻反射（体素近似：镜像源发的
		# "直达"不被挡）
		if Acoustic.occlusion_between(world, mirror, ear,
				MAX_PATH_DIST, wall["cell"]) > 0.01:
			continue
		# 增益 = 反射率 × 距离比一次方。距离衰减由 3D 播放器在镜像
		# 点自带（inverse distance）——曾再乘 (direct/path)² 双重
		# 衰减致 5m 反射只剩 0.1（不可闻）
		var gain: float = Acoustic.reflectivity(wall["block"]) \
				* clampf(direct / path, 0.0, 1.0) * GLOBAL_GAIN
		if gain < 0.05:
			continue
		events.append({
			"delay_sec": (path - direct) / SPEED_OF_SOUND,
			"pos": mirror,
			"gain": gain,
			"dist_to_wall": dist_to_wall,
		})
	# 按能量排序取最强（gain 近似反比于路径长——短路径即最强）
	events.sort_custom(func(a, b): return a["dist_to_wall"] < b["dist_to_wall"])
	return events.slice(0, MAX_REFLECTIONS)


## 声源沿 dir 找第一个不透明方块：返回
## {block, dist, face: Vector3（命中面朝声源的表面点）}，无则 {}。
## face 取命中格中心 + 半格法线偏移（声源侧表面）。
static func _first_wall(world: VoxelWorld, source: Vector3,
		dir: Vector3) -> Dictionary:
	var pos := Vector3i(floori(source.x), floori(source.y),
			floori(source.z))
	var step := Vector3i(
			1 if dir.x > 0.0 else -1,
			1 if dir.y > 0.0 else -1,
			1 if dir.z > 0.0 else -1)
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
			t_max[axis] = (boundary - source[axis]) / d
			t_delta[axis] = 1.0 / absf(d)
	var t := 0.0
	while t <= MAX_WALL_DIST:
		# 步进到下一格边界
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
		if t > MAX_WALL_DIST:
			break
		var b := world.get_block(pos)
		if Acoustic.is_opaque_block(b):
			# 命中面 = 格中心沿 -dir 回退半格（声源侧表面）
			var center := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
			return {
				"block": b,
				"dist": t,
				"face": center - dir * 0.5,
				"cell": pos,
			}
	return {}
