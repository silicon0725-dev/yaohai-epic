// 洞口体积雾（Tiny Glade 密度/源项公式的体素版，公式来自
// Sparse-GI TG_ATMOSPHERE 审计：消光 0.0125×scale×1.2、散射比
// 0.4/1.2 → ALBEDO=tint/3、HG g=0.65 由环境 anisotropy 承担）。
// 光束不是本 shader 画的：引擎体积积分逐 froxel 采样太阳阴影，
// 洞口的遮挡自动在雾中切出光束——这里只负责"哪里有雾"。
// 盒形 FogVolume：中心以下沉雾为主（雾往洞底积），边缘高斯衰减，
// 低频噪声做尘埃漂移。
shader_type fog;

uniform vec3 center = vec3(0.0);
uniform vec3 half_extents = vec3(4.0, 3.0, 4.0);
// 消光系数（/米）。参考 0.075/米 × 十米量级光程 → 光学厚度 ~0.75
uniform float extinction = 0.09;
uniform vec3 tint : source_color = vec3(0.94, 0.97, 1.0);
// 微弱天空源项（洞内偏暗；光束亮度来自太阳散射而非自发光）
uniform vec3 sky_color : source_color = vec3(0.10, 0.13, 0.18);
uniform float sky_energy = 1.0;
uniform float u_time = 0.0;
// 尘埃噪声幅度（0 = 关）
uniform float dust_amount = 0.35;

// 3D 值噪声（hash sin）：漂移的雾团/尘埃
float dust_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float h = i.x + i.y * 37.0 + i.z * 73.0;
	float a = fract(sin(h) * 43758.5453);
	float b = fract(sin(h + 1.0) * 43758.5453);
	float c = fract(sin(h + 37.0) * 43758.5453);
	float d = fract(sin(h + 38.0) * 43758.5453);
	float e = fract(sin(h + 73.0) * 43758.5453);
	float f2 = fract(sin(h + 74.0) * 43758.5453);
	float g = fract(sin(h + 110.0) * 43758.5453);
	float h2 = fract(sin(h + 111.0) * 43758.5453);
	return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
			mix(mix(e, f2, f.x), mix(g, h2, f.x), f.y), f.z);
}

void fog() {
	vec3 p = (WORLD_POSITION - center) / max(half_extents, vec3(0.001));
	// 盒内 [-1,1]³ 高斯衰减（TG profile 同构：exp2(-dot(q,q)) 0.6 系数）
	float profile = 0.75 * exp2(-dot(p * 1.15, p * 1.15));
	// 下沉雾：越靠盒底越浓（雾积在洞底，洞口上沿稀）
	profile *= mix(0.55, 1.15, clamp(0.5 - 0.5 * p.y, 0.0, 1.0));
	// 尘埃漂移：低频噪声 + 缓慢下沉/平移
	float dust = dust_noise(WORLD_POSITION * 0.8
			+ vec3(u_time * 0.05, -u_time * 0.03, u_time * 0.04));
	profile *= 1.0 + dust_amount * (dust - 0.5) * 2.0;
	DENSITY = max(extinction * profile, 0.0);
	// 散射/消光比 0.4/1.2（TG 审计值）
	ALBEDO = tint / 3.0;
	EMISSION = sky_color * tint * (sky_energy / 3.0);
}
