// 远景山壳（Voxy LOD 金字塔）：顶点色已含光照（C# 烘焙的太阳
// 漫反射），u_day 与全场景日夜因子联动——夜里随场景压暗（修复
// "远处 LOD 自发光"实机反馈：此前 StandardMaterial UNSHADED 恒定
// 亮度，昼夜循环时夜里壳比场景亮数倍）。语义与 terrain_surface
// 的 ALBEDO×COLOR.a×u_day 同构（壳无天光/方块光通道，全色乘）。
shader_type spatial;
render_mode unshaded;

uniform float u_day = 1.0;

void fragment() {
	ALBEDO = COLOR.rgb * vec3(u_day);
}
