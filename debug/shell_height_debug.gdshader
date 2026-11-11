// 远景壳高度调试着色：按世界 Y 分带（每 8 格一条色带），
// 蓝=海平面以下，绿/黄/红=越高越红。用于看清 LOD 阶梯与竖直墙。
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float sea_level = 64.0;
uniform float band = 8.0;

varying vec3 wpos;

void vertex() {
	wpos = VERTEX;
}

void fragment() {
	float y = wpos.y;
	float h = clamp((y - sea_level) / 160.0, 0.0, 1.0);
	vec3 c = mix(vec3(0.10, 0.35, 0.95), vec3(0.95, 0.15, 0.10), h);
	// 每 band 格一条暗带，量化阶梯一眼可数
	float k = mod(floor(y / band), 2.0) < 0.5 ? 1.0 : 0.55;
	ALBEDO = c * k;
}
