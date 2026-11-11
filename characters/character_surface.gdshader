// 角色表面：贴图 × 双通道体素光（对齐地形 terrain_surface 语义）+
// 自研 GPU 蒙皮（骨骼矩阵走 RGBA32F 数据纹理逐帧更新——
// mat4[] 数组 uniform 在多渲染通道（主/阴影/反射 RT）下实测被写坏，
// 纹理通道与水面 CPU 波场同路，稳定）。
//
// 蒙皮数据通道：COLOR.r = 骨0 索引/255、COLOR.g = 骨0 权重、
// COLOR.b = 骨1 索引/255、COLOR.a = 骨1 权重（≤2 影响/顶点）。
// u_bone_tex：20×3 RGBA32F——texel(骨i, 行k) = 第 k 列基 (basis.xyz)
// + w 平铺原点分量（列主序 mat4：c0=(basis.x,0) c1=(basis.y,0)
// c2=(basis.z,0) c3=(origin,1)）。
// 天光 → ALBEDO 受场景光（u_day 日夜系数）；方块光 → EMISSION 暖色
// 自发光（MC fullbright 语义）。镂空贴图 alpha 裁切（头发边缘）。
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D u_bone_tex : filter_nearest;
uniform float u_day = 1.0;
uniform float u_sky = 1.0;   // 体素天光 s³（0..1）
uniform float u_blk = 0.0;   // 体素方块光 b³（0..1）

mat4 _bone(int i) {
	vec4 r0 = texelFetch(u_bone_tex, ivec2(i, 0), 0);
	vec4 r1 = texelFetch(u_bone_tex, ivec2(i, 1), 0);
	vec4 r2 = texelFetch(u_bone_tex, ivec2(i, 2), 0);
	return mat4(
			vec4(r0.xyz, 0.0),
			vec4(r1.xyz, 0.0),
			vec4(r2.xyz, 0.0),
			vec4(r0.w, r1.w, r2.w, 1.0));
}

void vertex() {
	int b0 = int(COLOR.r * 255.0 + 0.5);
	int b1 = int(COLOR.b * 255.0 + 0.5);
	float w0 = COLOR.g;
	float w1 = COLOR.a;
	// COLOR 通道按 RGBA8 存储（1/255 量化）——权重归一防关节处微缩
	float sw = max(w0 + w1, 1e-4);
	w0 /= sw;
	w1 /= sw;
	mat4 m0 = _bone(b0);
	mat4 m1 = _bone(b1);
	VERTEX = (m0 * vec4(VERTEX, 1.0) * w0
			+ m1 * vec4(VERTEX, 1.0) * w1).xyz;
	vec3 n = mat3(m0) * NORMAL * w0 + mat3(m1) * NORMAL * w1;
	NORMAL = normalize(n);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	if (tex.a < 0.5) {
		discard;
	}
	ALBEDO = tex.rgb * (u_sky * u_day);
	EMISSION = tex.rgb * u_blk * vec3(1.44, 1.0, 0.56);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
