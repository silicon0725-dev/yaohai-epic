// 远景山壳（Voxy LOD 金字塔）：顶点色=群系基色（C#），法线在
// NORMAL 通道；太阳漫反射**实时**计算（u_sun_dir 每帧随真实太阳
// 转动下发，与水 shader 同款）——烘焙固定正午方向会在黄昏/夜里
// 与场景错位成"发光"（两轮实机反馈：恒亮 + 方向错位）。对比参数
// 底光 0.18 / 漫反射 0.45（峰 0.63）：立体感优先（"平面贴图感"
// 用户反馈）——谷底更暗、受光面亮，总亮度不超天（发光的根因
// 是雾色亮于天与方向错位，已在雾与太阳方向侧修死）。
shader_type spatial;
// cull_disabled：方块风 LOD 的侧壁/裙壁四向朝外，双面渲染免去
// 绕序依赖（远景几何成本可忽略）
render_mode unshaded, cull_disabled;

uniform float u_day = 1.0;
uniform vec3 u_sun_dir = vec3(0.5, 0.89, 0.25);

void fragment() {
	float diff = max(dot(normalize(NORMAL), normalize(u_sun_dir)), 0.0);
	// 亮度对齐真实地形（五态一致性实测：UNSHADED 壳比场景光照下
	// 的真实地形亮 ~2 倍——30.5 vs 16.2，交界带明暗差读作"接缝"）。
	// 底光 0.18→0.08、漫反射 0.45→0.22（整体 ~0.45×，立体感结构
	// 保留：受光面/背光面相对差不变）；u_day 日夜联动不变
	float lum = 0.08 + 0.22 * diff;
	ALBEDO = COLOR.rgb * vec3(lum * u_day);
}
