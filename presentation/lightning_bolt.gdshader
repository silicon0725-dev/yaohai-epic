// 雷击 bolt 亮带（天气批 2）：竖直 quad（9×55m）程序化锯齿主干
// + 分叉 + 冷白核心/蓝紫辉光，additive 叠加（BSL 写实：高对比
// 事件、辉光柔和衰减）。思路参考 gameidea.org 闪电 shader
//（billboard quad + 距离场亮度），实现为自研分段折线走线。
// u_seed 每次雷击换随机走线；u_fade 0.3s 线性淡出。
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

uniform float u_seed = 0.0;
uniform float u_fade = 1.0;

// 走线：8 段折线随机水平偏移（seed 驱动），幅度底部收口
//（钉在雷击点）、中部最大、顶部收（入云）
float path_x(float y) {
	float seg = 8.0;
	float i = floor(y * seg);
	float f = fract(y * seg);
	float a = (fract(sin((i + u_seed) * 127.1) * 43758.5453) - 0.5) * 0.55;
	float b = (fract(sin((i + 1.0 + u_seed) * 127.1) * 43758.5453) - 0.5) * 0.55;
	float x = mix(a, b, smoothstep(0.0, 1.0, f));
	return x * (0.35 + 0.65 * sin(y * 3.14159265));
}

void fragment() {
	// 主干：屏幕距走线的横向距离 → 白核 + 辉光两级衰减
	float d = abs(UV.x - 0.5 - path_x(UV.y));
	float core = exp(-d * 36.0);
	float glow = exp(-d * 6.0) * 0.4;
	// 分叉：中上部（每次 seed 决定起点/侧向）斜出短枝，顶端淡出
	float branch_y = 0.4 + fract(sin(u_seed * 91.7) * 43758.5453) * 0.3;
	float bd = 9.0;
	if (UV.y > branch_y) {
		float by = (UV.y - branch_y) / max(1.0 - branch_y, 0.001);
		bd = abs(UV.x - 0.5 - path_x(branch_y)
				- (fract(sin(u_seed * 57.3) * 43758.5453) - 0.5) * 0.8 * by);
	}
	float bcore = exp(-bd * 44.0) * (1.0 - smoothstep(0.8, 1.0, UV.y));
	float lum = (core + glow + bcore * 0.75) * u_fade;
	ALBEDO = vec3(0.96, 0.97, 1.0) * core * u_fade
			+ vec3(0.55, 0.65, 1.0) * (glow + bcore * 0.75) * u_fade;
	ALPHA = clamp(lum, 0.0, 1.0);
}
