// 火把头火焰：体积光线步进（真 3D——盒网格内沿视线步进 3D 噪声
// 密度场，任意角度有真视差，非面向玩家的贴图面片）。手法取自开源
// 体积火（yomotsu/VolumetricFire=Horváth 切片法的 raymarch 变体
// mattatz/THREE.Fire；两者无 license，仅借思路）：湍流位移随
// sqrt(h) 增大（火根稳、火尖乱）+ 温度色带 + 加色混合自然衰减。
// energy 由 TorchRenderer 按多频伪随机闪烁同步驱动并随眼适应
// 曝光反除（防曝光削顶色相塌缩）。
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

uniform float energy : hint_range(0.0, 6.0) = 1.0;

// 火焰体盒（模型空间 = 方块局部 0..1；7/16 见方 × 高 9/16→16/16）
const vec3 BOX_MN = vec3(0.28125, 0.5625, 0.28125);
const vec3 BOX_MX = vec3(0.71875, 1.0, 0.71875);
const int STEPS = 14;

varying vec3 v_local;  // 盒面入点（模型空间）
varying vec3 v_ray;    // 视线方向（模型空间）

void vertex() {
	v_local = VERTEX;
	// 相机世界位（VIEW_MATRIX 逆作用于原点）→ 视线向量回模型空间
	//（火把实体只有平移无旋转，逆变换便宜且逐顶点即可）
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam = (inverse(VIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_ray = normalize((inverse(MODEL_MATRIX) * vec4(world - cam, 0.0)).xyz);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float c000 = hash13(i);
	float c100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float c010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float c110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float c001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float c101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float c011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float c111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y),
			mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float s = 0.0;
	float amp = 0.55;
	for (int k = 0; k < 3; k++) {
		s += amp * vnoise3(p);
		p = p * 2.1 + 17.0;
		amp *= 0.5;
	}
	return s;
}

// 密度场：径向收窄轮廓 × 高度衰减 × 双尺度湍流（大尺度慢火舌 +
// 小尺度快撕扯）+ Horváth sqrt(h) 位移（底稳顶乱）
float density(vec3 q, float t) {
	vec2 r2 = (q.xz - 0.5) * (1.0 / 0.21875);  // -1..1
	float h = (q.y - 0.5625) / 0.4375;         // 0 火根 → 1 火尖
	float n1 = fbm3(vec3(q.x * 4.0, q.y * 3.5 - t * 1.6, q.z * 4.0));
	float n2 = fbm3(vec3(q.x * 9.0, q.y * 8.0 - t * 3.0, q.z * 9.0));
	float turb = n1 * 0.7 + n2 * 0.3;
	// 位移随 sqrt(h) 增大 + 高频啃边（分叉火舌/拉丝感的来源）
	float hh = h + sqrt(max(h, 0.0)) * (turb - 0.5) * 1.6;
	float radial = length(r2) * (1.0 + hh * 0.8) + (n2 - 0.5) * 0.4;
	float shape = 1.0 - smoothstep(0.35, 1.0, radial);
	shape *= smoothstep(0.0, 0.08, h);
	shape *= 1.0 - smoothstep(0.55, 1.0, hh);
	return clamp(shape * (0.55 + 0.6 * turb), 0.0, 1.0);
}

void fragment() {
	// 盒求交：片元在盒面上（入点），沿模型空间视线求远端
	vec3 inv = 1.0 / v_ray;
	vec3 ta = (BOX_MN - v_local) * inv;
	vec3 tb = (BOX_MX - v_local) * inv;
	vec3 tmax3 = max(ta, tb);
	float t_exit = max(min(min(tmax3.x, tmax3.y), tmax3.z), 0.0);
	float dt = t_exit / float(STEPS);
	// 抖动起始（时间变化的蓝噪近似——去步进 banding）
	vec3 p = v_local + v_ray * dt
			* hash13(vec3(FRAGCOORD.xy, floor(TIME * 24.0)));
	vec3 acc = vec3(0.0);
	float trans = 1.0;
	for (int i = 0; i < STEPS; i++) {
		float d = density(p, TIME);
		if (d > 0.01) {
			// 温度：密度 × 火根加成 → 平滑色带 暗红→橙→黄→白热
			float h = clamp((p.y - 0.5625) / 0.4375, 0.0, 1.0);
			float temp = d * (1.3 - h * 0.5);
			vec3 c = mix(vec3(0.75, 0.12, 0.01), vec3(1.0, 0.45, 0.06),
					smoothstep(0.05, 0.5, temp));
			c = mix(c, vec3(1.0, 0.75, 0.25), smoothstep(0.42, 0.75, temp));
			c = mix(c, vec3(1.05, 1.0, 0.9), smoothstep(0.62, 0.95, temp));
			acc += trans * c * d * dt * 11.0;
			trans *= 1.0 - clamp(d * dt * 6.0, 0.0, 1.0);
		}
		p += v_ray * dt;
	}
	ALBEDO = acc * energy;
	ALPHA = 1.0;
}
