## Physics Mod（physics-mod-pro v188i）言波公式的移植——CPU 侧。
## shader 侧（water_surface/water_side.gdshader）逐行同式，保证
## GPU 视觉与 CPU 物理采样（掉落物随波起伏）完全一致。
##
## 方法（mod 的 ocean_legacy.glsl physics_waveHeight）：13 次迭代的
## Gerstner 风格分形波——
##   波形 exp(sin(x)-1)：非对称尖峰宽谷（真实海浪形态）；
##   位置被波"拖拽"（p -= force*DRAG）：波峰水平翻卷感；
##   每级频率 x1.18、速度 x1.07、权重 x0.8 逐级细化；
##   方向每级转 12°。
## 返回值域约 [-ocean_height/2, +ocean_height/2]，位置的确定性纯函数
##（同位置同时间恒同值——浮物采样与水面渲染天然一致）。
class_name OceanWaves
extends RefCounted

const ITERATIONS := 13
const DRAG_MULT := 0.048
## 空间尺度：0.035（mod 原值）波长约 30 格——±0.25 格振幅摊在
## 30 格上坡度仅 5%，视觉上就是平面。0.10 -> 波长约 10.5 格，
## 同振幅坡度 15%，相邻格顶点高差约 0.3 格：肉眼可见的起伏
const XZ_SCALE := 0.10
const TIME_MULT := 0.9  # 波速（0.45 是 mod 原值：浪太慢，周期 ~11s，
# 固定点起伏视觉上不可感；翻倍后周期 ~5.5s，浮物颠簸可见）
const FREQUENCY := 6.0
const SPEED := 2.0
const WEIGHT := 0.8
const FREQUENCY_MULT := 1.18
const SPEED_MULT := 1.07
const ITER_INC := 12.0
## 波起伏总幅度（格）——shader 的 wave_amplitude 与 CPU 采样共用
## 同值（视觉与浮物起伏一致）。0.5 = ±0.25 格：近景/远景可见的
## 真实起伏，波峰会轻微漫过岸线（拍岸感）
const WAVE_AMPLITUDE := 0.5

## 全局海况缩放（ocean3d_lite 的 storm_scale 思路）：一个变量同时
## 放大物理采样与 shader 位移（main 每帧同步 uniform），1.0 平静
## ~2.5 风暴；天气系统接这里
static var storm_scale := 1.0


## 波浪位移（CPU 侧统一入口）：振幅与钳制跟 shader 完全一致
##（shader wave_amplitude=0.4 + clamp(-0.08, +0.22)；浮物/物理采样
## 必须走这里，直接调 wave_height 会与视觉水面漂移）
const SHADER_AMPLITUDE := 1.0
const DISPLACE_MIN := -0.16
const DISPLACE_MAX := 0.56


static func wave_offset(x: float, z: float, time: float) -> float:
	return clampf(
			wave_height(x, z, time, SHADER_AMPLITUDE * storm_scale),
			DISPLACE_MIN, DISPLACE_MAX)


## CPU/GPU 同源时钟：main._process 推进，shader 的 u_time uniform
## 每帧设同值——浮物波高采样与水面渲染波形严格同步（TIME 内置
## 时间与 CPU 毫秒基准不同，会相位漂移）
static var global_time := 0.0


static func advance(delta: float) -> void:
	global_time += delta


## 波高（世界单位）。factor 0..1 为波强（体素水面统一传 1.0；
## mod 里按生物群系/水深传入）。
static func wave_height(
		x: float, z: float, time: float, ocean_height: float, factor := 1.0
) -> float:
	var wave_factor := maxf(factor, 0.0)
	var adjusted := clampf(wave_factor * 2.0, 0.1, 1.0)
	var px := x * XZ_SCALE
	var pz := z * XZ_SCALE
	var iter := 0.0
	var frequency := FREQUENCY
	var speed := SPEED
	var weight := 1.0
	var height := 0.0
	var wave_sum := 0.0
	var t := time * TIME_MULT
	for i in ITERATIONS:
		var dir_x := sin(iter)
		var dir_z := cos(iter)
		var phase := (dir_x * px + dir_z * pz) * frequency + t * speed
		var wave := exp(sin(phase) - 1.0)
		var result := wave * cos(phase)
		# Gerstner 拖拽：位置随波形水平移动（波峰翻卷感的来源）
		var force := result * weight * DRAG_MULT * adjusted
		px -= force * dir_x
		pz -= force * dir_z
		height += wave * weight
		iter += ITER_INC
		wave_sum += weight
		weight *= WEIGHT
		frequency *= FREQUENCY_MULT
		speed *= SPEED_MULT
	return height / wave_sum * ocean_height * wave_factor \
			- ocean_height * wave_factor * 0.5
