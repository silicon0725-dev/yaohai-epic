// 图集平铺着色器（Greedy Meshing 配套，开发文档 §6.3、§7.1）：
// 合并四边形的 UV 处于 tile 空间（0..宽），UV2 携带 tile 在图集中的
// 原点；片元用 fract(uv) 在单一图集内完成纹理重复，避免图集渗色
// （Nearest 过滤 + 半 texel 内缩）。
shader_type spatial;

uniform sampler2D atlas : source_color, filter_nearest, repeat_enable;
uniform vec2 tile_fraction = vec2(1.0 / 16.0, 1.0);

varying vec2 tile_space;
varying vec2 tile_origin;

void vertex() {
	tile_space = UV;
	tile_origin = UV2;
}

void fragment() {
	vec2 local = clamp(fract(tile_space), vec2(0.002), vec2(0.998));
	ALBEDO = texture(atlas, tile_origin + local * tile_fraction).rgb;
}
