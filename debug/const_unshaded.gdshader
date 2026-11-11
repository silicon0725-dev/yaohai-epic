// 诊断用：恒色 unshaded（不用 NORMAL/COLOR），判断"放射扇"是否来自壳 shader
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec3 u_color = vec3(0.32, 0.40, 0.50);

void fragment() {
	ALBEDO = u_color;
}
