// 图集平铺着色器（Greedy Meshing 配套，开发文档 §6.3、§7.1）：
// 合并四边形的 UV 处于 tile 空间（0..宽），UV2 携带 tile 在图集中的
// 原点；片元用 fract(uv) 在单一图集内完成纹理重复，避免图集渗色
// （Nearest 过滤 + 半 texel 内缩）。
shader_type spatial;

uniform sampler2D atlas : source_color, filter_nearest, repeat_enable;
uniform vec2 tile_fraction = vec2(1.0 / 16.0, 1.0);
// 反射 RT 水下裁剪（同 terrain_surface.gdshader）：镜像相机渲染时丢弃
// 水面以下片元，防埋地镜像相机把地下方块内壁拍进倒影
uniform vec3 sspr_mirror_cam_pos = vec3(1.0e9, 1.0e9, 1.0e9);
uniform float sspr_clip_y = 0.0;
// 日夜天光系数（main 每帧下发）：天光顶点色（COLOR.a = s³）乘此系数
// 得夜暗；方块光暖色（COLOR.rgb）不乘——夜晚火把/提灯自动接管
uniform float u_day = 1.0;

varying vec2 tile_space;
varying vec2 tile_origin;
varying vec3 wpos;

void vertex() {
	tile_space = UV;
	tile_origin = UV2;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (distance(INV_VIEW_MATRIX[3].xyz, sspr_mirror_cam_pos) < 0.01
			&& wpos.y < sspr_clip_y) {
		discard;
	}
	vec2 local = clamp(fract(tile_space), vec2(0.002), vec2(0.998));
	vec3 tex = texture(atlas, tile_origin + local * tile_fraction).rgb;
	// 顶点色双通道（MC 语义）：
	//   天光（COLOR.a=s³ × u_day）→ ALBEDO，受场景光（太阳/月亮方向
	//   着色、阴影、环境光）——白天方向性明暗与山影保留；
	//   方块光（COLOR.rgb=暖色×b³）→ EMISSION 自发光——MC 中方块光
	//   全天候 fullbright，不随日夜/方向衰减（夜晚火把光池的保证；
	//   走 ALBEDO 会被趋零的场景光乘没——实机踩坑）
	ALBEDO = tex * vec3(COLOR.a * u_day);
	EMISSION = tex * COLOR.rgb;
}
