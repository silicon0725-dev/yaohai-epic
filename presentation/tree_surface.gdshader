// 树表面着色器：terrain_surface 的双通道顶点色语义 + 双面渲染。
// 方块光（COLOR.rgb 暖色）→ EMISSION 自发光（MC fullbright——夜晚
// 火把/提灯光池的保证）；天光（COLOR.a = s³）→ ALBEDO × u_day，
// 受太阳/月亮方向光与环境光。
// 曾用 StandardMaterial 合并式 max(s,b)³ 顶点色：露天区域 sky=15 ≥
// 火把 14 级，暖色调制（blk>sky 才生效）永不触发——树干"不受放置
// 光源影响"（实机报告）。与地形同构后昼夜两头都成立。
// 双面：树叶镂空孔洞透出背面内壁，倒树叶盒更饱满（同旧材质
// CULL_DISABLED）；树干无背面，统一双面无害。
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D atlas : source_color, filter_nearest;
// 倒树落叶盒：alpha 裁切让贴图透明孔洞成真洞
uniform bool cutout_mode = false;
// 日夜天光系数（main 每帧下发，经 TreeManager.set_day_factor）
uniform float u_day = 1.0;
// 抖动透明溶解（倒树消失动画）：0=完整，1=全消失。instance uniform
// ——per-MeshInstance 参数，共享材质零复制开销；不用普通 alpha（透
// 明渲染路径有排序成本且观感糊）。世界坐标 hash 颗粒 discard——像素
// 按其世界位置固定命运，静止物体图案稳定（alpha_scissor render mode
// 4.7 已删，手写 discard 不依赖）
instance uniform float dissolve : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 溶解：世界坐标 3D hash（粒度 ~1/16 格，细密颗粒），h < dissolve
	// 即 discard。dissolve=0 时整体跳过——常驻树零成本
	if (dissolve > 0.0) {
		vec3 cell = floor(world_pos * 16.0);
		float h = fract(sin(dot(cell,
				vec3(12.9898, 78.233, 37.719))) * 43758.5453);
		if (h < dissolve) {
			discard;
		}
	}
	vec4 tex = texture(atlas, UV);
	if (cutout_mode && tex.a < 0.5) {
		discard;
	}
	ALBEDO = tex.rgb * vec3(COLOR.a * u_day);
	EMISSION = tex.rgb * COLOR.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
