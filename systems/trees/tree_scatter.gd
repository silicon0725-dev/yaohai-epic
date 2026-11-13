## 树撒种判定（v2：显式 hash + 降水驱动密度 + cell/jitter 最小间距）。
##
## 研究来源 docs/reference-dynamic-trees.md：
## - DT 的分布约束=per-biome 密度函数（森林 noise()、荒漠 0.1×）+
##   泊松盘（树冠占位半径，防贴脸/重叠/稀疏带）。我们简化为
##   cell+jitter：世界划 6 格 cell，每 cell 至多 1 树（jitter 落点
##   唯一）——最小树距恒 ≥ 对角半宽 ≈ 4.2 格 ≥ 冠半径，DT 的位图
##   圆/弧掩码/三角化是 MC 跨 chunk 确定性+存档 16B 的过度工程。
## - 密度=降水场驱动（复用 terrain_generator 气候场 _precip 同参
##   噪声：湿区森林带、干旱区稀树——生态正确，且壳（C#）与生成
##   端（GD）同源可复刻）。
##
## ⚠ hash01 为显式数值混合（GD/C# 逐位同式，对拍测试钉死）——
## 曾用 GDScript 内置 hash([a,b,c])（C# 无法复刻，LOD 树烘壳无法
## 与生成端一致）。换公式=全世界树位置重排（老存档 cut 事件错位，
## 生成器迭代期已接受）。
class_name TreeScatter
extends RefCounted

## 撒种 cell 边长（格）：最小树距保证（同 cell 唯一树 → 距离
## ≥ cell 对角半宽 4.24；树冠半径 4-5 不重叠）
const CELL := 6
## 密度范围（每列概率基值）：干旱荒原 → 湿润雨林
const DENSITY_MIN := 0.0015
const DENSITY_MAX := 0.022
## 降水→森林因子平滑区间（FBM 输出 [-1,1]：只响应湿区，负降水
## 即干旱/半干旱=最低密度）
const WET_FROM := 0.0
const WET_TO := 0.45

## 降水噪声（与 terrain_generator._precip 同参数：seed+303/
## MOUNTAIN_MASK_FREQ/3 octaves——同值复刻，两侧改动必须同步）
static var _precip: FastNoiseLite
static var _precip_seed := -1


static func configure(world_seed: int) -> void:
	if _precip_seed == world_seed:
		return
	# 局部构建完成后一次性发布：先 _precip 后 _precip_seed——并发
	# worker 看到 seed 命中时实例必已配置完整（曾先写 seed 后配置
	# ：另一 worker 读到半配置实例（seed/freq 未设）→ 密度值错，
	# 树分布不确定）
	var n := FastNoiseLite.new()
	n.seed = world_seed + 303
	# 与 terrain_generator._make_fbm(seed + 303, 1/2048, 3) 同参
	#（SIMPLEX 显式指定）；噪声实例线程安全（只读采样）。两侧改动必须同步
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 1.0 / 2048.0
	n.fractal_octaves = 3
	_precip = n
	_precip_seed = world_seed


## 显式数值 hash → [0,1)：三整数 splitmix 风格混合。u32 环算术
##（GD int 64 位乘积 < 2^61 不溢出；C# uint 同式——对拍测试钉死）。
## 三次迭代手写展开（曾 for v in [a,b,c]：每调用分配一个 Array，
## 撒种热路径 90k 列/区块全在 GC 压力上）
static func hash01(a: int, b: int, c: int) -> float:
	var h: int = 0x9E3779B9
	h = (h ^ (a & 0xFFFFFFFF)) & 0xFFFFFFFF
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h = (h ^ (h >> 13)) & 0xFFFFFFFF
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	h = (h ^ (b & 0xFFFFFFFF)) & 0xFFFFFFFF
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h = (h ^ (h >> 13)) & 0xFFFFFFFF
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	h = (h ^ (c & 0xFFFFFFFF)) & 0xFFFFFFFF
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h = (h ^ (h >> 13)) & 0xFFFFFFFF
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return float(h) / 4294967296.0


## 列密度（每列概率）：降水场平滑映射。cell 中心采样（6 格内
## 密度一致——cell 判定与 jitter 无密度跳变）
static func density_at(world_seed: int, x: int, z: int) -> float:
	configure(world_seed)
	var n := _precip
	var p := 0.0
	if n != null:
		p = n.get_noise_2d(x, z)
	# smoothstep(0, 0.45, precip)：负降水=0 因子（荒漠密度下限）
	var t := clampf((p - WET_FROM) / (WET_TO - WET_FROM), 0.0, 1.0)
	var forest := t * t * (3.0 - 2.0 * t)
	return lerpf(DENSITY_MIN, DENSITY_MAX, forest)


## 撒种判定纯函数：该水平列是否长树（确定性）。
## cell 存在概率 = 密度 × CELL²（每列期望密度换算）；落点=cell 内
## hash jitter 唯一格。同 seed 同列恒同值（生成端/运行端/壳三处
## 共用本函数）。
## jitter 先行：每 cell 至多一格为真——35/36 的列用 2 次 hash 即
## 早退，不必算密度噪声（曾每列都采样噪声：同一 cell 的密度被
## 重复算 36 遍，撒种占区块生成热路径的大头）。
static func has_tree_at(world_seed: int, col: Vector2i) -> bool:
	var cx := floori(col.x / float(CELL))
	var cz := floori(col.y / float(CELL))
	# jitter 落点（seed+2/+3 两个独立流）
	var jx := int(hash01(world_seed + 2, cx, cz) * float(CELL))
	if col.x != cx * CELL + jx:
		return false
	var jz := int(hash01(world_seed + 3, cx, cz) * float(CELL))
	if col.y != cz * CELL + jz:
		return false
	# cell 存在判定（seed+1 混入，与 jitter 流分离）
	var exist := hash01(world_seed + 1, cx, cz)
	var density := density_at(world_seed, cx * CELL + CELL / 2,
			cz * CELL + CELL / 2)
	return exist < density * float(CELL * CELL)
