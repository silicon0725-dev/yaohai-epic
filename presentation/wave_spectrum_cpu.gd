## RealisticEnvironments 波谱的 CPU 移植（体素水结合层）。
## RE 的波浪是 RenderingDevice ComputeShader FFT 管线（gl_compatibility
## 后端不可用），但其频谱公式是纯数学，可在 GDScript 里离线采样成
## **波分量表**（Sum of Sines）：体素水 shader 用数组 uniform 逐波求和
## ——波形、波长分布、方向分布来自真实 JONSWAP/TMA + Hasselmann
## 频谱（风速/风程/水深/涌浪参数化），呈现保留体素风格。
##
## 公式来源（RE wave_generator.gd + spectrum_compute.glsl）：
## - 无量纲风程 ξ = min(g·F/U², 2.2e4)；α = 0.076·ξ^(-0.22)；
##   峰值角频率 ωp = 22·g/U·ξ^(-1/3)（JONSWAP，wikiwaves）
## - TMA 谱：S(ω) = αg²/ω⁵·exp(-1.25(ωp/ω)⁴)·γ^r × 深度衰减
## - 方向扩展：Longuet-Higgins (cos(θ/2))^(2s)，s 含涌浪项 swell²
## - 振幅 ∝ sqrt(S·D·Δω)，相位按种子哈希（确定性，世界种子联动）
class_name WaveSpectrumCPU
extends RefCounted

const G := 9.81
const FULLY_DEVELOPED_DIMENSIONLESS_FETCH := 2.2e4
## 波分量数（频率档 × 角度档）。更多波更细腻，shader 每像素按此求和。
const FREQ_BINS := 8
const ANGLE_BINS := 2

## 波分量表：每波 (方向x, 方向z, 波数 k, 相位 φ)，供 shader 数组。
var wave_vec4s := PackedVector4Array()
## 每波 (角频率 ω, 振幅 a)，供 shader 数组（与 wave_vec4s 同序）。
var wave_vec2s := PackedVector2Array()
## 所有波分量振幅和（shader 端归一化用）。
var amplitude_sum := 0.0


## 生成波分量表。参数语义同 RE 的 WaveSpectrum 资源。
## seed 传入世界种子保证确定性（同种子同海况）。
func build(
		wind_speed: float, wind_direction_deg: float, fetch_m: float,
		depth_m: float, swell: float, spread: float, seed: int
) -> void:
	wave_vec4s = PackedVector4Array()
	wave_vec2s = PackedVector2Array()
	amplitude_sum = 0.0

	# JONSWAP 参数（RE WaveGenerator 同款公式）
	var xi: float = minf(G * fetch_m / maxf(wind_speed * wind_speed, 1e-8),
			FULLY_DEVELOPED_DIMENSIONLESS_FETCH)
	var alpha: float = 0.076 * pow(xi, -0.22)
	var omega_p: float = 22.0 * G / maxf(wind_speed, 1e-4) * pow(xi, -1.0 / 3.0)
	var wind_rad := deg_to_rad(wind_direction_deg)

	# 频率档：0.75ωp .. 5ωp 对数分布（主浪到细浪）
	# 角度档：风方向 ±（约 35°/70° 两圈，方向谱自然收窄到风方向）
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(seed, ":", wind_speed, ":", wind_direction_deg))
	for fi in FREQ_BINS:
		var ratio := exp(lerp(log(0.75), log(5.0), float(fi) / (FREQ_BINS - 1.0)))
		var omega := omega_p * ratio
		var d_omega := omega_p * (exp(log(5.0) - log(0.75)) - 1.0) / (FREQ_BINS - 1.0) * ratio
		# TMA/JONSWAP 谱值（γ^r 峰形在 ω=ωp 处最大，r 随离峰衰减）
		var sigma := 0.07 if omega <= omega_p else 0.09
		var r := exp(-(omega - omega_p) * (omega - omega_p)
				/ (2.0 * sigma * sigma * omega_p * omega_p))
		var spectrum := alpha * G * G / pow(omega, 5.0) \
				* exp(-1.25 * pow(omega_p / omega, 4.0)) * pow(3.3, r)
		# 深度衰减（TMA Kitaigorodskii）
		var w_h: float = minf(omega * sqrt(depth_m / G), 2.0)
		spectrum *= 0.5 * w_h * w_h if w_h <= 1.0 \
				else 1.0 - 0.5 * (2.0 - w_h) * (2.0 - w_h)
		for ai in ANGLE_BINS:
			# 两圈对称偏角：±（30°+35°·档位）；spread 越大能量越集中风方向
			var side := 1 if ai == 0 else -1
			var tier := float(ai % ANGLE_BINS)
			var theta_off := deg_to_rad(30.0 + 35.0 * tier) * side
			var theta := wind_rad + theta_off
			# 方向增益：离风方向越远越弱（Longuet-Higgins cos(θ/2)^2s 的
			# 简化采样权重；swell 增大使方向更集中）
			var p := omega / omega_p
			var s: float = 6.97 * pow(p, 4.06) if omega <= omega_p \
					else 9.77 * pow(p, -2.33 - 1.45 * (wind_speed * omega_p / G - 1.17))
			s += 16.0 * tanh(omega_p / omega) * swell * swell
			var dir_gain: float = pow(absf(cos(theta_off * 0.5)), 2.0 * s * 0.5) \
					* lerpf(1.0, 0.55, spread)
			var energy: float = maxf(spectrum * dir_gain * d_omega, 0.0)
			var amp := sqrt(energy)
			# 深水色散 ω² = gk
			var k := omega * omega / G
			var phase := rng.randf() * TAU
			wave_vec4s.append(Vector4(cos(theta), sin(theta), k, phase))
			wave_vec2s.append(Vector2(omega, amp))
			amplitude_sum += amp
	# 振幅归一化：能量按 sqrt(S) 采样的相对分布保留，绝对尺度交给
	# shader 的 wave_amplitude（体素水面起伏幅度受限，见 shader 注释）
	var n := wave_vec2s.size()
	if amplitude_sum > 0.0:
		for i in n:
			wave_vec2s[i] = Vector2(wave_vec2s[i].x, wave_vec2s[i].y / amplitude_sum)


## CPU 侧波高求和（调试/测试用；shader 端同一组分量求和）。
## 返回归一化 [-1, 1] 附近的波高，实际位移 = 返回值 × 振幅尺度。
func height_at(x: float, z: float, time: float) -> float:
	var total := 0.0
	for i in wave_vec4s.size():
		var v: Vector4 = wave_vec4s[i]  # (dirx, dirz, k, phase)
		var p: Vector2 = wave_vec2s[i]  # (omega, amp)
		total += p.y * sin((v.x * x + v.y * z) * v.z - p.x * time + v.w)
	return total
