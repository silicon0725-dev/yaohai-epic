// 远景山壳（Voxy LOD 金字塔）：顶点色=群系基色（C#），法线在
// NORMAL 通道；太阳漫反射**实时**计算（u_sun_dir 每帧随真实太阳
// 转动下发，与水 shader 同款）——烘焙固定正午方向会在黄昏/夜里
// 与场景错位成"发光"（两轮实机反馈：恒亮 + 方向错位）。对比参数
// 底光 0.22 / 漫反射 0.38（峰 0.60）：阴面够暗（夜里山暗于天空=
// 剪影感），阳面峰值也压在天际亮度之下——山亮于天即"发光"悬浮感
//（PIL 真值实测：夕阳中环山 109 > 地平线天 100）。
shader_type spatial;
render_mode unshaded;

uniform float u_day = 1.0;
uniform vec3 u_sun_dir = vec3(0.5, 0.89, 0.25);

void fragment() {
	float diff = max(dot(normalize(NORMAL), normalize(u_sun_dir)), 0.0);
	float lum = 0.22 + 0.38 * diff;
	ALBEDO = COLOR.rgb * vec3(lum * u_day);
}
