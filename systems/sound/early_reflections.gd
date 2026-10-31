## 早期反射（1 阶镜像源法，面枚举版）：收集源↔听者包围盒内的
## 候选反射面（空气格×实心邻面），对每面做镜像源三验——
## ① mirror→ear 直线与面平面交点在面内（ISM 合法性）
## ② 反射点→ear 现实段无遮挡（虚拟段穿墙体是正常镜像几何）
## ③ 能量链 ≥ 可闻阈
## 架构学习自 Resonance Audio 的早期反射模型（每面 delay+gain，
## 由房间几何计算）与 Steam Audio 的 real-time pathing 概念。
## 曾用"源 6 方向 DDA 找最近面"——反射面应该是 mirror→ear 连线
## 与墙面的交点格，与源 6 方向命中格可差数格远（面内检查全部
## 正确拒绝 → 0 事件，实机报告封闭盒没回声的深因）。
## 混合分工：早期反射=几何镜像源（方向感/离散延迟，次数随封闭
## 程度的面数涌现），晚尾=腔体统计混响（acoustic_system）。
## 纯函数（plan_reflections）静态可测。
class_name EarlyReflections
extends RefCounted

const Acoustic := preload("res://systems/sound/acoustic_system.gd")

## 声速（m/s）——延迟 = 路径差/声速
const SPEED_OF_SOUND := 343.0
## 路径差下限（米）：与直达几乎重叠的反射不值得独立播放
const MIN_PATH_DELTA := 0.4
## 最多同时生成的反射声像数（每声源）
const MAX_REFLECTIONS := 2
## 总增益折减（反射天然弱于直达——散射/吸收残余）
const GLOBAL_GAIN := 0.7
## 能量剪枝阈值
const ENERGY_CUTOFF := 0.06
## 候选面扫描：源/听者包围盒向外扩（格）
const SCAN_MARGIN := 2


## 声源→听者的早期反射事件：[{delay_sec, pos, gain}]（pos=镜像源
## 位置，3D 声像从反射方向传来）。纯函数。
static func plan_reflections(world: VoxelWorld, source: Vector3,
		ear: Vector3, source_energy := 1.0) -> Array:
	var direct := source.distance_to(ear)
	if direct < 1.0 or direct > 24.0:
		return []
	var events := []
	for face in _candidate_faces(world, source, ear):
		var plane_d: float = face["plane_d"]
		var axis: int = face["axis"]
		var sign_f: float = face["sign"]
		# 双侧朝向检查：源与听者都必须在面的**空气侧**——背风面
		# （源在实心侧）的"反射"物理不存在（声须先穿墙）
		if (source[axis] - plane_d) * sign_f < 0.0 \
				or (ear[axis] - plane_d) * sign_f < 0.0:
			continue
		# 镜像源 = 源关于面平面的对称点（仅镜面轴翻转）
		var mirror := source
		mirror[axis] = 2.0 * plane_d - source[axis]
		var path := mirror.distance_to(ear)
		if path - direct < MIN_PATH_DELTA or path > 24.0:
			continue
		# 交点 = mirror→ear 与面平面交点；须在面片内
		var to_ear := ear - mirror
		var denom: float = to_ear[axis]
		if absf(denom) < 1.0e-6:
			continue
		var t: float = (plane_d - mirror[axis]) / denom
		if t <= 0.0 or t >= 1.0:
			continue
		var p := mirror + to_ear * t
		var cell: Vector3i = face["cell"]
		var on_face := true
		for a in 3:
			if a == axis:
				continue
			if absf(p[a] - (float(cell[a]) + 0.5)) > 0.5:
				on_face = false
				break
		if not on_face:
			continue
		# 反射点→ear 现实段无遮挡（豁免面所属格；p 恰在格边界，
		# occlusion 的起点格跳过兜底）
		if Acoustic.occlusion_between(world, p, ear, 24.0,
				[cell]) > 0.01:
			continue
		var refl: float = Acoustic.reflectivity(face["block"])
		var gain: float = source_energy * refl 				* clampf(direct / path, 0.0, 1.0) * GLOBAL_GAIN
		if gain < ENERGY_CUTOFF:
			continue
		events.append({
			"delay_sec": (path - direct) / SPEED_OF_SOUND,
			"pos": mirror,
			"gain": gain,
		})
	# 按能量排序取最强
	events.sort_custom(func(a, b): return a["gain"] > b["gain"])
	return events.slice(0, MAX_REFLECTIONS)


## 候选反射面收集：源↔听者包围盒（扩 SCAN_MARGIN）内所有
## "实心格 × 朝空气邻面"。返回
## [{cell: Vector3i(实心格), axis: int, plane_d: float(面平面坐标),
##   block: int}]
static func _candidate_faces(world: VoxelWorld, source: Vector3,
		ear: Vector3) -> Array:
	var mn := Vector3i(mini(floori(source.x), floori(ear.x)),
			mini(floori(source.y), floori(ear.y)),
			mini(floori(source.z), floori(ear.z))) 			- Vector3i(SCAN_MARGIN, SCAN_MARGIN, SCAN_MARGIN)
	var mx := Vector3i(maxi(floori(source.x), floori(ear.x)),
			maxi(floori(source.y), floori(ear.y)),
			maxi(floori(source.z), floori(ear.z))) 			+ Vector3i(SCAN_MARGIN + 1, SCAN_MARGIN + 1,
			SCAN_MARGIN + 1)
	var faces := []
	for x in range(mn.x, mx.x):
		for y in range(mn.y, mx.y):
			for z in range(mn.z, mx.z):
				var cell := Vector3i(x, y, z)
				var b := world.get_block(cell)
				if not Acoustic.is_opaque_block(b):
					continue
				for k in 6:
					var axis := k / 2
					@warning_ignore("integer_division")
					var sign_f := 1.0 if k % 2 == 0 else -1.0
					var n := Vector3i.ZERO
					n[axis] = int(sign_f)
					var air_cell := cell + n
					if Acoustic.is_opaque_block(
							world.get_block(air_cell)):
						continue
					# 面平面坐标 = 实心格朝空气侧的边界
					var plane_d: float = float(cell[axis]) + 0.5 							+ 0.5 * sign_f
					faces.append({
						"cell": cell, "axis": axis, "sign": sign_f,
						"plane_d": plane_d, "block": b,
					})
	return faces
