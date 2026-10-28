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
	ALBEDO = texture(atlas, tile_origin + local * tile_fraction).rgb;
	// 体素光照顶点色调制（与 StandardMaterial 的 vertex_color_use_as_albedo 同义）
	ALBEDO *= COLOR.rgb;
}
